//! Everything about the polish stage except running the model.
//!
//! Inference itself is per-platform — Swift talks to llama.cpp directly on
//! Apple the way `Transcriber` already talks to whisper.cpp, and Windows does
//! the same from Rust. What must **not** differ between them is what the model
//! is asked and what is done with its answer, so that lives here and is shared
//! through the FFI the clients already link.
//!
//! The instructions below were not guessed. They are the prompt that made an
//! 8B model repair every real transcript captured from a phone, kept
//! deliberately narrow because the failure mode of a small model is not a worse
//! answer, it is a confident invention.

/// What the model is told, and what it is told not to do.
///
/// **Deliberately permissive about small edits.** An earlier version said "fix
/// only transcription artefacts, do not add, remove, or reword" and was so
/// narrow it did nothing: two real emails in a row came back byte-identical,
/// one of them still carrying the abandoned opening "I wanted to...". A stage
/// that costs two and a half seconds and changes nothing is worse than no
/// stage at all.
///
/// The licence is justified by how the tool is used: short text, pasted where
/// the user is already looking, reviewed before it is sent. A small edit that
/// is wrong costs a correction; a false start left in costs the same
/// correction, and the tool exists to save typing.
///
/// What stays absolute is the last rule. Adding content is the one failure the
/// user cannot catch by reading, because invented text reads exactly like
/// text they wrote.
const INSTRUCTIONS: &str = "\
You tidy dictation. A speech recogniser produced the line below; it often \
writes punctuation and spelled-out letters as words (\"dot\", \"dash\", \
\"colon\", \"at\", \"k e v i n\").

Rewrite it as the text the speaker meant to write.
- Fix transcription mistakes, and drop abandoned false starts and filler words.
- Rebuild web and email addresses. If one matches a known term, use that term exactly.
- Start a new paragraph where the subject changes.
- Keep the speaker\'s words and meaning. Do not add anything they did not say.
- Reply with the text only. No preamble, no explanation, no quotes.";

/// A narrower job, for models too small for the full repair.
///
/// SmolLM2 360M answers the instructions above by repeating them — measured on
/// a phone and on a desktop, so it is the model's ceiling rather than a
/// delivery problem. Asking less of it is the only lever left that does not
/// involve a bigger download: two concrete jobs, no conditionals, no "if one
/// matches a known term".
const SIMPLE_INSTRUCTIONS: &str = "Tidy this dictated text.
- Write any email or web address the normal way.
- Start a new paragraph where the subject changes.
- Change nothing else.
Reply with the text only.";

/// Which instructions a model gets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    /// The full repair, for models that can follow it.
    Repair,
    /// Two jobs only, for models that cannot.
    Tidy,
}

/// Build the prompt for one utterance.
///
/// `vocabulary` is the user's terms — names, domains, jargon — and is the
/// single most valuable thing in the prompt. Whisper's own biasing is capped by
/// a 448-token context it shares with the transcript; here the list is cheap,
/// and it converts the model's riskiest failure into its most reliable
/// behaviour.
pub fn prompt(transcript: &str, vocabulary: &[String], style: Style) -> String {
    let mut out = String::with_capacity(transcript.len() + 512);
    out.push_str(match style {
        Style::Repair => INSTRUCTIONS,
        Style::Tidy => SIMPLE_INSTRUCTIONS,
    });
    // A model that cannot follow three instructions will not use a glossary
    // either, and every extra line is one more thing for it to echo.
    if style == Style::Repair && !vocabulary.is_empty() {
        out.push_str("\n\nKnown terms: ");
        out.push_str(&vocabulary.join(", "));
    }
    out.push_str("\n\nLine:\n");
    out.push_str(transcript.trim());
    out
}

