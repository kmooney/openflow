//! Fourth-order Butterworth high-pass, and the speech check that decides
//! whether a recording is worth handing to whisper at all.
//!
//! Ported from the macOS client with its constants intact: they were measured
//! on real recordings (notes/spec.md 6.1.1), not guessed, and re-deriving them
//! per platform would be re-running the same experiment for no reason.

/// Fourth-order Butterworth high-pass, as two cascaded biquads.
///
/// Aircraft cabin noise, HVAC rumble and handling thumps live mostly below
/// ~100 Hz; speech intelligibility starts around 300 Hz. Cutting the bottom end
/// costs nothing intelligible and removes a lot of energy whisper would
/// otherwise try to interpret.
///
/// Fourth order rather than second because the difference matters here: at an
/// octave below cutoff, 2nd order gives about -13 dB and 4th about -25 dB, and
/// cabin noise is loudest exactly there.
pub struct HighPassFilter {
    s1: Biquad,
    s2: Biquad,
}

impl Default for HighPassFilter {
    fn default() -> Self {
        Self::new(85.0, 16_000.0)
    }
}

impl HighPassFilter {
    pub fn new(cutoff: f32, sample_rate: f32) -> Self {
        // Butterworth pole Qs for a 4th-order cascade.
        HighPassFilter {
            s1: Biquad::new(cutoff, sample_rate, 0.5412),
            s2: Biquad::new(cutoff, sample_rate, 1.3066),
        }
    }

    /// Filters in place, carrying state across calls so chunked processing
    /// matches whole-array processing exactly.
    pub fn process(&mut self, samples: &mut [f32]) {
        self.s1.process(samples);
        self.s2.process(samples);
    }
}

struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

