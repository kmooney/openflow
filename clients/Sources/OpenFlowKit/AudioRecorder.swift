import Foundation
import AVFoundation

/// Microphone capture, resampled to the 16 kHz mono float whisper expects.
/// Cross-platform: the only divergence is the iOS audio session.
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
    public private(set) var isRecording = false
    /// True when the OS voice-processing unit is actually engaged.
    public private(set) var noiseSuppressionActive = false

    /// Apple's voice-processing I/O unit: echo cancellation, noise suppression
    /// and AGC, the same stack FaceTime uses.
    ///
    /// **Off by default.** Enabling it switches the input to an aggregate
    /// VPIO unit, and on this machine that produced captures of exact digital
    /// zeros -- working dictation traded for a feature that silently broke it.
    /// It is worth having in a noisy place, so it stays available behind a
    /// toggle with an automatic fallback, but it is not worth defaulting on
    /// until it is known to work on the hardware in front of the user.
    public var useVoiceProcessing = false
    /// High-pass the captured audio to strip low-frequency rumble.
    public var useHighPass = true

    public init() {}

    public enum RecorderError: Error, LocalizedError {
        case noConverter
        public var errorDescription: String? { "could not configure audio conversion" }
    }

    public func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        _conversionFailures = 0
        peak = 0
        sawSignal = false
        lock.unlock()

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
        #endif

        // Switching voice processing needs a clean graph: turning it back off
        // does not restore the input node, so a stale engine keeps delivering
        // nothing. Must happen before `inputNode` is captured.
        if configuredVoiceProcessing != useVoiceProcessing {
            rebuildEngine()
        }

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
                // The earlier attempt connected mainMixer -> output, which is
                // the wrong pair and failed with -10875.
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

        // Read AFTER any rebuild: enabling voice processing can change the
        // input node's format, and a rebuild replaces the node entirely.
        let input = engine.inputNode

        highPass = HighPassFilter()
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
        do {
            try engine.start()
        } catch {
            // A CoreAudio error must never reach the user as "-10875". If the
            // graph will not start, the only configuration that has ever caused
            // it is voice processing -- drop it and try once more with a clean
            // engine. Raw capture is worth far more than noise suppression.
            guard noiseSuppressionActive else { throw error }
            rebuildEngine()
            useVoiceProcessing = false
            noiseSuppressionActive = false
            highPass = HighPassFilter()
            converter = nil
            converterInputFormat = nil
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
                [weak self] buf, _ in self?.append(buf)
            }
            engine.prepare()
            try engine.start()
            configuredVoiceProcessing = false
        }
        isRecording = true
    }

    /// Set when a capture came back completely silent while voice processing
    /// was on. The caller uses this to fall back rather than silently failing.
    public private(set) var lastCaptureWasSilent = false

    /// Stop and hand back everything captured.
    @discardableResult
    public func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        lock.lock(); defer { lock.unlock() }
        // A digitally-silent capture is never a real recording -- even a quiet
        // room has a noise floor. It means the graph delivered nothing.
        lastCaptureWasSilent = !samples.isEmpty && samples.allSatisfy { $0 == 0 }
        return samples
    }

    /// Turn voice processing off after it produced silence, and rebuild the
    /// graph. `engine.reset()` is not enough -- the input node keeps its
    /// voice-processing configuration and keeps delivering nothing.
    public func disableVoiceProcessing() {
        useVoiceProcessing = false
        noiseSuppressionActive = false
        rebuildEngine()
    }

    private func rebuildEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        engine = AVAudioEngine()
        converter = nil
        configuredVoiceProcessing = nil
    }

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
        samples.append(contentsOf: chunk)
        let chunkPeak = chunk.reduce(Float(0)) { max($0, abs($1)) }
        peak = max(peak, chunkPeak)
        if chunkPeak > 0 { sawSignal = true }
        lock.unlock()
    }
}
