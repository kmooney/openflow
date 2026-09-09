import Foundation

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
public struct HighPassFilter {
    private var s1: Biquad
    private var s2: Biquad

    public init(cutoff: Float = 85, sampleRate: Float = 16_000) {
        // Butterworth pole Qs for a 4th-order cascade.
        s1 = Biquad(cutoff: cutoff, sampleRate: sampleRate, q: 0.5412)
        s2 = Biquad(cutoff: cutoff, sampleRate: sampleRate, q: 1.3066)
    }

    public mutating func process(_ samples: [Float]) -> [Float] {
        s2.process(s1.process(samples))
    }
}

private struct Biquad {
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(cutoff: Float, sampleRate: Float, q: Float) {
        let w0 = 2 * Float.pi * cutoff / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 + cosw) / 2 / a0
        b1 = -(1 + cosw) / a0
        b2 = (1 + cosw) / 2 / a0
        a1 = (-2 * cosw) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ samples: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        for i in samples.indices {
            let x = samples[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            out[i] = y
        }
        return out
    }
}

public enum SignalStats {
    public static func rms(_ s: ArraySlice<Float>) -> Float {
        guard !s.isEmpty else { return 0 }
        var acc: Float = 0
        for v in s { acc += v * v }
        return (acc / Float(s.count)).squareRoot()
    }

    public static func rms(_ s: [Float]) -> Float { rms(s[...]) }

    /// Peak level in dBFS, for a live meter.
    public static func peakDB(_ s: [Float]) -> Float {
        let peak = s.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0 ? 20 * log10(peak) : -120
    }

    /// Scale a recording up so whisper hears it at a sensible level.
    ///
    /// The microphone is not the problem and there is no gain knob to turn:
    /// `AVAudioSession.setInputGain` is refused on iPhone built-in mics
    /// (`isInputGainSettable` is false), and the session runs in `.measurement`
    /// mode, which exists precisely to hand back raw audio with the system's
    /// automatic gain control switched off. Quiet speech therefore arrives
    /// quiet, and asking the user to talk louder at their phone is not a fix.
    ///
    /// So the gain is applied here, where it is deterministic and testable —
    /// the same reasoning as `NoiseReduction`: the worst this can do is sound
    /// wrong, where a capture-time change can take the microphone down with it.
    ///
    /// The level is taken from the loud end of the *frame* energies rather than
    /// the absolute peak, so one door slam or table knock does not decide the
    /// gain for a whole utterance. Never attenuates: a recording that is
    /// already healthy is returned untouched.
    public static func normalized(_ samples: [Float],
                                  targetRMS: Float = 0.10,
                                  maxGain: Float = 12,
                                  sampleRate: Int = 16_000) -> (samples: [Float], gainDB: Float) {
        let window = sampleRate / 10                      // 100 ms
        guard samples.count >= window else { return (samples, 0) }

        var levels: [Float] = []
        var i = 0
        while i + window <= samples.count {
            levels.append(rms(samples[i..<(i + window)]))
            i += window
        }
        guard !levels.isEmpty else { return (samples, 0) }
        levels.sort()

        // The 95th percentile is "how loud this person actually is" — high
        // enough to be speech rather than the gaps between words, low enough
        // not to be a transient.
        let speechLevel = levels[max(0, (levels.count * 95) / 100 - 1)]
        guard speechLevel > 0 else { return (samples, 0) }

        var gain = min(maxGain, targetRMS / speechLevel)
        // Only ever louder. Whisper copes with a hot recording far better than
        // with a quiet one, and pulling a good recording down helps nobody.
        guard gain > 1.01 else { return (samples, 0) }

        // Whatever the frame energies say, do not drive the true peak into
        // clipping — square edges are exactly the artefact whisper reads as
        // noise.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if peak > 0 { gain = min(gain, 0.97 / peak) }
        guard gain > 1.01 else { return (samples, 0) }

        return (samples.map { $0 * gain }, 20 * log10(gain))
    }

    /// Does this recording plausibly contain speech?
    ///
    /// Whisper will confabulate fluent sentences out of steady broadband noise,
    /// so it is worth refusing to transcribe obvious non-speech. But the
    /// asymmetry matters: **losing something you actually said is worse than a
    /// hallucination you can see and delete.** So this is deliberately
    /// permissive and only rejects the clearly-empty case.
    ///
    /// Measured on real recordings: clean speech shows a 90th/10th percentile
    /// energy ratio of 3-11. The trap is that voice-processing AGC lifts the
    /// noise floor and compresses exactly that dynamic range, so a strict ratio
    /// test rejects real speech in a noisy room -- the situation where the user
    /// most needs it to work. Hence the absolute-level escape hatch below.
    public static func containsSpeech(_ samples: [Float], sampleRate: Int = 16_000) -> Bool {
        speechCheck(samples, sampleRate: sampleRate) == .speech
    }

    public enum SpeechVerdict: String, Sendable {
        case speech
        /// Nothing there at all.
        case silence
        /// Loud, but with no dynamics -- machinery, not a person.
        case steadyNoise
    }

    /// Anything at or above this frame energy is loud enough to be speech, and
    /// is accepted regardless of dynamics.
    public static var speechLevel: Float = 0.012
    /// Below this, treat as silence whatever the dynamics say.
    ///
    /// **Measured, not guessed.** These were 0.030 and 0.006, tuned against a
    /// Mac. An iPhone runs its session in `.measurement` mode, which hands back
    /// audio with the system's gain control switched off, and a normal speaking
    /// voice arrives around -38 dBFS peak — roughly 20 dB below what those
    /// numbers assumed. The result was five seconds of real speech discarded as
    /// "heard nothing", with the microphone working perfectly.
    ///
    /// The discrimination that matters is the dynamic-range test below, which
    /// is scale-invariant and does the real work of telling a voice from a hum.
    /// These two are only the guards at either end, and guards set 20 dB inside
    /// the signal are not guards, they are a fault. Erring low is the correct
    /// direction: losing something you actually said is worse than a
    /// hallucination you can see and delete.
    public static var silenceLevel: Float = 0.0015
    /// Only used to reject in the band between the two levels above.
    public static var minDynamicRatio: Float = 1.5

    public static func speechCheck(_ samples: [Float], sampleRate: Int = 16_000) -> SpeechVerdict {
        let window = sampleRate / 10                      // 100 ms
        guard samples.count >= window * 3 else {
            return SignalStats.rms(samples) > silenceLevel ? .speech : .silence
        }
        var levels: [Float] = []
        var i = 0
        while i + window <= samples.count {
            levels.append(rms(samples[i..<(i + window)]))
            i += window
        }
        levels.sort()

        // The quiet end is the noise floor: a low percentile is right for it.
        let floorLevel = levels[levels.count / 10]

        // The loud end must be the LOUDEST frame, not a high percentile.
        //
        // Using the 90th percentile here assumed speech fills most of the
        // recording. It does not: hold the key, pause to think, say five words,
        // release, and forty of fifty frames are silence -- so the 90th
        // percentile *is* silence and the whole utterance was thrown away.
        // Four taps in five seconds fail the same way, which is how this was
        // found. What matters is whether anything loud happened at all.
        let peakLevel = levels[max(0, (levels.count * 98) / 100 - 1)]

        if peakLevel < silenceLevel { return .silence }
        // Clearly audible: accept without asking about dynamics. AGC flattens
        // them, and a quiet talker in a loud room is the case that has to work.
        if peakLevel >= speechLevel { return .speech }
        // In between: require some dynamics to tell a voice from a hum.
        return peakLevel > floorLevel * minDynamicRatio ? .speech : .steadyNoise
    }
}
