//! Shared state behind both the tray and the window.
//!
//! The hotkey and the Listen button drive the same engine; they differ only in
//! where the text goes. This is the Windows counterpart of `AppModel` in the
//! macOS client, and it keeps the same property: the tray and the window are
//! two views of one model, so the tone picker and the counters cannot disagree.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::HWND;

use crate::kit::chord::ModifierChord;
use crate::kit::context::DictationContext;
use crate::kit::engine::{self, Command, Delivery, EngineHandle, Event, State};
use crate::kit::formatter::LedgerEntry;
use crate::kit::models::{self, ModelStore};
use crate::kit::settings::Settings;
use crate::kit::store::{Stats, Store, Utterance};
use crate::kit::tone::Tone;
use crate::kit::tone_memory::{FileToneStorage, Source, ToneMemory};
use crate::kit::vocabulary::{self, VocabularyBook};
use crate::kit::wake::Wake;
use crate::win::hotkey::{self, Hotkey, HotkeyEvent};
use crate::win::playback::Playback;
use crate::win::{focus, paster};

/// How often the foreground app is checked, so the tray shows the register you
/// are about to get before you press anything.
///
/// macOS gets an activation notification and needs no poll. Windows has
/// `SetWinEventHook`, which would mean another hook thread and another way for
/// a wedged app to hold us up, for a label. Twice a second is two cheap
/// syscalls and is indistinguishable to a person.
const FOREGROUND_POLL: Duration = Duration::from_millis(500);

