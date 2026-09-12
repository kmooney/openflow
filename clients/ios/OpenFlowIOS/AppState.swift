import Combine
import Foundation
import SwiftUI
import UIKit
import AVFoundation
import OpenFlowKit

/// iOS counterpart of the macOS AppModel. The engine, store, formatter and
/// handoff are all shared code -- only the shell differs.
///
/// The iOS shell has one idea the Mac does not need: a **session**. The
/// microphone is opened once, in the foreground, and stays open while the user
/// works in other apps. Recordings start and stop inside that session without
/// anything being opened again, which is the only arrangement iOS permits —
/// see `AudioRecorder.open()`.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var stats: Stats
    @Published private(set) var history: [Utterance] = []
    @Published private(set) var state: DictationState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var inputDB: Float = -120
    /// Tokens per second from the last polish run. Zero until a model has run
    /// once, which is why the stat only appears after it has.
    @Published private(set) var polishTokensPerSecond: Double = 0
    @Published var status = ""
    @Published var query = "" { didSet { reloadHistory() } }
    @Published var tone: Tone {
        didSet {
            UserDefaults.standard.set(Int(tone.rawValue), forKey: "tone")
            engine.tone = tone
            // Guarded rather than unconditional: writing back a value that came
            // *from* the container posts a notification that comes straight
            // back to us. Comparing first makes the exchange settle instead of
            // ringing.
            if handoff?.tone() != tone { handoff?.setTone(tone) }
        }
    }
    /// Whether the recording in flight belongs to the keyboard.
    ///
    /// Only a keyboard-owned transcript is offered for insertion. Everything
    /// dictated here was offered too, on the theory that the user might switch
    /// to a text field afterwards — so a note dictated in the app would be
    /// pasted, unasked, into the next thing they typed in for the following
    /// three minutes. The offer is a handoff, not a clipboard; text dictated
    /// in the app stays in the app (and on the clipboard), and the history's
    /// "Send to keyboard" action is there for the times it should go.
    private var recordingIsForKeyboard = false

    /// Set when launched from the keyboard, so we can start listening at once
    /// and hand the result straight back.
    @Published var handedOffFromKeyboard = false
    /// False until the keyboard has proved it can reach the shared container,
    /// which only happens with Full Access.
    @Published private(set) var keyboardReady = false
    /// Shown once a session opens: the user's next move is to leave, and
    /// nothing about a phone makes that obvious.
    @Published var showSwipeHint = false

    let engine: DictationEngine
    let models: ModelStore
    /// The polish model, chosen the same way the speech model is.
    let polish: ModelStore
    /// Terms handed to whisper before it listens.
    let vocabulary: WordListStore
    /// Phrase → text, applied after everything else.
    let dictionary: WordListStore
    private let store: Store
    private let handoff: Handoff?
    private let liveActivity = LiveActivityController()
    private let voiceProcessingFailedKey = "voiceProcessingFailed"
    /// When a recording last started, finished or was discarded. Drives the
    /// idle timeout — see `MicrophoneIdlePolicy`.
    private var lastActivity = Date()
    private var tick: Timer?
    private var heartbeat: Timer?
    /// Darwin notification tokens (the keyboard's requests).
    private var observers: [NSObjectProtocol] = []
    /// NotificationCenter tokens. Kept apart because the two are removed by
    /// different calls, and putting them in one array meant the
    /// NotificationCenter ones were silently never removed —
    /// `Handoff.removeObserver` ignores anything that is not its own box.
    private var localObservers: [NSObjectProtocol] = []
    /// Combine, not NotificationCenter: the word lists are plain published
    /// values and the engine only needs the latest one.
    private var wordListSubscriptions: Set<AnyCancellable> = []

    init(engine: DictationEngine, store: Store, models: ModelStore,
         polish: ModelStore, vocabulary: WordListStore, dictionary: WordListStore,
         handoff: Handoff?) {
        self.engine = engine
        self.models = models
        self.polish = polish
        self.vocabulary = vocabulary
        self.dictionary = dictionary
        self.store = store
        self.handoff = handoff
        self.stats = store.stats()
        // The container wins over local defaults: a tone chosen on the keyboard
        // must survive the app being killed, and the keyboard cannot write to
        // the app's UserDefaults.
        self.tone = Handoff(appGroup: OpenFlowIDs.appGroup)?.tone()
            ?? Tone(rawValue: UInt32(UserDefaults.standard.integer(forKey: "tone")))
            ?? .formal
        engine.tone = tone
        // Both lists, now and on every edit. Re-read rather than parsed once at
        // launch: the editor is in this app, so a term added at 3pm has to
        // apply to the sentence dictated at 3:01.
        engine.vocabulary = vocabulary.terms
        engine.dictionary = dictionary.text
        vocabulary.$text
            .sink { [weak engine] text in engine?.vocabulary = Vocabulary.parse(text) }
            .store(in: &wordListSubscriptions)
        dictionary.$text
            .sink { [weak engine] text in engine?.dictionary = text }
            .store(in: &wordListSubscriptions)
        // `didSet` does not fire for the assignment in `init`, so on a fresh
        // install the container would hold no tone at all and the keyboard
        // would show Formal whatever the app was set to. Seed it, without
        // clobbering a choice already made on the keyboard.
        if handoff?.tone() == nil { handoff?.setTone(tone) }
        // The whole iOS design in one line: the microphone is not opened per
        // recording, it is held.
        engine.holdMicrophoneOpen = true

        // Apple's voice-processing unit — echo cancellation, noise suppression
        // and, the reason it is on here, automatic gain control. An iPhone has
        // no settable input gain, so this is the only thing that can make a
        // quiet talker arrive at a usable level rather than being asked to
        // raise their voice at their phone.
        //
        // It is off by default in the shared code because it once produced
        // captures of exact digital zeros — on a Mac. If it does that here it
        // is caught within half a second and switched off, and *that verdict is
        // remembered*: a device where it fails should not spend the first
        // recording of every launch rediscovering it.
        engine.useVoiceProcessing = !UserDefaults.standard.bool(forKey: voiceProcessingFailedKey)
        engine.onState = { [weak self] s in Task { @MainActor in self?.apply(s) } }
        engine.onNotice = { [weak self] m in
            Task { @MainActor in
                self?.status = m
                self?.rememberVoiceProcessingVerdict()
            }
        }
        engine.onLive = { [weak self] live in
            Task { @MainActor in self?.applyLive(live) }
        }

        // Everything the keyboard can ask for. All four are answerable from
        // the background, which is the point: the user is in another app and
        // the keyboard is the only OpenFlow surface they can reach.
        observers.append(Handoff.observeStartRequests { [weak self] in
            Task { @MainActor in self?.beginFromKeyboard() }
        })
        observers.append(Handoff.observeStopRequests { [weak self] in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.finish()
            }
        })
        observers.append(Handoff.observeCancelRequests { [weak self] in
            Task { @MainActor in self?.cancel() }
        })
        observers.append(Handoff.observeCloseRequests { [weak self] in
            Task { @MainActor in self?.endSession() }
        })
        observers.append(Handoff.observeToneChanges { [weak self] in
            Task { @MainActor in
                guard let self, let picked = self.handoff?.tone(), picked != self.tone
                else { return }
                self.tone = picked
            }
        })

        // iOS will not let a backgrounded app submit GPU work — whisper's Metal
        // encode fails outright with kIOGPUCommandBufferCallbackError
        // BackgroundExecutionNotPermitted. Since transcribing from the
        // background is the whole point of the keyboard, the backend is chosen
        // on the way across rather than discovered mid-utterance.
        let centre = NotificationCenter.default
        localObservers.append(centre.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.engine.isLive else { return }
                    self.engine.prepare(forGPU: false)
                }
            })
        localObservers.append(centre.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.engine.prepare(forGPU: true) }
            })

        // We are definitionally not live at launch. Says so explicitly because
        // the flag lives in a file that outlives the process: a crash or a kill
        // mid-recording used to leave the keyboard offering "Finish" until the
        // staleness window expired.
        handoff?.setMic(live: false, recording: false)
        // Same for the notch. A stranded Live Activity from a killed session
        // would otherwise sit there claiming the microphone is open.
        liveActivity.adoptExisting()
        liveActivity.end()

        keyboardReady = handoff?.keyboardIsReady ?? false
        reloadHistory()
    }

    deinit {
        tick?.invalidate()
        heartbeat?.invalidate()
        for o in observers { Handoff.removeObserver(o) }
        for o in localObservers { NotificationCenter.default.removeObserver(o) }
    }

    var isRecording: Bool { if case .recording = state { return true }; return false }
    var isThinking: Bool { if case .thinking = state { return true }; return false }
    /// Microphone open — the indicator is lit and the keyboard can start a
    /// recording from inside another app.
    var isLive: Bool { engine.isLive }

    // MARK: - the session

    /// Open the microphone on arrival, without being asked and **without
    /// arming a recording**.
    ///
    /// There is exactly one reason to bring this app to the front, and it is
    /// not to read the history — so the microphone opens by itself. But it does
    /// not start recording, and that distinction is the whole point:
    ///
    /// Arming here meant the user swiped back to a keyboard already reading
    /// *Insert*, inserted, and only then saw *Speak*. Every cycle after the
    /// first began at *Speak*. So the first one was the odd one out, and the
    /// first one is the one that teaches the user what the key does. An open
    /// microphone that is not yet recording is the state the rest of the loop
    /// returns to, so it is the state to arrive in.
    ///
    /// Silent when the microphone is already open, when a transcription is in
    /// flight, or when permission has been refused — none of those are helped
    /// by asking again on every return to the foreground.
    func openMicrophoneOnAppearing() {
        guard !isLive, !isThinking else { return }
        guard AVAudioApplication.shared.recordPermission != .denied else { return }
        openMicrophone()
    }

    /// Open the microphone and start talking. One tap, because the user's next
    /// move is to leave this screen and a second tap would have to happen
    /// somewhere they can no longer see.
    func startSession() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Ask before opening, not after. A session opened without permission
        // activates, runs, lights nothing and hears nothing — which looks
        // exactly like a broken microphone rather than a missing answer.
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.openAndListen() }
                    else { self.status = "Microphone access was declined." }
                }
            }
            return
        case .denied:
            status = "Microphone access is off — turn it on in Settings › OpenFlow."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        default:
            break
        }
        openAndListen()
    }

    /// Open the microphone and leave it idle. Returns false if it would not
    /// open, so callers do not go on to arm a recording against nothing.
    @discardableResult
    private func openMicrophone() -> Bool {
        do {
            try engine.openMicrophone()
        } catch {
            let e = error as NSError
            status = "could not open the microphone: \(e.domain) \(e.code)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
        liveActivity.start(recording: false)
        showSwipeHint = true
        // Opening is itself activity. Without this the idle clock would still
        // be running from whenever a recording last ended — so a session opened
        // after a quiet spell would close on its first heartbeat, before the
        // user had said a word.
        lastActivity = Date()
        return true
    }

    private func openAndListen() {
        guard openMicrophone() else { return }
        recordingIsForKeyboard = handedOffFromKeyboard
        engine.begin()
    }

    /// Put the microphone away. Also reachable from the keyboard, so it must
    /// work from the background — closing a session does, unlike opening one.
    func endSession() {
        if isRecording {
            // Do not throw away what has already been said just because the
            // user is done. Transcribe it, then close.
            engine.end(appContext: nil) { [weak self] result in
                Task { @MainActor in
                    self?.deliver(result)
                    self?.engine.closeMicrophone()
                }
            }
            return
        }
        engine.closeMicrophone()
    }

    /// Throw the current recording away without transcribing it, keeping the
    /// microphone open.
    func cancel() {
        guard isRecording else { return }
        _ = engine.discard()
        status = "Discarded"
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - recordings within a session

    func toggle() {
        if isRecording { finish() }
        else if isLive { begin() }
        else { startSession() }
    }

    func begin() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Arriving from the keyboard makes this recording the keyboard's, even
        // though the tap happened here: "Open OpenFlow" is the cold-start half
        // of the same flow.
        recordingIsForKeyboard = handedOffFromKeyboard
        // The keyboard is told we are live from `apply`, once the engine has
        // actually started -- not here. Setting it up front meant a failed
        // start left the flag stuck at "recording" forever, and the keyboard
        // offered a Finish button that could never finish.
        engine.begin()
    }

    /// A start asked for by the keyboard while we sit in the background. It
    /// costs nothing beyond flipping a flag, because the graph opened in
    /// `startSession` never stopped — but if it *has* stopped (an interruption
    /// we could not recover from), say so rather than pretending.
    private func beginFromKeyboard() {
        guard !isRecording, !isThinking else { return }
        guard isLive else {
            handoff?.setStatus("microphone closed — open OpenFlow")
            return
        }
        recordingIsForKeyboard = true
        engine.begin()
    }

    func finish() {
        // `engine.end` returns early, without ever calling back, when it is not
        // recording. Reconcile the shared flag here or the keyboard is left
        // showing a Finish button whose taps disappear into nothing.
        guard isRecording else {
            publishMicState()
            return
        }
        liveActivity.note("Transcribing…")
        // Authoritative, in case a transition notification was missed. Cheap
        // when it agrees with what `prepare(forGPU:)` already arranged.
        engine.preferGPU = UIApplication.shared.applicationState == .active
        engine.end { [weak self] result in
            Task { @MainActor in self?.deliver(result) }
        }
    }

    private func deliver(_ result: Result<DictationOutcome, Error>) {
        switch result {
        case .success(let o):
            UIPasteboard.general.string = o.text
            // Only the keyboard's own recordings are offered to it. One
            // dictated here is finished here: it is in the history and on the
            // clipboard, and "Send to keyboard" in the history is how it
            // travels when the user wants it to.
            //
            // Not `try?`. If this write fails the transcript exists in history
            // and nowhere the keyboard can reach, which looks from the outside
            // exactly like a recording that worked and then vanished — the
            // clipboard copy above is the only thing standing between the user
            // and losing it, so say so.
            if recordingIsForKeyboard {
                do {
                    try handoff?.offer(o.text, tone: tone)
                    status = "\(o.result.spokenWords) words · inserted"
                } catch {
                    NSLog("openflow: could not offer the transcript to the keyboard: %@",
                          error.localizedDescription)
                    status = "Transcribed, but the keyboard could not be handed the text — it is on the clipboard."
                    handoff?.setFailure("could not hand over the text — it is on the clipboard")
                }
            } else {
                status = "\(o.result.spokenWords) words · copied"
            }
            // The handoff is over either way. Without this the banner promising
            // the keyboard is waiting stayed up for the rest of the session,
            // and every later recording inherited a claim that was no longer
            // true.
            recordingIsForKeyboard = false
            handedOffFromKeyboard = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .failure(let e):
            status = e.localizedDescription
            // The keyboard is very likely the surface the user is looking at,
            // and it hears nothing at all when a transcription fails — no
            // transcript is offered, so no notification is posted. Tell it.
            handoff?.setFailure(e.localizedDescription)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        rememberVoiceProcessingVerdict()
        refresh()
    }

    /// Persist a voice-processing failure so it is not rediscovered, at the
    /// cost of a recording, on every launch.
    private func rememberVoiceProcessingVerdict() {
        guard engine.voiceProcessingFailed,
              !UserDefaults.standard.bool(forKey: voiceProcessingFailedKey) else { return }
        UserDefaults.standard.set(true, forKey: voiceProcessingFailedKey)
        NSLog("openflow: voice processing failed on this device — not asking again")
    }

    // MARK: - state plumbing

    private func apply(_ s: DictationState) {
        state = s
        // Hooked here rather than at each call site: `apply` is the one funnel
        // every state change passes through, so a new way to start a recording
        // cannot forget to mark the session as in use.
        if s == .recording || s == .thinking { lastActivity = Date() }
        publishMicState()
        switch s {
        case .idle:              handoff?.setStatus("idle")
        case .open:              handoff?.setStatus("mic open")
        case .recording:         handoff?.setStatus("recording")
        case .thinking:          handoff?.setStatus("transcribing")
        case .failed(let m):     handoff?.setStatus("could not start: \(m)")
        }

        switch s {
        case .recording: liveActivity.update(recording: true)
        case .open:      liveActivity.update(recording: false)
        case .thinking:  liveActivity.note("Transcribing…")
        case .idle:      liveActivity.end()
        case .failed:    liveActivity.end()
        }

        if case .recording = s { startTick() } else { stopTick() }
        // A failed start is worth saying out loud. It used to set the state and
        // nothing else, which is how a dead microphone looked like a dead
        // button.
        if case .failed(let message) = s { status = message }
    }

    /// The microphone came or went, independently of any recording. An
    /// interruption we could not recover from lands here, and it must reach
    /// both the keyboard and the notch: they are the two surfaces still
    /// claiming the session is alive.
    private func applyLive(_ live: Bool) {
        publishMicState()
        if live {
            startHeartbeat()
        } else {
            stopHeartbeat()
            liveActivity.end()
            showSwipeHint = false
            if !isThinking {
                status = "Microphone closed."
            }
        }
    }

    /// The one place the keyboard's view of us is written. Derived from the
    /// engine rather than from the caller's intent, so the two processes cannot
    /// disagree about what is happening.
    private func publishMicState() {
        handoff?.setMic(live: engine.isLive, recording: isRecording,
                        startedAt: recordingStartedAt)
        if engine.isLive { startHeartbeat() } else { stopHeartbeat() }
    }

    /// When the current recording began, so the keyboard and the Live Activity
    /// can run their own timers rather than waiting for us to push numbers at
    /// them from the background.
    private var recordingStartedAt: Date? {
        guard isRecording else { return nil }
        return Date().addingTimeInterval(-engine.recordedSeconds)
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

    /// Proof of life for the keyboard, which cannot see this process at all.
    /// Without it a killed app leaves a state file that reads "microphone
    /// open" forever, and the keyboard offers a button that does nothing.
    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.handoff?.heartbeat()
                self.closeMicrophoneIfIdle()
            }
        }
    }

    private func stopHeartbeat() { heartbeat?.invalidate(); heartbeat = nil }

    /// Put an unused microphone away. Rides the heartbeat rather than adding a
    /// second timer: the heartbeat already runs exactly when a session is open,
    /// which is exactly when this question is worth asking.
    private func closeMicrophoneIfIdle() {
        guard isLive else { return }
        guard MicrophoneIdlePolicy.shouldClose(lastActivity: lastActivity,
                                               isRecording: isRecording,
                                               isThinking: isThinking) else { return }
        NSLog("openflow: closing the microphone after %.0f minutes idle",
              MicrophoneIdlePolicy.timeout / 60)
        endSession()
        // Said plainly, because the indicator going out is the visible part and
        // the reason for it is not.
        status = "Microphone closed after \(Int(MicrophoneIdlePolicy.timeout / 60)) minutes idle."
        handoff?.setStatus("closed — idle")
    }

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
