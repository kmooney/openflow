//! End-to-end check of everything between a recording and the finished text:
//! noise reduction, the speech gate, whisper, and the formatter.
//!
//! It needs a model and a recording, which are hundreds of megabytes and
//! someone's voice respectively, so neither lives in the repository. Point it
//! at both and it runs; leave either unset and it skips, loudly enough to
//! notice in the output but without failing a build that never had them.
//!
//! ```powershell
//! # a model, if you do not already have one
//! curl.exe -L -o ggml-tiny.en.bin `
//!   https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin
//!
//! # a recording: 16 kHz mono WAV. Windows will make you one:
//! Add-Type -AssemblyName System.Speech
//! $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
//! $f = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000,
//!        [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
//!        [System.Speech.AudioFormat.AudioChannel]::Mono)
//! $s.SetOutputToWaveFile("speech.wav", $f)
//! $s.Speak("um so the deploy failed this morning and we had to roll it back")
//! $s.Dispose()
//!
//! $env:OPENFLOW_TEST_MODEL = "ggml-tiny.en.bin"
//! $env:OPENFLOW_TEST_AUDIO = "speech.wav"
//! .\build-windows.ps1 -Test
//! ```
//!
//! `OPENFLOW_TEST_TRANSCRIPT` optionally names words the transcript must
//! contain, comma-separated; it defaults to the sentence above.

use std::path::PathBuf;

use openflow_windows::kit::denoise;
use openflow_windows::kit::filters::{speech_check, SpeechVerdict};
use openflow_windows::kit::formatter;
use openflow_windows::kit::tone::Tone;
use openflow_windows::kit::transcribe::Transcriber;

fn env_path(key: &str) -> Option<PathBuf> {
    let value = std::env::var(key).ok()?;
    let path = PathBuf::from(value);
    if path.exists() {
        Some(path)
    } else {
        eprintln!("{key} points at {} which does not exist", path.display());
        None
    }
}

fn load_mono_16k(path: &PathBuf) -> Vec<f32> {
    let mut reader = hound::WavReader::open(path).expect("open the fixture");
    let spec = reader.spec();
    assert_eq!(
        spec.sample_rate, 16_000,
        "the fixture must already be 16 kHz mono; capture does the resampling"
    );
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Int => reader
            .samples::<i32>()
            .flatten()
            .map(|v| v as f32 / (1i32 << (spec.bits_per_sample - 1)) as f32)
            .collect(),
        hound::SampleFormat::Float => reader.samples::<f32>().flatten().collect(),
    };
    if spec.channels == 1 {
        samples
    } else {
        samples
            .chunks(spec.channels as usize)
            .map(|f| f.iter().sum::<f32>() / f.len() as f32)
            .collect()
    }
}

#[test]
fn a_recording_becomes_formatted_text() {
    let (Some(model), Some(audio)) = (
        env_path("OPENFLOW_TEST_MODEL"),
        env_path("OPENFLOW_TEST_AUDIO"),
    ) else {
        eprintln!(
            "skipping: set OPENFLOW_TEST_MODEL and OPENFLOW_TEST_AUDIO to run the end-to-end check"
        );
        return;
    };

    let samples = load_mono_16k(&audio);
    assert!(!samples.is_empty(), "the fixture is empty");

    // 1. Noise reduction. It must return a clean recording untouched -- the
    //    failure mode it was written to avoid is eating half the speech.
    let audio = denoise::reduce(&samples);
    assert_eq!(audio.len(), samples.len());

    // 2. The gate. A recording it rejects never reaches whisper, so if this is
    //    wrong nothing downstream matters.
    assert_eq!(
        speech_check(&audio, 16_000),
        SpeechVerdict::Speech,
        "the speech gate rejected a recording of speech"
    );

    // 3. Transcription, with a vocabulary hint in place so the prompt path is
    //    exercised rather than skipped.
    let transcriber = Transcriber::open(&model).expect("load the model");
    let raw = transcriber.transcribe(&audio, &["Kubernetes".to_string()]);
    eprintln!("transcript: {raw}");
    assert!(!raw.is_empty(), "whisper returned nothing");

    let expected = std::env::var("OPENFLOW_TEST_TRANSCRIPT")
        .unwrap_or_else(|_| "deploy,failed,roll".to_string());
    let lower = raw.to_lowercase();
    for word in expected.split(',').map(str::trim).filter(|w| !w.is_empty()) {
        assert!(
            lower.contains(&word.to_lowercase()),
            "expected {word:?} in the transcript, got {raw:?}"
        );
    }

    // 4. Formatting, through the same core the Swift clients reach by FFI.
    let result = formatter::format(&raw, Tone::Formal, "");
    eprintln!("formatted: {}", result.formatted);
    assert!(
        result.ok,
        "the guardrail rejected the formatter's own output: {}",
        result.note
    );
    assert_eq!(
        result.spoken_words,
        raw.split_whitespace().count(),
        "words spoken is the raw count, before any cleanup"
    );
    assert!(
        result.formatted.starts_with(|c: char| c.is_uppercase()),
        "formatted text should start with a capital: {:?}",
        result.formatted
    );
    // Whatever else changed, the words the user actually said are still there.
    assert!(
        result.formatted.to_lowercase().contains("deploy"),
        "the formatter lost the content: {:?}",
        result.formatted
    );
    // And the ledger round-trips into the shape the history database stores.
    let ledger = formatter::LedgerEntry::decode(&result.ledger_json());
    assert_eq!(ledger, result.ledger);
}
