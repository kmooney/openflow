import XCTest
import AVFoundation
@testable import OpenFlowKit

/// These verify the seams, not the logic. The formatting rules are tested in
/// Rust (60 tests); what can only break here is the interop.
final class InteropTests: XCTestCase {

    func testRustCoreIsReachable() {
        XCTAssertFalse(Formatter.coreVersion.isEmpty)
    }

    func testFormattingCrossesTheFFIIntact() {
        let r = Formatter.format("Um, so the deploy failed and uh I think we should roll back.",
                                 tone: .formal)
        XCTAssertTrue(r.ok)
        XCTAssertFalse(r.formatted.contains("Um"))
        XCTAssertFalse(r.formatted.contains(" uh "))
        // 13 words said, fewer written -- the count must reflect the former
        XCTAssertEqual(r.spokenWords, 13, "spoken words must count what was SAID")
        XCTAssertLessThan(r.writtenWords, r.spokenWords, "fillers were removed, so fewer were written")
    }

    func testToneCrossesTheFFI() {
        let raw = "I'm running late. I'll be there in ten minutes, sorry."
        XCTAssertTrue(Formatter.format(raw, tone: .formal).formatted.contains("."))
        let vc = Formatter.format(raw, tone: .veryCasual).formatted
        XCTAssertEqual(vc, vc.lowercased(), "very casual should be lowercase: \(vc)")
    }