/// Where OpenFlow keeps everything: history, models, vocabulary, settings.
pub fn support_dir() -> PathBuf {
    std::env::var("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir())
        .join("OpenFlow")
}

pub struct App {
    pub settings: Settings,
    pub support: PathBuf,
    pub store: Arc<Store>,
    pub engine: EngineHandle,
    pub models: ModelStore,
    pub memory: ToneMemory,
    pub playback: Playback,
    hotkey: Hotkey,
    wake: Arc<Wake>,

    pub stats: Stats,
    pub history: Vec<Utterance>,
    pub query: String,
    pub status: String,
    status_since: Instant,

    pub state: State,
    pub tone: Tone,
    pub context: DictationContext,
    pub tone_source: Source,

    pub vocabulary: VocabularyBook,
    vocabulary_text: String,
    /// The dictionary file, verbatim. Not parsed here: `openflow-core` owns
    /// the format so all three clients expand it identically.
    dictionary_text: String,

    /// The window that had focus when the chord went down. The paste goes back
    /// to it, not to wherever focus has drifted by the time whisper finishes.
    paste_target: Option<isize>,
    last_foreground: Instant,
    model_revision: u64,
    /// True when a database could not be opened and history is in memory only.
    pub history_is_ephemeral: bool,
}

impl App {
    pub fn new(wake: Arc<Wake>) -> App {
        let support = support_dir();
        let _ = std::fs::create_dir_all(&support);
        let settings = Settings::load(&support);

        let (store, history_is_ephemeral) = match Store::open(&support.join("history.sqlite")) {
            Ok(s) => (Arc::new(s), false),
            // History in memory beats refusing to let the user dictate.
            Err(_) => (Arc::new(Store::in_memory()), true),
        };

        let models = ModelStore::new(
            support.join("models"),
            settings.selected_model.clone(),
            wake.clone(),
        );
        let engine = engine::spawn(
            store.clone(),
            engine::Config {
                model_path: models.active_path(),
                support: support.clone(),
                tone: settings.tone,
                keep_audio: settings.keep_audio,
                noise_reduction: settings.noise_suppression,
                high_pass: settings.high_pass,
                reject_non_speech: settings.reject_non_speech,
            },
            wake.clone(),
        );

        let memory = ToneMemory::new(
            Box::new(FileToneStorage::new(&support.join("tones.json"))),
            settings.tone,
        );
        let hotkey = hotkey::start(
            settings.chord,
            Duration::from_millis(settings.arm_delay_ms),
            wake.clone(),
        );

        let mut app = App {
            stats: store.stats(),
            history: Vec::new(),
            query: String::new(),
            status: String::new(),
            status_since: Instant::now(),
            state: State::Idle,
            tone: settings.tone,
            context: DictationContext::unknown(),
            tone_source: Source::Fallback,
            vocabulary: VocabularyBook::default(),
            vocabulary_text: String::new(),
            dictionary_text: String::new(),
            paste_target: None,
            last_foreground: Instant::now() - FOREGROUND_POLL,
            model_revision: models.selection_revision,
            history_is_ephemeral,
            settings,
            support,
            store,
            engine,
            models,
            memory,
            playback: Playback::default(),
            hotkey,
            wake,
        };
        app.reload_vocabulary();
        app.reload_dictionary();
        app.reload_history();
        app
    }

    // MARK: the tick

    /// Everything that has to happen whether or not the window is on screen.
    /// Called from `logic`, which eframe runs even while hidden.
    pub fn tick(&mut self) {
        self.pump_hotkey();
        self.pump_engine();
        if self.models.poll() {
            self.apply_model_selection();
        }
        if self.models.selection_revision != self.model_revision {
            self.apply_model_selection();
        }
        self.follow_foreground();
        if !self.status.is_empty() && self.status_since.elapsed() > Duration::from_secs(4) {
            self.status.clear();
        }
    }

    fn pump_hotkey(&mut self) {
        while let Ok(event) = self.hotkey.events.try_recv() {
            match event {
                HotkeyEvent::Pressed => {
                    // Read focus before recording: by the time the utterance
                    // ends the field may be gone, and the text has to land
                    // where the user was looking.
                    self.paste_target = focus::foreground_window().map(|h| h.0 as isize);
                    let context = focus::current();
                    self.adopt(context);
                    self.engine.send(Command::Begin);
                }
                HotkeyEvent::Released => {
                    let key = self.context.key();
                    self.engine.send(Command::End {
                        delivery: Delivery::Paste,
                        app_context: key,
                    });
                }
                HotkeyEvent::Cancelled => self.engine.send(Command::Cancel),
            }
        }
    }

    fn pump_engine(&mut self) {
        while let Ok(event) = self.engine.events.try_recv() {
            match event {
                Event::State(s) => self.state = s,
                Event::Cancelled => {
                    self.set_status("That was a keyboard shortcut \u{2014} nothing recorded.")
                }
                Event::Failed(message) => {
                    self.set_status(&message);
                    self.refresh();
                }
                Event::Finished(outcome) => {
                    match outcome.delivery {
                        Delivery::Paste => {
                            let target = self
                                .paste_target
                                .take()
                                .map(|h| HWND(h as *mut std::ffi::c_void));
                            paster::paste(outcome.text.clone(), target);
                            self.set_status(&format!(
                                "{} words \u{b7} {}ms",
                                outcome.result.spoken_words, outcome.latency_ms
                            ));
                        }
                        Delivery::Clipboard => {
                            paster::copy(&outcome.text);
                            self.set_status(&format!(
                                "{} words \u{b7} copied to clipboard",
                                outcome.result.spoken_words
                            ));
                        }
                    }
                    if !outcome.result.ok {
                        // Say why. "Formatting rolled back" on its own leaves
                        // the user with nothing to report or act on.
                        self.status.push_str(" \u{b7} formatting rolled back: ");
                        self.status.push_str(&outcome.result.note);
                    }
                    self.refresh();
                }
            }
        }
    }

    /// Track the foreground app so the tray shows the register you are about to
    /// get. Field-level detail waits for the chord: reading the focused element
    /// is a cross-process call, and doing it twice a second for a label would
    /// be rude to every other app on the machine.
    fn follow_foreground(&mut self) {
        if self.last_foreground.elapsed() < FOREGROUND_POLL {
            return;
        }
        self.last_foreground = Instant::now();
        if self.is_recording() {
            return; // the context is already pinned to where this is going
        }
        let context = focus::current_app_only();
        // Our own window is where the user *corrects* the tone, so activating
        // it must leave the context they are correcting in place.
        if context.app_id.as_deref() == Some(crate::OUR_EXE) {
            return;
        }
        if context.app_id != self.context.app_id {
            self.adopt(context);
        }
    }

    // MARK: dictation

    pub fn is_recording(&self) -> bool {
        self.state == State::Recording
    }

    pub fn live_seconds(&self) -> f64 {
        self.engine.live.lock().unwrap().seconds
    }

    pub fn input_db(&self) -> f32 {
        self.engine.live.lock().unwrap().peak_db
    }

    pub fn input_device(&self) -> Option<String> {
        self.engine.live.lock().unwrap().device_name.clone()
    }

    /// Listen button: toggles, and always copies rather than pastes. When the
    /// button is pressed our own window has focus, so pasting would deliver the
    /// text into OpenFlow itself.
    pub fn toggle_listen(&mut self) {
        if self.is_recording() {
            self.engine.send(Command::End {
                delivery: Delivery::Clipboard,
                app_context: None,
            });
        } else {
            self.engine.send(Command::Begin);
        }
    }

    pub fn needs_model(&self) -> bool {
        self.models.active_path().is_none()
    }

    pub fn active_model_name(&self) -> &str {
        models::model(&self.models.selected_id)
            .map(|m| m.display_name)
            .unwrap_or("none")
    }

    pub fn hotkey_ready(&self) -> bool {
        self.hotkey.is_installed()
    }

    // MARK: tone

    /// Point the model at a new destination and take the register that belongs
    /// to it.
    pub fn adopt(&mut self, context: DictationContext) {
        // A foreground poll reports no field. Do not let that erase a field
        // resolved a moment ago for the same app: the coarser reading is not
        // news, and dropping to it would flip the picker back and forth.
        if context.app_id == self.context.app_id
            && context.field == crate::kit::context::FieldKind::Unknown
            && self.context.field != crate::kit::context::FieldKind::Unknown
        {
            return;
        }
        self.context = context;
        let resolved = self.memory.resolve(&self.context);
        self.tone_source = resolved.source;
        self.set_tone(resolved.tone);
        // The prompt is rebuilt and resent on every transcription, so this is
        // just a list swap -- no reload, nothing to invalidate.
        self.engine
            .send(Command::SetVocabulary(self.vocabulary.terms(&self.context)));
    }

    fn set_tone(&mut self, tone: Tone) {
        if self.tone != tone {
            self.tone = tone;
            self.engine.send(Command::SetTone(tone));
        }
    }

    /// The user picked a register. That is the whole teaching signal: it means
    /// "this is what I want *here*", so it is written against the current
    /// context rather than becoming a global mode to remember to unset later.
    pub fn choose_tone(&mut self, picked: Tone) {
        self.set_tone(picked);
        if self.memory.remember(picked, &self.context) {
            if let Some(key) = self.context.key() {
                self.tone_source = Source::Remembered(key);
            }
            let label = self.context.label();
            self.set_status(&format!("{} remembered for {label}", picked.name()));
        } else {
            // Nothing to attach it to -- dictating to the clipboard, or no
            // foreground app. Becomes the global default instead.
            self.memory.fallback = picked;
            self.settings.tone = picked;
            self.save_settings();
            self.tone_source = Source::Fallback;
            self.set_status(&format!("{} is now the default", picked.name()));
        }
    }

    pub fn forget_tone(&mut self, key: Option<&str>) {
        match key {
            Some(k) => self.memory.forget(k),
            None => {
                let context = self.context.clone();
                self.memory.forget_context(&context)
            }
        }
        let context = self.context.clone();
        self.adopt(context);
    }

    pub fn forget_all_tones(&mut self) {
        self.memory.forget_all();
        let context = self.context.clone();
        self.adopt(context);
    }

    pub fn remember_tone_for_key(&mut self, tone: Tone, key: &str) {
        self.memory.set_tone(tone, key);
        let context = self.context.clone();
        self.adopt(context);
    }

    pub fn tone_is_remembered(&self) -> bool {
        matches!(self.tone_source, Source::Remembered(_))
    }

    /// One line under the picker: what tone applies where, and on what basis.
    pub fn tone_explanation(&self) -> String {
        let label = self.context.label();
        match &self.tone_source {
            Source::Remembered(_) => format!("Remembered for {label}"),
            Source::Suggested(_) => {
                format!("Suggested for {label} \u{2014} pick one to make it stick")
            }
            Source::Fallback => {
                if self.context.app_id.is_none() {
                    "Default for anywhere with nothing remembered".into()
                } else {
                    format!("Default \u{2014} pick one to remember it for {label}")
                }
            }
        }
    }

    // MARK: settings

    pub fn set_chord(&mut self, chord: ModifierChord) {
        if !chord.is_usable() || chord == self.settings.chord {
            return;
        }
        self.settings.chord = chord;
        self.save_settings();
        self.hotkey.set_chord(chord);
        self.set_status(&format!("Push to talk is now {}", chord.label()));
    }

    pub fn set_arm_delay(&mut self, ms: u64) {
        self.settings.arm_delay_ms = ms;
        self.save_settings();
        self.hotkey.set_arm_delay(Duration::from_millis(ms));
    }

    pub fn set_keep_audio(&mut self, on: bool) {
        self.settings.keep_audio = on;
        self.save_settings();
        self.engine.send(Command::SetKeepAudio(on));
    }

    pub fn set_noise_suppression(&mut self, on: bool) {
        self.settings.noise_suppression = on;
        self.save_settings();
        self.engine.send(Command::SetNoiseReduction(on));
    }

    pub fn set_high_pass(&mut self, on: bool) {
        self.settings.high_pass = on;
        self.save_settings();
        self.engine.send(Command::SetHighPass(on));
    }

    pub fn set_reject_non_speech(&mut self, on: bool) {
        self.settings.reject_non_speech = on;
        self.save_settings();
        self.engine.send(Command::SetRejectNonSpeech(on));
    }

    pub fn select_model(&mut self, id: &str) {
        self.models.select(id);
        self.apply_model_selection();
    }

    pub fn delete_model(&mut self, id: &str) {
        self.models.delete(id);
        self.apply_model_selection();
    }

    fn apply_model_selection(&mut self) {
        self.model_revision = self.models.selection_revision;
        self.settings.selected_model = (!self.models.selected_id.is_empty())
            .then(|| self.models.selected_id.clone());
        self.save_settings();
        self.engine.send(Command::SetModel(self.models.active_path()));
    }

    fn save_settings(&self) {
        self.settings.save(&self.support);
    }

    // MARK: vocabulary

    pub fn vocabulary_path(&self) -> PathBuf {
        self.support.join("vocab.txt")
    }

    pub fn reload_vocabulary(&mut self) {
        let path = self.vocabulary_path();
        if !path.exists() {
            let _ = std::fs::write(&path, VOCAB_TEMPLATE);
        }
        self.vocabulary_text = std::fs::read_to_string(&path).unwrap_or_default();
        self.vocabulary = VocabularyBook::parse(&self.vocabulary_text);
        self.engine
            .send(Command::SetVocabulary(self.vocabulary.terms(&self.context)));
    }

    pub fn vocabulary_here(&self) -> Vec<String> {
        self.vocabulary.terms(&self.context)
    }

    /// The raw file contents, so an editor can merge into it rather than over
    /// it. The file is hand-edited and must never be rewritten from a parse.
    pub fn vocabulary_text(&self) -> &str {
        &self.vocabulary_text
    }

    /// Write a seeded list into one app's section and reload.
    ///
    /// The file is rewritten rather than appended to, so a backup goes down
    /// first: this is a file the user hand-edits, and losing it to a bad merge
    /// would be unforgivable for a convenience feature.
    pub fn seed_vocabulary(&mut self, terms: &[String], app_id: &str) {
        let path = self.vocabulary_path();
        let updated = vocabulary::file::replacing_section(&self.vocabulary_text, app_id, terms);
        if path.exists() {
            let backup = path.with_extension("txt.bak");
            let _ = std::fs::remove_file(&backup);
            let _ = std::fs::copy(&path, &backup);
        }
        match std::fs::write(&path, updated) {
            Ok(()) => {
                self.reload_vocabulary();
                self.set_status(&format!("Added {} terms for {app_id}", terms.len()));
            }
            Err(e) => self.set_status(&format!("Could not write the vocabulary: {e}")),
        }
    }

    // MARK: dictionary

    pub fn dictionary_path(&self) -> PathBuf {
        self.support.join("dictionary.txt")
    }

    /// Read the dictionary and hand it to the engine as text.
    ///
    /// A separate file from vocab.txt, because they do opposite jobs at
    /// opposite ends of the pipeline: vocabulary steers what whisper hears, the
    /// dictionary rewrites what it wrote.
    pub fn reload_dictionary(&mut self) {
        let path = self.dictionary_path();
        if !path.exists() {
            let _ = std::fs::write(&path, DICTIONARY_TEMPLATE);
        }
        self.dictionary_text = std::fs::read_to_string(&path).unwrap_or_default();
        self.engine
            .send(Command::SetDictionary(self.dictionary_text.clone()));
    }

    pub fn dictionary_entries(&self) -> Vec<openflow_core::dictionary::Entry> {
        openflow_core::dictionary::parse(&self.dictionary_text)
    }

    /// Open dictionary.txt in whatever the user edits text with.
    pub fn edit_dictionary(&mut self) {
        let path = self.dictionary_path();
        if !path.exists() {
            let _ = std::fs::write(&path, DICTIONARY_TEMPLATE);
        }
        let _ = std::process::Command::new("cmd")
            .args(["/c", "start", "", &path.to_string_lossy()])
            .spawn();
        self.set_status("Reload the dictionary when you have saved it.");
    }

    /// Open vocab.txt in whatever the user edits text with.
    pub fn edit_vocabulary(&mut self) {
        let path = self.vocabulary_path();
        if !path.exists() {
            let _ = std::fs::write(&path, VOCAB_TEMPLATE);
        }
        let _ = std::process::Command::new("cmd")
            .args(["/c", "start", "", &path.to_string_lossy()])
            .spawn();
        self.set_status("Reload the vocabulary when you have saved it.");
    }

    // MARK: history

    pub fn refresh(&mut self) {
        self.stats = self.store.stats();
        self.reload_history();
    }

    pub fn reload_history(&mut self) {
        self.history = self.store.recent(300, &self.query);
    }

    pub fn copy(&mut self, text: &str) {
        paster::copy(text);
        self.set_status("Copied");
    }

    pub fn delete(&mut self, id: i64, audio_path: Option<&str>) {
        if self.playback.playing() == audio_path {
            self.playback.stop();
        }
        self.store.delete(id);
        self.refresh();
    }

    pub fn delete_all(&mut self) {
        self.playback.stop();
        self.store.delete_all();
        self.refresh();
    }

    pub fn ledger(&self, u: &Utterance) -> Vec<LedgerEntry> {
        LedgerEntry::decode(&u.ledger)
    }

    pub fn audio_on_disk(&self) -> i64 {
        crate::kit::audio_store::total_bytes(&self.support)
    }

    pub fn set_status(&mut self, message: &str) {
        self.status = message.to_string();
        self.status_since = Instant::now();
    }

    /// Point the background threads at the UI, once there is one to point at.
    pub fn connect_ui(&self, f: impl Fn() + Send + Sync + 'static) {
        self.wake.set(f);
    }

    pub fn shutdown(&mut self) {
        self.engine.send(Command::Shutdown);
        self.hotkey.stop();
    }
}

const VOCAB_TEMPLATE: &str = "\
# Words OpenFlow should expect: names, places, jargon.
# One per line. Lines starting with # are ignored.
# Whisper's prompt caps around 224 tokens, so keep the most-used first.

# Terms above any [section] apply everywhere. A [program.exe] header starts a
# list used only while that program has focus -- which is how you get
# \"git status\" in a terminal instead of \"get status\". OpenFlow shows the
# name of the program you last dictated into under Settings > Vocabulary.

# [wt.exe]
# git status
# kubectl
# ssh
";

const DICTIONARY_TEMPLATE: &str = "\
# Your dictionary: say the phrase on the left, get the text on the right.
# One entry per line. The replacement is inserted exactly as written --
# no capitalization, no punctuation repair.
#
#   my email = you@example.com
#   my number = (555) 123-4567
#   my sign off = Best,\\nKevin
#
# \\n makes a line break. Lines starting with # are ignored.
# Longer phrases win: \"my work email\" beats \"my email\".
";

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh install must expand nothing: every line of the template is a
    /// comment, and an example that fired would put text the user never typed
    /// into their first message.
    #[test]
    fn the_dictionary_template_parses_to_nothing() {
        assert!(openflow_core::dictionary::parse(DICTIONARY_TEMPLATE).is_empty());
    }

    #[test]
    fn the_support_directory_is_under_the_users_roaming_profile() {
        let dir = support_dir();
        assert!(dir.ends_with("OpenFlow"));
    }

    #[test]
    fn the_vocabulary_template_parses_to_nothing() {
        // Every line is a comment: a fresh install must not bias decoding
        // toward the words in its own help text.
        let book = VocabularyBook::parse(VOCAB_TEMPLATE);
        assert!(book.global.is_empty());
        assert!(book.per_app.is_empty());
    }

    #[test]
    fn the_template_shows_the_windows_section_syntax() {
        assert!(VOCAB_TEMPLATE.contains("[wt.exe]"));
        assert!(!VOCAB_TEMPLATE.contains("bundle"), "that is a macOS idea");
    }
}
