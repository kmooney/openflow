//! C ABI over `openflow-core`, consumed by the Swift clients on macOS and iOS.
//!
//! One call in, JSON out. The surface is deliberately tiny: everything that has
//! to be *correct* (formatting, normalization, the ledger) stays in Rust and is
//! written once; everything platform-shaped (capture, hotkeys, insertion) stays
//! in Swift.

use openflow_core::*;
use std::ffi::{c_char, CStr, CString};

fn esc(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '"' => "\\\"".into(),
            '\\' => "\\\\".into(),
            '\n' => "\\n".into(),
            '\t' => "\\t".into(),
            c if (c as u32) < 0x20 => format!("\\u{:04x}", c as u32),
            c => c.to_string(),
        })
        .collect()
}

fn tone_from(v: u32) -> Tone {
    match v {
        1 => Tone::Casual,
        2 => Tone::VeryCasual,
        _ => Tone::Formal,
    }
}

/// Format a raw transcript. `tone`: 0 formal, 1 casual, 2 very casual.
/// Returns owned JSON; the caller must pass it to `of_string_free`.
///
/// Never returns null and never panics across the boundary: on any internal
/// failure it returns the input unchanged with `"ok":false`, because dropping
/// the user's words is worse than dropping the formatting.
#[no_mangle]
pub extern "C" fn of_format(input: *const c_char, tone: u32) -> *mut c_char {
    let fallback = || CString::new("{\"ok\":false,\"formatted\":\"\"}").unwrap().into_raw();
    if input.is_null() {
        return fallback();
    }
    let raw = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s.trim(),
        Err(_) => return fallback(),
    };

    let res = std::panic::catch_unwind(|| {
        let cfg = Config::default();
        let policy = Policy::default();
        let tone = tone_from(tone);

        let (formatted, edits) = format_with_edits(raw, &cfg);
        let candidate = apply_letter_layout(&formatted, tone);
        let verdict = check_declared(raw, &candidate, &edits, &policy, &cfg);

        // The verdict is **reported, not enforced.**
        //
        // It used to replace the formatted text with the raw transcript on any
        // undeclared difference. That assumed the transcript was the thing to
        // preserve, and it is not: whisper hears "h-t-t-p-s colon slash slash
        // kevin dash mooney dot com", which is right about the sounds and
        // wrong about the text. Reconstructing that address changes nearly
        // every word, so the guardrail reverted the one pass whose entire job
        // was fixing what whisper got wrong.
        //
        // Checking an output against an input that is itself flawed only
        // enforces the flaw. What replaces it is an audit trail: every stage's
        // output is recorded, so a bad transformation is visible and deletable
        // rather than prevented in advance.
        let out = candidate;
        let (ok, note) = match &verdict {
            EditVerdict::Pass => (true, String::new()),
            EditVerdict::Undeclared { dropped, added } => (
                false,
                format!("undeclared dropped={:?} added={:?}", dropped, added),
            ),
            EditVerdict::Forbidden(r) => (false, format!("forbidden {:?}", r)),
            EditVerdict::OverBudget { edits, changed, of } => (
                false,
                format!("over budget: {} edits, {} of {} words", edits, changed, of),
            ),
        };

        let ledger: Vec<String> = edits
            .iter()
            .map(|e| {
                format!(
                    "{{\"from\":\"{}\",\"to\":\"{}\",\"why\":\"{:?}\"}}",
                    esc(&e.from), esc(&e.to), e.reason
                )
            })
            .collect();

        // words *spoken* is the raw count -- what the user actually said,
        // before any cleanup. That is the number worth reporting back.
        let spoken = raw.split_whitespace().count();
        let written = out.split_whitespace().count();

        format!(
            "{{\"ok\":{},\"formatted\":\"{}\",\"raw\":\"{}\",\"note\":\"{}\",\
             \"spokenWords\":{},\"writtenWords\":{},\"ledger\":[{}]}}",
            ok, esc(&out), esc(raw), esc(&note), spoken, written, ledger.join(",")
        )
    });

    match res.ok().and_then(|s| CString::new(s).ok()) {
        Some(c) => c.into_raw(),
        None => fallback(),
    }
}

/// Free a string returned by this library.
#[no_mangle]
pub extern "C" fn of_string_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(CString::from_raw(p)) };
    }
}

