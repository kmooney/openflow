//! The user's word list -- names, places, jargon whisper will not know. The
//! highest-leverage quality control they have (notes/spec.md 5.2), indexed per
//! app (5.2.1).

use std::collections::{HashMap, HashSet};

use crate::kit::context::DictationContext;

/// Whisper's prompt caps around 224 tokens, so a long list has to be trimmed
/// rather than dumped. File order, most important first.
pub const MAX_TERMS: usize = 120;
/// What whisper will actually accept.
pub const PROMPT_TOKEN_BUDGET: usize = 224;

/// A vocabulary split by where it applies.
///
/// The prompt is rebuilt and resent on every transcription -- `whisper_full` is
/// one-shot and keeps no state between calls -- so varying the list by app
/// costs nothing beyond the tokens themselves. That is what makes per-app
/// biasing worth doing: in a terminal "git status" should beat "get status",
/// and in a mail client it should not.
///
/// One file with sections, rather than a file per app: the vocabulary is
/// something the user edits by hand, and scattering it across a directory would
/// make "what have I taught it?" unanswerable at a glance.
///
/// ```text
/// Anthropic                 # before any section: applies everywhere
/// Siobhan
///
/// [wt.exe]                  # only when Windows Terminal has focus
/// git status
/// kubectl
/// ```
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VocabularyBook {
    /// Applies wherever you dictate.
    pub global: Vec<String>,
    /// Keyed by lower-cased executable name, matching `DictationContext::app_id`.
    pub per_app: HashMap<String, Vec<String>>,
}

impl VocabularyBook {
    pub fn parse(text: &str) -> VocabularyBook {
        let mut global: Vec<String> = Vec::new();
        let mut per_app: HashMap<String, Vec<String>> = HashMap::new();
        let mut section: Option<String> = None;

        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line.starts_with('[') && line.ends_with(']') {
                let id = line[1..line.len() - 1].trim().to_lowercase();
                // "[]" is a typo, not a section. Treat the rest of the file as
                // global rather than silently dropping every term after it.
                section = if id.is_empty() { None } else { Some(id) };
                continue;
            }
            match &section {
                Some(app) => per_app.entry(app.clone()).or_default().push(line.to_string()),
                None => global.push(line.to_string()),
            }
        }

        global.truncate(MAX_TERMS);
        for terms in per_app.values_mut() {
            terms.truncate(MAX_TERMS);
        }
        VocabularyBook { global, per_app }
    }

    /// The prompt terms for one destination.
    ///
    /// App terms come first because the list is truncated from the tail: when
    /// the two together exceed the token budget, the words chosen *for this
    /// app* are the ones that must survive.
    pub fn terms(&self, context: &DictationContext) -> Vec<String> {
        self.terms_for_app(context.app_id.as_deref())
    }

    pub fn terms_for_app(&self, app_id: Option<&str>) -> Vec<String> {
        let specific = app_id
            .and_then(|id| self.per_app.get(&id.to_lowercase()))
            .cloned()
            .unwrap_or_default();
        let mut seen: HashSet<String> = HashSet::new();
        let mut out: Vec<String> = Vec::new();
        for term in specific.iter().chain(self.global.iter()) {
            // Case-insensitive: "Kubectl" and "kubectl" are one term, and
            // spending the budget twice on it helps nothing.
            if seen.insert(term.to_lowercase()) {
                out.push(term.clone());
            }
        }
        out.truncate(MAX_TERMS);
        out
    }

    /// Apps this book says anything about, for the UI.
    pub fn apps(&self) -> Vec<String> {
        let mut apps: Vec<String> = self.per_app.keys().cloned().collect();
        apps.sort();
        apps
    }
}

/// Rough token cost of a prompt built from these terms.
///
/// Whisper's initial prompt is capped near 224 tokens and silently truncated
/// past it, so a seeded list needs a number the UI can show before it writes
/// anything. Deliberately an over-estimate: ~3.2 characters per token rather
/// than the usual 4, because domain names fragment badly ("doordash.com" is not
/// one token).
pub fn estimated_prompt_tokens(terms: &[String]) -> usize {
    if terms.is_empty() {
        return 0;
    }
    let frame = 12; // "The following names..."
    let body: usize = terms.iter().map(|t| t.chars().count() + 2).sum();
    frame + (body as f64 / 3.2).ceil() as usize
}