impl Biquad {
    fn new(cutoff: f32, sample_rate: f32, q: f32) -> Self {
        let w0 = 2.0 * std::f32::consts::PI * cutoff / sample_rate;
        let (sinw, cosw) = w0.sin_cos();
        let alpha = sinw / (2.0 * q);
        let a0 = 1.0 + alpha;
        Biquad {
            b0: (1.0 + cosw) / 2.0 / a0,
            b1: -(1.0 + cosw) / a0,
            b2: (1.0 + cosw) / 2.0 / a0,
            a1: (-2.0 * cosw) / a0,
            a2: (1.0 - alpha) / a0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    fn process(&mut self, samples: &mut [f32]) {
        for s in samples.iter_mut() {
            let x = *s;
            let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2
                - self.a1 * self.y1
                - self.a2 * self.y2;
            self.x2 = self.x1;
            self.x1 = x;
            self.y2 = self.y1;
            self.y1 = y;
            *s = y;
        }
    }
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum SpeechVerdict {
    Speech,
    /// Nothing there at all.
    Silence,
    /// Loud, but with no dynamics -- machinery, not a person.
    SteadyNoise,
}

impl SpeechVerdict {
    /// The value written to the history row's `outcome` column. Kept identical
    /// to the Swift clients so one database means one thing.
    pub fn outcome(self) -> &'static str {
        match self {
            SpeechVerdict::Speech => "ok",
            SpeechVerdict::Silence => "silence",
            SpeechVerdict::SteadyNoise => "steadyNoise",
        }
    }
}

/// Anything at or above this frame energy is loud enough to be speech, and is
/// accepted regardless of dynamics.
pub const SPEECH_LEVEL: f32 = 0.012;
/// Below this, treat as silence whatever the dynamics say.
///
/// These were 0.030 and 0.006, and both were too high by roughly 20 dB. Kept
/// identical to the Swift clients on purpose: measured on an iPhone, where a
/// normal speaking voice arrives around -38 dBFS peak, the old values rejected
/// five seconds of real speech as "heard nothing" with the microphone working
/// perfectly. A desktop captures louder than a phone, so the old numbers were
/// never *wrong* here — but they are guards, the dynamic-range test below does
/// the actual discrimination, and there is no reason for a guard to sit inside
/// the signal on any platform.
pub const SILENCE_LEVEL: f32 = 0.0015;
/// Only used to reject in the band between the two levels above.
pub const MIN_DYNAMIC_RATIO: f32 = 1.5;

pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let acc: f32 = samples.iter().map(|v| v * v).sum();
    (acc / samples.len() as f32).sqrt()
}

/// Does this recording plausibly contain speech?
///
/// Whisper will confabulate fluent sentences out of steady broadband noise, so
/// it is worth refusing to transcribe obvious non-speech. But the asymmetry
/// matters: **losing something you actually said is worse than a hallucination
/// you can see and delete.** So this is deliberately permissive and only
/// rejects the clearly-empty case.
pub fn speech_check(samples: &[f32], sample_rate: usize) -> SpeechVerdict {
    let window = sample_rate / 10; // 100 ms
    if samples.len() < window * 3 {
        return if rms(samples) > SILENCE_LEVEL {
            SpeechVerdict::Speech
        } else {
            SpeechVerdict::Silence
        };
    }

    let mut levels: Vec<f32> = samples.chunks_exact(window).map(rms).collect();
    levels.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    // The quiet end is the noise floor: a low percentile is right for it.
    let floor = levels[levels.len() / 10];

    // The loud end must be the LOUDEST frame, not a high percentile.
    //
    // Using the 90th percentile here assumed speech fills most of the
    // recording. It does not: hold the key, pause to think, say five words,
    // release, and forty of fifty frames are silence -- so the 90th percentile
    // *is* silence and the whole utterance was thrown away. What matters is
    // whether anything loud happened at all.
    let peak = levels[((levels.len() * 98) / 100).saturating_sub(1)];

    if peak < SILENCE_LEVEL {
        return SpeechVerdict::Silence;
    }
    // Clearly audible: accept without asking about dynamics. Automatic gain
    // control flattens them, and a quiet talker in a loud room is the case that
    // has to work.
    if peak >= SPEECH_LEVEL {
        return SpeechVerdict::Speech;
    }
    // In between: require some dynamics to tell a voice from a hum.
    if peak > floor * MIN_DYNAMIC_RATIO {
        SpeechVerdict::Speech
    } else {
        SpeechVerdict::SteadyNoise
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq: f32, seconds: f32, amp: f32) -> Vec<f32> {
        let n = (16_000.0 * seconds) as usize;
        (0..n)
            .map(|i| amp * (2.0 * std::f32::consts::PI * freq * i as f32 / 16_000.0).sin())
            .collect()
    }

    #[test]
    fn the_high_pass_removes_rumble_and_keeps_speech_band() {
        let mut low = tone(40.0, 1.0, 0.5);
        let mut mid = tone(1000.0, 1.0, 0.5);
        let before_low = rms(&low);
        let before_mid = rms(&mid);
        HighPassFilter::default().process(&mut low);
        HighPassFilter::default().process(&mut mid);
        // Ignore the settling transient at the head of each.
        assert!(rms(&low[2000..]) < before_low * 0.1, "40 Hz should be crushed");
        assert!(rms(&mid[2000..]) > before_mid * 0.9, "1 kHz should be untouched");
    }

    #[test]
    fn chunked_filtering_matches_whole_array_filtering() {
        let signal = tone(300.0, 0.5, 0.3);
        let mut whole = signal.clone();
        HighPassFilter::default().process(&mut whole);

        let mut chunked = signal.clone();
        let mut f = HighPassFilter::default();
        for chunk in chunked.chunks_mut(512) {
            f.process(chunk);
        }
        for (a, b) in whole.iter().zip(chunked.iter()) {
            assert!((a - b).abs() < 1e-6, "state must carry across chunks");
        }
    }

    #[test]
    fn silence_is_rejected() {
        let quiet = vec![0.0f32; 16_000];
        assert_eq!(speech_check(&quiet, 16_000), SpeechVerdict::Silence);
    }

    #[test]
    fn a_loud_steady_hum_is_not_speech() {
        // Constant amplitude, well under the absolute speech level: no
        // dynamics, so nothing here swings the way a voice does.
        let hum = tone(120.0, 2.0, 0.020);
        assert_eq!(speech_check(&hum, 16_000), SpeechVerdict::SteadyNoise);
    }

    /// Four taps on the desk in five seconds is 8% of the frames. An earlier
    /// version took the 90th percentile as "how loud did it get", so the
    /// answer was silence and the whole recording was thrown away. This is the
    /// case that found the bug.
    #[test]
    fn a_few_loud_moments_in_a_long_silence_are_not_silence() {
        let mut samples = vec![0.0f32; 16_000 * 5];
        for tap in 0..4 {
            let start = 16_000 + tap * 16_000;
            for i in start..start + 400 {
                samples[i] = 0.4 * (i as f32 * 0.1).sin();
            }
        }
        assert_eq!(speech_check(&samples, 16_000), SpeechVerdict::Speech);
    }

    /// Losing something you said is worse than a hallucination you can delete,
    /// so anything clearly audible is transcribed whatever its dynamics.
    #[test]
    fn clearly_audible_audio_is_accepted_regardless_of_dynamics() {
        let loud = tone(200.0, 2.0, 0.2);
        assert_eq!(speech_check(&loud, 16_000), SpeechVerdict::Speech);
    }

    #[test]
    fn a_very_short_recording_falls_back_to_level_alone() {
        let blip = tone(300.0, 0.05, 0.3);
        assert_eq!(speech_check(&blip, 16_000), SpeechVerdict::Speech);
        assert_eq!(speech_check(&vec![0.0; 400], 16_000), SpeechVerdict::Silence);
    }
}
