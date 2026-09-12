//! The user's dictionary: spoken phrase in, exact text out.
//!
//! "my email" becomes `kevin@example.com`; "my address" becomes a street
//! address with the line breaks intact. This is the one substitution in the
//! pipeline that is entirely the user's instruction, which is why it is
//! deterministic and runs after the model: a polish model asked to expand a
//! shortcut would guess, and a guessed email address is worse than none.
//!
//! Shared so macOS, iOS and Windows read the same file and produce the same
//! text. The file is plain, because the user writes it by hand:
//!
//! ```text
//! # anything after a hash is a comment
//! my email = kevin@example.com
//! my number = (555) 123-4567
//! my sign off = Best,\nKevin
//! ```
//!
//! The replacement is used **verbatim** -- no capitalization, no punctuation
//! repair. If it is an address, it stays lower case at the start of a sentence,
//! which is what an address should do.

use crate::{find_phrase, Edit, EditReason};

/// One phrase and what it expands to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// What the user says. Matched case-insensitively, on word boundaries.
    pub phrase: String,
    /// What is written instead, verbatim.
    pub replacement: String,
}

/// Read the dictionary file.
///
/// Blank lines and `#` comments are skipped. A line with no `=` is skipped too,
/// rather than guessed at -- a half-written entry should do nothing, not
/// something surprising.
///
/// `\n` in the replacement becomes a real newline, so a stored sign-off or
/// postal address keeps its shape. `\\` is a literal backslash.
pub fn parse(text: &str) -> Vec<Entry> {
    let mut out: Vec<Entry> = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((phrase, replacement)) = line.split_once('=') else {
            continue;
        };
        let phrase = phrase.trim().to_lowercase();
        let replacement = unescape(replacement.trim());
        if phrase.is_empty() || replacement.is_empty() {
            continue;
        }
        // Later wins, so editing a line rather than deleting the old one does
        // what the user expects.
        if let Some(existing) = out.iter_mut().find(|e| e.phrase == phrase) {
            existing.replacement = replacement;
            continue;
        }
        out.push(Entry {
            phrase,
            replacement,
        });
    }
    // Longest phrase first: "my work email" must win over "my email", and file
    // order is not something the user should have to think about.
    out.sort_by(|a, b| b.phrase.len().cmp(&a.phrase.len()));
    out
}

fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('\\') => out.push('\\'),
            // An unknown escape keeps both characters: the user typed a
            // backslash for a reason we do not know.
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// Expand every entry, returning the text and one declared `Edit` per
/// substitution so the audit trail can show what was replaced.
pub fn apply(s: &str, entries: &[Entry]) -> (String, Vec<Edit>) {
    let mut out = s.to_string();
    let mut edits = Vec::new();

    for entry in entries {
        // Search forward from the end of each replacement rather than
        // restarting: an entry whose replacement contains its own phrase
        // ("my email = my email is kevin@...") would otherwise expand forever.
        let mut from = 0usize;
        while from < out.len() {
            let Some((a, b)) = find_phrase(&out[from..], &entry.phrase) else {
                break;
            };
            let (a, b) = (from + a, from + b);
            out = format!("{}{}{}", &out[..a], entry.replacement, &out[b..]);
            from = a + entry.replacement.len();
            edits.push(Edit {
                from: entry.phrase.clone(),
                to: entry.replacement.clone(),
                reason: EditReason::Shortcut,
            });
        }
    }
    (out, edits)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_phrase_expands_verbatim() {
        let d = parse("my email = kevin@example.com");
        let (out, edits) = apply("You can reach me at my email any time.", &d);
        assert_eq!(out, "You can reach me at kevin@example.com any time.");
        assert_eq!(edits.len(), 1);
    }

    /// The point of expanding verbatim: an address does not get sentence case.
    #[test]
    fn the_replacement_is_not_recapitalized() {
        let d = parse("my email = kevin@example.com");
        let (out, _) = apply("My email is where to send it.", &d);
        assert!(out.starts_with("kevin@example.com is"), "{out}");
    }

    #[test]
    fn the_longest_phrase_wins() {
        let d = parse("my email = home@x.com\nmy work email = work@y.com");
        let (out, _) = apply("send it to my work email please", &d);
        assert!(out.contains("work@y.com"), "{out}");
        assert!(!out.contains("home@x.com"), "{out}");
    }

    #[test]
    fn word_boundaries_are_respected() {
        let d = parse("cat = dog");
        let (out, edits) = apply("the catalogue", &d);
        assert_eq!(out, "the catalogue");
        assert!(edits.is_empty());
    }

    #[test]
    fn a_self_referential_entry_terminates() {
        let d = parse("my email = my email is kevin@example.com");
        let (out, _) = apply("Here is my email.", &d);
        assert_eq!(out, "Here is my email is kevin@example.com.");
    }

    #[test]
    fn escapes_become_real_newlines() {
        let d = parse(r"my signoff = Best,\nKevin");
        assert_eq!(d[0].replacement, "Best,\nKevin");
    }

    #[test]
    fn comments_and_junk_lines_are_ignored() {
        let d = parse("# a note\n\nno equals sign here\nok = fine\n = nothing\nempty =");
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].phrase, "ok");
    }

    #[test]
    fn every_occurrence_is_replaced() {
        let d = parse("my email = k@x.com");
        let (out, edits) = apply("my email, and again my email", &d);
        assert_eq!(out, "k@x.com, and again k@x.com");
        assert_eq!(edits.len(), 2);
    }
}