/// Salvage usable text from whatever the model returned.
///
/// Small models ignore "reply with the text only" often enough that this is not
/// defensive programming, it is the normal path. Every rule here corresponds to
/// something a model on the catalogue actually did.
pub fn clean(reply: &str, transcript: &str) -> String {
    let mut s = reply.trim();

    // Qwen3 emits its reasoning inline unless thinking is disabled.
    if let Some(end) = s.find("</think>") {
        s = s[end + "</think>".len()..].trim();
    } else if s.contains("<think>") {
        // Opened and never closed: the model spent its whole token budget
        // reasoning and never reached an answer. Measured on Qwen3 0.6B, which
        // burned all 256 tokens describing what it was about to do. There is no
        // answer in there to salvage.
        return transcript.trim().to_string();
    }

    // "Here is the rewritten line:" and friends.
    //
    // Matched on task words rather than on shape. The first attempt stripped
    // any short line ending in a colon, which also ate "Here are the three
    // things I need:" -- a sentence someone might well dictate, and exactly
    // the kind of false positive that is invisible until it deletes a line of
    // a message.
    const PREAMBLE_MARKERS: &[&str] = &[
        "rewritten", "corrected", "output", "result", "answer", "revised",
        "repaired", "version", "plain text",
    ];
    if let Some((head, tail)) = s.split_once('\n') {
        let h = head.trim_end();
        let lower = h.to_ascii_lowercase();
        if h.ends_with(':')
            && !tail.trim().is_empty()
            && PREAMBLE_MARKERS.iter().any(|m| lower.contains(m))
        {
            s = tail.trim();
        }
    }

    // Models quote their answer even when told not to.
    let quoted = (s.starts_with('"') && s.ends_with('"'))
        || (s.starts_with('\u{201c}') && s.ends_with('\u{201d}'));
    if quoted && s.chars().count() > 2 {
        let mut c = s.chars();
        c.next();
        c.next_back();
        s = c.as_str().trim();
    }

    // A model too small to follow the instruction repeats it instead. Measured
    // on SmolLM2 360M, which returns the bullet list verbatim both on a phone
    // and through ollama on a desktop -- so this is the model's ceiling, not a
    // delivery problem. Pasting the instructions into someone's message is the
    // worst outcome available, and it is cheap to refuse.
    //
    // Both prompts are listed. The first version only knew the full repair's
    // phrases, so switching a model to the narrower prompt would have let it
    // echo *those* instructions straight into someone's message instead.
    const ECHOES: &[&str] = &[
        // the full tidy
        "Fix transcription mistakes",
        "drop abandoned false starts",
        "Rebuild web and email addresses",
        "You tidy dictation",
        "Known terms:",
        // the narrower job
        "Tidy this dictated text",
        "Write any email or web address the normal way",
        "Start a new paragraph where the subject changes",
        "Reply with the text only",
    ];
    if ECHOES.iter().any(|e| s.contains(e)) {
        return transcript.trim().to_string();
    }

    // A refusal, an empty answer, or an essay: keep what the user said. Losing
    // the utterance is far worse than leaving it unpolished, and an answer
    // several times longer than the input is never a repair.
    if s.is_empty() || s.chars().count() > transcript.chars().count() * 3 + 80 {
        return transcript.trim().to_string();
    }
    s.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vocabulary_reaches_the_prompt() {
        let p = prompt("k e v i n dot com", &["kevin-mooney.com".to_string()], Style::Repair);
        assert!(p.contains("Known terms: kevin-mooney.com"));
        assert!(p.trim_end().ends_with("k e v i n dot com"));
    }

    #[test]
    fn no_vocabulary_means_no_empty_section() {
        let p = prompt("hello", &[], Style::Repair);
        assert!(!p.contains("Known terms"));
    }

    #[test]
    fn strips_reasoning() {
        assert_eq!(
            clean("<think>the user wants...</think>\nhttps://kevin-mooney.com", "x"),
            "https://kevin-mooney.com"
        );
    }

    #[test]
    fn strips_a_preamble_line() {
        assert_eq!(
            clean("Here is the rewritten line:\nhttps://kevin-mooney.com", "x"),
            "https://kevin-mooney.com"
        );
    }

    /// A real sentence that happens to end in a colon must survive.
    #[test]
    fn keeps_a_legitimate_colon_ending() {
        let s = "Here are the three things I need:\nmilk, bread, eggs";
        assert_eq!(clean(s, s), s);
    }

    #[test]
    fn strips_quotes() {
        assert_eq!(clean("\"hello there\"", "hello there"), "hello there");
    }

    /// The safety net: anything that is obviously not a repair falls back to
    /// what the user actually said.
    #[test]
    fn an_essay_falls_back_to_the_transcript() {
        let t = "meet me at noon";
        let essay = "I would be happy to help you with that! ".repeat(20);
        assert_eq!(clean(&essay, t), t);
    }

    #[test]
    fn an_empty_answer_falls_back() {
        assert_eq!(clean("   ", "meet me at noon"), "meet me at noon");
    }
}

