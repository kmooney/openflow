import Foundation
import SwiftUI
import UIKit
import OpenFlowKit

/// iOS counterpart of the macOS AppModel. The engine, store, formatter and
/// handoff are all shared code -- only the shell differs.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var stats: Stats
    @Published private(set) var history: [Utterance] = []
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var inputDB: Float = -120
    @Published var status = ""
    @Published var query = "" { didSet { reloadHistory() } }
    @Published var tone: Tone {
        didSet {
            UserDefaults.standard.set(Int(tone.rawValue), forKey: "tone")
            engine.tone = tone
        }
    }
    /// Set when launched from the keyboard, so we can start listening at once
    /// and hand the result straight back.
    @Published var handedOffFromKeyboard = false
    /// False until the keyboard has proved it can reach the shared container,
    /// which only happens with Full Access.
    @Published private(set) var keyboardReady = false

    let engine: DictationEngine
    let models: ModelStore
    private let store: Store
    private let handoff: Handoff?
    private var tick: Timer?
    private var stopObserver: NSObjectProtocol?

    init(engine: DictationEngine, store: Store, models: ModelStore, handoff: Handoff?) {
        self.engine = engine
        self.models = models
        self.store = store
        self.handoff = handoff
        self.stats = store.stats()
        self.tone = Tone(rawValue: UInt32(UserDefaults.standard.integer(forKey: "tone"))) ?? .formal
        engine.tone = tone
        engine.onState = { [weak self] s in Task { @MainActor in self?.apply(s) } }
        engine.onNotice = { [weak self] m in Task { @MainActor in self?.status = m } }

        // The keyboard asks us to stop when the user taps its key from inside
        // another app -- we are in the background then, still recording, and
        // this is the only way back.
        stopObserver = Handoff.observeStopRequests { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.finish()
            }
        }
        // We are definitionally not recording at launch. Says so explicitly
        // because the flag lives in a file that outlives the process: a crash
        // or a kill mid-recording used to leave the keyboard offering "Finish"
        // until the five-minute staleness window expired.
        handoff?.setRecording(false)

        keyboardReady = handoff?.keyboardIsReady ?? false
        reloadHistory()
    }

    deinit {
        tick?.invalidate()
        if let stopObserver { Handoff.removeObserver(stopObserver) }
    }

    var isRecording: Bool { if case .recording = state { return true }; return false }
    var isThinking: Bool { if case .thinking = state { return true }; return false }

    func toggle() { isRecording ? finish() : begin() }

    func begin() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // The keyboard is told we are live from `apply`, once the engine has
        // actually started -- not here. Setting it up front meant a failed
        // start left the flag stuck at "recording" forever, and the keyboard
        // offered a Finish button that could never finish.
        engine.begin()
    }

    func finish() {
        // `engine.end` returns early, without ever calling back, when it is not
        // recording. Reconcile the shared flag here or the keyboard is left
        // showing a Finish button whose taps disappear into nothing.
        guard isRecording else {
            handoff?.setRecording(false)
            return
        }
        engine.end { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let o):
                    UIPasteboard.general.string = o.text
                    // Offer it to the keyboard whether or not we were launched
                    // by it: the user may switch to a text field afterwards,
                    // and the offer expires on its own if unused.
                    try? self.handoff?.offer(o.text, tone: self.tone)
                    self.status = self.handedOffFromKeyboard
                        ? "Ready — switch back to your app"
                        : "\(o.result.spokenWords) words · copied"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .failure(let e):
                    self.status = e.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
                self.refresh()
            }
        }
    }

    private func apply(_ s: DictationState) {
        state = s
        // The one place the keyboard's view of us is written. Derived from the
        // engine rather than from the caller's intent, so the two processes
        // cannot disagree about whether a recording is running.
        handoff?.setRecording(s == .recording)
        switch s {
        case .idle:              handoff?.setStatus("idle")
        case .recording:         handoff?.setStatus("recording")
        case .thinking:          handoff?.setStatus("transcribing")
        case .failed(let m):     handoff?.setStatus("could not start: \(m)")
        }
        if case .recording = s { startTick() } else { stopTick() }
        // A failed start is worth saying out loud. It used to set the state and
        // nothing else, which is how a dead microphone looked like a dead
        // button.
        if case .failed(let message) = s { status = message }
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

    func refresh() {
        stats = store.stats()
        keyboardReady = handoff?.keyboardIsReady ?? false
        reloadHistory()
    }
    private func reloadHistory() { history = store.recent(limit: 300, query: query) }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        status = "Copied"
    }

    func sendToKeyboard(_ text: String) {
        try? handoff?.offer(text, tone: tone)
        status = "Ready for the keyboard"
    }

    func delete(_ u: Utterance) { store.delete(id: u.id); refresh() }
    func deleteAll() { store.deleteAll(); refresh() }
}
