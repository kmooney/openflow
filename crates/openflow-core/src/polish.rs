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
/// Three rules, in the order they matter:
///
/// 1. **Repair only.** A model asked to "improve" dictation rewrites it, and a
///    rewrite of someone's message is not a transcription of it.
/// 2. **Use the known terms exactly.** This is the whole reason vocabulary is
///    passed at all: a garbled address is a matching problem when the right
///    string is in front of the model, and a guessing problem when it is not.
/// 3. **Answer with the text alone.** Small models narrate otherwise, and a
///    preamble pasted into someone's message is worse than no polish.
const INSTRUCTIONS: &str = "\
You repair dictation. A speech recogniser produced the line below; it often \
writes punctuation and spelled-out letters as words (\"dot\", \"dash\", \
\"colon\", \"at\", \"k e v i n\").

Rewrite it as the text the speaker meant.
- Fix only transcription artefacts. Do not add, remove, or reword content.
- Rebuild web and email addresses. If one matches a known term, use that term exactly.
- Reply with the corrected text only. No preamble, no explanation, no quotes.";

/// Build the prompt for one utterance.
///
/// `vocabulary` is the user's terms — names, domains, jargon — and is the
/// single most valuable thing in the prompt. Whisper's own biasing is capped by
/// a 448-token context it shares with the transcript; here the list is cheap,
/// and it converts the model's riskiest failure into its most reliable
/// behaviour.
pub fn prompt(transcript: &str, vocabulary: &[String]) -> String {
    let mut out = String::with_capacity(transcript.len() + 512);
    out.push_str(INSTRUCTIONS);
    if !vocabulary.is_empty() {
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

    // Qwen3 emits its reasoning inline unless thinking is disabled, and
    // disabling it is a per-model flag the caller may not have set.
    if let Some(end) = s.find("</think>") {
        s = s[end + "</think>".len()..].trim();
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
    const ECHOES: &[&str] = &[
        "Fix only transcription artefacts",
        "Reply with the corrected text only",
        "Rebuild web and email addresses",
        "You repair dictation",
        "Known terms:",
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
        let p = prompt("k e v i n dot com", &["kevin-mooney.com".to_string()]);
        assert!(p.contains("Known terms: kevin-mooney.com"));
        assert!(p.trim_end().ends_with("k e v i n dot com"));
    }

    #[test]
    fn no_vocabulary_means_no_empty_section() {
        let p = prompt("hello", &[]);
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
        let echo = "- Fix only transcription artefacts. Do not add, remove, or reword content.\n\
                    - Reply with the corrected text only. No preamble, no explanation, no quotes.";
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
