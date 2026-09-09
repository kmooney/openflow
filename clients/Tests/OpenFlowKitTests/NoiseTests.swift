import XCTest
import AVFoundation
@testable import OpenFlowKit

final class NoiseTests: XCTestCase {

    /// Speech alternating with pauses, over a constant noise floor -- the shape
    /// of dictating in a noisy cabin.
    private func noisySpeech(noise: Float, voice: Float, seconds: Int = 4) -> (mixed: [Float], clean: [Float]) {
        var mixed = [Float](), clean = [Float]()
        var rng = SystemRandomNumberGenerator()
        for i in 0..<(16_000 * seconds) {
            let speaking = (i / 8_000) % 2 == 0
            // two harmonics: closer to voiced speech than a single tone
            let v = speaking
                ? (sinf(2 * .pi * 180 * Float(i) / 16_000) * 0.6
                 + sinf(2 * .pi * 540 * Float(i) / 16_000) * 0.4) * voice
                : 0
            clean.append(v)
            mixed.append(v + Float.random(in: -noise...noise, using: &rng))
        }
        return (mixed, clean)
    }

    func testNoiseFloorDropsInThePauses() {
        let (mixed, _) = noisySpeech(noise: 0.05, voice: 0.25)
        let cleaned = NoiseReduction.reduce(mixed)
        XCTAssertEqual(cleaned.count, mixed.count)

        // second half of a pause, past any transition
        let pause = 10_000..<15_000
        let before = SignalStats.rms(Array(mixed[pause]))
        let after = SignalStats.rms(Array(cleaned[pause]))
        print("  pause noise: \(before) -> \(after)")
        XCTAssertLessThan(after, before * 0.5, "steady noise should be well suppressed in pauses")
    }

    func testSpeechSurvives() {
        let (mixed, clean) = noisySpeech(noise: 0.05, voice: 0.25)
        let cleaned = NoiseReduction.reduce(mixed)
        let speech = 2_000..<7_000
        // Compare against the CLEAN reference, not the noisy mix: some of the
        // drop from the mix is the noise we meant to remove.
        let reference = SignalStats.rms(Array(clean[speech]))
        let after = SignalStats.rms(Array(cleaned[speech]))
        print("  speech vs clean: \(reference) -> \(after)")
        XCTAssertGreaterThan(after, reference * 0.6, "speech must not be gutted with the noise")
    }

    func testSignalToNoiseImproves() {
        let (mixed, _) = noisySpeech(noise: 0.05, voice: 0.25)
        let cleaned = NoiseReduction.reduce(mixed)
        func snr(_ s: [Float]) -> Float {
            SignalStats.rms(Array(s[2_000..<7_000])) / max(SignalStats.rms(Array(s[10_000..<15_000])), 1e-6)
        }
        let before = snr(mixed), after = snr(cleaned)
        print("  SNR: \(before) -> \(after)")
        XCTAssertGreaterThan(after, before * 1.5, "the whole point is a better signal-to-noise ratio")
    }

    func testRealSpeechStaysIntelligibleAndDetectable() throws {
        let wav = URL(fileURLWithPath: "../m0/audio/s10.wav")
        guard FileManager.default.fileExists(atPath: wav.path) else { throw XCTSkip("no fixture") }
        let samples = try InteropTests.loadMono16kPublic(wav)
        let cleaned = NoiseReduction.reduce(samples)
        XCTAssertEqual(SignalStats.speechCheck(cleaned), .speech)
        // An already-clean recording should be returned essentially untouched.
        XCTAssertGreaterThan(SignalStats.rms(cleaned), SignalStats.rms(samples) * 0.95,
                             "denoising a clean recording only removes speech")
    }

    func testShortInputIsReturnedUnchanged() {
        let tiny = [Float](repeating: 0.1, count: 100)
        XCTAssertEqual(NoiseReduction.reduce(tiny), tiny)
    }
}

extension NoiseTests {
    /// Isolates the STFT round trip from the noise maths: with the gain pinned
    /// to 1, analysis + synthesis must reproduce the input. This is the test
    /// that catches reconstruction scaling errors, which otherwise masquerade
    /// as the denoiser being too aggressive.
    func testAnalysisSynthesisRoundTripIsUnityGain() {
        let over = NoiseReduction.overSubtraction
        let floor = NoiseReduction.spectralFloor
        let minRatio = NoiseReduction.minNoiseRatio
        defer {
            NoiseReduction.overSubtraction = over
            NoiseReduction.spectralFloor = floor
            NoiseReduction.minNoiseRatio = minRatio
        }
        NoiseReduction.overSubtraction = 0      // subtract nothing
        NoiseReduction.spectralFloor = 1.0      // gain pinned to 1
        NoiseReduction.minNoiseRatio = 0        // never take the skip path

        var rng = SystemRandomNumberGenerator()
        let input = (0..<32_000).map { i in
            sinf(2 * .pi * 300 * Float(i) / 16_000) * 0.3
                + Float.random(in: -0.05...0.05, using: &rng)
        }
        let out = NoiseReduction.reduce(input)

        // ignore the first and last frame, where overlap-add has no neighbour
        let body = 1_000..<31_000
        let a = SignalStats.rms(Array(input[body]))
        let b = SignalStats.rms(Array(out[body]))
        print("  round trip: \(a) -> \(b)")
        XCTAssertEqual(b, a, accuracy: a * 0.02, "STFT round trip must be unity gain")
    }
}