    func testLedgerCrossesTheFFI() {
        let r = Formatter.format(
            "Hey buddy, I wanted to say thank- no, no, no. I wanted to thank you.", tone: .formal)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.ledger.count, 1)
        XCTAssertEqual(r.ledger.first?.why, "SelfCorrection")
        XCTAssertTrue(r.ledger.first?.to.isEmpty ?? false)
    }

    func testUnicodeAndEmptySurviveTheBoundary() {
        XCTAssertFalse(Formatter.format("Café, naïve, 日本語, 🎤", tone: .formal).formatted.isEmpty)
        _ = Formatter.format("", tone: .formal)   // must not crash
    }

    // MARK: - whisper

    private var modelPath: String? {
        let candidates = [
            NSString(string: "~/Library/Application Support/OpenFlow/models/ggml-small.en.bin")
                .expandingTildeInPath,
            "../m0/whisper.cpp/models/ggml-small.en.bin",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func testWhisperTranscribesThroughTheSwiftWrapper() throws {
        guard let modelPath else { throw XCTSkip("no model installed") }
        let wav = URL(fileURLWithPath: "../m0/audio/s10.wav")
        guard FileManager.default.fileExists(atPath: wav.path) else { throw XCTSkip("no fixture") }

        let samples = try Self.loadMono16k(wav)
        XCTAssertGreaterThan(samples.count, 16_000)

        let t = try XCTUnwrap(Transcriber(modelPath: modelPath))
        let text = t.transcribe(samples: samples)
        XCTAssertTrue(text.lowercased().contains("deploy"), "got: \(text)")
    }

    func testVocabularyBiasingIsWiredUp() throws {
        guard let modelPath else { throw XCTSkip("no model installed") }
        let wav = URL(fileURLWithPath: "../m0/audio/nouns2.wav")
        guard FileManager.default.fileExists(atPath: wav.path) else { throw XCTSkip("no fixture") }

        let samples = try Self.loadMono16k(wav)
        let t = try XCTUnwrap(Transcriber(modelPath: modelPath))
        let plain = t.transcribe(samples: samples)
        let biased = t.transcribe(samples: samples, vocabulary: ["Larchmont", "Siobhan", "Xiaoming"])
        XCTAssertFalse(plain.contains("Larchmont"), "baseline unexpectedly correct: \(plain)")
        XCTAssertTrue(biased.contains("Larchmont"), "vocabulary hint did not reach whisper: \(biased)")
    }

    func testVocabularyParsingSkipsCommentsAndCaps() {
        let v = Vocabulary.parse("# a comment\nLarchmont\n\n  Siobhan  \n# another\n")
        XCTAssertEqual(v, ["Larchmont", "Siobhan"])
    }

    // MARK: - store

    func testStoreCountsSpokenWords() throws {
        let tmp = NSTemporaryDirectory() + "of-test-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try Store(path: tmp)
        store.record(raw: "one two three", final: "One two three.", tone: .formal,
                     spokenWords: 3, durationMS: 1200, latencyMS: 400,
                     guardrailPassed: true, ledger: "[]", appContext: "com.apple.Notes")
        store.record(raw: "four five", final: "Four five.", tone: .casual,
                     spokenWords: 2, durationMS: 800, latencyMS: 300,
                     guardrailPassed: true, ledger: "[]", appContext: nil)
        let s = store.stats()
        XCTAssertEqual(s.utterances, 2)
        XCTAssertEqual(s.spokenWords, 5)
        XCTAssertEqual(s.todayWords, 5)
        store.deleteAll()
        XCTAssertEqual(store.stats().spokenWords, 0)
    }

    func testHistoryBrowseSearchAndDelete() throws {
        let tmp = NSTemporaryDirectory() + "of-hist-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try Store(path: tmp)

        let a = store.record(raw: "call larchmont about the roof", final: "Call Larchmont about the roof.",
                             tone: .formal, spokenWords: 5, durationMS: 2000, latencyMS: 500,
                             guardrailPassed: true, ledger: "[]", appContext: nil)
        _ = store.record(raw: "buy milk", final: "Buy milk.", tone: .casual,
                         spokenWords: 2, durationMS: 900, latencyMS: 300,
                         guardrailPassed: true, ledger: "[]", appContext: nil)

        let all = store.recent()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.finalText, "Buy milk.", "most recent must come first")
        XCTAssertEqual(all.first?.tone, "Casual")

        // search covers what was said as well as what was written
        XCTAssertEqual(store.recent(query: "larchmont").count, 1)
        XCTAssertEqual(store.recent(query: "roof").count, 1)
        XCTAssertEqual(store.recent(query: "nothing here").count, 0)

        store.delete(id: a)
        XCTAssertEqual(store.recent().count, 1)
        XCTAssertEqual(store.stats().spokenWords, 2, "stats must follow deletions")
    }

    func testLedgerRoundTripsThroughTheStore() throws {
        let tmp = NSTemporaryDirectory() + "of-led-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let store = try Store(path: tmp)
        let r = Formatter.format("Let's meet at noon, scratch that, let's meet at one.", tone: .formal)
        let json = String(data: try JSONEncoder().encode(r.ledger), encoding: .utf8)!
        store.record(raw: r.raw, final: r.formatted, tone: .formal, spokenWords: r.spokenWords,
                     durationMS: 3000, latencyMS: 600, guardrailPassed: r.ok,
                     ledger: json, appContext: nil)
        let back = try XCTUnwrap(store.recent().first)
        let entries = LedgerEntry.decode(back.ledger)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.why, "SelfCorrection")
        XCTAssertFalse(entries.first?.description.isEmpty ?? true)
    }

    // MARK: - noise handling

    func testHighPassRemovesLowFrequencyRumble() {
        // 40 Hz rumble, the shape of aircraft cabin noise
        let n = 16_000
        let rumble = (0..<n).map { sinf(2 * .pi * 40 * Float($0) / 16_000) * 0.5 }
        var f = HighPassFilter(cutoff: 85)
        let out = f.process(rumble)
        let before = SignalStats.rms(rumble)
        let after = SignalStats.rms(Array(out.suffix(8_000)))   // past the transient
        // 4th order at 85 Hz gives roughly -25 dB an octave down
        XCTAssertLessThan(after, before * 0.12, "rumble should be strongly attenuated")
    }

    func testHighPassKeepsSpeechBand() {
        let n = 16_000
        let voice = (0..<n).map { sinf(2 * .pi * 500 * Float($0) / 16_000) * 0.5 }
        var f = HighPassFilter(cutoff: 85)
        let out = f.process(voice)
        let before = SignalStats.rms(voice)
        let after = SignalStats.rms(Array(out.suffix(8_000)))
        XCTAssertGreaterThan(after, before * 0.8, "500 Hz must pass essentially untouched")
    }

    func testQuietSteadyNoiseIsRejected() {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<32_000).map { _ in Float.random(in: -0.02...0.02, using: &rng) }
        XCTAssertEqual(SignalStats.speechCheck(noise), .steadyNoise)
    }

    func testLoudAudioIsAcceptedEvenWithoutDynamics() {
        // The airplane case. Voice-processing AGC lifts the noise floor and
        // flattens dynamics, so a strict ratio test rejects real speech exactly
        // where the user most needs it to work. Above the speech level we take
        // it and let whisper decide.
        var rng = SystemRandomNumberGenerator()
        let loud = (0..<32_000).map { _ in Float.random(in: -0.25...0.25, using: &rng) }
        XCTAssertEqual(SignalStats.speechCheck(loud), .speech,
                       "clearly audible input must not be gated out")
    }

    func testQuietTalkerOverRoomToneSurvives() {
        // speech-shaped: a modest tone that swings above a constant floor
        var out = [Float]()
        for i in 0..<32_000 {
            let floorNoise = Float.random(in: -0.012...0.012)
            let speaking = (i / 3200) % 2 == 0
            let voice = speaking ? sinf(2 * .pi * 220 * Float(i) / 16_000) * 0.05 : 0
            out.append(floorNoise + voice)
        }
        XCTAssertEqual(SignalStats.speechCheck(out), .speech)
    }

    func testSilenceIsRejected() {
        XCTAssertEqual(SignalStats.speechCheck([Float](repeating: 0, count: 32_000)), .silence)
    }

    func testFailedCapturesAreStillRecorded() throws {
        // A capture that produced nothing is exactly the one worth keeping.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("h.sqlite").path)
        let clip = try AudioStorage.write([Float](repeating: 0.01, count: 16_000),
                                          id: "n", under: dir)

        store.record(raw: "", final: "", tone: .formal, spokenWords: 0, durationMS: 1000,
                     latencyMS: 20, guardrailPassed: true, ledger: "[]", appContext: nil,
                     audioPath: clip.path, outcome: "steadyNoise")

        let row = try XCTUnwrap(store.recent().first)
        XCTAssertEqual(row.outcome, "steadyNoise")
        XCTAssertEqual(row.spokenWords, 0)
        XCTAssertNotNil(row.audioPath, "the audio must survive so it can be replayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.audioPath!))
    }

    func testRealSpeechIsAccepted() throws {
        let wav = URL(fileURLWithPath: "../m0/audio/s10.wav")
        guard FileManager.default.fileExists(atPath: wav.path) else { throw XCTSkip("no fixture") }
        let samples = try Self.loadMono16k(wav)
        XCTAssertTrue(SignalStats.containsSpeech(samples), "real speech must survive the gate")
    }

    func testAudioRoundTripsToDiskAndBack() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-audio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = (0..<16_000).map { sinf(2 * .pi * 440 * Float($0) / 16_000) * 0.3 }

        let url = try AudioStorage.write(samples, id: "clip", under: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(AudioStorage.totalBytes(under: dir), 16_000)

        let back = try Self.loadMono16k(url)
        XCTAssertEqual(back.count, samples.count, accuracy: 64)

        AudioStorage.remove(url.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeletingAnUtteranceRemovesItsAudio() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("of-del-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(path: dir.appendingPathComponent("h.sqlite").path)

        let clip = try AudioStorage.write([Float](repeating: 0.1, count: 1600),
                                          id: "x", under: dir)
        let id = store.record(raw: "hi", final: "Hi.", tone: .formal, spokenWords: 1,
                              durationMS: 100, latencyMS: 10, guardrailPassed: true,
                              ledger: "[]", appContext: nil, audioPath: clip.path)
        XCTAssertEqual(store.recent().first?.audioPath, clip.path)

        store.delete(id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path),
                       "a hard delete must take the audio with it")
    }

    /// Diagnostic: what do the filter and the gate actually do to real audio?
    func testDiagnoseGateOnRealAudio() throws {
        let files = ["s05", "s10", "s20", "s30", "disfluent", "nouns", "nouns2"]
        print("\n  clip        peak    rmsIn   rmsOut  p10     p90     ratio  speech?")
        for name in files {
            let url = URL(fileURLWithPath: "../m0/audio/\(name).wav")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let raw = try Self.loadMono16k(url)
            var f = HighPassFilter()
            let filtered = f.process(raw)

            let window = 1600
            var levels: [Float] = []
            var i = 0
            while i + window <= filtered.count {
                levels.append(SignalStats.rms(filtered[i..<(i+window)])); i += window
            }
            levels.sort()
            let p10 = levels[levels.count/10], p90 = levels[(levels.count*9)/10]
            print(String(format: "  %-10s  %.3f   %.4f  %.4f  %.4f  %.4f  %.2f   %@",
                         (name as NSString).utf8String!,
                         filtered.reduce(Float(0)) { max($0, abs($1)) },
                         SignalStats.rms(raw), SignalStats.rms(filtered),
                         p10, p90, p90 / max(p10, 0.00001),
                         SignalStats.containsSpeech(filtered) ? "YES" : "*** NO ***"))
        }
    }

    static func loadMono16kPublic(_ u: URL) throws -> [Float] { try loadMono16k(u) }

    /// Read any wav as the 16 kHz mono float whisper wants.
    private static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                     frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: inBuf)
        if file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1 {
            let ch = inBuf.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ch, count: Int(inBuf.frameLength)))
        }
        let conv = AVAudioConverter(from: file.processingFormat, to: target)!
        let ratio = 16_000 / file.processingFormat.sampleRate
        let out = AVAudioPCMBuffer(pcmFormat: target,
                                   frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096)!
        var done = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true; status.pointee = .haveData; return inBuf
        }
        let ch = out.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}

