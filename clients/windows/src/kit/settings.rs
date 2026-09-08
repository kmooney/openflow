//! Persisted preferences. Windows has no `UserDefaults`, and the registry is
//! the wrong place for something a user might want to read, copy between
//! machines or delete: this is one JSON file next to the history database.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::kit::chord::ModifierChord;
use crate::kit::tone::Tone;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub chord: ModifierChord,
    /// The register for anywhere the tone memory has nothing to say about.
    pub tone: Tone,
    /// Keep clips on disk for debugging. Off by default -- audio is the most
    /// sensitive thing here, and the rule is transcribe-and-discard.
    pub keep_audio: bool,
    /// Our own spectral subtraction, applied after capture. It leaves a clean
    /// recording untouched, so it is on by default.
    pub noise_suppression: bool,
    /// Strip low-frequency rumble before anything else sees the audio.
    pub high_pass: bool,
    /// Refuse to transcribe recordings that are probably just room noise.
    pub reject_non_speech: bool,
    pub selected_model: Option<String>,
    /// How long the chord must be held before the microphone opens.
    ///
    /// macOS opens immediately, because a held Control-Option means nothing
    /// else. On Windows the default chord is a prefix of real shortcuts
    /// (Ctrl+Shift+T, Ctrl+Shift+Arrow), so a short delay keeps the microphone
    /// out of them entirely rather than opening and discarding several times a
    /// minute. Set it to 0 for macOS behaviour.
    pub arm_delay_ms: u64,
    pub launched_before: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            chord: ModifierChord::default(),
            tone: Tone::Formal,
            keep_audio: false,
            noise_suppression: true,
            high_pass: true,
            reject_non_speech: true,
            selected_model: None,
            arm_delay_ms: 250,
            launched_before: false,
        }
    }
}

impl Settings {
    pub fn path(support: &Path) -> PathBuf {
        support.join("settings.json")
    }

    pub fn load(support: &Path) -> Settings {
        std::fs::read_to_string(Self::path(support))
            .ok()
            .and_then(|json| serde_json::from_str(&json).ok())
            .unwrap_or_default()
    }

    /// Written on every change. It is a few hundred bytes, and losing the
    /// user's chord because the app was killed would be a silly way to fail.
    pub fn save(&self, support: &Path) {
        let _ = std::fs::create_dir_all(support);
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(Self::path(support), json);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kit::chord;

    #[test]
    fn the_default_chord_is_ctrl_shift() {
        assert_eq!(Settings::default().chord.label(), "Ctrl+Shift");
    }

    #[test]
    fn a_missing_or_broken_file_gives_defaults_rather_than_failing() {
        let dir = std::env::temp_dir().join(format!("of-settings-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let s = Settings::load(&dir);
        assert_eq!(s.chord, ModifierChord::default());

        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(Settings::path(&dir), "{ not json").unwrap();
        assert_eq!(Settings::load(&dir).chord, ModifierChord::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn settings_survive_a_round_trip() {
        let dir = std::env::temp_dir().join(format!("of-settings-rt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut s = Settings::default();
        s.chord = ModifierChord::new(chord::CONTROL | chord::ALT);
        s.tone = Tone::VeryCasual;
        s.keep_audio = true;
        s.selected_model = Some("small.en".into());
        s.save(&dir);

        let back = Settings::load(&dir);
        assert_eq!(back.chord, s.chord);
        assert_eq!(back.tone, Tone::VeryCasual);
        assert!(back.keep_audio);
        assert_eq!(back.selected_model.as_deref(), Some("small.en"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A file written by an older build must not reset everything it does not
    /// mention.
    #[test]
    fn unknown_and_missing_fields_are_tolerated() {
        let s: Settings = serde_json::from_str(r#"{"keep_audio": true, "future": 3}"#).unwrap();
        assert!(s.keep_audio);
        assert_eq!(s.chord, ModifierChord::default());
        assert!(s.noise_suppression, "an absent field keeps its default");
    }
}
