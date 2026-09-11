//! Paragraphs the polish model produced must survive the deterministic pass.
//!
//! They did not: `apply_addresses` and `apply_quotes` each flattened the whole
//! message with `split_whitespace`, so the model laid out a two-paragraph
//! email and the formatter put it straight back into one block, two stages
//! later, with nothing in the audit trail pointing at it.

use openflow_core::*;

const EMAIL: &str = "Hi, Cynthia. I hope this email finds you well.\n\nI'd be delighted if this could be included. Thanks again for your time. Best, Kevin.";

#[test]
fn paragraphs_survive_every_tone() {
    for tone in [Tone::Formal, Tone::Casual, Tone::VeryCasual] {
        let (formatted, _) = format_with_edits(EMAIL, &Config::default());
        let out = apply_letter_layout(&formatted, tone);
        // Case-insensitive: the very casual register lower-cases everything,
        // so the assertion is about the break, not the capital.
        assert!(out.to_lowercase().contains("\n\ni'd be delighted"),
                "paragraph lost for {tone:?}:\n{out}");
    }
}

#[test]
fn the_address_pass_keeps_newlines() {
    let s = "Go to kevin dash mooney dot com.\n\nThen tell me.";
    let out = apply_addresses(s);
    assert!(out.contains("kevin-mooney.com"), "the address must still be rebuilt: {out}");
    assert!(out.contains("\n\nThen tell me"), "the paragraph must survive: {out}");
}

#[test]
fn the_quote_pass_keeps_newlines() {
    assert!(apply_quotes("One.\n\nTwo.").contains("\n\nTwo"));
}

/// Several paragraphs, not just two.
#[test]
fn many_paragraphs_survive() {
    let s = "One.\n\nTwo.\n\nThree.\n\nFour.";
    let (out, _) = format_with_edits(s, &Config::default());
    assert_eq!(out.matches("\n\n").count(), 3, "got: {out:?}");
}

/// The body must never come back as a wall of text, whatever the model did or
/// did not do. Every other mechanism tried — a 0.6B model, the speaker's own
/// pauses — worked sometimes; this one is the floor under them.
#[test]
fn a_long_body_is_broken_up() {
    let raw = "Hi Cynthia, I hope this email finds you well. I enjoyed our chat on Wednesday. \
               One of the questions you asked me triggered a bit of reflection, so I extended my \
               answer into a longer essay and published it at my website. You can find that essay \
               at https://kevin-mooney.com. I'd be delighted if this could be included as part of \
               my application, but even if it can't be, I think some people on your team may find \
               it interesting. Thanks again for your time. Best, Kevin.";
    let (formatted, _) = format_with_edits(raw, &Config::default());
    let out = apply_letter_layout(&formatted, Tone::Formal);
    assert!(out.matches("\n\n").count() >= 2, "still a wall of text:\n{out}");
    assert!(out.starts_with("Hi Cynthia,"), "salutation lost:\n{out}");
    assert!(out.contains("Best,\nKevin"), "signature lost:\n{out}");
}

/// A short message is left exactly as it was.
#[test]
fn a_short_message_is_not_chopped_up() {
    let raw = "Tell him I am running late. I will be there by four.";
    let (formatted, _) = format_with_edits(raw, &Config::default());
    assert!(!apply_letter_layout(&formatted, Tone::Formal).contains("\n\n"));
}

/// A model that laid the message out properly must not be overruled.
#[test]
fn existing_paragraphs_are_respected() {
    let s = "One. Two. Three. Four.\n\nFive. Six. Seven. Eight. Nine. Ten. Eleven. Twelve. \
             Thirteen. Fourteen. Fifteen. Sixteen. Seventeen. Eighteen. Nineteen. Twenty. \
             Twenty one. Twenty two. Twenty three. Twenty four. Twenty five. Twenty six. \
             Twenty seven. Twenty eight. Twenty nine. Thirty. Thirty one. Thirty two.";
    assert_eq!(ensure_paragraphs(s, 55, 3), s);
}
