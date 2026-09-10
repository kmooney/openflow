import SwiftUI
import WidgetKit
import ActivityKit
import OpenFlowKit

/// What the notch shows while OpenFlow holds the microphone.
///
/// The whole point of this extension is that the session outlives the app's
/// time on screen. Once the user swipes back to their own app, this is the only
/// thing telling them the microphone is still open and how long they have been
/// talking — iOS's own indicator is a coloured dot with no story attached.
@main
struct OpenFlowActivityBundle: WidgetBundle {
    var body: some Widget {
        DictationLiveActivity()
    }
}

struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("OpenFlow").font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        dot(context.state)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    timer(context.state, markSize: 22)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(context.state.recording ? .red : .secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(hint(context.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                dot(context.state)
            } compactTrailing: {
                // The number the user asked for, in the only place they can see
                // it from inside another app.
                timer(context.state, markSize: 16)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(context.state.recording ? .red : .secondary)
                    .frame(maxWidth: 44)
            } minimal: {
                dot(context.state)
            }
            .keylineTint(context.state.recording ? .red : .accentColor)
        }
    }

    private func lockScreen(_ state: DictationActivityAttributes.ContentState) -> some View {
        HStack(spacing: 12) {
            dot(state).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.status).font(.headline)
                Text(hint(state)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            timer(state, markSize: 24)
                .font(.title2.monospacedDigit())
                .foregroundStyle(state.recording ? .red : .secondary)
        }
        .padding()
    }

    private func dot(_ state: DictationActivityAttributes.ContentState) -> some View {
        Image(systemName: state.recording ? "mic.fill" : "mic")
            .foregroundStyle(state.recording ? .red : .secondary)
    }

    /// Counts by itself from the origin it is given. The app is in the
    /// background whenever this matters and cannot push a new number every
    /// second — nor should it have to.
    ///
    /// When nothing is being recorded there is no number to show, and the word
    /// "open" was doing nothing the status line beside it did not already say.
    /// The mark is better use of the space: it says *whose* microphone is lit,
    /// which is the one question the system's own indicator cannot answer.
    @ViewBuilder
    private func timer(_ state: DictationActivityAttributes.ContentState,
                       markSize: CGFloat) -> some View {
        if state.recording {
            Text(timerInterval: state.since...Date.distantFuture,
                 pauseTime: nil, countsDown: false, showsHours: false)
                .multilineTextAlignment(.trailing)
        } else {
            // Sized per call site rather than by the font: the mark is shapes,
            // and shapes do not read `.font()`.
            OpenFlowMark().frame(width: markSize, height: markSize)
        }
    }

    private func hint(_ state: DictationActivityAttributes.ContentState) -> String {
        state.recording
            ? "Tap the check on the OpenFlow keyboard to insert."
            : "Tap the microphone on the OpenFlow keyboard to speak."
    }
}