// MARK: - levelling quiet speech
//
// There is no gain knob on an iPhone: `setInputGain` is refused on the built-in
// microphone, and `.measurement` mode deliberately hands back audio with the
// system's AGC switched off. So a quiet talker is levelled here instead of
// being asked to raise their voice at their phone.

final class NormalizationTests: XCTestCase {

    /// Speech-shaped: bursts with gaps, which is what the percentile logic is
    /// built around.
    private func utterance(level: Float, seconds: Double = 3) -> [Float] {
        let n = Int(16_000 * seconds)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / 16_000
            // Talk for 300 ms, pause for 200 ms.
            let speaking = Int(t / 0.5) % 2 == 0
            guard speaking else { continue }
            out[i] = level * sin(2 * .pi * 180 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t))
        }
        return out
    }

    func testQuietSpeechIsLifted() {
        let quiet = utterance(level: 0.01)          // about -40 dBFS
        let (out, gainDB) = SignalStats.normalized(quiet)

        XCTAssertGreaterThan(gainDB, 6, "a very quiet capture must be lifted appreciably")
        XCTAssertGreaterThan(SignalStats.rms(out), SignalStats.rms(quiet))
    }

    /// Never attenuate. Whisper copes with a hot recording far better than a
    /// quiet one, and pulling a good recording down helps nobody.
    func testHealthyRecordingIsUntouched() {
        let healthy = utterance(level: 0.5)
        let (out, gainDB) = SignalStats.normalized(healthy)

        XCTAssertEqual(gainDB, 0, "an already-loud recording must be returned as-is")
        XCTAssertEqual(out, healthy)
    }

    /// The gain must never drive the waveform into clipping: square edges are
    /// precisely the artefact whisper reads as noise.
    func testGainNeverClips() {
        var quiet = utterance(level: 0.02)
        quiet[1000] = 0.9                            // a knock on the desk
        let (out, _) = SignalStats.normalized(quiet)

        let peak = out.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(peak, 1.0, "normalisation must not clip")
    }

    /// One transient must not set the level for a whole utterance — that is why
    /// frame energies are used rather than the absolute peak.
    func testTransientDoesNotSuppressTheGain() {
        var quiet = utterance(level: 0.01)
        quiet[500] = 0.35                            // a single loud click
        let (_, gainDB) = SignalStats.normalized(quiet)

        XCTAssertGreaterThan(gainDB, 3, "a click must not decide the gain for the utterance")
    }

    func testSilenceIsLeftAlone() {
        let (out, gainDB) = SignalStats.normalized([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(gainDB, 0)
        XCTAssertTrue(out.allSatisfy { $0 == 0 }, "there is nothing to amplify in silence")
    }
}

// MARK: - the levels a phone actually produces
//
// The speech check's absolute guards were tuned against a Mac. An iPhone in
// `.measurement` mode delivers a normal speaking voice around -38 dBFS peak,
// some 20 dB below what those numbers assumed, and five seconds of real speech
// was discarded as "heard nothing" with the microphone working perfectly.

final class QuietSpeechTests: XCTestCase {

    /// Speech-shaped: bursts with gaps, at a level a phone really delivers.
    private func utterance(peak: Float, seconds: Double = 5) -> [Float] {
        let n = Int(16_000 * seconds)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / 16_000
            guard Int(t / 0.5) % 2 == 0 else { continue }   // talk, pause, talk
            out[i] = peak * sin(2 * .pi * 180 * t) * (0.6 + 0.4 * sin(2 * .pi * 3 * t))
        }
        return out
    }

    /// The exact case that was being thrown away: -38 dBFS peak, five seconds.
    func testQuietPhoneSpeechIsAccepted() {
        let quiet = utterance(peak: 0.0126)             // -38 dBFS
        XCTAssertEqual(SignalStats.speechCheck(quiet), .speech,
                       "a normal speaking voice on a phone must not read as silence")
    }

    /// Still permissive at the level the meter showed on failing recordings.
    func testVeryQuietSpeechIsAccepted() {
        XCTAssertEqual(SignalStats.speechCheck(utterance(peak: 0.005)), .speech)
    }

    /// The guard must still catch an empty room. Steady broadband noise is what
    /// whisper confabulates fluent sentences out of.
    func testSteadyNoiseIsStillRejected() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<(16_000 * 5)).map { _ in
            Float.random(in: -0.004...0.004, using: &rng)
        }
        XCTAssertNotEqual(SignalStats.speechCheck(noise), .speech,
                          "lowering the floor must not let a hum through as speech")
    }

    func testDigitalSilenceIsStillSilence() {
        XCTAssertEqual(SignalStats.speechCheck([Float](repeating: 0, count: 16_000 * 3)),
                       .silence)
    }
}
