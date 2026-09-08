import Foundation

/// One dictation result waiting to be inserted by the keyboard.
public struct PendingTranscript: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public let tone: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString, text: String, tone: String,
                createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.tone = tone
        self.createdAt = createdAt
    }
}

/// The bridge between the iOS app and its keyboard extension.
///
/// A keyboard extension cannot use the microphone and runs under a memory
/// ceiling far below what a Whisper model needs, so the app does the work and
/// hands the finished text over. They share an App Group container; this is the
/// entire protocol between them.
///
/// Deliberately a *file plus a notification*, not a notification carrying the
/// text: the keyboard is frequently not running when the app finishes, and a
/// Darwin notification has no payload and no delivery guarantee. The file is
/// the truth and the notification is only an optimisation for the case where
/// the keyboard happens to be alive.
///
/// Parameterised on a directory rather than reaching for the App Group
/// directly, so it can be tested off-device.
public struct Handoff {
    public let directory: URL

    /// Posted when a transcript is written. No payload -- Darwin notifications
    /// cannot carry one across processes.
    public static let notificationName = "dev.openflow.transcript"
    /// Posted by the keyboard to ask the app to start keeping audio. This only
    /// works because the microphone is *already* open: nothing is started, a
    /// flag is flipped, and iOS never sees a backgrounded app try to begin
    /// capturing.
    public static let startRequestName = "dev.openflow.start"
    /// Posted by the keyboard to ask the app to stop recording and transcribe.
    /// The reverse direction: the app is in the background while the user is
    /// back in their own app, so the keyboard needs a way to say "done".
    public static let stopRequestName = "dev.openflow.stop"
    /// Throw the current recording away without transcribing it.
    public static let cancelRequestName = "dev.openflow.cancel"
    /// Put the microphone away and turn the indicator off. Allowed from the
    /// background — it is only *starting* that iOS refuses — so the keyboard
    /// can end a session without the user going back to the app.
    public static let closeRequestName = "dev.openflow.close"
    /// Posted by the app whenever its microphone state changes, so a keyboard
    /// that happens to be on screen redraws at once instead of waiting for its
    /// next poll.
    public static let stateChangedName = "dev.openflow.state"

    public init(directory: URL) { self.directory = directory }