extension InteropTests {

    /// A tap is a broadband transient. An 85 Hz high-pass must pass it almost
    /// untouched -- if taps vanish, the filter is not doing what it claims.
    func testTransientsSurviveTheHighPass() {
        var s = [Float](repeating: 0, count: 16_000)
        for tap in stride(from: 1000, to: 16_000, by: 4000) {
            for i in 0..<80 {                      // 5 ms click, decaying
                s[tap + i] = sinf(Float(i) * 0.9) * (1 - Float(i) / 80) * 0.6
            }
        }
        var f = HighPassFilter()
        let out = f.process(s)
        let before = SignalStats.rms(s), after = SignalStats.rms(out)
        print("  taps: rms \(before) -> \(after)  peak \(out.reduce(Float(0)) { max($0, abs($1)) })")
        XCTAssertGreaterThan(after, before * 0.85, "clicks are broadband; they must pass")
        XCTAssertEqual(SignalStats.speechCheck(out), .speech,
                       "audible taps must not be gated out as silence")
    }

    /// The app filters in small buffers, not one array. If per-chunk state is
    /// wrong the production path can differ from every test that passes.
    func testChunkedFilteringMatchesWholeArray() {
        let n = 8_000
        let sig = (0..<n).map { sinf(2 * .pi * 440 * Float($0) / 16_000) * 0.4 }

        var whole = HighPassFilter()
        let a = whole.process(sig)

        var chunked = HighPassFilter()
        var b: [Float] = []
        for start in stride(from: 0, to: n, by: 512) {
            b += chunked.process(Array(sig[start..<min(start + 512, n)]))
        }

        XCTAssertEqual(a.count, b.count)
        let maxDiff = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 1e-5, "chunked filtering diverged from whole-array")
        XCTAssertGreaterThan(SignalStats.rms(b), SignalStats.rms(sig) * 0.8,
                             "440 Hz must survive chunked filtering")
    }
}

extension InteropTests {

    /// Sparse events must not read as silence. Regression for the bug where the
    /// loud end of the check was a 90th percentile, so anything occupying less
    /// than 10% of the recording was discarded.
    func testSparseTapsAreNotSilence() {
        var s = [Float](repeating: 0.001, count: 80_000)      // 5 s of room tone
        for tap in stride(from: 8_000, to: 80_000, by: 16_000) {
            for i in 0..<80 { s[tap + i] = sinf(Float(i) * 0.9) * 0.6 }
        }
        XCTAssertEqual(SignalStats.speechCheck(s), .speech,
                       "four audible taps in five seconds is not silence")
    }

    func testAShortPhraseInALongRecordingSurvives() {
        // press, think, say a few words, release: mostly silence by duration
        var s = [Float](repeating: 0.002, count: 96_000)      // 6 s
        for i in 0..<16_000 {                                 // 1 s of speech
            s[64_000 + i] = sinf(2 * .pi * 220 * Float(i) / 16_000) * 0.15
        }
        XCTAssertEqual(SignalStats.speechCheck(s), .speech,
                       "a short utterance in a long capture must not be discarded")
    }
}