/// Editing vocab.txt without destroying what the user wrote in it.
///
/// The file is theirs -- hand-written terms, comments, ordering that may mean
/// something to them. Seeding writes into one section and must leave every
/// other byte alone, so this is a text edit rather than a parse-and-rewrite.
pub mod file {
    use super::VocabularyBook;

    /// Replace the term lines of `[app]` with `terms`, preserving comments
    /// inside that section and everything outside it.
    ///
    /// Appends the section if absent. Removes it if `terms` is empty, so
    /// clearing a seeded list does not leave a dangling header that silently
    /// captures whatever the user types after it.
    pub fn replacing_section(text: &str, app: &str, terms: &[String]) -> String {
        let wanted = app.to_lowercase();
        let mut out: Vec<String> = Vec::new();
        let mut lines: Vec<&str> = text.split('\n').collect();
        let mut in_section = false;
        let mut wrote = false;
        // A trailing newline shows up as a final empty component; hold it back
        // so appending does not drift the file down by a line each time.
        let had_trailing_newline = lines.last().is_some_and(|l| l.is_empty());
        if had_trailing_newline {
            lines.pop();
        }

        for line in lines {
            let trimmed = line.trim();
            let is_header = trimmed.starts_with('[') && trimmed.ends_with(']');

            if is_header {
                let id = trimmed[1..trimmed.len() - 1].trim().to_lowercase();
                in_section = false; // leaving ours, if we were in it
                if id == wanted {
                    in_section = true;
                    wrote = true;
                    if terms.is_empty() {
                        continue; // drop the header too
                    }
                    out.push(line.to_string()); // keep it as written
                    continue;
                }
                out.push(line.to_string());
                continue;
            }

            if !in_section {
                out.push(line.to_string());
                continue;
            }

            // Inside our section: comments and blank lines are the user's,
            // term lines are ours to replace.
            if trimmed.starts_with('#') || (!terms.is_empty() && trimmed.is_empty()) {
                out.push(line.to_string());
            }
        }

        if wrote && !terms.is_empty() {
            // Re-emit the terms directly after the header (and any comments
            // that followed it), which is where they were.
            out = reinsert(terms, out, &wanted);
        } else if !wrote && !terms.is_empty() {
            if out.last().is_some_and(|l| !l.trim().is_empty()) {
                out.push(String::new());
            }
            out.push(format!("[{app}]"));
            out.extend(terms.iter().cloned());
        }

        let mut result = out.join("\n");
        if had_trailing_newline || !result.is_empty() {
            result.push('\n');
        }
        result
    }

    fn reinsert(terms: &[String], lines: Vec<String>, app: &str) -> Vec<String> {
        let mut out = lines;
        let Some(header) = out.iter().position(|l| {
            let t = l.trim();
            t.starts_with('[')
                && t.ends_with(']')
                && t[1..t.len() - 1].trim().to_lowercase() == app
        }) else {
            return out;
        };

        // Past the header, skip the comment block that belongs to it.
        let mut at = header + 1;
        while at < out.len() && out[at].trim().starts_with('#') {
            at += 1;
        }
        for (i, term) in terms.iter().enumerate() {
            out.insert(at + i, term.clone());
        }
        out
    }

