//! The whole dictation cycle, minus anything platform-shaped.
//!
//! The hotkey drives this and pastes the result; the Listen button drives the
//! same engine and copies instead. Neither owns any of the logic below.
//!
//! It runs on its own thread because every step of it blocks: cpal's stream
//! must be created and dropped on one thread, whisper saturates the CPU for
//! several hundred milliseconds, and none of that may happen on the UI thread
//! or on the keyboard hook's thread (a low-level hook that takes longer than
//! `LowLevelHooksTimeout` is silently removed by Windows).

use std::path::PathBuf;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};

use crate::kit::audio::AudioRecorder;
use crate::kit::audio_store;
use crate::kit::denoise;
use crate::kit::filters::{speech_check, SpeechVerdict};
use crate::kit::formatter::{self, FormatResult};
use crate::kit::store::{NewUtterance, Store};
use crate::kit::tone::Tone;
use crate::kit::transcribe::Transcriber;
use crate::kit::wake::Wake;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    Idle,
    Recording,
    Thinking,
}

/// Where the finished text should go.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum Delivery {
    /// Paste into whatever had focus. Used by the hotkey.
    Paste,
    /// Copy only. Used by the Listen button -- pasting would land the text in
    /// our own window, which is never what you meant.
    Clipboard,
}

pub struct Outcome {
    pub text: String,
    pub result: FormatResult,
    pub latency_ms: i64,
    pub delivery: Delivery,
}

/// What the engine sends back to the UI. Everything is a message rather than a
/// callback so the UI thread never holds a lock the audio thread wants.
pub enum Event {
    State(State),
    Finished(Box<Outcome>),
    Failed(String),
    /// The chord turned out to be a keyboard shortcut. Nothing was said, so
    /// nothing is recorded -- the "every capture is recorded" rule exists to
    /// keep the evidence for failed *utterances*, and this was not one.
    Cancelled,
}

pub enum Command {
    Begin,
    End {
        delivery: Delivery,
        app_context: Option<String>,
    },
    Cancel,
    SetTone(Tone),
    SetVocabulary(Vec<String>),
    /// The dictionary file, verbatim. Parsing it belongs to `openflow-core`,
    /// so macOS, iOS and Windows expand the same file the same way.
    SetDictionary(String),
    SetModel(Option<PathBuf>),
    SetKeepAudio(bool),
    SetNoiseReduction(bool),
    SetHighPass(bool),
    SetRejectNonSpeech(bool),
    Shutdown,
}

/// The bits of engine state the UI reads every frame. Kept behind its own lock
/// so a repaint never waits on a transcription.
#[derive(Default)]
pub struct Live {
    pub recording: bool,
    pub seconds: f64,
    pub peak_db: f32,
    pub has_model: bool,
    pub device_name: Option<String>,
    pub input_rate: Option<u32>,
}

pub struct EngineHandle {
    pub commands: Sender<Command>,
    pub events: Receiver<Event>,
    pub live: Arc<Mutex<Live>>,
}

impl EngineHandle {
    pub fn send(&self, c: Command) {
        let _ = self.commands.send(c);
    }
}

pub struct Config {
    pub model_path: Option<PathBuf>,
    pub support: PathBuf,
    pub tone: Tone,
    pub keep_audio: bool,
    pub noise_reduction: bool,
    pub high_pass: bool,
    pub reject_non_speech: bool,
}

/// Start the engine thread. The model is loaded up front, not per utterance:
/// it costs hundreds of milliseconds the user should never pay mid-sentence.
pub fn spawn(store: Arc<Store>, config: Config, wake: Arc<Wake>) -> EngineHandle {
    let (command_tx, command_rx) = std::sync::mpsc::channel::<Command>();
    let (event_tx, event_rx) = std::sync::mpsc::channel::<Event>();
    let live = Arc::new(Mutex::new(Live::default()));

    let thread_live = live.clone();
    std::thread::Builder::new()
        .name("openflow.dictation".into())
        .spawn(move || run(store, config, command_rx, event_tx, thread_live, wake))
        .expect("the dictation thread must start");

    EngineHandle {
        commands: command_tx,
        events: event_rx,
        live,
    }
}

struct Engine {
    recorder: AudioRecorder,
    store: Arc<Store>,
    transcriber: Option<Transcriber>,
    model_path: Option<PathBuf>,
    support: PathBuf,
    tone: Tone,
    vocabulary: Vec<String>,
    dictionary: String,
    keep_audio: bool,
    noise_reduction: bool,
    reject_non_speech: bool,
    live: Arc<Mutex<Live>>,
    events: Sender<Event>,
    wake: Arc<Wake>,
}