#[cfg(test)]
mod preamble_tests {
    use super::clean;

    /// Every one of these is a preamble a model on the catalogue actually
    /// produced, or a near variant of one.
    #[test]
    fn strips_the_preambles_models_write() {
        for head in [
            "Here is the rewritten line:",
            "Corrected text:",
            "Output:",
            "Here is the rewritten line as plain text:",
            "Revised version:",
        ] {
            let reply = format!("{head}\nhttps://kevin-mooney.com");
            assert_eq!(clean(&reply, "x"), "https://kevin-mooney.com", "failed on {head}");
        }
    }

    /// And every one of these is a line someone might dictate.
    #[test]
    fn keeps_sentences_that_end_in_a_colon() {
        for s in [
            "Here are the three things I need:\nmilk, bread, eggs",
            "Agenda:\nbudget, hiring, launch date",
            "Tell them this:\nwe ship on Friday",
        ] {
            assert_eq!(clean(s, s), s, "wrongly stripped: {s}");
        }
    }
}

#[cfg(test)]
mod echo_tests {
    use super::clean;

    /// What SmolLM2 360M actually returns, verbatim.
    #[test]
    fn a_prompt_echo_falls_back_to_the_transcript() {
        let transcript = "so I think we should be good to go";
        let echo = "- Fix transcription mistakes, and drop abandoned false starts and filler words.\n\
                    - Rebuild web and email addresses. If one matches a known term, use that term exactly.";
        assert_eq!(clean(echo, transcript), transcript);
    }

    #[test]
    fn a_partial_echo_is_caught_too() {
        let t = "meet me at noon";
        assert_eq!(clean("Known terms: kevin-mooney.com\n\nLine:\nmeet", t), t);
    }

    /// And a genuine repair still passes through untouched.
    #[test]
    fn a_real_answer_survives() {
        assert_eq!(
            clean("https://kevin-mooney.com", "k e v i n dot com"),
            "https://kevin-mooney.com"
        );
    }
}

#[cfg(test)]
mod style_tests {
    use super::*;

    #[test]
    fn tidy_asks_for_two_jobs_and_no_glossary() {
        let p = prompt("hello there", &["kevin-mooney.com".to_string()], Style::Tidy);
        assert!(p.contains("Start a new paragraph"));
        assert!(p.contains("email or web address"));
        assert!(!p.contains("Known terms"),
                "a model that cannot follow three rules will not use a glossary");
        assert!(!p.contains("transcription mistakes"));
    }

    #[test]
    fn repair_is_unchanged() {
        let p = prompt("hello", &["a-term".to_string()], Style::Repair);
        assert!(p.contains("Fix transcription mistakes"));
        assert!(p.contains("Known terms: a-term"));
    }
}

#[cfg(test)]
mod tidy_echo_tests {
    use super::clean;

    /// The narrower prompt has to be echo-protected too, or switching a model
    /// to it simply changes which instructions get pasted into a message.
    #[test]
    fn an_echo_of_the_tidy_prompt_falls_back() {
        let t = "meet me at noon";
        for echo in [
            "Tidy this dictated text.\n- Write any email or web address the normal way.",
            "- Start a new paragraph where the subject changes.\n- Change nothing else.",
            "Reply with the text only.",
        ] {
            assert_eq!(clean(echo, t), t, "not caught: {echo}");
        }
    }
}

#[cfg(test)]
mod unclosed_think_tests {
    use super::clean;

    /// Qwen3 0.6B burning its whole token budget on reasoning, verbatim in
    /// shape: a `<think>` that never closes because the answer never arrived.
    #[test]
    fn reasoning_that_never_finishes_falls_back() {
        let t = "Hi John, I hope this finds you well.";
        let all_thinking = "<think>\nOkay, let's start by looking at the original line \
                            and the corrections needed. First, the line starts with";
        assert_eq!(clean(all_thinking, t), t);
    }

    /// Closed reasoning still yields whatever followed it.
    #[test]
    fn closed_reasoning_yields_the_answer() {
        assert_eq!(clean("<think>hmm</think>\nHi John,", "x"), "Hi John,");
    }
}
