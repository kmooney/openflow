//! Spectral-subtraction noise reduction.
//!
//! Ours rather than the operating system's. It runs on a plain array of samples
//! after capture, so the worst it can do is sound bad -- it cannot take the
//! microphone down with it, which is exactly what happened when the macOS
//! client tried to lean on Apple's voice-processing unit (notes/spec.md 6.1.1).
//! It is also deterministic and testable, which a duplex audio unit is not.
//!
//! The method suits the problem: aircraft, HVAC and fan noise are close to
//! stationary, and stationary noise is precisely what spectral subtraction
//! removes well. It estimates a per-frequency noise floor from the quietest
//! frames -- no separate "silence sample" needed, because a dictated utterance
//! always contains pauses.

use rustfft::{num_complex::Complex32, FftPlanner};

const FRAME: usize = 512;
const HOP: usize = 256; // 50% overlap; Hann squared sums to a constant

#[derive(Copy, Clone, Debug)]
pub struct NoiseReduction {
    /// How aggressively to subtract the estimated noise. Above ~2.5 speech
    /// starts to sound watery.
    pub over_subtraction: f32,
    /// Never attenuate a bin below this fraction of its original magnitude.
    /// Zeroing bins outright is what makes spectral subtraction sound like
    /// bubbling ("musical noise"); leaving a floor avoids it.
    pub spectral_floor: f32,
    /// Percentile of frame magnitudes taken as the noise estimate, per bin.
    /// Per-bin magnitudes of broadband noise are Rayleigh-distributed, so a low
    /// percentile sits well under the mean and subtracting it barely dents the
    /// noise. A quarter is high enough to bite and still below the level speech
    /// reaches in any bin it occupies.
    pub noise_percentile: f32,
    /// Below this noise-to-signal ratio the recording is already clean and is
    /// returned untouched. Denoising clean audio only removes speech: the
    /// per-bin "noise" estimate of a quiet recording is mostly quiet speech.
    pub min_noise_ratio: f32,
}

impl Default for NoiseReduction {
    fn default() -> Self {
        NoiseReduction {
            over_subtraction: 2.0,
            spectral_floor: 0.08,
            noise_percentile: 0.25,
            min_noise_ratio: 0.18,
        }
    }
}

/// Denoise with the shipped settings.
pub fn reduce(samples: &[f32]) -> Vec<f32> {
    NoiseReduction::default().reduce(samples)
}

