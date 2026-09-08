import Foundation
import ActivityKit
import OpenFlowKit

/// Owns the one Live Activity that reports the open microphone.
///
/// Starting one requires the foreground, which is fine: the session it
/// describes can only be opened from the foreground either. *Updating* one
/// does not, which is what matters — every subsequent recording is started and
/// finished from the keyboard while the app is in the background, and the notch
/// has to keep up.
@MainActor
final class LiveActivityController {
    private var activity: Activity<DictationActivityAttributes>?

    /// What we have most recently asked for. Held locally rather than read back
    /// from `activity.content`, which lags behind an update still in flight —
    /// and lagging here would restart the timer on every heartbeat.
    private var current: DictationActivityAttributes.ContentState?

    /// Updates are `async` and were originally fired and forgotten, one Task
    /// each. Opening a session posts two in the same turn — "mic open" then
    /// "recording" — and they landed in whichever order they finished, which
    /// left the Dynamic Island saying *open* over a running recording. Each
    /// update now waits for the one before it.
    private var inFlight: Task<Void, Never>?

    /// Whether the user has left Live Activities on for this app. Nothing here
    /// is load-bearing if they have not — the session still works, it just
    /// stops narrating itself.
    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(recording: Bool) {
        guard enabled, activity == nil else { return update(recording: recording) }
        let state = DictationActivityAttributes.ContentState(
            recording: recording, since: Date(),
            status: recording ? "Listening" : "Mic open")
        activity = try? Activity.request(
            attributes: DictationActivityAttributes(),
            content: .init(state: state, staleDate: nil))
        current = activity == nil ? nil : state
    }

    func update(recording: Bool, status: String? = nil) {
        guard activity != nil else { return start(recording: recording) }
        // `since` moves only when the phase changes, so the timer counts the
        // current utterance rather than restarting on every update.
        let since = current?.recording == recording ? (current?.since ?? Date()) : Date()
        push(.init(recording: recording, since: since,
                   status: status ?? (recording ? "Listening" : "Mic open")))
    }

    /// Say what is happening without claiming a recording is running — used for
    /// "Transcribing…", which is neither recording nor an idle microphone.
    func note(_ status: String) {
        guard let current else { return }
        push(.init(recording: false, since: current.since, status: status))
    }

    private func push(_ state: DictationActivityAttributes.ContentState) {
        guard let activity else { return }
        current = state
        let previous = inFlight
        inFlight = Task {
            await previous?.value
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        current = nil
        let previous = inFlight
        inFlight = nil
        // `.immediate`: the microphone is off, and an activity that lingers
        // saying otherwise is worse than none at all.
        Task {
            await previous?.value
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Adopt an activity left behind by a previous launch. Without this a crash
    /// mid-session strands a Live Activity claiming the microphone is open,
    /// with nothing left alive to end it.
    func adoptExisting() {
        activity = Activity<DictationActivityAttributes>.activities.first
        current = activity?.content.state
    }
}
