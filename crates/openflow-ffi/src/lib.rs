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

        let (out, ok, note) = match &verdict {
            EditVerdict::Pass => (candidate, true, String::new()),
            EditVerdict::Undeclared { dropped, added } => (
                raw.to_string(), false,
                format!("undeclared dropped={:?} added={:?}", dropped, added),
            ),
            EditVerdict::Forbidden(r) => (raw.to_string(), false, format!("forbidden {:?}", r)),
            EditVerdict::OverBudget { edits, changed, of } => (
                raw.to_string(), false,
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
