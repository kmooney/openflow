import Foundation
import AVFoundation

/// Microphone capture, resampled to the 16 kHz mono float whisper expects.
///
/// Two states, and the distinction is the whole design on iOS:
///
/// - **live** — the audio session is active and the engine is running, with a
///   tap installed. The system microphone indicator is lit. Buffers arrive and
///   are thrown away.
/// - **recording** — the same graph, with the buffers kept.
///
/// Nothing is *started* when a recording begins; a flag is flipped. That is
/// what makes it possible for the keyboard extension to begin a recording
/// while the app sits in the background, which iOS otherwise forbids outright
/// (see `open()`).
///
/// macOS leaves `keepSessionOpen` false and gets the old behaviour: the graph
/// comes up for a recording and goes away after it.
public final class AudioRecorder {
    /// Rebuilt whenever voice processing is switched, because switching it
    /// back off does NOT restore the input node: the node stays reconfigured
    /// and delivers nothing, so turning the setting off left dictation just as
    /// broken as leaving it on. A fresh engine is the only reliable reset.
    private var engine = AVAudioEngine()
    private var configuredVoiceProcessing: Bool?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000, channels: 1,
                                       interleaved: false)!
    private var converter: AVAudioConverter?
    /// The format the current converter was built for. Buffers can change
    /// format mid-session, so this is checked on every callback.
    private var converterInputFormat: AVAudioFormat?
    private var samples: [Float] = []
    private let lock = NSLock()          // the tap runs on the audio thread
    private var highPass = HighPassFilter()

    /// Session active, engine running, microphone indicator lit.
    public private(set) var isLive = false
    /// Keeping what the tap delivers, rather than discarding it.
    public private(set) var isRecording = false
    /// True when the OS voice-processing unit is actually engaged.
    public private(set) var noiseSuppressionActive = false

    /// Hold the graph open between recordings. Set by iOS, where a
    /// backgrounded app cannot start capturing but *can* continue one it
    /// already has — so it never stops. Costs the microphone indicator being
    /// lit for as long as the session is open, which is the honest price and
    /// exactly what the user is agreeing to when they open it.
    public var keepSessionOpen = false

    /// Apple's voice-processing I/O unit: echo cancellation, noise suppression
    /// and AGC, the same stack FaceTime uses.
    ///
    /// **Off by default here; iOS turns it on.** Enabling it switches the input
    /// to an aggregate VPIO unit, and on the Mac that produced captures of
    /// exact digital zeros -- working dictation traded for a feature that
    /// silently broke it. So the shared default stays off and the caller opts
    /// in for the hardware it has actually been tried on.
    ///
    /// iOS opts in because it has no alternative: an iPhone's input gain is not
    /// settable, so the AGC inside this unit is the only thing that can lift a
    /// quiet talker to a usable level. The automatic fallback below still
    /// applies, and iOS remembers the verdict rather than re-testing it with
    /// the first recording of every launch.
    public var useVoiceProcessing = false
    /// High-pass the captured audio to strip low-frequency rumble.
    public var useHighPass = true

    /// The graph came up or went away underneath us. Argument is the new value
    /// of `isLive`. An open session can be taken away by a phone call or a
    /// media-services reset, and the keyboard is showing UI that claims
    /// otherwise, so this cannot be silent.
    public var onLiveChange: (@Sendable (Bool) -> Void)?

    #if os(iOS)
    private var observers: [NSObjectProtocol] = []
    #endif

    public init() {
        #if os(iOS)
        observeSessionEvents()
        #endif
    }

    deinit {
        #if os(iOS)
        for o in observers { NotificationCenter.default.removeObserver(o) }
        #endif
    }

    #if os(iOS)
    /// Session-level processing, which is **not** the same lever as
    /// `useVoiceProcessing` — and conflating the two cost a round of testing.
    ///
    /// `useVoiceProcessing` swaps the engine's input node for the aggregate
    /// VPIO unit. That is the thing that has now produced captures of exact
    /// digital zeros on two separate devices, and it is switched off for good
    /// on any device where it does.
    ///
    /// The session *mode* is independent of it. `.measurement` exists to switch
    /// the system's input processing off and hand back raw audio — automatic
    /// gain control included, which is precisely why a quiet talker arrives at
    /// -27 dBFS. `.default` leaves that processing on. It colours what whisper
    /// hears, which is what `.measurement` was chosen to avoid, but a little
    /// colouration on audio that is actually audible beats pristine audio
    /// nobody can transcribe.
    ///
    /// So: VPIO off, system AGC on. The failure of the first does not require
    /// giving up the second.
    private var sessionMode: AVAudioSession.Mode {
        useVoiceProcessing ? .voiceChat : .default
    }
    #endif

    public enum RecorderError: Error, LocalizedError {
        case noConverter
        case notLive
        public var errorDescription: String? {
            switch self {
            case .noConverter: return "could not configure audio conversion"
            case .notLive:     return "the microphone is not open"
            }
        }
    }

    // MARK: - the live session

    /// Bring the capture graph up and leave it running.
    ///
    /// **Foreground only on iOS.** A backgrounded app cannot begin capturing:
    /// not the activation (OSStatus 560557684, `'!int'`) and not the engine
    /// either (2003329396, `'what'`) even against a healthy active session
    /// with the microphone routed and a valid format. Everything downstream of
    /// this — the keyboard starting a recording from inside another app —
    /// works only because the graph opened here never stops.
    public func open() throws {
        guard !isLive else { return }

        #if os(iOS)
        // `.mixWithOthers`, not `.duckOthers`. A session that stays open for
        // the length of a work session must not hold someone's music down for
        // all of it, and mixing also stops other audio from interrupting us —
        // which for an always-on session matters more than a clean capture
        // while music happens to be playing.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: sessionMode,
                                options: [.mixWithOthers, .allowBluetooth,
                                          .defaultToSpeaker])
        try session.setActive(true, options: [])
        #endif

        try startGraph()
        try startEngine()
        isLive = true
        onLiveChange?(true)
    }

    /// Put the microphone away: graph down, session deactivated, indicator off.
    public func close() {
        guard isLive || engine.isRunning else { return }
        stopGraph()
        isRecording = false
        #if os(iOS)
        // Deactivating IS allowed from the background — it is only starting
        // that iOS refuses — so the keyboard can end a session from inside
        // another app.
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        if isLive {
            isLive = false
            onLiveChange?(false)
        }
    }

    /// Build and start the engine against whatever session is current.
    /// Assumes the session is already active on iOS.
    private func startGraph() throws {
        // Rebuild every time. After a session deactivation the input node's
        // format goes invalid, so a reused engine starts and quietly captures
        // nothing -- which is exactly what "the first recording works and the
        // second does not" looks like.
        rebuildEngine()

        noiseSuppressionActive = false
        if useVoiceProcessing {
            do {
                // Nothing else is touched: adding the mixer/output connection
                // that VPIO documentation implies made engine.start() fail with
                // -10875 outright. If VPIO delivers silence anyway, `stop()`
                // flags it and the caller falls back.
                try engine.inputNode.setVoiceProcessingEnabled(true)
                // VPIO is a full-duplex unit: it needs a live render path, not
                // just a tap. Routing input -> mainMixer completes it (the
                // mixer auto-connects to the output), and muting the mixer
                // stops it being fed back to the speakers.
                //
                // format: nil -- the node's format is not valid until the
                // engine starts, and passing an invalid one is a hard crash
                // (IsFormatSampleRateAndChannelCountValid), not an error.
                engine.connect(engine.inputNode, to: engine.mainMixerNode, format: nil)
                engine.mainMixerNode.outputVolume = 0
                noiseSuppressionActive = true
            } catch {
                rebuildEngine()          // leave no half-configured node behind
                noiseSuppressionActive = false
            }
        }
        configuredVoiceProcessing = useVoiceProcessing

        installTapAndStart()
    }

    private func installTapAndStart() {
        // Read AFTER any rebuild: enabling voice processing can change the
        // input node's format, and a rebuild replaces the node entirely.
        let input = engine.inputNode

        lock.lock()
        highPass = HighPassFilter()
        lock.unlock()
        converter = nil
        converterInputFormat = nil

        // format: nil -- do NOT pin the tap to a format read before the engine
        // starts. Voice processing swaps the input node for a VPIO unit that
        // negotiates its own format at start time, so a format captured
        // beforehand disagrees with the buffers that actually arrive. The
        // converter was built from that stale format while `append` computed
        // its ratio from the real one; the mismatch is what produced captures
        // of exact digital zeros.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            self?.append(buf)
        }
        engine.prepare()
    }

    /// The graph is up but the tap has not been started yet; this is the part
    /// that can fail, and the part that falls back.
    private func startEngine() throws {
        do {
            try engine.start()
        } catch {
            #if os(iOS)
            let ee = error as NSError
            NSLog("openflow: engine.start failed %@ %ld", ee.domain, ee.code)
            #endif
            // A CoreAudio error must never reach the user as "-10875". If the
            // graph will not start, the only configuration that has ever caused
            // it is voice processing -- drop it and try once more with a clean
            // engine. Raw capture is worth far more than noise suppression.
            guard noiseSuppressionActive else { throw error }
            rebuildEngine()
            useVoiceProcessing = false
            noiseSuppressionActive = false
            installTapAndStart()
            try engine.start()
            configuredVoiceProcessing = false
        }
    }

    private func stopGraph() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - recording

    /// Begin keeping what the microphone delivers.
    ///
    /// When the session is already live this touches no CoreAudio object at
    /// all — which is the only reason it can be called from the background.
    public func start() throws {
        guard !isRecording else { return }

        if !isLive {
            try open()
        } else if !engine.isRunning || configuredVoiceProcessing != useVoiceProcessing {
            // Either the engine died under us (a configuration change we did
            // not catch) or the voice-processing setting moved — which needs a
            // clean graph, because turning it back off does not restore the
            // input node.
            //
            // Rebuilt *in place*, against the session that is already active.
            // Deliberately not a close-and-reopen: reopening needs the
            // foreground, and this can run while the user is in another app
            // with only the keyboard on screen.
            try startGraph()
            try startEngine()
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        _conversionFailures = 0
        peak = 0
        sawSignal = false
        highPass = HighPassFilter()
        isRecording = true          // set under the lock: the tap reads it
        lock.unlock()
    }

    /// Set when a capture came back completely silent while voice processing
    /// was on. The caller uses this to fall back rather than silently failing.
    public private(set) var lastCaptureWasSilent = false

    /// Stop keeping audio and hand back everything captured. The graph stays
    /// up when `keepSessionOpen` is set, so the next `start()` needs nothing
    /// from the foreground.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        lock.lock()
        isRecording = false
        let captured = samples
        samples.removeAll(keepingCapacity: false)
        // A digitally-silent capture is never a real recording -- even a quiet
        // room has a noise floor. It means the graph delivered nothing.
        lastCaptureWasSilent = !captured.isEmpty && captured.allSatisfy { $0 == 0 }
        lock.unlock()

        if !keepSessionOpen { close() }
        return captured
    }

    /// Turn voice processing off after it produced silence, and rebuild the
    /// graph. `engine.reset()` is not enough -- the input node keeps its
    /// voice-processing configuration and keeps delivering nothing.
    public func disableVoiceProcessing() {
        useVoiceProcessing = false
        noiseSuppressionActive = false
        rebuildEngine()
        // A live session must not be left holding a stopped engine: the
        // microphone indicator would stay lit over a graph delivering nothing,
        // which is the worst of both states.
        if isLive {
            do {
                try startGraph()
                try startEngine()
            } catch {
                isLive = false
                onLiveChange?(false)
            }
        }
    }

    private func rebuildEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine = AVAudioEngine()
        converter = nil
        configuredVoiceProcessing = nil
    }

    // MARK: - surviving a long session

    #if os(iOS)
    /// A session held open for minutes meets everything a session held open
    /// for eight seconds never did: phone calls, Bluetooth headsets arriving,
    /// audio daemons restarting. Each of these silently kills the graph, and a
    /// dead graph is indistinguishable from a quiet room by the time anyone
    /// notices — so each is caught and repaired here, and reported when it
    /// cannot be.
    private func observeSessionEvents() {
        let centre = NotificationCenter.default

        observers.append(centre.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    self.handleGraphLost("interrupted")
                case .ended:
                    let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    if opts.contains(.shouldResume) { self.attemptResume() }
                @unknown default:
                    break
                }
            })

        // The engine stops itself when the hardware format changes under it —
        // plugging in headphones mid-session, for instance. The tap has to be
        // reinstalled against the new input node.
        observers.append(centre.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: .main) { [weak self] _ in
                guard let self, self.isLive, !self.engine.isRunning else { return }
                self.attemptResume()
            })

        // audiod restarted. Everything we hold is stale, including the session.
        observers.append(centre.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.handleGraphLost("audio services reset")
                self.attemptResume()
            })
    }

    private func handleGraphLost(_ reason: String) {
        NSLog("openflow: capture graph lost (%@)", reason)
        stopGraph()
        // Deliberately keeps `isRecording`: whatever was captured before the
        // interruption is still worth transcribing, and `stop()` must still
        // hand it back rather than returning nothing.
        guard isLive else { return }
        isLive = false
        onLiveChange?(false)
    }

    /// Try to get the microphone back. Fails in the background — that is the
    /// platform rule this whole design is arranged around — and failing
    /// quietly here is the one thing that must not happen, because the
    /// keyboard is elsewhere claiming the microphone is open.
    private func attemptResume() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: sessionMode,
                                    options: [.mixWithOthers, .allowBluetooth,
                                              .defaultToSpeaker])
            try session.setActive(true, options: [])
            try startGraph()
            try startEngine()
            if !isLive {
                isLive = true
                onLiveChange?(true)
            }
        } catch {
            let e = error as NSError
            NSLog("openflow: could not resume capture: %@ %ld", e.domain, e.code)
            if isLive {
                isLive = false
                onLiveChange?(false)
            }
        }
    }
    #endif

    // MARK: - metering

    private var peak: Float = 0
    private var sawSignal = false

    /// Has any non-zero sample arrived yet? The one question worth asking
    /// early: if this is still false half a second in, the graph is dead and
    /// no amount of waiting will fix it.
    public var hasSignal: Bool {
        lock.lock(); defer { lock.unlock() }
        return sawSignal
    }
    private var _conversionFailures = 0
    /// Chunks the converter refused. Non-zero means the capture is incomplete
    /// -- and a dropped chunk is indistinguishable from silence downstream, so
    /// this is the only way to tell the two apart.
    public var conversionFailures: Int {
        lock.lock(); defer { lock.unlock() }
        return _conversionFailures
    }

    /// Loudest sample since the last read, as dBFS, for a live meter. Reading
    /// resets it, so callers see peak-since-last-poll rather than peak-ever.
    /// Metered even when idle, so the app can show that an open microphone is
    /// genuinely hearing something.
    public func drainPeakDB() -> Float {
        lock.lock(); defer { peak = 0; lock.unlock() }
        return peak > 0 ? 20 * log10(peak) : -120
    }

    /// Seconds captured so far, for the recording indicator.
    public var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16_000.0
    }

    private func append(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0, buf.format.sampleRate > 0 else { return }

        // Build the converter from the format actually being delivered, and
        // rebuild if it ever changes. Deriving it from a format read earlier is
        // what broke this.
        if converterInputFormat != buf.format || converter == nil {
            converter = AVAudioConverter(from: buf.format, to: target)
            converterInputFormat = buf.format
        }
        guard let converter else { return }

        let ratio = target.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        if let err {
            // A conversion failure must not be silent: dropping every chunk
            // looks identical to a quiet room.
            lock.lock(); _conversionFailures += 1; lock.unlock()
            _ = err
            return
        }
        guard let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        var chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        lock.lock()
        // Filter state is carried across chunks, so this must stay under the
        // same lock and in capture order.
        if useHighPass { chunk = highPass.process(chunk) }
        let chunkPeak = chunk.reduce(Float(0)) { max($0, abs($1)) }
        peak = max(peak, chunkPeak)
        // Metering runs whether or not we are keeping the audio; only the
        // samples themselves are gated. An idle live session should still be
        // able to prove the microphone is working.
        if isRecording {
            samples.append(contentsOf: chunk)
            if chunkPeak > 0 { sawSignal = true }
        }
        lock.unlock()
    }
}
