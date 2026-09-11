import Foundation

public enum DictationState: Sendable, Equatable {
    /// Microphone closed. No indicator, nothing running.
    case idle
    /// Microphone open and running, but nothing is being kept. The system
    /// recording indicator is lit and iOS considers the app to be capturing —
    /// which is precisely what buys the ability to start a recording later
    /// from the background.
    case open
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
    #if canImport(CLlamaShim)
    private var polisher: Polisher?
    #endif
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
    /// Hold the microphone open between recordings rather than opening it for
    /// each one. iOS sets this; macOS does not need it and pays the indicator
    /// for nothing. See `AudioRecorder.open()` for why the alternative does
    /// not exist on iOS.
    public var holdMicrophoneOpen: Bool {
        get { recorder.keepSessionOpen }
        set { recorder.keepSessionOpen = newValue }
    }
    /// Spectral-subtraction noise reduction, applied after capture. Ours, not
    /// the OS's -- see NoiseReduction for why. Safe to leave on: it returns a
    /// clean recording untouched.
    public var noiseReduction = true
    /// The polish model, or empty for none. Set from the user's choice in the
    /// model picker; changing it drops the loaded weights and reloads lazily.
    public var polishModelPath: String = "" {
        didSet {
            guard polishModelPath != oldValue else { return }
            NSLog("openflow: polish model set to |%@|", polishModelPath)
            work.async { [self] in
                #if canImport(CLlamaShim)
                polisher = nil
                #endif
            }
        }
    }
    /// Tokens per second from the last polish run, or 0 if none. Measured, and
    /// published because the whole reason the model is a choice is that this
    /// number differs wildly between devices.
    public private(set) var lastPolishTokensPerSecond: Double = 0