#[no_mangle]
pub extern "C" fn of_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// Build the polish prompt for one utterance.
///
/// `vocabulary` is a newline-separated list; empty means none. Returns owned
/// UTF-8 that the caller frees with `of_string_free`.
///
/// Here rather than in each client so that macOS, iOS and Windows ask the model
/// the same question. The inference itself is per-platform — the same split
/// whisper already has — but the prompt is exactly the part that must not drift.
#[no_mangle]
pub extern "C" fn of_polish_prompt(
    transcript: *const c_char,
    vocabulary: *const c_char,
    simple: u32,
) -> *mut c_char {
    let empty = || CString::new("").unwrap().into_raw();
    if transcript.is_null() {
        return empty();
    }
    let text = match unsafe { CStr::from_ptr(transcript) }.to_str() {
        Ok(s) => s,
        Err(_) => return empty(),
    };
    let vocab: Vec<String> = if vocabulary.is_null() {
        Vec::new()
    } else {
        unsafe { CStr::from_ptr(vocabulary) }
            .to_str()
            .unwrap_or("")
            .lines()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .map(|l| l.to_string())
            .collect()
    };
    let style = if simple != 0 {
        openflow_core::polish::Style::Tidy
    } else {
        openflow_core::polish::Style::Repair
    };
    CString::new(openflow_core::polish::prompt(text, &vocab, style))
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// Salvage usable text from a model's reply, falling back to the transcript.
#[no_mangle]
pub extern "C" fn of_polish_clean(
    reply: *const c_char,
    transcript: *const c_char,
) -> *mut c_char {
    let empty = || CString::new("").unwrap().into_raw();
    if reply.is_null() || transcript.is_null() {
        return empty();
    }
    let (r, t) = unsafe {
        (
            CStr::from_ptr(reply).to_str().unwrap_or(""),
            CStr::from_ptr(transcript).to_str().unwrap_or(""),
        )
    };
    CString::new(openflow_core::polish::clean(r, t))
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// Where this speaker's paragraph breaks fall, from the gaps in one utterance.
///
/// Shared so every client breaks paragraphs at the same place. The loop that
/// joins whisper's segments is a few lines and belongs with the whisper binding
/// on each platform; deciding what counts as a pause is the part that must not
/// drift.
///
/// `gaps` is `count` inter-segment gaps in milliseconds. A null pointer or a
/// short list yields the fixed default.
///
/// # Safety
/// `gaps` must point to `count` readable `int64_t` values, or be null.
#[no_mangle]
pub unsafe extern "C" fn of_paragraph_threshold_ms(gaps: *const i64, count: usize) -> i64 {
    if gaps.is_null() || count == 0 {
        return openflow_core::polish::PARAGRAPH_GAP_MS;
    }
    let slice = unsafe { std::slice::from_raw_parts(gaps, count) };
    openflow_core::polish::paragraph_threshold_ms(slice)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn format_through_ffi(s: &str) -> String {
        let input = CString::new(s).unwrap();
        let p = of_format(input.as_ptr(), 0);
        let out = unsafe { CStr::from_ptr(p) }.to_string_lossy().to_string();
        of_string_free(p);
        out
    }

    /// The whole point of reporting the verdict instead of enforcing it.
    ///
    /// Reconstructing an address changes nearly every word, so the guardrail
    /// called it an undeclared rewrite and handed back the raw transcript --
    /// reverting the one pass whose job was fixing what whisper got wrong.
    #[test]
    fn a_rebuilt_address_survives_the_verdict() {
        let out = format_through_ffi(
            "my site is h-t-t-p-s colon slash slash kevin dash mooney dot com",
        );
        assert!(
            out.contains("https://kevin-mooney.com"),
            "the address must reach the user, whatever the verdict says: {out}"
        );
    }

    #[test]
    fn an_email_survives_the_verdict() {
        let out = format_through_ffi("reach me at kevin at gmail dot com");
        assert!(out.contains("kevin@gmail.com"), "{out}");
    }

    /// Reported, not enforced -- the note still records what the check thought,
    /// so the audit trail can show it.
    #[test]
    fn the_verdict_is_still_reported() {
        let out = format_through_ffi(
            "my site is h-t-t-p-s colon slash slash kevin dash mooney dot com",
        );
        assert!(out.contains("\"ok\":false"), "the check still runs: {out}");
    }

    /// Ordinary prose is untouched and still passes cleanly.
    #[test]
    fn prose_is_unaffected() {
        let out = format_through_ffi("the dot com boom was wild");
        assert!(out.contains("dot com boom"), "{out}");
        assert!(out.contains("\"ok\":true"), "{out}");
    }
}
