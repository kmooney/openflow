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
