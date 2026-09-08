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

            Button(action: state.toggle) {
                ZStack {
                    Circle()
                        .fill(state.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 76, height: 76)
                        .scaleEffect(state.isRecording ? 1 + min(0.18, level * 0.4) : 1)
                        .animation(.easeOut(duration: 0.1), value: level)
                    Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .disabled(state.isThinking)
            .buttonStyle(.plain)

            Text(state.isRecording ? "Tap to finish" : "Tap and speak")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 16)
    }

    private var level: Double {
        Double(max(0, min(1, (state.inputDB + 50) / 50)))
    }

    private var statusLine: String {
        if state.isRecording { return String(format: "● %.1fs", state.elapsed) }
        if state.isThinking { return "transcribing…" }
        return state.status
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