    /// The App Group container. Nil when the keyboard lacks Full Access, which
    /// is the usual reason this fails in the wild.
    public init?(appGroup: String) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        self.directory = url
    }

    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }
    private var sessionURL: URL { directory.appendingPathComponent("session.json") }

    /// The keyboard writes this the moment it can, which is only possible with
    /// Full Access. Its presence is therefore how the *app* knows whether the
    /// keyboard is usable — there is no API to ask directly.
    private var keyboardReadyURL: URL { directory.appendingPathComponent("keyboard-ready") }

    public func markKeyboardReady() {
        try? Data().write(to: keyboardReadyURL, options: .atomic)
    }

    public var keyboardIsReady: Bool {
        FileManager.default.fileExists(atPath: keyboardReadyURL.path)
    }

    // MARK: - shared microphone state
    //
    // Two facts, not one, and the split is the whole point. "Live" means the
    // audio graph is running and the system indicator is lit; "recording"
    // means we are keeping what it delivers. The keyboard needs both: a live
    // microphone is one it can start a recording on from inside another app,
    // and a closed one is only ever an instruction to go back to the app.

    public struct MicState: Codable, Equatable, Sendable {
        /// Session open, graph running, indicator lit.
        public var live: Bool
        /// Keeping audio right now.
        public var recording: Bool
        /// When the current recording began. Nil unless `recording`.
        public var startedAt: Date?
        /// Heartbeat. The app rewrites this while it is live so a keyboard can
        /// tell "still going" from "the app was killed and nobody cleaned up".
        public var updatedAt: Date

        public init(live: Bool = false, recording: Bool = false,
                    startedAt: Date? = nil, updatedAt: Date = Date()) {
            self.live = live
            self.recording = recording
            self.startedAt = startedAt
            self.updatedAt = updatedAt
        }

        public static let closed = MicState()

        /// Seconds recorded so far, for the keyboard's own timer. Derived from
        /// a timestamp rather than pushed as a number: the app is in the
        /// background and cannot be relied on to tick.
        public var elapsed: TimeInterval {
            guard recording, let startedAt else { return 0 }
            return max(0, Date().timeIntervalSince(startedAt))
        }
    }

    /// How long a heartbeat stays believable. The app rewrites it every few
    /// seconds while live; well beyond that and the process is gone.
    public static let heartbeatTimeout: TimeInterval = 20

    public func setMic(live: Bool, recording: Bool, startedAt: Date? = nil) {
        let state = MicState(live: live, recording: recording,
                             startedAt: recording ? (startedAt ?? Date()) : nil)
        try? JSONEncoder().encode(state).write(to: sessionURL, options: .atomic)
        Self.post(Self.stateChangedName)
    }

    /// Rewrite the timestamp without changing anything else. Called on a timer
    /// while the microphone is open.
    public func heartbeat() {
        guard var state = storedMicState() else { return }
        state.updatedAt = Date()
        try? JSONEncoder().encode(state).write(to: sessionURL, options: .atomic)
    }

    private func storedMicState() -> MicState? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        return try? JSONDecoder().decode(MicState.self, from: data)
    }

    /// What the app is doing. A stale heartbeat reads as closed: if the app
    /// was killed mid-recording the flag would otherwise stick forever and the
    /// keyboard would keep offering to finish a recording that no longer
    /// exists.
    public func micState(staleAfter: TimeInterval = Handoff.heartbeatTimeout) -> MicState {
        guard let state = storedMicState(),
              Date().timeIntervalSince(state.updatedAt) < staleAfter
        else { return .closed }
        return state
    }

    /// Is the app recording right now?
    public func isRecording(staleAfter: TimeInterval = Handoff.heartbeatTimeout) -> Bool {
        micState(staleAfter: staleAfter).recording
    }

    /// Is the microphone open — whether or not anything is being kept?
    public func isLive(staleAfter: TimeInterval = Handoff.heartbeatTimeout) -> Bool {
        micState(staleAfter: staleAfter).live
    }

    // MARK: - requests from the keyboard

    /// Ask the app to start keeping audio.
    public static func requestStart() { post(startRequestName) }
    /// Ask the app to stop recording and transcribe.
    public static func requestStop() { post(stopRequestName) }
    /// Ask the app to throw the current recording away.
    public static func requestCancel() { post(cancelRequestName) }
    /// Ask the app to put the microphone away entirely.
    public static func requestClose() { post(closeRequestName) }

    public static func observeStartRequests(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        observe(name: startRequestName, handler)
    }

    public static func observeStopRequests(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        observe(name: stopRequestName, handler)
    }

    public static func observeCancelRequests(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        observe(name: cancelRequestName, handler)
    }

    public static func observeCloseRequests(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        observe(name: closeRequestName, handler)
    }

    /// Observe the app's microphone state changing. Used by the keyboard so it
    /// redraws the instant something happens rather than on its next poll.
    public static func observeStateChanges(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        observe(name: stateChangedName, handler)
    }

    // MARK: - what the app is actually doing
    //
    // The keyboard cannot see the app's state, read its logs, or tell the
    // difference between "did not receive the request", "received it and
    // failed to start", and "started fine". Without this it can only report
    // its own optimism, which is how a dead microphone came to display
    // "Listening…".

    private var statusURL: URL { directory.appendingPathComponent("status") }

    /// Marks a status line as a failure the keyboard should stop waiting on.
    /// A transcription that fails posts no transcript notification, so without
    /// this the keyboard has nothing to distinguish "still working" from "over,
    /// and it did not work" — and sat on *Working* until its timeout.
    public static let failurePrefix = "!"

    /// Record what just happened, for the keyboard to display.
    public func setStatus(_ line: String) {
        try? Data("\(Date().timeIntervalSince1970)|\(line)".utf8)
            .write(to: statusURL, options: .atomic)
        // Wake a keyboard that is on screen. Polling would find this within a
        // quarter second anyway; a failure the user is staring at deserves not
        // to wait even that long.
        Self.post(Self.stateChangedName)
    }

    /// Record a failure. The keyboard shows it and stops waiting.
    public func setFailure(_ line: String) {
        setStatus(Self.failurePrefix + line)
    }

    /// The app's last reported failure, if recent enough to be about the thing
    /// the user just did. Consumed by reading, so one failure is shown once.
    public func takeFailure(within seconds: TimeInterval = 30) -> String? {
        guard let line = lastStatus(within: seconds),
              line.hasPrefix(Self.failurePrefix) else { return nil }
        try? FileManager.default.removeItem(at: statusURL)
        return String(line.dropFirst(Self.failurePrefix.count))
    }

    /// The app's last reported state, if recent enough to still describe now.
    public func lastStatus(within seconds: TimeInterval = 60) -> String? {
        guard let raw = try? String(contentsOf: statusURL, encoding: .utf8) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, let stamp = TimeInterval(parts[0]),
              Date().timeIntervalSince1970 - stamp < seconds else { return nil }
        return String(parts[1])
    }

    /// Offer a transcript for the keyboard to insert.
    public func offer(_ text: String, tone: Tone) throws {
        let pending = PendingTranscript(text: text, tone: tone.name)
        let data = try JSONEncoder().encode(pending)
        // Atomic: the keyboard may read at any moment, and a half-written file
        // would be inserted as garbage into someone's message.
        try data.write(to: pendingURL, options: .atomic)
        Self.postNotification()
    }

    /// Take the pending transcript, if any, and remove it.
    ///
    /// One-shot by construction: reading deletes. The keyboard is asked for
    /// this every time it appears, and inserting the same sentence twice is a
    /// worse failure than missing it once.
    ///
    /// `maxAge` guards against inserting something dictated long ago — if the
    /// user gave up and went elsewhere, that text is no longer wanted.
    public func take(maxAge: TimeInterval = 180) -> PendingTranscript? {
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: pendingURL) }
        guard let pending = try? JSONDecoder().decode(PendingTranscript.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(pending.createdAt) <= maxAge else { return nil }
        return pending
    }

    /// Is something waiting? Does not consume it.
    public var hasPending: Bool {
        FileManager.default.fileExists(atPath: pendingURL.path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: pendingURL)
    }

    // MARK: - cross-process notification

    public static func postNotification() { post(notificationName) }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Observe transcript notifications. The token must be kept alive.
    public static func observe(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        observe(name: notificationName, handler)
    }

    static func observe(name: String, _ handler: @escaping () -> Void) -> NSObjectProtocol {
        let box = ObserverBox(handler: handler)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(box).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString, nil, .deliverImmediately)
        return box
    }

    public static func removeObserver(_ token: NSObjectProtocol) {
        guard let box = token as? ObserverBox else { return }
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(box).toOpaque())
    }
}

final class ObserverBox: NSObject {
    let handler: () -> Void
    init(handler: @escaping () -> Void) { self.handler = handler }
}
