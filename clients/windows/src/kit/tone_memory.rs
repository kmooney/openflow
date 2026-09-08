//! Remembers which register belongs to which app and field, and answers with
//! one for a context it has never seen.
//!
//! Tone is a per-utterance choice, not a setting (notes/spec.md 4.4), and that
//! is still true -- the picker overrides everything, every time. What this adds
//! is that the choice starts from the right place: you dictate a URL into an
//! address bar and it does not arrive with sentence case and a full stop.
//!
//! Three layers, most specific first:
//!   1. what the user taught, for this exact field, then for this app
//!   2. what we suggest out of the box, so day one already behaves
//!   3. the global picker, for everything else

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::kit::context::DictationContext;
use crate::kit::tone::Tone;

/// One learned tone: "Slack gets casual".
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ToneRule {
    pub key: String,
    pub tone: Tone,
    /// Snapshotted at write time so the list still reads like English after a
    /// restart, when the app it names may not be running.
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// The user chose this, for the named key.
    Remembered(String),
    /// A shipped default, not yet confirmed by the user.
    Suggested(String),
    /// Nothing matched; the global picker decides.
    Fallback,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolution {
    pub tone: Tone,
    pub source: Source,
}

impl Resolution {
    pub fn is_remembered(&self) -> bool {
        matches!(self.source, Source::Remembered(_))
    }
}

/// Where the rules live. A trait only so the tests can run against something
/// that is not the user's real settings directory.
pub trait ToneStorage {
    fn load(&self) -> Option<String>;
    fn save(&self, json: &str);
}

pub struct FileToneStorage {
    path: PathBuf,
}

impl FileToneStorage {
    pub fn new(path: &Path) -> Self {
        FileToneStorage {
            path: path.to_path_buf(),
        }
    }
}

impl ToneStorage for FileToneStorage {
    fn load(&self) -> Option<String> {
        std::fs::read_to_string(&self.path).ok()
    }

    fn save(&self, json: &str) {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(&self.path, json);
    }
}

#[derive(Default)]
pub struct InMemoryToneStorage {
    data: std::sync::Mutex<Option<String>>,
}

impl ToneStorage for InMemoryToneStorage {
    fn load(&self) -> Option<String> {
        self.data.lock().unwrap().clone()
    }

    fn save(&self, json: &str) {
        *self.data.lock().unwrap() = Some(json.to_string());
    }
}

pub struct ToneMemory {
    storage: Box<dyn ToneStorage + Send>,
    rules: HashMap<String, ToneRule>,
    /// The register for anywhere we have nothing to say about. Owned by the
    /// caller (it is the picker's sticky value) and set on us so `resolve` can
    /// always return an answer.
    pub fallback: Tone,
}

impl ToneMemory {
    pub fn new(storage: Box<dyn ToneStorage + Send>, fallback: Tone) -> Self {
        let rules = storage
            .load()
            .and_then(|json| serde_json::from_str::<Vec<ToneRule>>(&json).ok())
            .unwrap_or_default()
            .into_iter()
            .map(|r| (r.key.clone(), r))
            .collect();
        ToneMemory {
            storage,
            rules,
            fallback,
        }
    }

    // MARK: reading

    pub fn resolve(&self, context: &DictationContext) -> Resolution {
        let keys = context.lookup_keys();

        // Anything the user taught wins, and the app-wide lesson outranks our
        // suggestions -- someone who sets Chrome to formal means it in the
        // address bar too.
        for key in &keys {
            if let Some(rule) = self.rules.get(key) {
                return Resolution {
                    tone: rule.tone,
                    source: Source::Remembered(key.clone()),
                };
            }
        }
        if let Some(key) = context.key() {
            if let Some(tone) = suggestion(&key) {
                return Resolution {
                    tone,
                    source: Source::Suggested(key),
                };
            }
        }
        // The rule that needs no table: you are typing a URL or a query, not
        // writing to anyone. Applies in every browser, including the one that
        // ships next year.
        if context.field.is_distinct() {
            if let Some(key) = context.key() {
                return Resolution {
                    tone: Tone::VeryCasual,
                    source: Source::Suggested(key),
                };
            }
        }
        if let Some(key) = keys.last() {
            if let Some(tone) = suggestion(key) {
                return Resolution {
                    tone,
                    source: Source::Suggested(key.clone()),
                };
            }
        }
        Resolution {
            tone: self.fallback,
            source: Source::Fallback,
        }
    }

    pub fn tone(&self, context: &DictationContext) -> Tone {
        self.resolve(context).tone
    }

    /// Everything the user has taught. Sorted by name rather than by when it
    /// changed, so editing a rule in a list does not make it jump out from
    /// under the pointer.
    pub fn all(&self) -> Vec<ToneRule> {
        let mut rules: Vec<ToneRule> = self.rules.values().cloned().collect();
        rules.sort_by_key(|r| r.label.to_lowercase());
        rules
    }

    // MARK: writing

    /// Teach this context a register. Returns false when there is no context to
    /// attach it to -- the caller should treat that as a change to `fallback`.
    pub fn remember(&mut self, tone: Tone, context: &DictationContext) -> bool {
        let Some(key) = context.key() else {
            return false;
        };
        self.rules.insert(
            key.clone(),
            ToneRule {
                key,
                tone,
                label: context.label(),
            },
        );
        self.persist();
        true
    }

    /// Change an existing rule in place, keeping the name it was written with.
    /// For editing the list; teaching a new one goes through `remember`.
    pub fn set_tone(&mut self, tone: Tone, key: &str) {
        if let Some(rule) = self.rules.get_mut(key) {
            rule.tone = tone;
            self.persist();
        }
    }

    pub fn forget(&mut self, key: &str) {
        if self.rules.remove(key).is_some() {
            self.persist();
        }
    }

    pub fn forget_context(&mut self, context: &DictationContext) {
        if let Some(key) = context.key() {
            self.forget(&key);
        }
    }

    pub fn forget_all(&mut self) {
        if !self.rules.is_empty() {
            self.rules.clear();
            self.persist();
        }
    }

    fn persist(&self) {
        if let Ok(json) = serde_json::to_string_pretty(&self.all()) {
            self.storage.save(&json);
        }
    }
}

/// Starting points, not decisions. The first time the user picks anything for
/// one of these it becomes a rule and this table stops applying to it, so being
/// wrong here costs exactly one correction.
///
/// Keys are lower-cased executable names, matching `DictationContext::key`.
pub fn suggestion(key: &str) -> Option<Tone> {
    let tone = match key {
        // Correspondence that leaves the building.
        "outlook.exe" | "olk.exe" | "winword.exe" | "powerpnt.exe" | "thunderbird.exe"
        | "hxoutlook.exe" => Tone::Formal,

        // Messaging: capitals kept, line breaks instead of full stops.
        "teams.exe" | "ms-teams.exe" | "slack.exe" | "discord.exe" | "whatsapp.exe"
        | "signal.exe" | "telegram.exe" | "notepad.exe" | "obsidian.exe" | "notion.exe" => {
            Tone::Casual
        }

        // Nothing you type here is prose.
        "windowsterminal.exe" | "wt.exe" | "cmd.exe" | "powershell.exe" | "pwsh.exe"
        | "conhost.exe" | "alacritty.exe" | "wezterm-gui.exe" | "putty.exe" | "mintty.exe" => {
            Tone::VeryCasual
        }

        _ => return None,
    };
    Some(tone)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kit::context::FieldKind;

    fn memory() -> ToneMemory {
        ToneMemory::new(Box::new(InMemoryToneStorage::default()), Tone::Formal)
    }

    fn ctx(app: &str, field: FieldKind) -> DictationContext {
        DictationContext::new(Some(app.into()), Some(app.into()), field)
    }

    #[test]
    fn nothing_known_falls_back_to_the_picker() {
        let mut m = memory();
        m.fallback = Tone::Casual;
        let r = m.resolve(&ctx("someapp.exe", FieldKind::MultiLine));
        assert_eq!(r.tone, Tone::Casual);
        assert_eq!(r.source, Source::Fallback);
    }

    #[test]
    fn shipped_suggestions_make_day_one_behave() {
        let m = memory();
        assert_eq!(m.tone(&ctx("outlook.exe", FieldKind::MultiLine)), Tone::Formal);
        assert_eq!(m.tone(&ctx("slack.exe", FieldKind::MultiLine)), Tone::Casual);
        assert_eq!(m.tone(&ctx("wt.exe", FieldKind::MultiLine)), Tone::VeryCasual);
    }

    /// The rule that needs no table, so it works in a browser that ships next
    /// year: an address bar is not prose.
    #[test]
    fn any_address_bar_is_very_casual_without_being_listed() {
        let m = memory();
        let r = m.resolve(&ctx("somebrowser.exe", FieldKind::UrlBar));
        assert_eq!(r.tone, Tone::VeryCasual);
        assert!(matches!(r.source, Source::Suggested(_)));
    }

    #[test]
    fn what_the_user_taught_wins() {
        let mut m = memory();
        assert!(m.remember(Tone::VeryCasual, &ctx("outlook.exe", FieldKind::MultiLine)));
        let r = m.resolve(&ctx("outlook.exe", FieldKind::MultiLine));
        assert_eq!(r.tone, Tone::VeryCasual);
        assert!(r.is_remembered());
    }

    /// Someone who sets a browser to formal means it in the address bar too,
    /// until the address bar is taught something of its own.
    #[test]
    fn the_app_wide_lesson_outranks_a_suggestion_for_its_field() {
        let mut m = memory();
        m.remember(Tone::Formal, &ctx("chrome.exe", FieldKind::MultiLine));
        assert_eq!(m.tone(&ctx("chrome.exe", FieldKind::UrlBar)), Tone::Formal);

        // ...and teaching the bar itself overrides that again.
        m.remember(Tone::VeryCasual, &ctx("chrome.exe", FieldKind::UrlBar));
        assert_eq!(m.tone(&ctx("chrome.exe", FieldKind::UrlBar)), Tone::VeryCasual);
        assert_eq!(m.tone(&ctx("chrome.exe", FieldKind::MultiLine)), Tone::Formal);
    }

    #[test]
    fn a_subject_line_shares_the_apps_slot() {
        let mut m = memory();
        m.remember(Tone::Casual, &ctx("outlook.exe", FieldKind::MultiLine));
        // SingleLine is not distinct, so it reads the same slot -- the user
        // should not have to teach the same thing twice.
        assert_eq!(m.tone(&ctx("outlook.exe", FieldKind::SingleLine)), Tone::Casual);
    }

    #[test]
    fn there_is_nowhere_to_attach_a_tone_with_no_app() {
        let mut m = memory();
        assert!(!m.remember(Tone::Casual, &DictationContext::unknown()));
        assert!(m.all().is_empty());
    }

    #[test]
    fn forgetting_falls_back_to_the_suggestion() {
        let mut m = memory();
        let c = ctx("slack.exe", FieldKind::MultiLine);
        m.remember(Tone::Formal, &c);
        assert_eq!(m.tone(&c), Tone::Formal);
        m.forget_context(&c);
        assert_eq!(m.tone(&c), Tone::Casual, "back to the shipped suggestion");
    }

    #[test]
    fn rules_survive_a_restart() {
        let storage = std::sync::Arc::new(SharedStorage::default());
        {
            let mut m = ToneMemory::new(Box::new(storage.clone()), Tone::Formal);
            m.remember(Tone::VeryCasual, &ctx("outlook.exe", FieldKind::MultiLine));
        }
        let m = ToneMemory::new(Box::new(storage.clone()), Tone::Formal);
        assert_eq!(m.tone(&ctx("outlook.exe", FieldKind::MultiLine)), Tone::VeryCasual);
        assert_eq!(m.all().len(), 1);
    }

    #[test]
    fn the_list_is_sorted_by_name_so_editing_does_not_reorder_it() {
        let mut m = memory();
        m.remember(Tone::Casual, &ctx("zed.exe", FieldKind::MultiLine));
        m.remember(Tone::Casual, &ctx("atom.exe", FieldKind::MultiLine));
        let labels: Vec<String> = m.all().into_iter().map(|r| r.label).collect();
        assert_eq!(labels, vec!["atom.exe", "zed.exe"]);
        m.set_tone(Tone::Formal, "zed.exe");
        let labels: Vec<String> = m.all().into_iter().map(|r| r.label).collect();
        assert_eq!(labels, vec!["atom.exe", "zed.exe"], "editing must not reorder");
    }

    #[derive(Default)]
    struct SharedStorage {
        data: std::sync::Mutex<Option<String>>,
    }

    impl ToneStorage for std::sync::Arc<SharedStorage> {
        fn load(&self) -> Option<String> {
            self.data.lock().unwrap().clone()
        }
        fn save(&self, json: &str) {
            *self.data.lock().unwrap() = Some(json.to_string());
        }
    }
}
