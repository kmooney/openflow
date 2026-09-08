//! Microphone capture, resampled to the 16 kHz mono float whisper expects.
//!
//! WASAPI through cpal. Shared-mode capture arrives at whatever the device's
//! mix format is -- 48 kHz stereo on most machines -- so resampling is not
//! optional here the way it nearly is on a Mac.
//!
//! Two rules carried over from the macOS client, both of which were learned the
//! hard way (notes/spec.md 6.1.1):
//!
//! - **The resampler is built from the format actually delivered**, never from
//!   one read beforehand. A converter whose ratio disagrees with the buffers
//!   arriving emits zeros, and a capture of exact digital zeros is
//!   indistinguishable downstream from a quiet room.
//! - **Anything touching capture needs a runtime assertion in the shipping
//!   app**, because a test runner has no microphone and proves nothing about
//!   this file. `saw_signal` is that assertion.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

use crate::kit::filters::HighPassFilter;

pub const TARGET_RATE: u32 = 16_000;

#[derive(Default)]
struct Capture {
    samples: Vec<f32>,
    peak: f32,
    saw_signal: bool,
    high_pass: Option<HighPassFilter>,
    resampler: Option<Resampler>,
    /// The device format the current resampler was built for. Checked on every
    /// callback: a format that changes mid-session must rebuild it, not be
    /// resampled with the old ratio.
    source: Option<(u32, u16)>,
}

pub struct AudioRecorder {
    stream: Option<cpal::Stream>,
    capture: Arc<Mutex<Capture>>,
    failed: Arc<Mutex<Option<String>>>,
    running: Arc<AtomicBool>,
    /// High-pass the captured audio to strip low-frequency rumble.
    pub use_high_pass: bool,
    /// What the device is actually giving us, for the settings pane.
    pub device_name: Option<String>,
    pub input_rate: Option<u32>,
}

impl Default for AudioRecorder {
    fn default() -> Self {
        AudioRecorder {
            stream: None,
            capture: Arc::new(Mutex::new(Capture::default())),
            failed: Arc::new(Mutex::new(None)),
            running: Arc::new(AtomicBool::new(false)),
            use_high_pass: true,
            device_name: None,
            input_rate: None,
        }
    }
}

impl AudioRecorder {
    pub fn is_recording(&self) -> bool {
        self.stream.is_some()
    }

    pub fn start(&mut self) -> Result<(), String> {
        if self.stream.is_some() {
            return Ok(());
        }
        {
            let mut c = self.capture.lock().unwrap();
            *c = Capture {
                high_pass: self.use_high_pass.then(HighPassFilter::default),
                ..Default::default()
            };
        }
        *self.failed.lock().unwrap() = None;

        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or("No microphone is available. Check Settings > Privacy > Microphone.")?;
        self.device_name = device.description().ok().map(|d| d.name().to_string());

        let supported = device
            .default_input_config()
            .map_err(|e| format!("Could not read the microphone's format: {e}"))?;
        let sample_format = supported.sample_format();
        let config = supported.config();
        self.input_rate = Some(config.sample_rate);

        let capture = self.capture.clone();
        let failed = self.failed.clone();
        let running = self.running.clone();
        let channels = config.channels;
        let rate = config.sample_rate;
        let high_pass = self.use_high_pass;

        let on_error = {
            let failed = failed.clone();
            let running = running.clone();
            move |e: cpal::Error| {
                *failed.lock().unwrap() = Some(e.to_string());
                running.store(false, Ordering::Relaxed);
            }
        };

        // Sample formats other than f32 are converted at the edge rather than
        // threaded through the pipeline: everything downstream is f32, and one
        // conversion site is easier to keep correct than four.
        let stream = match sample_format {
            cpal::SampleFormat::F32 => device.build_input_stream(
                config.clone(),
                move |data: &[f32], _| append(&capture, data, rate, channels, high_pass),
                on_error,
                None,
            ),
            cpal::SampleFormat::I16 => device.build_input_stream(
                config.clone(),
                move |data: &[i16], _| {
                    let f: Vec<f32> = data.iter().map(|v| *v as f32 / 32768.0).collect();
                    append(&capture, &f, rate, channels, high_pass);
                },
                on_error,
                None,
            ),
            cpal::SampleFormat::U16 => device.build_input_stream(
                config.clone(),
                move |data: &[u16], _| {
                    let f: Vec<f32> = data
                        .iter()
                        .map(|v| (*v as f32 - 32768.0) / 32768.0)
                        .collect();
                    append(&capture, &f, rate, channels, high_pass);
                },
                on_error,
                None,
            ),
            other => return Err(format!("Unsupported microphone sample format: {other:?}")),
        }
        .map_err(|e| format!("Could not open the microphone: {e}"))?;

        stream
            .play()
            .map_err(|e| format!("Could not start the microphone: {e}"))?;
        self.running.store(true, Ordering::Relaxed);
        self.stream = Some(stream);
        Ok(())
    }

