//! The bridge into `openflow-core`.
//!
//! The Swift clients reach the core through a C ABI because Swift cannot link a
//! Rust crate directly. This client is Rust, so it calls the same functions
//! with no boundary in between -- but it must produce *identical* output,
//! including the ledger's JSON shape, or a history database written on Windows
//! would not read the same as one written on a Mac. This mirrors
//! `crates/openflow-ffi/src/lib.rs` deliberately and closely.

use openflow_core::{
    apply_letter_layout, check_declared, format_with_edits, Config, EditVerdict, Policy,
};
use serde::{Deserialize, Serialize};

use crate::kit::tone::Tone;

/// One word the formatter changed, and why.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LedgerEntry {
    pub from: String,
    pub to: String,
    pub why: String,
}

impl LedgerEntry {
    /// Human-readable for the history UI.
    pub fn description(&self) -> String {
        if self.to.is_empty() {
            format!("removed \u{201c}{}\u{201d} ({})", self.from, self.why)
        } else {
            format!(
                "\u{201c}{}\u{201d} \u{2192} \u{201c}{}\u{201d} ({})",
                self.from, self.to, self.why
            )
        }
    }

    /// Decode the JSON blob the store keeps per utterance.
    pub fn decode(json: &str) -> Vec<LedgerEntry> {
        serde_json::from_str(json).unwrap_or_default()
    }
}

#[derive(Clone, Debug)]
pub struct FormatResult {
    pub ok: bool,
    pub formatted: String,
    pub raw: String,
    pub note: String,
    /// Words the user actually said, before any cleanup. This is the number
    /// worth reporting back to them.
    pub spoken_words: usize,
    pub ledger: Vec<LedgerEntry>,
}

impl FormatResult {
    pub fn ledger_json(&self) -> String {
        serde_json::to_string(&self.ledger).unwrap_or_else(|_| "[]".into())
    }
}

/// Format a raw transcript.
///
/// Never panics out of here: on any internal failure it returns the input
/// unchanged with `ok: false`, because dropping the user's words is worse than
/// dropping the formatting.
pub fn format(raw: &str, tone: Tone) -> FormatResult {
    let raw = raw.trim().to_string();
    let attempt = std::panic::catch_unwind({
        let raw = raw.clone();
        move || {
            let cfg = Config::default();
            let policy = Policy::default();

            let (formatted, edits) = format_with_edits(&raw, &cfg);
            let candidate = apply_letter_layout(&formatted, tone.core());
            let verdict = check_declared(&raw, &candidate, &edits, &policy, &cfg);

            let (out, ok, note) = match &verdict {
                EditVerdict::Pass => (candidate, true, String::new()),
                EditVerdict::Undeclared { dropped, added } => (
                    raw.clone(),
                    false,
                    format!("undeclared dropped={dropped:?} added={added:?}"),
                ),
                EditVerdict::Forbidden(r) => (raw.clone(), false, format!("forbidden {r:?}")),
                EditVerdict::OverBudget { edits, changed, of } => (
                    raw.clone(),
                    false,
                    format!("over budget: {edits} edits, {changed} of {of} words"),
                ),
            };

            let ledger: Vec<LedgerEntry> = edits
                .iter()
                .map(|e| LedgerEntry {
                    from: e.from.clone(),
                    to: e.to.clone(),
                    why: format!("{:?}", e.reason),
                })
                .collect();

            FormatResult {
                spoken_words: raw.split_whitespace().count(),
                ok,
                formatted: out,
                raw,
                note,
                ledger,
            }
        }
    });

    attempt.unwrap_or_else(|_| {
        let words = raw.split_whitespace().count();
        FormatResult {
            ok: false,
            formatted: raw.clone(),
            note: "formatter failed".into(),
            raw,
            spoken_words: words,
            ledger: Vec::new(),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fillers_are_removed_and_the_guardrail_still_passes() {
        let r = format("um so the deploy failed", Tone::Formal);
        assert!(r.ok, "note: {}", r.note);
        assert!(!r.formatted.to_lowercase().starts_with("um"));
    }

    /// The ledger is what makes "Show Original" in the history worth having: a
    /// change the user cannot see is a change we did not declare.
    #[test]
    fn a_spoken_correction_is_declared_in_the_ledger() {
        let r = format("the server is up scratch that the server is down", Tone::Formal);
        assert!(r.ok, "note: {}", r.note);
        assert_eq!(r.formatted, "The server is down");
        assert!(
            r.ledger.iter().any(|e| e.why == "SelfCorrection" && e.to.is_empty()),
            "ledger was {:?}",
            r.ledger
        );
    }

    /// The number reported back is what the user actually said, not what
    /// survived the cleanup.
    #[test]
    fn spoken_words_counts_the_raw_transcript() {
        let r = format("um so the deploy failed", Tone::Formal);
        assert_eq!(r.spoken_words, 5);
    }

    #[test]
    fn the_ledger_round_trips_through_the_store_format() {
        let r = format("um hello there", Tone::Formal);
        let json = r.ledger_json();
        let back = LedgerEntry::decode(&json);
        assert_eq!(back, r.ledger);
    }

    #[test]
    fn a_broken_ledger_blob_decodes_to_nothing_rather_than_failing() {
        assert!(LedgerEntry::decode("not json").is_empty());
        assert!(LedgerEntry::decode("").is_empty());
    }

    #[test]
    fn empty_input_is_handled() {
        let r = format("   ", Tone::Formal);
        assert_eq!(r.spoken_words, 0);
        assert!(r.formatted.is_empty());
    }

    #[test]
    fn tone_reaches_the_core() {
        let formal = format("hey are you around", Tone::Formal);
        let very_casual = format("hey are you around", Tone::VeryCasual);
        assert_ne!(
            formal.formatted, very_casual.formatted,
            "the register has to change something or it is not a setting"
        );
    }

    #[test]
    fn a_ledger_entry_reads_like_english() {
        let removed = LedgerEntry {
            from: "um".into(),
            to: String::new(),
            why: "Filler".into(),
        };
        assert!(removed.description().starts_with("removed"));
        let changed = LedgerEntry {
            from: "gonna".into(),
            to: "going to".into(),
            why: "Contraction".into(),
        };
        assert!(changed.description().contains("\u{2192}"));
    }
}
