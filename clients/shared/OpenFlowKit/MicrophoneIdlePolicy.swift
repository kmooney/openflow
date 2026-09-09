import Foundation

/// When to put a held-open microphone away.
///
/// Holding the microphone open is what lets the keyboard start a recording from
/// inside another app, and the price is the system recording indicator lit for
/// as long as the session lasts. That price is worth paying while someone is
/// dictating and worth nothing at all once they have stopped — an indicator
/// burning through the afternoon over a session nobody is using is the version
/// of this design that deserves the suspicion it would attract.
///
/// So the session expires. A closed microphone is recoverable in two taps (the
/// keyboard's *Open OpenFlow* key, then the app opens it on arrival), which is
/// a far better failure than a microphone nobody asked to stay on.
///
/// A separate type rather than four lines in a timer callback because it is a
/// policy, and policies should be readable and testable without an audio
/// session, a phone, or five minutes of waiting.
public enum MicrophoneIdlePolicy {

    /// How long an open-but-unused microphone is allowed to stay open.
    public static let timeout: TimeInterval = 300      // five minutes

    /// Should the session be closed now?
    ///
    /// "Idle" means no recording has started or finished. Merely bringing the
    /// keyboard up is not activity: the user may be typing by hand for an hour
    /// with the OpenFlow keyboard selected, and none of that needs the
    /// microphone.
    ///
    /// - Parameters:
    ///   - lastActivity: when a recording last started, finished or was discarded.
    ///   - isRecording: never close mid-utterance.
    ///   - isThinking: never close with a transcription in flight — the audio is
    ///     already captured and the result is still owed to the user.
    public static func shouldClose(lastActivity: Date,
                                   now: Date = Date(),
                                   isRecording: Bool,
                                   isThinking: Bool,
                                   timeout: TimeInterval = timeout) -> Bool {
        guard !isRecording, !isThinking else { return false }
        return now.timeIntervalSince(lastActivity) >= timeout
    }
}
