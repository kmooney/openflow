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

// ------------------------------------------------- blank lines between them

use openflow_core::{apply_letter_layout, space_paragraphs, Tone};

/// The ask: a model that breaks paragraphs with one newline produces something
/// that still reads as a wall of text. Email shape is blank lines.
#[test]
fn a_sentence_break_becomes_a_blank_line() {
    let out = space_paragraphs("I enjoyed our chat.\nI wrote it up afterwards.");
    assert_eq!(out, "I enjoyed our chat.\n\nI wrote it up afterwards.");
}

#[test]
fn an_existing_blank_line_is_not_doubled() {
    let out = space_paragraphs("One.\n\nTwo.");
    assert_eq!(out, "One.\n\nTwo.");
}

/// A spoken "new line" mid-sentence is not a paragraph break.
#[test]
fn a_line_that_does_not_end_a_sentence_stays_tight() {
    let out = space_paragraphs("12 Rye Lane\nLondon");
    assert_eq!(out, "12 Rye Lane\nLondon");
}

#[test]
fn a_sign_off_keeps_its_name_on_the_next_line() {
    let out = apply_letter_layout("Hi Cynthia. Thanks for the call. Best, Kevin", Tone::Formal);
    assert!(out.ends_with("Best,\nKevin"), "{out:?}");
    assert!(out.starts_with("Hi Cynthia.\n\n"), "{out:?}");
}

#[test]
fn lists_do_not_get_blank_lines() {
    let out = space_paragraphs("Here it is.\n- one\n- two");
    assert_eq!(out, "Here it is.\n- one\n- two");
}