fn run(
    store: Arc<Store>,
    config: Config,
    commands: Receiver<Command>,
    events: Sender<Event>,
    live: Arc<Mutex<Live>>,
    wake: Arc<Wake>,
) {
    let mut recorder = AudioRecorder::default();
    recorder.use_high_pass = config.high_pass;

    let mut engine = Engine {
        recorder,
        store,
        transcriber: None,
        model_path: config.model_path.clone(),
        support: config.support,
        tone: config.tone,
        vocabulary: Vec::new(),
        dictionary: String::new(),
        keep_audio: config.keep_audio,
        noise_reduction: config.noise_reduction,
        reject_non_speech: config.reject_non_speech,
        live,
        events,
        wake,
    };
    engine.warm_up();

    while let Ok(command) = commands.recv() {
        match command {
            Command::Begin => engine.begin(),
            Command::End {
                delivery,
                app_context,
            } => engine.end(delivery, app_context.as_deref()),
            Command::Cancel => engine.cancel(),
            Command::SetTone(t) => engine.tone = t,
            Command::SetVocabulary(v) => engine.vocabulary = v,
            Command::SetDictionary(d) => engine.dictionary = d,
            Command::SetModel(path) => engine.use_model(path),
            Command::SetKeepAudio(v) => engine.keep_audio = v,
            Command::SetNoiseReduction(v) => engine.noise_reduction = v,
            Command::SetHighPass(v) => engine.recorder.use_high_pass = v,
            Command::SetRejectNonSpeech(v) => engine.reject_non_speech = v,
            Command::Shutdown => break,
        }
        engine.publish();
    }
}

impl Engine {
    fn emit(&self, e: Event) {
        let _ = self.events.send(e);
        // Transcription finishes on this thread, and the paste happens on the
        // UI thread's next tick. Waiting for a timer to notice would put the
        // idle interval between the user releasing the chord and their words
        // appearing.
        self.wake.wake();
    }

    fn publish(&self) {
        let mut live = self.live.lock().unwrap();
        live.recording = self.recorder.is_recording();
        live.seconds = if live.recording {
            self.recorder.duration()
        } else {
            0.0
        };
        live.peak_db = if live.recording {
            self.recorder.drain_peak_db()
        } else {
            -120.0
        };
        live.has_model = self.model_path.is_some();
        live.device_name = self.recorder.device_name.clone();
        live.input_rate = self.recorder.input_rate;
    }

    /// Load the model once, up front.
    fn warm_up(&mut self) {
        if let Some(path) = self.model_path.clone() {
            self.transcriber = Transcriber::open(&path);
            if self.transcriber.is_none() {
                self.emit(Event::Failed(format!(
                    "Could not load the speech model at {}.",
                    path.display()
                )));
            }
        }
        self.publish();
    }

    /// Switch to a different model. The old one is dropped before the new one
    /// is loaded, so a 500 MB model does not briefly need a gigabyte.
    fn use_model(&mut self, path: Option<PathBuf>) {
        if path == self.model_path {
            return;
        }
        self.transcriber = None;
        self.model_path = path;
        self.warm_up();
    }

    fn begin(&mut self) {
        if self.recorder.is_recording() {
            return;
        }
        match self.recorder.start() {
            Ok(()) => self.emit(Event::State(State::Recording)),
            Err(e) => self.emit(Event::Failed(e)),
        }
    }

    /// The chord was a shortcut after all. Throw the audio away without a row:
    /// nothing was said.
    fn cancel(&mut self) {
        if !self.recorder.is_recording() {
            return;
        }
        self.recorder.stop();
        self.emit(Event::State(State::Idle));
        self.emit(Event::Cancelled);
    }

