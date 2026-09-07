import AppKit
import Combine
import OpenFlowKit

/// Shared state behind both the menu bar and the window. The hotkey and the
/// Listen button drive the same engine; they differ only in where the text goes.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var stats: Stats
    @Published private(set) var history: [Utterance] = []
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var status: String = ""
    @Published var query: String = "" { didSet { reloadHistory() } }
    /// Keep clips on disk for debugging. Off by default -- audio is the most
    /// sensitive thing here, and the rule is transcribe-and-discard.
    @Published var keepAudio: Bool {
        didSet {
            UserDefaults.standard.set(keepAudio, forKey: "keepAudio")
            engine.keepAudio = keepAudio
        engine.noiseReduction = noiseSuppression
        }
    }
    @Published private(set) var inputDB: Float = -120
    /// False until the *global* hotkey is live. Without Accessibility
    /// permission the in-app monitor still fires, so the chord appears to work
    /// inside OpenFlow and nowhere else -- which is worse than not working at
    /// all, because it looks fine.
    @Published var hotkeyReady = false
    var onRequestAccessibility: (() -> Void)?
    /// Our own spectral subtraction, applied after capture. It cannot break
    /// the audio graph the way the OS voice-processing unit did, and it leaves
    /// a clean recording untouched, so it is on by default.
    @Published var noiseSuppression: Bool {
        didSet {
            UserDefaults.standard.set(noiseSuppression, forKey: "noiseSuppression")
            engine.noiseReduction = noiseSuppression
        }
    }
    let playback = AudioPlayback()

    @Published var tone: Tone {
        didSet {
            UserDefaults.standard.set(Int(tone.rawValue), forKey: "tone")
            engine.tone = tone
        }
    }

    let engine: DictationEngine
    private let store: Store
    private var tick: Timer?

    init(engine: DictationEngine, store: Store) {
        self.engine = engine
        self.store = store
        self.stats = store.stats()
        self.tone = Tone(rawValue: UInt32(UserDefaults.standard.integer(forKey: "tone"))) ?? .formal
        self.keepAudio = UserDefaults.standard.bool(forKey: "keepAudio")
        self.noiseSuppression = UserDefaults.standard.object(forKey: "noiseSuppression") as? Bool ?? true
        engine.tone = tone
        engine.keepAudio = keepAudio
        engine.noiseReduction = noiseSuppression
        engine.onState = { [weak self] s in
            Task { @MainActor in self?.apply(s) }
        }
        engine.onNotice = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.status = message
                if self.noiseSuppression { self.noiseSuppression = false }
            }
        }
        reloadHistory()
    }

    var isRecording: Bool { if case .recording = state { return true }; return false }

    // MARK: - dictation

    /// Where the finished text should go.
    enum Delivery {
        /// Paste into whatever had focus. Used by the hotkey.
        case paste(appContext: String?)
        /// Copy only. Used by the Listen button -- pasting would land the text
        /// in our own window, which is never what you meant.
        case clipboard
    }

    func begin() { engine.begin() }

    func finish(_ delivery: Delivery) {
        let context: String? = { if case .paste(let c) = delivery { return c }; return nil }()
        engine.end(appContext: context) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let o):
                    switch delivery {
                    case .paste:
                        Paster.paste(o.text)
                        self.status = "\(o.result.spokenWords) words · \(o.latencyMS)ms"
                    case .clipboard:
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(o.text, forType: .string)
                        self.status = "\(o.result.spokenWords) words · copied to clipboard"
                    }
                    if !o.result.ok { self.status += " · formatting rolled back" }
                case .failure(let e):
                    self.status = e.localizedDescription
                    // The engine disables voice processing when it yields
                    // silence; keep the UI honest about it.
                    if self.engine.voiceProcessingFailed, self.noiseSuppression {
                        self.noiseSuppression = false
                    }
                }
                self.refresh()
                self.clearStatusSoon()
            }
        }
    }

    /// Listen button: toggles, and always copies rather than pastes.
    func toggleListen() {
        if isRecording { finish(.clipboard) } else { begin() }
    }

    private func apply(_ s: DictationState) {
        state = s
        if case .recording = s { startTick() } else { stopTick() }
        if case .failed(let m) = s { status = m; clearStatusSoon() }
    }

    private func startTick() {
        stopTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = self.engine.recordedSeconds
                self.inputDB = self.engine.drainPeakDB()
            }
        }
    }

    private func stopTick() { tick?.invalidate(); tick = nil; elapsed = 0; inputDB = -120 }

    var noiseSuppressionActive: Bool { engine.noiseSuppressionActive }

    var audioOnDiskBytes: Int64 {
        AudioStorage.totalBytes(under: AppDelegate.supportDir)
    }

    private func clearStatusSoon() {
        let mine = status
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.status == mine { self?.status = "" }
        }
    }

    // MARK: - history

    func refresh() {
        stats = store.stats()
        reloadHistory()
    }

    private func reloadHistory() {
        history = store.recent(limit: 300, query: query)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "Copied"
        clearStatusSoon()
    }

    func delete(_ u: Utterance) {
        if playback.playingPath == u.audioPath { playback.stop() }
        store.delete(id: u.id)
        refresh()
    }

    func deleteAll() {
        playback.stop()
        store.deleteAll()
        refresh()
    }

    func reloadVocabulary(from url: URL) {
        engine.vocabulary = Vocabulary.load(from: url)
    }
}
