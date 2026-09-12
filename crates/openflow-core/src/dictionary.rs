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

use crate::{Edit, EditReason};

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
///
/// A **structural** entry -- one whose replacement is whitespace, like
/// `new graf = \n\n` -- also eats the punctuation on the side it touches.
/// Said aloud, "call me at my number, new graf. I'm grateful" leaves a comma
/// and a full stop stranded around the break:
///
/// ```text
///     ...call me at (518) 588-3929,
///
///     . I'm grateful...
/// ```
///
/// Those marks belonged to the spoken instruction, not to the sentence.
/// Punctuation beside an ordinary text entry is left exactly where it is: the
/// full stop in "reach me at my email." is the writer's, and dropping it would
/// be the same mistake in the other direction.
pub fn apply(s: &str, entries: &[Entry]) -> (String, Vec<Edit>) {
    let mut out = s.to_string();
    let mut edits = Vec::new();

    for entry in entries {
        let words = phrase_words(&entry.phrase);
        if words.is_empty() {
            continue;
        }
        let eats_before = entry.replacement.starts_with(char::is_whitespace);
        let eats_after = entry.replacement.ends_with(char::is_whitespace);
        let opens_paragraph = entry.replacement.ends_with('\n');

        // Search forward from the end of each replacement rather than
        // restarting: an entry whose replacement contains its own phrase
        // ("my email = my email is kevin@...") would otherwise expand forever.
        let mut from = 0usize;
        while from < out.len() {
            let Some((a, b)) = match_phrase(&out[from..], &words) else {
                break;
            };
            let (mut a, mut b) = (from + a, from + b);
            if eats_before {
                a = trim_back(&out, a);
            }
            if eats_after {
                b = trim_forward(&out, b);
            }
            let mut tail = out[b..].to_string();
            if opens_paragraph {
                // The deterministic pass capitalized sentences before this ran,
                // so a break introduced here starts on whatever case whisper
                // heard -- "best kevin" rather than "Best kevin".
                capitalize_first(&mut tail);
            }
            out = format!("{}{}{}", &out[..a], entry.replacement, tail);
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

/// Split a phrase into bare, lower-cased words.
fn phrase_words(phrase: &str) -> Vec<String> {
    phrase.split_whitespace().map(bare).filter(|w| !w.is_empty()).collect()
}

fn bare(token: &str) -> String {
    token
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '\'')
        .collect::<String>()
        .to_lowercase()
}

/// Find the phrase in the text, ignoring how whisper spaced and punctuated it.
///
/// Matched on the letters of whole words rather than as a literal string,
/// because a longer trigger is the best defence against a mishearing -- and a
/// longer trigger is exactly what whisper rewrites on the way out. "open flow
/// new paragraph" comes back as "OpenFlow, new paragraph.": a comma nobody
/// said, and two words joined into one. A substring search finds neither, which
/// would make the safest trigger the one least likely to fire.
///
/// Word boundaries still hold at both ends -- "cat" does not match "catalogue"
/// -- because only whole words are ever accumulated.
fn match_phrase(hay: &str, words: &[String]) -> Option<(usize, usize)> {
    let target: String = words.concat();
    let spans = word_spans(hay);

    for i in 0..spans.len() {
        let mut acc = String::new();
        for span in &spans[i..] {
            acc.push_str(&span.2);
            if acc.len() > target.len() || !target.starts_with(&acc) {
                break;
            }
            if acc == target {
                return Some((spans[i].0, span.1));
            }
        }
    }
    None
}

/// Every run of word characters, as (start, end, lower-cased text).
fn word_spans(hay: &str) -> Vec<(usize, usize, String)> {
    let mut spans = Vec::new();
    let mut start: Option<usize> = None;
    for (i, c) in hay.char_indices() {
        let part = c.is_alphanumeric() || c == '\'';
        match (part, start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                spans.push((s, i, hay[s..i].to_lowercase()));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        spans.push((s, hay.len(), hay[s..].to_lowercase()));
    }
    spans
}

/// Whitespace and the marks that cling to a spoken instruction. Not `-`, which
/// is part of words, and not a quote, which has a partner elsewhere.
fn is_trimmable(c: char) -> bool {
    c.is_whitespace() || matches!(c, ',' | '.' | ';' | ':' | '!' | '?')
}

/// Walk `at` back over trimmable characters, stopping at a line break: a
/// paragraph that is already there is not punctuation to absorb.
fn trim_back(s: &str, at: usize) -> usize {
    let mut at = at;
    while let Some(c) = s[..at].chars().next_back() {
        if !is_trimmable(c) || c == '\n' {
            break;
        }
        at -= c.len_utf8();
    }
    at
}

fn trim_forward(s: &str, at: usize) -> usize {
    let mut at = at;
    while let Some(c) = s[at..].chars().next() {
        if !is_trimmable(c) || c == '\n' {
            break;
        }
        at += c.len_utf8();
    }
    at
}

fn capitalize_first(s: &mut String) {
    let Some(i) = s.char_indices().find(|(_, c)| c.is_alphabetic()).map(|(i, _)| i) else {
        return;
    };
    let c = s[i..].chars().next().unwrap();
    if c.is_uppercase() {
        return;
    }
    // Only if nothing but whitespace precedes it -- otherwise this is the
    // middle of a sentence the replacement was inserted into.
    if !s[..i].chars().all(char::is_whitespace) {
        return;
    }
    let upper: String = c.to_uppercase().collect();
    s.replace_range(i..i + c.len_utf8(), &upper);
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

    /// Verbatim from the phone: "new graf" is a spoken instruction, and the
    /// comma and full stop around it belonged to the instruction.
    #[test]
    fn a_structural_entry_eats_the_punctuation_it_leaves_behind() {
        let d = parse(r"new graf = \n\n");
        let (out, _) = apply(
            "You can call me at (518) 588-3929, new graf. I'm grateful for your time, new graf, best Kevin.",
            &d,
        );
        assert_eq!(
            out,
            "You can call me at (518) 588-3929\n\nI'm grateful for your time\n\nBest Kevin."
        );
    }

    /// The other direction: an ordinary entry must not swallow the writer's
    /// own full stop.
    #[test]
    fn a_text_entry_leaves_punctuation_alone() {
        let d = parse("my email = kevin@example.com");
        let (out, _) = apply("Reach me at my email.", &d);
        assert_eq!(out, "Reach me at kevin@example.com.");
    }

    /// The user's own suggestion: a longer trigger is harder to mishear. It is
    /// also the one whisper rewrites most -- a comma nobody said, and "open
    /// flow" written as "OpenFlow" -- so the match has to survive both.
    #[test]
    fn a_sentence_length_trigger_survives_whispers_punctuation() {
        let d = parse(r"open flow new paragraph = \n\n");
        let (out, edits) = apply(
            "That is the plan. OpenFlow, new paragraph. Let me know what you think.",
            &d,
        );
        assert_eq!(out, "That is the plan\n\nLet me know what you think.");
        assert_eq!(edits.len(), 1);
    }

    /// Consecutive words only -- the gap between them may be punctuation, never
    /// another word.
    #[test]
    fn words_of_a_phrase_must_be_adjacent() {
        let d = parse("my email = k@x.com");
        let (out, _) = apply("my very old email", &d);
        assert_eq!(out, "my very old email");
    }

    #[test]
    fn every_occurrence_is_replaced() {
        let d = parse("my email = k@x.com");
        let (out, edits) = apply("my email, and again my email", &d);
        assert_eq!(out, "k@x.com, and again k@x.com");
        assert_eq!(edits.len(), 2);
    }
}
