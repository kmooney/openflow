import SwiftUI
import OpenFlowKit

struct RootView: View {
    @ObservedObject var state: AppState
    @State private var showingModels = false
    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !state.keyboardReady { setupBanner }
                stats
                Divider()
                HistoryList(state: state)
                // Above the recorder, not over it. As an overlay this card
                // sat squarely on the microphone button, hiding the elapsed
                // time and the key that finishes the recording — at the exact
                // moment it was telling the user the recording was running.
                if state.showSwipeHint { SwipeBackHint(state: state) }
                Divider()
                recorder
            }
            .navigationTitle("OpenFlow")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingModels) {
                ModelsView(models: state.models)
            }
            .sheet(isPresented: $showingSetup) { KeyboardSetupView() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Tone", selection: $state.tone) {
                        ForEach(Tone.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingModels = true } label: {
                        Image(systemName: "waveform.circle")
                    }
                    .accessibilityLabel("Speech model")
                }
            }
        }
    }

    /// Shown until the keyboard proves it can reach the shared container. The
    /// keyboard cannot explain itself in the space it has, so the explaining
    /// happens here where there is room.
    private var setupBanner: some View {
        Button { showingSetup = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "keyboard.badge.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up the keyboard")
                        .font(.subheadline.weight(.medium))
                    Text("Two taps in Settings, then you can dictate anywhere.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    private var stats: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Stat(value: state.stats.spokenWords.formatted(), label: "words", prominent: true)
            Stat(value: state.stats.todayWords.formatted(), label: "today")
            Stat(value: state.stats.utterances.formatted(), label: "utterances")
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var recorder: some View {
        VStack(spacing: 10) {
            if state.handedOffFromKeyboard {
                Label("Dictating for the keyboard — the text will be waiting when you switch back.",
                      systemImage: "keyboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Wraps rather than clips: a failure here arrives as an OSStatus
            // string long enough that a fixed single line hid the only part
            // that identified it.
            Text(statusLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(state.isRecording ? .red : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 16)
                .padding(.horizontal, 12)
                .textSelection(.enabled)

            // One key, and only one. Discard and close-the-microphone live
            // on the keyboard instead: by the time you want either, you are in
            // another app and this screen is not where you are looking.
            Button(action: state.toggle) {
                ZStack {
                    Circle()
                        .fill(state.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 76, height: 76)
                        .scaleEffect(state.isRecording ? 1 + min(0.18, level * 0.4) : 1)
                        .animation(.easeOut(duration: 0.1), value: level)
                    Image(systemName: primarySymbol)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .disabled(state.isThinking)
            .buttonStyle(.plain)

            Text(primaryCaption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 16)
    }

    private var primarySymbol: String {
        if state.isRecording { return "checkmark" }
        return "mic.fill"
    }

    private var primaryCaption: String {
        if state.isRecording { return "Tap to finish and insert" }
        if state.isLive { return "Microphone open — tap to speak" }
        return "Tap to open the microphone"
    }

    private var level: Double {
        Double(max(0, min(1, (state.inputDB + 50) / 50)))
    }

    private var statusLine: String {
        if state.isRecording { return String(format: "● %.1fs", state.elapsed) }
        if state.isThinking { return "transcribing…" }
        if state.isLive, state.status.isEmpty { return "○ microphone open" }
        return state.status
    }
}

/// What to do next, at the moment there is nothing on screen to say it.
///
/// The session is open and the user's next move is to *leave* — which is the
/// one instruction an app cannot give by putting a button somewhere, because
/// the gesture is a system one along the bottom edge. So it is drawn: an arrow
/// that runs the length of the home indicator, in the direction of the swipe.
struct SwipeBackHint: View {
    @ObservedObject var state: AppState
    @State private var slide = false

    var body: some View {
        VStack(spacing: 10) {
            Text("Now go back to your app")
                .font(.headline)
            Text("Swipe right along the bottom edge. The microphone stays open — bring up the OpenFlow keyboard, tap Speak, then tap Insert when you are done.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 6)
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: slide ? 150 : 0)
                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                               value: slide)
            }
            .frame(width: 180, height: 18)

            Button("Got it") { state.showSwipeHint = false }
                .font(.subheadline)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.10))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { slide = true }
    }
}

struct Stat: View {
    let value: String
    let label: String
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: prominent ? 26 : 17,
                              weight: prominent ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct HistoryList: View {
    @ObservedObject var state: AppState

    var body: some View {
        List {
            ForEach(state.history, id: \.id) { u in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(u.createdAt, format: .relative(presentation: .numeric))
                        Text(u.tone)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                        if u.outcome == "ok" {
                            Text("\(u.spokenWords) words")
                        } else {
                            Label("nothing captured", systemImage: "waveform.slash")
                        }
                        Spacer()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if u.outcome == "ok" {
                        Text(u.finalText).font(.body)
                        // What whisper actually heard, whenever the formatter
                        // changed it. The pipeline is only trustworthy if you
                        // can see what each stage did — and when a rebuilt
                        // address comes out wrong, this is the line that says
                        // whether the model or the rules got it wrong.
                        if u.rawText != u.finalText, !u.rawText.isEmpty {
                            Label(u.rawText, systemImage: "ear")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(Array(LedgerEntry.decode(u.ledger).enumerated()), id: \.offset) { _, e in
                        Text(e.description).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { state.delete(u) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button { state.copy(u.finalText) } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }.tint(.blue)
                    Button { state.sendToKeyboard(u.finalText) } label: {
                        Label("To Keyboard", systemImage: "keyboard")
                    }.tint(.indigo)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $state.query, prompt: "Search history")
        .overlay {
            if state.history.isEmpty {
                ContentUnavailableView("Nothing dictated yet", systemImage: "waveform",
                                       description: Text("Tap the microphone and speak."))
            }
        }
    }
}