    /// Terms already written under `[app]`, in file order. Used to keep a
    /// user's hand-added entries ahead of anything seeded.
    pub fn section(text: &str, app: &str) -> Vec<String> {
        VocabularyBook::parse(text)
            .per_app
            .get(&app.to_lowercase())
            .cloned()
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::file;
    use super::*;
    use crate::kit::context::FieldKind;

    fn ctx(app: &str) -> DictationContext {
        DictationContext::new(Some(app.into()), None, FieldKind::Unknown)
    }

    #[test]
    fn a_file_with_no_sections_is_entirely_global() {
        let book = VocabularyBook::parse("Anthropic\nSiobhan\n");
        assert_eq!(book.global, vec!["Anthropic", "Siobhan"]);
        assert!(book.per_app.is_empty());
        assert_eq!(book.terms_for_app(Some("wt.exe")), vec!["Anthropic", "Siobhan"]);
    }

    #[test]
    fn a_section_applies_only_in_its_app() {
        let book = VocabularyBook::parse("Anthropic\n\n[wt.exe]\ngit status\nkubectl\n");
        assert_eq!(book.global, vec!["Anthropic"]);
        assert_eq!(book.terms(&ctx("wt.exe")), vec!["git status", "kubectl", "Anthropic"]);
        assert_eq!(book.terms(&ctx("outlook.exe")), vec!["Anthropic"]);
    }

    #[test]
    fn section_headers_are_matched_case_insensitively() {
        let book = VocabularyBook::parse("[WT.EXE]\nkubectl\n");
        assert_eq!(book.terms(&ctx("wt.exe")), vec!["kubectl"]);
    }

    #[test]
    fn app_terms_come_first_so_truncation_keeps_them() {
        let mut text = String::new();
        for i in 0..MAX_TERMS {
            text.push_str(&format!("global{i}\n"));
        }
        text.push_str("[wt.exe]\nkubectl\n");
        let book = VocabularyBook::parse(&text);
        let terms = book.terms(&ctx("wt.exe"));
        assert_eq!(terms.len(), MAX_TERMS);
        assert_eq!(terms[0], "kubectl", "the app's own words must survive the cut");
    }

    #[test]
    fn a_term_is_not_paid_for_twice() {
        let book = VocabularyBook::parse("Kubectl\n[wt.exe]\nkubectl\n");
        assert_eq!(book.terms(&ctx("wt.exe")), vec!["kubectl"]);
    }

    #[test]
    fn comments_and_blank_lines_are_ignored() {
        let book = VocabularyBook::parse("# a note\n\nAnthropic\n");
        assert_eq!(book.global, vec!["Anthropic"]);
    }

    /// An empty header is a typo. Dropping every term after it would be a
    /// silent, baffling loss.
    #[test]
    fn an_empty_header_falls_back_to_global() {
        let book = VocabularyBook::parse("[]\nAnthropic\n");
        assert_eq!(book.global, vec!["Anthropic"]);
        assert!(book.per_app.is_empty());
    }

    #[test]
    fn seeding_writes_one_section_and_leaves_the_rest_alone() {
        let before = "# mine\nAnthropic\n\n[wt.exe]\n# hand-written\nkubectl\n";
        let after = file::replacing_section(before, "chrome.exe", &["doordash.com".into()]);
        assert!(after.contains("# mine"));
        assert!(after.contains("Anthropic"));
        assert!(after.contains("[wt.exe]"));
        assert!(after.contains("kubectl"));
        assert!(after.contains("[chrome.exe]"));
        assert!(after.contains("doordash.com"));
    }

    #[test]
    fn seeding_an_existing_section_replaces_its_terms_but_keeps_its_comments() {
        let before = "[chrome.exe]\n# sites I visit\nold.example\n";
        let after = file::replacing_section(before, "chrome.exe", &["new.example".into()]);
        assert!(after.contains("# sites I visit"));
        assert!(after.contains("new.example"));
        assert!(!after.contains("old.example"));
    }

    #[test]
    fn clearing_a_section_removes_its_header_too() {
        let before = "Anthropic\n\n[chrome.exe]\nold.example\n";
        let after = file::replacing_section(before, "chrome.exe", &[]);
        assert!(!after.contains("[chrome.exe]"), "a dangling header captures later edits");
        assert!(after.contains("Anthropic"));
    }

    #[test]
    fn seeding_twice_is_idempotent() {
        let once = file::replacing_section("Anthropic\n", "chrome.exe", &["a.example".into()]);
        let twice = file::replacing_section(&once, "chrome.exe", &["a.example".into()]);
        assert_eq!(once, twice, "the file must not drift on repeated seeding");
    }

    #[test]
    fn the_token_estimate_is_an_over_estimate() {
        assert_eq!(estimated_prompt_tokens(&[]), 0);
        let terms: Vec<String> = (0..20).map(|i| format!("domain{i}.com")).collect();
        let est = estimated_prompt_tokens(&terms);
        assert!(est > 20, "one token per term is not a real estimate");
        assert!(est < PROMPT_TOKEN_BUDGET * 3);
    }
}