    /// Stop, transcribe, format, persist.
    ///
    /// **Every recording produces a row**, including the ones that yielded
    /// nothing. A capture that came back empty is precisely the one you want to
    /// look at later, and throwing it away destroys the evidence.
    fn end(&mut self, delivery: Delivery, app_context: Option<&str>) {
        if !self.recorder.is_recording() {
            return;
        }
        let device_error = self.recorder.error();
        let saw_signal = self.recorder.has_signal();
        let samples = self.recorder.stop();
        let audio_ms = (samples.len() as f64 / 16.0) as i64;
        self.emit(Event::State(State::Thinking));
        self.publish();

        let started = std::time::Instant::now();

        // Written before anything can go wrong, so failures keep their audio --
        // and written RAW, so a stored clip is what the microphone actually
        // heard rather than what the denoiser left behind.
        let audio_path = if self.keep_audio && !samples.is_empty() {
            audio_store::write(&samples, &unique_id(), &self.support)
                .ok()
                .map(|p| p.to_string_lossy().into_owned())
        } else {
            None
        };

        // A device that failed mid-utterance must say so rather than being
        // reported as a quiet room.
        if let Some(e) = device_error {
            return self.fail(
                "empty",
                &format!("The microphone stopped: {e}"),
                audio_ms,
                started,
                app_context,
                audio_path,
            );
        }
        // Digital silence is never a real recording -- even a quiet room has a
        // noise floor. It means the graph delivered nothing at all.
        if !samples.is_empty() && !saw_signal {
            return self.fail(
                "empty",
                "The microphone delivered no audio at all. Check that OpenFlow is allowed to use it in Settings > Privacy > Microphone.",
                audio_ms,
                started,
                app_context,
                audio_path,
            );
        }

        let audio = if self.noise_reduction {
            denoise::reduce(&samples)
        } else {
            samples
        };

        // Cheap check before the expensive one: whisper will invent fluent
        // sentences from steady noise. Deliberately permissive -- losing
        // something you said is worse than a hallucination you can delete.
        let verdict = speech_check(&audio, 16_000);
        if self.reject_non_speech && verdict != SpeechVerdict::Speech {
            let message = if verdict == SpeechVerdict::Silence {
                "heard nothing"
            } else {
                "only background noise"
            };
            return self.fail(
                verdict.outcome(),
                message,
                audio_ms,
                started,
                app_context,
                audio_path,
            );
        }

        if self.transcriber.is_none() {
            if let Some(path) = self.model_path.clone() {
                self.transcriber = Transcriber::open(&path);
            }
        }
        let Some(transcriber) = self.transcriber.as_ref() else {
            let message = match &self.model_path {
                None => "No speech model installed \u{2014} choose one in Settings.".to_string(),
                Some(p) => format!("Could not load the model at {}", p.display()),
            };
            return self.fail("empty", &message, audio_ms, started, app_context, audio_path);
        };

        // The dictionary's trigger phrases go to whisper as well. A shortcut
        // only fires if its phrase was transcribed correctly, and the phrases
        // people invent are the ones whisper has no reason to expect.
        let mut heard = self.vocabulary.clone();
        heard.extend(
            openflow_core::dictionary::parse(&self.dictionary)
                .into_iter()
                .map(|e| e.phrase),
        );
        let raw = transcriber.transcribe(&audio, &heard);
        if raw.is_empty() {
            return self.fail(
                "empty",
                "no words recognised",
                audio_ms,
                started,
                app_context,
                audio_path,
            );
        }

        let result = formatter::format(&raw, self.tone, &self.dictionary);
        let latency_ms = started.elapsed().as_millis() as i64;

        self.store.record(NewUtterance {
            raw: &result.raw,
            final_text: &result.formatted,
            tone: self.tone,
            spoken_words: result.spoken_words as i64,
            duration_ms: audio_ms,
            latency_ms,
            guardrail_passed: result.ok,
            ledger: &result.ledger_json(),
            app_context,
            audio_path: audio_path.as_deref(),
            outcome: "ok",
        });

        self.emit(Event::State(State::Idle));
        self.emit(Event::Finished(Box::new(Outcome {
            text: result.formatted.clone(),
            result,
            latency_ms,
            delivery,
        })));
    }

    fn fail(
        &mut self,
        outcome: &str,
        message: &str,
        audio_ms: i64,
        started: std::time::Instant,
        app_context: Option<&str>,
        audio_path: Option<String>,
    ) {
        self.store.record(NewUtterance {
            raw: "",
            final_text: "",
            tone: self.tone,
            spoken_words: 0,
            duration_ms: audio_ms,
            latency_ms: started.elapsed().as_millis() as i64,
            guardrail_passed: true,
            ledger: "[]",
            app_context,
            audio_path: audio_path.as_deref(),
            outcome,
        });
        self.emit(Event::State(State::Idle));
        self.emit(Event::Failed(message.to_string()));
    }
}

fn unique_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The engine thread must come up and shut down cleanly even with no model
    /// and no microphone -- which is exactly the state a fresh install is in,
    /// and the state a test runner is always in.
    #[test]
    fn it_starts_and_stops_without_a_model() {
        let store = Arc::new(Store::in_memory());
        let handle = spawn(
            store,
            Config {
                model_path: None,
                support: std::env::temp_dir().join("openflow-test"),
                tone: Tone::Formal,
                keep_audio: false,
                noise_reduction: true,
                high_pass: true,
                reject_non_speech: true,
            },
        );
        handle.send(Command::SetTone(Tone::Casual));
        handle.send(Command::Shutdown);
        // No model means nothing is loaded and nothing claims to be.
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert!(!handle.live.lock().unwrap().has_model);
    }

    #[test]
    fn ending_without_recording_does_nothing() {
        let store = Arc::new(Store::in_memory());
        let handle = spawn(
            store.clone(),
            Config {
                model_path: None,
                support: std::env::temp_dir().join("openflow-test"),
                tone: Tone::Formal,
                keep_audio: false,
                noise_reduction: true,
                high_pass: true,
                reject_non_speech: true,
            },
        );
        handle.send(Command::End {
            delivery: Delivery::Paste,
            app_context: None,
        });
        handle.send(Command::Shutdown);
        std::thread::sleep(std::time::Duration::from_millis(50));
        assert_eq!(store.recent(10, "").len(), 0, "a row without a recording is a lie");
    }
}
