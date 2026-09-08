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
    private var startObserver: NSObjectProtocol?
    private var heartbeat: Timer?

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
        // The keyboard can ask us to start, which only works while we are
        // alive. Whether we stay alive in the background is the other half of
        // what needs testing.
        startObserver = Handoff.observeStartRequests { [weak self] in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                self.begin()
            }
        }
        // Tell the keyboard we are reachable. It has no way to ask.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handoff?.beat() }
        }
        handoff?.beat()

        keyboardReady = handoff?.keyboardIsReady ?? false
        reloadHistory()
    }

    var isRecording: Bool { if case .recording = state { return true }; return false }
    var isThinking: Bool { if case .thinking = state { return true }; return false }

    func toggle() { isRecording ? finish() : begin() }

    func begin() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Tell the keyboard we are live, so its key becomes "finish and
        // insert" rather than "open the app".
        handoff?.setRecording(true)
        engine.begin()
    }

    func finish() {
        engine.end { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.handoff?.setRecording(false)
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
        if case .recording = s { startTick() } else { stopTick() }
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
        // The keyboard can ask us to start, which only works while we are
        // alive. Whether we stay alive in the background is the other half of
        // what needs testing.
        startObserver = Handoff.observeStartRequests { [weak self] in
            Task { @MainActor in
                guard let self, !self.isRecording else { return }
                self.begin()
            }
        }
        // Tell the keyboard we are reachable. It has no way to ask.
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handoff?.beat() }
        }
        handoff?.beat()

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
