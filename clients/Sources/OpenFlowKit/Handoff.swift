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
    /// Posted by the keyboard to ask the app to stop recording and transcribe.
    /// The reverse direction: the app is in the background while the user is
    /// back in their own app, so the keyboard needs a way to say "done".
    public static let stopRequestName = "dev.openflow.stop"

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

    // MARK: - shared recording state
    //
    // The keyboard has to know whether the app is currently listening, so its
    // microphone key can mean "stop and insert" rather than "open the app
    // again". Two processes, so this lives in the container.

    private struct SessionState: Codable {
        var recording: Bool
        var startedAt: Date
    }

    public func setRecording(_ recording: Bool) {
        let state = SessionState(recording: recording, startedAt: Date())
        try? JSONEncoder().encode(state).write(to: sessionURL, options: .atomic)
    }

    /// Is the app recording right now? Stale state is treated as "no": if the
    /// app was killed mid-recording the flag would otherwise stick forever and
    /// the keyboard's microphone key would never open the app again.
    public func isRecording(staleAfter: TimeInterval = 300) -> Bool {
        guard let data = try? Data(contentsOf: sessionURL),
              let state = try? JSONDecoder().decode(SessionState.self, from: data),
              state.recording,
              Date().timeIntervalSince(state.startedAt) < staleAfter
        else { return false }
        return true
    }

    /// Ask the app to stop recording and transcribe.
    public static func requestStop() {
        post(stopRequestName)
    }

    public static func observeStopRequests(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        observe(name: stopRequestName, handler)
    }

    // MARK: - what the app is actually doing
    //
    // The keyboard cannot see the app's state, read its logs, or tell the
    // difference between "did not receive the request", "received it and
    // failed to start", and "started fine". Without this it can only report
    // its own optimism, which is how a dead microphone came to display
    // "Listening…".

    private var statusURL: URL { directory.appendingPathComponent("status") }

    /// Record what just happened, for the keyboard to display.
    public func setStatus(_ line: String) {
        try? Data("\(Date().timeIntervalSince1970)|\(line)".utf8)
            .write(to: statusURL, options: .atomic)
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