    /// Stop and hand back everything captured.
    pub fn stop(&mut self) -> Vec<f32> {
        let Some(stream) = self.stream.take() else {
            return Vec::new();
        };
        drop(stream);
        self.running.store(false, Ordering::Relaxed);
        let mut c = self.capture.lock().unwrap();
        std::mem::take(&mut c.samples)
    }

    /// Has any non-zero sample arrived yet? The one question worth asking
    /// early: if this is still false half a second in, the graph is dead and no
    /// amount of waiting will fix it.
    pub fn has_signal(&self) -> bool {
        self.capture.lock().unwrap().saw_signal
    }

    /// Whatever the audio backend reported asynchronously. A device unplugged
    /// mid-utterance arrives here rather than as a silent short recording.
    pub fn error(&self) -> Option<String> {
        self.failed.lock().unwrap().clone()
    }

    /// Loudest sample since the last read, as dBFS, for a live meter. Reading
    /// resets it, so callers see peak-since-last-poll rather than peak-ever.
    pub fn drain_peak_db(&self) -> f32 {
        let mut c = self.capture.lock().unwrap();
        let peak = c.peak;
        c.peak = 0.0;
        if peak > 0.0 {
            20.0 * peak.log10()
        } else {
            -120.0
        }
    }

    /// Seconds captured so far, for the recording indicator.
    pub fn duration(&self) -> f64 {
        self.capture.lock().unwrap().samples.len() as f64 / TARGET_RATE as f64
    }
}

fn append(
    capture: &Arc<Mutex<Capture>>,
    data: &[f32],
    rate: u32,
    channels: u16,
    high_pass: bool,
) {
    if data.is_empty() || channels == 0 {
        return;
    }
    let mut c = capture.lock().unwrap();

    // Build the resampler from the format actually being delivered, and rebuild
    // if it ever changes. Deriving it from a format read earlier is what
    // produced captures of exact digital zeros on macOS.
    if c.source != Some((rate, channels)) {
        c.source = Some((rate, channels));
        c.resampler = Some(Resampler::new(rate, TARGET_RATE));
    }

    // Downmix first: a stereo headset puts the voice in both channels, and
    // resampling interleaved frames would blend two different instants.
    let mono: Vec<f32> = if channels == 1 {
        data.to_vec()
    } else {
        data.chunks(channels as usize)
            .map(|f| f.iter().sum::<f32>() / f.len() as f32)
            .collect()
    };

    let mut chunk = match c.resampler.as_mut() {
        Some(r) => r.process(&mono),
        None => mono,
    };
    if chunk.is_empty() {
        return;
    }

    // Filter state is carried across chunks, so this must stay under the same
    // lock and in capture order.
    if high_pass {
        if let Some(f) = c.high_pass.as_mut() {
            f.process(&mut chunk);
        }
    }

    let chunk_peak = chunk.iter().fold(0.0f32, |m, v| m.max(v.abs()));
    c.peak = c.peak.max(chunk_peak);
    if chunk_peak > 0.0 {
        c.saw_signal = true;
    }
    c.samples.extend_from_slice(&chunk);
}

/// Rate conversion with an anti-aliasing box average.
///
/// Every real microphone on Windows hands over 44.1 or 48 kHz, so this almost
/// always decimates by 3-ish. Straight linear interpolation would fold
/// everything above 8 kHz back down into the speech band; averaging the source
/// samples that fall inside each output period removes most of it for a few
/// additions per sample. When the source rate is *below* the target the window
/// is shorter than one sample and it degrades to linear interpolation, which is
/// the right behaviour there.
struct Resampler {
    ratio: f64,
    /// Fractional read position into the concatenated source stream.
    position: f64,
    /// Source samples not yet consumed, carried between callbacks so chunk
    /// boundaries are not audible.
    pending: Vec<f32>,
}

impl Resampler {
    fn new(from: u32, to: u32) -> Resampler {
        Resampler {
            ratio: from as f64 / to as f64,
            position: 0.0,
            pending: Vec::new(),
        }
    }

    fn process(&mut self, input: &[f32]) -> Vec<f32> {
        self.pending.extend_from_slice(input);
        if self.ratio == 1.0 {
            return std::mem::take(&mut self.pending);
        }

        let mut out = Vec::with_capacity((self.pending.len() as f64 / self.ratio) as usize + 1);
        loop {
            let start = self.position;
            let end = start + self.ratio;
            // Need one sample past the window for the interpolating case.
            if end.ceil() as usize + 1 > self.pending.len() {
                break;
            }
            out.push(sample_window(&self.pending, start, end));
            self.position = end;
        }

        // Drop what has been fully consumed, keeping the fractional offset.
        let consumed = self.position.floor() as usize;
        if consumed > 0 {
            self.pending.drain(..consumed.min(self.pending.len()));
            self.position -= consumed as f64;
        }
        out
    }
}

