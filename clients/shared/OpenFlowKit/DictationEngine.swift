import Foundation

public enum DictationState: Sendable, Equatable {
    case idle
    case recording
    case thinking
    case failed(String)
}

public struct DictationOutcome: Sendable {
    public let text: String
    public let result: FormatResult
    public let audioMS: Int
    public let latencyMS: Int
}

/// The whole dictation cycle, minus anything platform-shaped.
///
/// macOS drives this from a hotkey and pastes the result; iOS drives it from a
/// button and hands the result to its keyboard extension. Neither owns any of
/// the logic below.
public final class DictationEngine {
    private let recorder = AudioRecorder()
    private let store: Store
    private var transcriber: Transcriber?
    private var modelPath: String
    private let work = DispatchQueue(label: "openflow.dictation", qos: .userInitiated)

    public var tone: Tone = .formal
    public var vocabulary: [String] = []
    /// Keep the audio on disk for debugging. Off by default: the standing rule
    /// is transcribe-and-discard.
    public var keepAudio = false
    /// Where clips go when `keepAudio` is on.
    public var supportDirectory: URL?
    /// Reject recordings that are probably just room noise instead of letting
    /// whisper confabulate sentences out of them.
    public var rejectNonSpeech = true
    /// Spectral-subtraction noise reduction, applied after capture. Ours, not
    /// the OS's -- see NoiseReduction for why. Safe to leave on: it returns a
    /// clean recording untouched.
    public var noiseReduction = true
    public private(set) var state: DictationState = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }
    public var onState: (@Sendable (DictationState) -> Void)?
    /// Something the user should be told mid-flight, e.g. that noise
    /// suppression was switched off because it delivered nothing.
    public var onNotice: (@Sendable (String) -> Void)?

    public init(modelPath: String, store: Store) {
        self.modelPath = modelPath
        self.store = store
    }

    /// Switch to a different model. The old one is dropped and the new one
    /// loaded off the main queue, so the UI does not stall on a 500 MB file.
    public func useModel(at path: String) {
        guard path != modelPath else { return }
        // Reload eagerly: the user picked a model and the next thing they do is
        // hold the key, which must not pay the load.
        work.async { [self] in
            transcriber = nil            // free the old weights before loading
            modelPath = path
            if !path.isEmpty { transcriber = Transcriber(modelPath: path) }
        }
    }

    public var currentModelPath: String { modelPath }

    /// Load the model once, up front. It costs ~150ms and the user should
    /// never pay it mid-utterance.
    public func warmUp() {
        guard !modelPath.isEmpty else { return }
        work.async { [self] in
            if transcriber == nil { transcriber = Transcriber(modelPath: modelPath) }
        }
    }

    /// False when there is nothing to transcribe with -- on macOS, before the
    /// first model has been downloaded.
    public var hasModel: Bool { !modelPath.isEmpty }

    public var isRecording: Bool { recorder.isRecording }
    public var recordedSeconds: TimeInterval { recorder.duration }
    public var noiseSuppressionActive: Bool { recorder.noiseSuppressionActive }
    /// Mirrors the recorder so callers can offer it as a setting.
    public var useVoiceProcessing: Bool {
        get { recorder.useVoiceProcessing }
        set {
            recorder.useVoiceProcessing = newValue
            // Re-arm: turning it back on deserves a fresh chance to fail loudly
            // rather than silently producing nothing.
            if newValue { voiceProcessingFailed = false }
        }
    }
    /// Set once we have had to fall back, so the UI can say why.
    public private(set) var voiceProcessingFailed = false
    /// Peak level since the last call, dBFS. Drives the input meter.
    public func drainPeakDB() -> Float { recorder.drainPeakDB() }

    public func begin() {
        // `.failed` has to be startable, or one failed start is terminal:
        // nothing ever moves the state back to `.idle`, so every later tap
        // became a silent no-op and the microphone button looked dead with no
        // explanation. Only `.thinking` is genuinely unsafe to interrupt --
        // the recorder is already stopped and a transcription is in flight.
        guard state != .thinking else { return }
        do {
            try recorder.start()
            state = .recording
            watchForDeadInput()
        } catch {
            // Domain and code first. `localizedDescription` for a CoreAudio
            // failure reads "The operation couldn't be completed. (OSStatus
            // error -10875.)" -- the number is the only identifying part and
            // it is at the very end, which is exactly where a status line
            // truncates it away.
            let e = error as NSError
            NSLog("openflow: recorder start failed: %@ %ld", e.domain, e.code)
            state = .failed("start failed: \(e.domain) \(e.code) — \(e.localizedDescription)")
        }
    }

    /// If nothing has arrived shortly after starting, the graph is dead --
    /// waiting will not fix it. Voice processing is the only thing that has
    /// ever caused this, so drop it and restart the capture immediately rather
    /// than letting the user speak a whole utterance into a broken pipeline
    /// and discover it afterwards.
    private func watchForDeadInput() {
        guard recorder.noiseSuppressionActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.recorder.isRecording, !self.recorder.hasSignal else { return }
            self.voiceProcessingFailed = true
            self.recorder.disableVoiceProcessing()
            do {
                try self.recorder.start()          // fresh engine, no VPIO
                self.onNotice?("Noise suppression delivered no audio — switched off. Keep talking.")
            } catch {
                self.state = .failed("microphone unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Stop, transcribe, format, persist. `completion` runs on the main queue.
    ///
    /// **Every recording produces a row**, including the ones that yielded
    /// nothing. A capture that came back empty is precisely the one you want to
    /// look at later, and throwing it away destroys the evidence.
    public func end(appContext: String? = nil,
                    completion: @escaping @Sendable (Result<DictationOutcome, Error>) -> Void) {
        guard recorder.isRecording else { return }
        let hadVoiceProcessing = recorder.noiseSuppressionActive
        let samples = recorder.stop()
        let audioMS = Int(Double(samples.count) / 16.0)

        // Digital silence is never a real recording. If voice processing was on
        // it is the cause: turn it off for good and say so, rather than blaming
        // the user's microphone for something we did.
        let failures = recorder.conversionFailures
        if failures > 0 {
            // Format mismatch between the tap and the converter. Surfaced
            // rather than swallowed: dropped chunks look exactly like a quiet
            // room, which is how this went unnoticed for three rounds.
            NSLog("openflow: %d audio chunks failed conversion", failures)
        }

        if recorder.lastCaptureWasSilent, hadVoiceProcessing, !voiceProcessingFailed {
            voiceProcessingFailed = true
            recorder.disableVoiceProcessing()
            state = .idle
            completion(.failure(NSError(domain: "openflow", code: 5, userInfo: [
                NSLocalizedDescriptionKey:
                    failures > 0
                        ? "Audio format mismatch (\(failures) chunks dropped) — noise suppression turned off. Try again."
                        : "Noise suppression produced no audio — turned it off. Try again."])))
            return
        }
        state = .thinking
        let tone = self.tone
        let vocab = self.vocabulary
        let keepAudio = self.keepAudio
        let support = self.supportDirectory
        let rejectNonSpeech = self.rejectNonSpeech
        let denoise = self.noiseReduction

        work.async { [self] in
            let t0 = Date()

            // Written before anything can go wrong, so failures keep their
            // audio -- and written RAW, so a stored clip is what the microphone
            // actually heard rather than what the denoiser left behind.
            var audioPath: String?
            if keepAudio, let support, !samples.isEmpty {
                audioPath = try? AudioStorage.write(samples, id: UUID().uuidString,
                                                    under: support).path
            }

            let audio = denoise ? NoiseReduction.reduce(samples) : samples

            func fail(_ outcome: String, _ message: String) {
                store.record(raw: "", final: "", tone: tone, spokenWords: 0,
                             durationMS: audioMS, latencyMS: Int(Date().timeIntervalSince(t0) * 1000),
                             guardrailPassed: true, ledger: "[]", appContext: appContext,
                             audioPath: audioPath, outcome: outcome)
                DispatchQueue.main.async {
                    self.state = .idle
                    completion(.failure(NSError(domain: "openflow", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: message])))
                }
            }

            // Cheap check before the expensive one: whisper will invent fluent
            // sentences from steady noise. Deliberately permissive -- losing
            // something you said is worse than a hallucination you can delete.
            let verdict = SignalStats.speechCheck(audio)
            if rejectNonSpeech, verdict != .speech {
                return fail(verdict.rawValue,
                            verdict == .silence ? "heard nothing" : "only background noise")
            }

            if transcriber == nil, !modelPath.isEmpty {
                transcriber = Transcriber(modelPath: modelPath)
            }
            guard let transcriber else {
                return fail("empty", modelPath.isEmpty
                            ? "No speech model installed — choose one in Speech Model."
                            : "could not load model at \(modelPath)")
            }

            let raw = transcriber.transcribe(samples: audio, vocabulary: vocab)
            guard !raw.isEmpty else { return fail("empty", "no words recognised") }

            let result = Formatter.format(raw, tone: tone)
            let latencyMS = Int(Date().timeIntervalSince(t0) * 1000)
            let ledgerJSON = (try? JSONEncoder().encode(result.ledger))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            store.record(raw: result.raw, final: result.formatted, tone: tone,
                         spokenWords: result.spokenWords, durationMS: audioMS,
                         latencyMS: latencyMS, guardrailPassed: result.ok,
                         ledger: ledgerJSON, appContext: appContext,
                         audioPath: audioPath, outcome: "ok")

            DispatchQueue.main.async {
                self.state = .idle
                completion(.success(DictationOutcome(
                    text: result.formatted, result: result,
                    audioMS: audioMS, latencyMS: latencyMS)))
            }
        }
    }

    public func stats() -> Stats { store.stats() }
}
