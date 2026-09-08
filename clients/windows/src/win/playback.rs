//! Replay a stored clip from the history list.
//!
//! `PlaySoundW` rather than an audio library: the clips are 16 kHz mono WAVs
//! written by this app, playing one is the entire requirement, and it is
//! asynchronous with a built-in "stop whatever is playing" -- so starting a new
//! clip cannot layer over the previous one.

use std::path::Path;

use windows::core::HSTRING;
use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_FILENAME, SND_NODEFAULT};

#[derive(Default)]
pub struct Playback {
    playing: Option<String>,
}

impl Playback {
    /// Start `path`, or stop it if it is already the one playing.
    pub fn toggle(&mut self, path: Option<&str>) {
        let Some(path) = path.filter(|p| !p.is_empty()) else {
            return;
        };
        if self.playing.as_deref() == Some(path) {
            self.stop();
            return;
        }
        if !Path::new(path).exists() {
            // The clip was deleted out from under the row.
            self.stop();
            return;
        }
        let wide = HSTRING::from(path);
        // SND_NODEFAULT: if the file will not play, say nothing rather than
        // making the machine ding for no reason the user can act on.
        let ok = unsafe { PlaySoundW(&wide, None, SND_FILENAME | SND_ASYNC | SND_NODEFAULT) };
        self.playing = ok.as_bool().then(|| path.to_string());
    }

    pub fn stop(&mut self) {
        unsafe {
            // Passing no sound is how PlaySound is told to stop; whether it had
            // anything to stop is not interesting.
            let _ = PlaySoundW(None, None, SND_ASYNC);
        }
        self.playing = None;
    }

    pub fn playing(&self) -> Option<&str> {
        self.playing.as_deref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_clip_is_not_played_and_is_not_a_panic() {
        let mut p = Playback::default();
        p.toggle(Some("C:/nope/missing.wav"));
        assert_eq!(p.playing(), None);
        p.toggle(None);
        p.toggle(Some(""));
        assert_eq!(p.playing(), None);
    }

    #[test]
    fn stopping_when_nothing_plays_is_harmless() {
        let mut p = Playback::default();
        p.stop();
        assert_eq!(p.playing(), None);
    }
}