fn sample_window(data: &[f32], start: f64, end: f64) -> f32 {
    let first = start.floor() as usize;
    let last = end.floor() as usize;
    if first == last {
        // Window narrower than one sample: linear interpolation.
        let frac = start - start.floor();
        let a = data[first];
        let b = *data.get(first + 1).unwrap_or(&a);
        return a + (b - a) * frac as f32;
    }
    // Average across the window, weighting the partial samples at each end.
    let mut acc = 0.0f64;
    let mut weight = 0.0f64;
    for i in first..=last.min(data.len() - 1) {
        let lo = (i as f64).max(start);
        let hi = ((i + 1) as f64).min(end);
        let w = (hi - lo).max(0.0);
        acc += data[i] as f64 * w;
        weight += w;
    }
    if weight > 0.0 {
        (acc / weight) as f32
    } else {
        data[first]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kit::filters::rms;

    fn sine(freq: f32, rate: u32, seconds: f32) -> Vec<f32> {
        let n = (rate as f32 * seconds) as usize;
        (0..n)
            .map(|i| (2.0 * std::f32::consts::PI * freq * i as f32 / rate as f32).sin() * 0.5)
            .collect()
    }

    #[test]
    fn forty_eight_k_becomes_sixteen_k_at_the_right_length() {
        let input = sine(440.0, 48_000, 1.0);
        let mut r = Resampler::new(48_000, 16_000);
        let out = r.process(&input);
        // Within a sample or two of a third: the tail waits for more input.
        assert!(
            (out.len() as i64 - 16_000).abs() < 4,
            "expected ~16000 samples, got {}",
            out.len()
        );
    }

    #[test]
    fn resampling_preserves_level() {
        let input = sine(440.0, 48_000, 0.5);
        let mut r = Resampler::new(48_000, 16_000);
        let out = r.process(&input);
        let before = rms(&input);
        let after = rms(&out);
        assert!(
            (after - before).abs() < before * 0.05,
            "level must survive resampling: {before} -> {after}"
        );
    }

    /// The bug this guards against is a resampler that emits nothing, or
    /// emits at the wrong rate, when the callback size does not divide evenly
    /// by the ratio.
    #[test]
    fn chunked_input_produces_the_same_total_as_one_pass() {
        let input = sine(300.0, 44_100, 0.5);
        let mut whole = Resampler::new(44_100, 16_000);
        let one_pass = whole.process(&input);

        let mut chunked = Resampler::new(44_100, 16_000);
        let mut pieces = Vec::new();
        for chunk in input.chunks(479) {
            pieces.extend(chunked.process(chunk));
        }
        assert!(
            (pieces.len() as i64 - one_pass.len() as i64).abs() <= 1,
            "chunking must not change the output length: {} vs {}",
            pieces.len(),
            one_pass.len()
        );
        for (a, b) in one_pass.iter().zip(pieces.iter()) {
            assert!((a - b).abs() < 1e-5, "chunk boundaries must be inaudible");
        }
    }

    /// Whisper is fed 16 kHz, so anything above 8 kHz has to be attenuated on
    /// the way down or it folds back into the speech band as a whistle.
    #[test]
    fn high_frequencies_are_attenuated_rather_than_aliased() {
        let input = sine(15_000.0, 48_000, 0.5); // well above the 8 kHz limit
        let mut r = Resampler::new(48_000, 16_000);
        let out = r.process(&input);
        assert!(
            rms(&out) < rms(&input) * 0.4,
            "a 15 kHz tone must not survive decimation at full level"
        );
    }

    #[test]
    fn speech_band_content_passes_through() {
        let input = sine(500.0, 48_000, 0.5);
        let mut r = Resampler::new(48_000, 16_000);
        let out = r.process(&input);
        assert!(rms(&out) > rms(&input) * 0.9, "500 Hz must survive intact");
    }

    #[test]
    fn a_matching_rate_is_passed_straight_through() {
        let input = sine(300.0, 16_000, 0.1);
        let mut r = Resampler::new(16_000, 16_000);
        assert_eq!(r.process(&input), input);
    }

    #[test]
    fn upsampling_from_a_slow_device_still_works() {
        let input = sine(300.0, 8_000, 0.5);
        let mut r = Resampler::new(8_000, 16_000);
        let out = r.process(&input);
        assert!((out.len() as i64 - 8_000).abs() < 4);
        assert!(rms(&out) > rms(&input) * 0.9);
    }
}