    /// Whether to run whisper on the GPU.
    ///
    /// **iOS will not let a backgrounded app use the GPU**, and transcribing
    /// from the background is the entire point of the keyboard — so this is
    /// false exactly then. Set per transcription by the caller, which is the
    /// only place that knows whether the app is on screen.
    ///
    /// Not a one-way fallback: a single background failure used to swap a CPU
    /// context in permanently and make in-app dictation slow forever after.
    public var preferGPU = true
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
        recorder.onLiveChange = { [weak self] live in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onLive?(live)
                // A session taken away mid-recording still has audio worth
                // transcribing, so `.recording` is left alone and `end()` will
                // hand back what was captured before the interruption.
                if !live, self.state == .open { self.state = .idle }
            }
        }
    }

    /// The microphone opened or was taken away. Distinct from `onState`
    /// because the keyboard extension needs to know about the *session*, not
    /// about any particular recording.
    public var onLive: (@Sendable (Bool) -> Void)?

    /// Microphone open and running.
    public var isLive: Bool { recorder.isLive }

    /// Open the microphone and leave it open.
    ///
    /// **Foreground only.** This is the one operation iOS will not let a
    /// backgrounded app perform, and every other affordance — the keyboard's
    /// microphone key especially — exists downstream of it having already
    /// happened.
    public func openMicrophone() throws {
        try recorder.open()
        if state == .idle || isFailed(state) { state = .open }
    }

    /// Put the microphone away. Allowed from the background.
    public func closeMicrophone() {
        if recorder.isRecording { _ = recorder.stop() }
        recorder.close()
        state = .idle
    }

    private func isFailed(_ s: DictationState) -> Bool {
        if case .failed = s { return true }
        return false
    }

    /// Where the state machine rests after a recording: back to an open
    /// microphone if we are holding one, otherwise all the way to idle.
    private var restingState: DictationState { recorder.isLive ? .open : .idle }

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

    /// Choose the backend ahead of time and load it now.
    ///
    /// Called when the app crosses into or out of the background, because that
    /// is exactly when the right backend changes and exactly when there is time
    /// to pay for it. Switching costs a 147 MB model reload; done lazily it
    /// lands in the middle of the first utterance after the switch, which is
    /// the one moment it must not.
    public func prepare(forGPU gpu: Bool) {
        guard preferGPU != gpu || transcriber?.requestedGPU != gpu else { return }
        preferGPU = gpu
        guard !modelPath.isEmpty else { return }
        work.async { [self] in
            guard transcriber?.requestedGPU != gpu else { return }
            transcriber = nil            // free the old weights before loading
            transcriber = Transcriber(modelPath: modelPath, useGPU: gpu)
        }
    }

    /// Load the model once, up front. It costs ~150ms and the user should
    /// never pay it mid-utterance.
    public func warmUp() {
        guard !modelPath.isEmpty else { return }
        work.async { [self] in
            if transcriber == nil {
                transcriber = Transcriber(modelPath: modelPath, useGPU: preferGPU)
            }
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
            // A start that fails against a live session leaves the graph in an
            // unknown state; do not keep claiming the microphone is open.
            if !recorder.isLive { recorder.close() }
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
            // Discard the silence first. `start()` is a no-op while the
            // recorder still believes it is recording, so without this the
            // "restart" restarted nothing and the user spoke a whole utterance
            // into the dead graph anyway.
            _ = self.recorder.stop()
            self.recorder.disableVoiceProcessing()
            do {
                try self.recorder.start()          // fresh engine, no VPIO
                self.onNotice?("Noise suppression delivered no audio — switched off. Keep talking.")
            } catch {
                self.state = .failed("microphone unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Run the polish model, if the user chose one.
    ///
    /// Returns the transcript unchanged on every failure path — no model, a
    /// model that would not load, a reply that was not a repair. Losing what
    /// someone said to a formatting stage is far worse than leaving it
    /// unpolished, which is the same rule the formatter itself follows.
    private func polished(_ raw: String, vocabulary: [String]) -> String {
        #if canImport(CLlamaShim)
        guard !polishModelPath.isEmpty else { return raw }
        if polisher == nil {
            NSLog("openflow: loading the polish model (gpu=%@)", preferGPU ? "yes" : "no")
            polisher = Polisher(modelPath: polishModelPath, useGPU: preferGPU)
            NSLog("openflow: polish model %@", polisher == nil ? "FAILED to load" : "loaded")
            if polisher == nil {
                NSLog("openflow: could not load the polish model at %@", polishModelPath)
                return raw
            }
        }
        // Which instructions this particular model gets. Looked up from the
        // catalogue by filename, because the engine knows a path and the
        // catalogue knows what that model can actually do.
        let simple = PolishCatalog.all.first {
            $0.filename == (polishModelPath as NSString).lastPathComponent
        }?.needsSimplePrompt ?? false
        guard let polisher,
              let out = polisher.polish(raw, vocabulary: vocabulary,
                                        simplePrompt: simple) else {
            return raw
        }
        let rate = polisher.lastTokensPerSecond
        DispatchQueue.main.async { self.lastPolishTokensPerSecond = rate }
        return out
        #else
        return raw
        #endif
    }

    /// Stop recording and throw the audio away. The microphone stays open.
    ///
    /// Nothing is written to history: this is the user saying "forget that",
    /// and a row recording that they changed their mind is not evidence of
    /// anything. Distinct from `end()`, which records even its failures.
    @discardableResult
    public func discard() -> Bool {
        guard recorder.isRecording else { return false }
        _ = recorder.stop()
        state = restingState
        return true
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

        // What the microphone actually delivered, on every recording without
        // exception.
        //
        // "no words recognised" is the same sentence whether whisper was handed
        // four seconds of clear speech or eighty milliseconds of nothing, and
        // those are opposite problems with opposite fixes. The level meter is
        // no help either: it is fed by the tap, which runs whether or not the
        // samples are being kept, so a lively meter over an empty capture looks
        // exactly like a working one.
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let peakDB = peak > 0 ? 20 * log10(peak) : -120
        let evidence = String(format: "%.1fs, peak %.0f dBFS", Double(audioMS) / 1000, peakDB)
        NSLog("openflow: captured %d samples (%d ms), peak %.1f dBFS, %d dropped chunks",
              samples.count, audioMS, peakDB, recorder.conversionFailures)

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
            state = restingState
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
                // Every failure carries what was captured. Without it the user
                // is told the transcription failed and given nothing to tell
                // apart a dead capture from a live one whisper could not read.
                let message = "\(message) (\(evidence))"
                // The success path logs its timing; without this the failure
                // path is the one case that leaves no trace in the console at
                // all — which is exactly the case worth reading.
                NSLog("openflow: giving up — %@ [%@] after %d ms",
                      message, outcome, Int(Date().timeIntervalSince(t0) * 1000))
                store.record(raw: "", final: "", tone: tone, spokenWords: 0,
                             speechModel: (modelPath as NSString).lastPathComponent,
                             polishModel: (polishModelPath as NSString).lastPathComponent,
                             durationMS: audioMS, latencyMS: Int(Date().timeIntervalSince(t0) * 1000),
                             guardrailPassed: true, ledger: "[]", appContext: appContext,
                             audioPath: audioPath, outcome: outcome)
                DispatchQueue.main.async {
                    self.state = self.restingState
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

            // Rebuild only when the backend is wrong for where we are running.
            // Foreground → background → foreground costs two reloads, not one
            // per utterance.
            if let t = transcriber, t.requestedGPU != preferGPU {
                transcriber = nil
            }
            if transcriber == nil, !modelPath.isEmpty {
                transcriber = Transcriber(modelPath: modelPath, useGPU: preferGPU)
            }
            guard let transcriber else {
                return fail("empty", modelPath.isEmpty
                            ? "No speech model installed — choose one in Speech Model."
                            : "could not load model at \(modelPath)")
            }

            // Applied AFTER the speech check, never before: the check's
            // thresholds are absolute, so normalising first would make a silent
            // room look exactly as loud as a sentence and defeat the one
            // defence against whisper confabulating sentences out of noise.
            let (levelled, gainDB) = SignalStats.normalized(audio)
            if gainDB > 0 {
                NSLog("openflow: lifted quiet capture by %.1f dB before transcription", gainDB)
            }

            var raw = transcriber.transcribe(samples: levelled, vocabulary: vocab)

            // A failed whisper run and a silent one both come back as "".
            // Retry once on the CPU: Metal is the only part of this that has
            // ever failed while everything around it worked, and a slow
            // transcription is worth immeasurably more than none. The CPU
            // context is kept — a GPU that just failed is not going to start
            // working on the next utterance.
            if raw.isEmpty, transcriber.lastStatus != 0, transcriber.usesGPU {
                let status = transcriber.lastStatus
                NSLog("openflow: whisper failed on the GPU (%d) — retrying on the CPU", status)
                if let cpu = Transcriber(modelPath: modelPath, useGPU: false) {
                    self.transcriber = cpu
                    raw = cpu.transcribe(samples: levelled, vocabulary: vocab)
                    if !raw.isEmpty {
                        DispatchQueue.main.async {
                            self.onNotice?("Switched to CPU transcription — the GPU path failed (\(status)).")
                        }
                    }
                }
            }

            guard !raw.isEmpty else {
                // Never the same sentence for both. "no words recognised" sent
                // every previous investigation at the microphone, which was
                // working the whole time.
                let code = self.transcriber?.lastStatus ?? 0
                return fail("empty", code != 0
                            ? "transcription failed — whisper returned \(code)"
                            : "no words recognised")
            }

            // whisper -> polish -> deterministic formatting.
            //
            // The model runs before the rules, not after: tone and structure
            // are the user's explicit choice, and a model asked to "polish"
            // casual text quietly formalises it back. Applying them last means
            // nothing downstream can undo them.
            let polished = self.polished(raw, vocabulary: vocab)
            let result = Formatter.format(polished, tone: tone)
            #if DEBUG
            // The pipeline, stage by stage. DEBUG only on purpose: this is the
            // user's speech, and an app whose whole claim is that nothing
            // leaves the device should not be writing transcripts into the
            // system log on a shipping build.
            NSLog("openflow: heard  |%@|", raw)
            // Always, including when nothing happened. Logging only the change
            // made "no model selected", "model failed to load" and "model
            // returned the same text" indistinguishable — three different
            // problems that all look like silence.
            if polishModelPath.isEmpty {
                NSLog("openflow: polish skipped — no model selected")
            } else if polished == raw {
                NSLog("openflow: polish made no change (%@)",
                      (polishModelPath as NSString).lastPathComponent)
            } else {
                NSLog("openflow: polish |%@| (%.1f tok/s)", polished,
                      self.lastPolishTokensPerSecond)
            }
            NSLog("openflow: format |%@|%@", result.formatted,
                  result.ok ? "" : " (note: \(result.note))")
            #endif
            let latencyMS = Int(Date().timeIntervalSince(t0) * 1000)
            NSLog("openflow: transcribed %d ms of audio in %d ms (gpu=%@, %d threads)",
                  audioMS, latencyMS, (self.transcriber?.usesGPU ?? false) ? "yes" : "no",
                  Transcriber.defaultThreads)
            let ledgerJSON = (try? JSONEncoder().encode(result.ledger))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            store.record(raw: result.raw, final: result.formatted, tone: tone,
                         spokenWords: result.spokenWords,
                         speechModel: (modelPath as NSString).lastPathComponent,
                         polishModel: (polishModelPath as NSString).lastPathComponent,
                         durationMS: audioMS,
                         latencyMS: latencyMS, guardrailPassed: result.ok,
                         ledger: ledgerJSON, appContext: appContext,
                         audioPath: audioPath, outcome: "ok")

            DispatchQueue.main.async {
                self.state = self.restingState
                completion(.success(DictationOutcome(
                    text: result.formatted, result: result,
                    audioMS: audioMS, latencyMS: latencyMS)))
            }
        }
    }

    public func stats() -> Stats { store.stats() }
}
