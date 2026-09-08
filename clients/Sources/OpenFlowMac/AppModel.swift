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

    /// The register the next utterance will use. Set automatically from
    /// `memory` whenever focus moves; set by hand through `chooseTone`, which
    /// is also how the memory is taught.
    @Published private(set) var tone: Tone {
        didSet {
            guard tone != oldValue else { return }
            engine.tone = tone
        }
    }

    /// Where the next utterance is going, and why it has the tone it has.
    @Published private(set) var context: DictationContext = .unknown
    @Published private(set) var toneSource: ToneMemory.Source = .fallback
    /// Bumped on every write so SwiftUI reloads the remembered-tones list.
    @Published private(set) var memoryRevision = 0

    /// The chord that opens the microphone. Changing it re-arms the monitor
    /// through `onChordChanged`; nothing else in the app reads the raw mask.
    @Published private(set) var chord: ModifierChord
    var onChordChanged: ((ModifierChord) -> Void)?
    /// Set by the delegate, which owns the preferences window.
    var onShowPreferences: ((PreferencesTab) -> Void)?

    let engine: DictationEngine
    let memory: ToneMemory
    let models: ModelStore
    private let store: Store
    private var tick: Timer?
    private var bag = Set<AnyCancellable>()

    init(engine: DictationEngine, store: Store, models: ModelStore) {
        self.engine = engine
        self.store = store
        self.models = models
        self.stats = store.stats()
        let storedChord = UserDefaults.standard.object(forKey: "chord") as? Int
        self.chord = storedChord.map { ModifierChord(mask: UInt($0)) } ?? .default
        let fallback = Tone(rawValue: UInt32(UserDefaults.standard.integer(forKey: "tone"))) ?? .formal
        self.tone = fallback
        self.memory = ToneMemory(storage: UserDefaultsToneStorage(), fallback: fallback)
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
        // Republish the two things the menu bar and the footer read -- which
        // model is active, and whether any exist. Deliberately not
        // `models.objectWillChange`: that fires on every download progress
        // chunk, and the menu bar rebuilds its whole NSMenu on each republish.
        models.$selectedID.map { _ in () }
            .merge(with: models.$installed.map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        reloadHistory()
    }

    // MARK: - settings

    func showPreferences(_ tab: PreferencesTab = .general) { onShowPreferences?(tab) }

    /// Rejects anything that would fire during ordinary typing rather than
    /// storing it and leaving the user with a hotkey that never stops.
    func setChord(_ new: ModifierChord) {
        guard new.isUsable, new != chord else { return }
        chord = new
        UserDefaults.standard.set(Int(new.mask), forKey: "chord")
        onChordChanged?(new)
        status = "Push to talk is now \(new.symbols)"
        clearStatusSoon()
    }

    // MARK: - models

    var activeModelName: String {
        ModelCatalog.model(id: models.selectedID)?.displayName ?? "none"
    }

    /// Nothing usable installed. The Listen button and the hotkey both need
    /// this to be false before they can produce anything.
    var needsModel: Bool { models.activeURL == nil }

    var isRecording: Bool { if case .recording = state { return true }; return false }

    // MARK: - dictation

    /// Where the finished text should go.
    enum Delivery {
        /// Paste into whatever had focus. Used by the hotkey.
        case paste
        /// Copy only. Used by the Listen button -- pasting would land the text
        /// in our own window, which is never what you meant.
        case clipboard
    }

    func begin() { engine.begin() }

    /// Push-to-talk entry point. The context is captured before the microphone
    /// opens -- once we start recording, focus has already moved on.
    func begin(in context: DictationContext) {
        adopt(context)
        engine.begin()
    }

    func finish(_ delivery: Delivery) {
        // History records the field, not just the app, so "which register did
        // I use in Safari's address bar" is answerable after the fact.
        let key: String? = { if case .paste = delivery { return context.key }; return nil }()
        engine.end(appContext: key) { [weak self] result in
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

    // MARK: - tone memory

    /// Point the model at a new destination and take the register that belongs
    /// to it. Called on the hotkey press with the focused field resolved, and
    /// on app switches with just the app -- so the menu bar shows the tone you
    /// are about to get before you press anything.
    func adopt(_ context: DictationContext) {
        // An app switch reports no field. Do not let that erase a field we
        // resolved a moment ago for the same app: the coarser reading is not
        // news, and dropping to it would flip the picker back and forth.
        if context.bundleID == self.context.bundleID,
           context.field == .unknown, self.context.field != .unknown { return }

        self.context = context
        let resolved = memory.resolve(context)
        toneSource = resolved.source
        tone = resolved.tone
    }

    /// The user picked a register. That is the whole teaching signal: it means
    /// "this is what I want *here*", so it is written against the current
    /// context rather than becoming a global mode the user has to remember to
    /// unset later.
    func chooseTone(_ picked: Tone) {
        tone = picked
        if memory.remember(picked, for: context), let key = context.key {
            toneSource = .remembered(key)
            memoryRevision += 1
            status = "\(picked.name) remembered for \(context.label)"
        } else {
            // Nothing to attach it to -- dictating to the clipboard, or no
            // Accessibility permission. Becomes the global default instead.
            memory.fallback = picked
            UserDefaults.standard.set(Int(picked.rawValue), forKey: "tone")
            toneSource = .fallback
            status = "\(picked.name) is now the default"
        }
        clearStatusSoon()
    }

    /// Drop what was learned here and fall back to the suggestion, or to the
    /// global default.
    func forgetTone(_ key: String? = nil) {
        if let key { memory.forget(key) } else { memory.forget(context) }
        memoryRevision += 1
        adopt(context)
    }

    func forgetAllTones() {
        memory.forgetAll()
        memoryRevision += 1
        adopt(context)
    }

    var rememberedTones: [ToneRule] { memory.all }

    /// Edit a rule from the list, which may or may not be the one in play.
    func remember(_ tone: Tone, forKey key: String) {
        memory.setTone(tone, forKey: key)
        memoryRevision += 1
        adopt(context)
    }

    /// True when the current register was taught rather than guessed.
    var toneIsRemembered: Bool {
        if case .remembered = toneSource { return true }
        return false
    }

    /// One line under the picker: what tone applies where, and on what basis.
    var toneExplanation: String {
        switch toneSource {
        case .remembered:
            return "Remembered for \(context.label)"
        case .suggested:
            return "Suggested for \(context.label) — pick one to make it stick"
        case .fallback:
            return context.bundleID == nil
                ? "Default for anywhere with nothing remembered"
                : "Default — pick one to remember it for \(context.label)"
        }
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
