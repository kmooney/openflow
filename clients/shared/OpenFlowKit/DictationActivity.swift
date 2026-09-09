#if canImport(ActivityKit) && os(iOS)
import Foundation
import ActivityKit

/// The Live Activity shown while the microphone is open.
///
/// iOS lights its own recording indicator whenever an app is capturing, but
/// that indicator is a dot: it cannot say *which* app, whether a recording is
/// running or merely possible, or how long you have been talking. A session
/// that stays open for minutes at a time needs all three, and the Dynamic
/// Island is the only place to put them where they are visible from inside
/// someone else's app.
///
/// Elapsed time is published as a *start date*, not a number of seconds. The
/// app is in the background and cannot be relied on to tick; `Text(timerInterval:)`
/// counts on its own once it has the origin.
public struct DictationActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Keeping audio, as opposed to merely holding the microphone open.
        public var recording: Bool
        /// When the current phase began — the origin for the timer.
        public var since: Date
        /// One short line: "Listening", "Transcribing…", "Mic open".
        public var status: String

        public init(recording: Bool, since: Date, status: String) {
            self.recording = recording
            self.since = since
            self.status = status
        }
    }

    public init() {}
}
#endif