impl NoiseReduction {
    pub fn reduce(&self, samples: &[f32]) -> Vec<f32> {
        let n = FRAME;
        if samples.len() < n * 4 {
            return samples.to_vec();
        }

        let mut planner = FftPlanner::<f32>::new();
        let forward = planner.plan_fft_forward(n);
        let inverse = planner.plan_fft_inverse(n);

        let window: Vec<f32> = (0..n)
            .map(|i| 0.5 * (1.0 - (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos()))
            .collect();

        let half = n / 2;
        let frame_count = (samples.len() - n) / HOP + 1;

        // --- analysis: FFT every frame, keep the spectra
        let mut spectra: Vec<Vec<Complex32>> = Vec::with_capacity(frame_count);
        let mut mags: Vec<Vec<f32>> = Vec::with_capacity(frame_count);
        for f in 0..frame_count {
            let start = f * HOP;
            let mut buf: Vec<Complex32> = (0..n)
                .map(|i| Complex32::new(samples[start + i] * window[i], 0.0))
                .collect();
            forward.process(&mut buf);
            mags.push((0..=half).map(|b| buf[b].norm()).collect());
            spectra.push(buf);
        }

        // --- noise estimate: a low percentile per bin, across time.
        // A dictated utterance always has pauses, so the quiet end of each
        // bin's history is the noise floor. No calibration step required.
        let idx = ((frame_count as f32 * self.noise_percentile) as usize).min(frame_count - 1);
        let mut noise = vec![0.0f32; half + 1];
        let mut column = vec![0.0f32; frame_count];
        for (b, slot) in noise.iter_mut().enumerate() {
            for (f, c) in column.iter_mut().enumerate() {
                *c = mags[f][b];
            }
            column.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            *slot = column[idx];
        }

        // Is there enough noise to be worth removing? Comparing the estimated
        // floor against the overall level answers it. On a clean recording the
        // "noise" estimate is largely quiet speech, and subtracting it costs
        // half the signal for no benefit.
        let noise_mean: f32 = noise.iter().sum::<f32>() / noise.len() as f32;
        let overall_mean: f32 = mags.iter().map(|m| m.iter().sum::<f32>()).sum::<f32>()
            / (frame_count * (half + 1)) as f32;
        if overall_mean <= 1e-9 || noise_mean / overall_mean < self.min_noise_ratio {
            return samples.to_vec();
        }

        // --- gain per bin, applied to the complex spectrum so phase is kept.
        // The mirrored half gets the same gain, or the inverse transform stops
        // being real.
        for (f, spec) in spectra.iter_mut().enumerate() {
            for b in 0..=half {
                let m = mags[f][b];
                if m <= 1e-9 {
                    continue;
                }
                let cleaned = m - self.over_subtraction * noise[b];
                let gain = (cleaned / m).max(self.spectral_floor);
                spec[b] *= gain;
                if b > 0 && b < half {
                    spec[n - b] *= gain;
                }
            }
        }

        // --- synthesis: inverse FFT and overlap-add
        let mut out = vec![0.0f32; samples.len()];
        let mut norm = vec![0.0f32; samples.len()];
        let scale = 1.0 / n as f32;

        for (f, spec) in spectra.iter_mut().enumerate() {
            inverse.process(spec);
            let start = f * HOP;
            for i in 0..n {
                out[start + i] += spec[i].re * scale * window[i];
                norm[start + i] += window[i] * window[i];
            }
        }

        for i in 0..out.len() {
            if norm[i] > 1e-6 {
                out[i] /= norm[i];
            } else {
                // The first and last half-frame have no overlapping neighbour;
                // passing the input through beats fading it to nothing.
                out[i] = samples[i];
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::kit::filters::{rms, speech_check, SpeechVerdict};

    /// Cheap deterministic noise. A seeded generator rather than a real RNG so
    /// a failure is reproducible.
    struct Rng(u32);
    impl Rng {
        fn next(&mut self) -> f32 {
            self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (self.0 >> 8) as f32 / 8_388_608.0 - 1.0 // -1..1
        }
    }

    /// Speech alternating with pauses, over a constant noise floor -- the shape
    /// of dictating in a noisy cabin.
    fn noisy_speech(noise: f32, voice: f32, seconds: usize) -> (Vec<f32>, Vec<f32>) {
        let mut rng = Rng(12345);
        let mut mixed = Vec::new();
        let mut clean = Vec::new();
        for i in 0..(16_000 * seconds) {
            let speaking = (i / 8_000) % 2 == 0;
            let t = i as f32 / 16_000.0;
            // Two harmonics: closer to voiced speech than a single tone.
            let v = if speaking {
                ((2.0 * std::f32::consts::PI * 180.0 * t).sin() * 0.6
                    + (2.0 * std::f32::consts::PI * 540.0 * t).sin() * 0.4)
                    * voice
            } else {
                0.0
            };
            clean.push(v);
            mixed.push(v + rng.next() * noise);
        }
        (mixed, clean)
    }

    #[test]
    fn noise_floor_drops_in_the_pauses() {
        let (mixed, _) = noisy_speech(0.05, 0.25, 4);
        let cleaned = reduce(&mixed);
        assert_eq!(cleaned.len(), mixed.len());
        // Second half of a pause, past any transition.
        let before = rms(&mixed[10_000..15_000]);
        let after = rms(&cleaned[10_000..15_000]);
        assert!(
            after < before * 0.5,
            "steady noise should be well suppressed in pauses: {before} -> {after}"
        );
    }

    #[test]
    fn speech_survives() {
        let (mixed, clean) = noisy_speech(0.05, 0.25, 4);
        let cleaned = reduce(&mixed);
        // Compare against the CLEAN reference, not the noisy mix: some of the
        // drop from the mix is the noise we meant to remove.
        let reference = rms(&clean[2_000..7_000]);
        let after = rms(&cleaned[2_000..7_000]);
        assert!(
            after > reference * 0.6,
            "speech must not be gutted with the noise: {reference} -> {after}"
        );
    }

    #[test]
    fn signal_to_noise_improves() {
        let (mixed, _) = noisy_speech(0.05, 0.25, 4);
        let cleaned = reduce(&mixed);
        let snr = |s: &[f32]| rms(&s[2_000..7_000]) / rms(&s[10_000..15_000]).max(1e-6);
        let before = snr(&mixed);
        let after = snr(&cleaned);
        assert!(
            after > before * 1.5,
            "the whole point is a better signal-to-noise ratio: {before} -> {after}"
        );
    }

    #[test]
    fn a_clean_recording_is_returned_untouched() {
        let (_, clean) = noisy_speech(0.0, 0.25, 4);
        let out = reduce(&clean);
        assert_eq!(out, clean, "denoising clean audio only removes speech");
        assert_eq!(speech_check(&out, 16_000), SpeechVerdict::Speech);
    }

    #[test]
    fn short_input_is_returned_unchanged() {
        let tiny = vec![0.1f32; 100];
        assert_eq!(reduce(&tiny), tiny);
    }

    /// Isolates the STFT round trip from the noise maths: with the gain pinned
    /// to 1, analysis + synthesis must reproduce the input. This is the test
    /// that catches reconstruction scaling errors, which otherwise masquerade
    /// as the denoiser being too aggressive.
    #[test]
    fn analysis_synthesis_round_trip_is_unity_gain() {
        let nr = NoiseReduction {
            over_subtraction: 0.0, // subtract nothing
            spectral_floor: 1.0,   // gain pinned to 1
            min_noise_ratio: 0.0,  // never take the skip path
            ..Default::default()
        };
        let mut rng = Rng(999);
        let input: Vec<f32> = (0..32_000)
            .map(|i| {
                (2.0 * std::f32::consts::PI * 300.0 * i as f32 / 16_000.0).sin() * 0.3
                    + rng.next() * 0.05
            })
            .collect();
        let out = nr.reduce(&input);
        // Ignore the head and tail, where overlap-add has no neighbour.
        let a = rms(&input[1_000..31_000]);
        let b = rms(&out[1_000..31_000]);
        assert!(
            (b - a).abs() < a * 0.02,
            "STFT round trip must be unity gain: {a} -> {b}"
        );
    }
}
