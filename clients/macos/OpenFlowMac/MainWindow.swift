import SwiftUI
import OpenFlowKit

struct MainWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            Divider()
            HistoryPane(model: model)
        }
        .frame(minWidth: 560, minHeight: 420)
        // An accessory app has no app menu, so ⌘, has to be bound by a view.
        .background {
            Button("") { model.showPreferences() }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
        }
    }
}

// MARK: - header

private struct Header: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Stat(value: model.stats.spokenWords.formatted(), label: "words spoken", prominent: true)
                Stat(value: model.stats.todayWords.formatted(), label: "today")
                Stat(value: model.stats.utterances.formatted(), label: "utterances")
                Stat(value: "\(Int(model.stats.secondsSpoken / 60))", label: "minutes")
                Spacer()
            }

            HStack(spacing: 12) {
                Button(action: model.toggleListen) {
                    Label(model.isRecording ? "Stop" : "Listen",
                          systemImage: model.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 86)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)
                .disabled(isThinking || model.needsModel)

                // Not bound straight to `model.tone`: picking is the teaching
                // signal, and it has to register even when you pick the tone
                // that is already showing -- that is how you confirm a
                // suggestion and pin it for this app.
                Picker("", selection: Binding(get: { model.tone },
                                              set: { model.chooseTone($0) })) {
                    ForEach(Tone.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .labelsHidden()

                RememberedTonesButton(model: model)

                Spacer()

                Text(rightHandText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(model.isRecording ? .red : .secondary)
                    .animation(.default, value: model.status)
            }

            HStack(spacing: 6) {
                Image(systemName: model.toneIsRemembered ? "pin.fill" : "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(model.toneIsRemembered ? Color.accentColor : Color.secondary.opacity(0.6))
                Text(model.toneExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(model.toneIsRemembered ? .secondary : .tertiary)
                    .lineLimit(1)
                if model.toneIsRemembered {
                    Button("Forget") { model.forgetTone() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                } else if model.context.bundleID != nil {
                    // A segmented picker does not fire when you tap the segment
                    // that is already selected, so confirming a suggestion --
                    // "yes, casual, keep it" -- needs a control of its own.
                    Button("Pin to \(model.context.label)") { model.chooseTone(model.tone) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                Spacer()
            }
            .padding(.top, -6)

            if !model.hotkeyReady {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("The \(model.chord.symbols) hotkey only works inside this window "
                         + "until OpenFlow has Accessibility permission.")
                        .font(.system(size: 11))
                    Button("Open Settings…") { model.onRequestAccessibility?() }
                        .controlSize(.small)
                    Spacer()
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 10) {
                Text("Hold \(model.chord.symbols) anywhere to dictate into the focused app. "
                     + "Listen copies here instead.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if model.isRecording {
                    LevelMeter(db: model.inputDB)
                    Text(model.inputDB < -90 ? "no signal" : "listening")
                        .font(.system(size: 10))
                        .foregroundStyle(model.inputDB < -90 ? Color.orange : Color.secondary)
                }
            }
        }
        .padding(16)
    }

    private var isThinking: Bool { if case .thinking = model.state { return true }; return false }

    private var rightHandText: String {
        if model.isRecording { return String(format: "● %.1fs", model.elapsed) }
        if isThinking { return "transcribing…" }
        return model.status
    }
}

/// The memory, made visible. Something that changes tone behind your back has
/// to be inspectable, or the first time it guesses wrong it reads as a bug --
/// so every rule is listed, editable in place, and removable.
private struct RememberedTonesButton: View {
    @ObservedObject var model: AppModel
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .buttonStyle(.borderless)
        .help("Tones remembered per app and field")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            RememberedTones(model: model)
        }
    }
}

private struct RememberedTones: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Remembered tones")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
            Text("Set by picking a tone while that app has focus.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 8)
            Divider()

            if model.rememberedTones.isEmpty {
                Text("Nothing yet — OpenFlow is using its suggestions.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.rememberedTones) { rule in
                            RememberedRow(model: model, rule: rule)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxHeight: 260)
                Divider()
                HStack {
                    Spacer()
                    Button("Forget All", role: .destructive) { model.forgetAllTones() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(width: 360)
        // The list is a snapshot of a plain dictionary, so redraw it whenever
        // the memory changes rather than making every rule observable.
        .id(model.memoryRevision)
    }
}

private struct RememberedRow: View {
    @ObservedObject var model: AppModel
    let rule: ToneRule

    var body: some View {
        HStack(spacing: 8) {
            Text(rule.label)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { rule.tone },
                                          set: { model.remember($0, forKey: rule.key) })) {
                ForEach(Tone.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .frame(width: 118)
            .controlSize(.small)
            Button { model.forgetTone(rule.key) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget this one")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

/// Live input level. Mostly there to answer "is it hearing me, or the engines?"
private struct LevelMeter: View {
    let db: Float
    private var fraction: Double {
        // -50 dBFS floor: below that is effectively silence for speech.
        Double(max(0, min(1, (db + 50) / 50)))
    }
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary).frame(width: 70, height: 4)
            Capsule()
                .fill(fraction > 0.85 ? Color.orange : Color.accentColor)
                .frame(width: 70 * fraction, height: 4)
        }
        .animation(.linear(duration: 0.1), value: fraction)
        .help("Input level")
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var prominent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: prominent ? 26 : 17, weight: prominent ? .semibold : .regular,
                              design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - history

private struct HistoryPane: View {
    @ObservedObject var model: AppModel
    @State private var selection: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if model.history.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "Nothing dictated yet" : "No matches",
                    systemImage: model.query.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(model.query.isEmpty
                        ? "Hold \(model.chord.symbols) and say something, or press Listen."
                        : "No utterance contains “\(model.query)”."))
                .frame(maxHeight: .infinity)
            } else {
                List(model.history, id: \.id, selection: $selection) { u in
                    Row(u: u, model: model).tag(u.id)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(model.history.count) shown")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if model.keepAudio || model.audioOnDiskBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: model.audioOnDiskBytes,
                                                   countStyle: .file))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    model.showPreferences(.model)
                } label: {
                    Label(model.needsModel ? "No speech model" : model.activeModelName,
                          systemImage: model.needsModel
                              ? "exclamationmark.triangle.fill" : "waveform.badge.mic")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(model.needsModel ? Color.orange : Color.secondary)
                .help("Choose or download the model that transcribes your speech")
                Button("Delete All…", role: .destructive, action: confirmDeleteAll)
                    .disabled(model.stats.utterances == 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search history")
    }

    private func confirmDeleteAll() {
        let a = NSAlert()
        a.messageText = "Delete all dictation history?"
        a.informativeText = "Every utterance is removed permanently. This cannot be undone."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { model.deleteAll() }
    }
}

private struct Row: View {
    let u: Utterance
    @ObservedObject var model: AppModel
    @ObservedObject private var playback: AudioPlayback
    @State private var hovering = false
    @State private var showingOriginal = false

    init(u: Utterance, model: AppModel) {
        self.u = u
        self.model = model
        self.playback = model.playback
    }

    private var ledger: [LedgerEntry] { LedgerEntry.decode(u.ledger) }

    private var failureText: String {
        switch u.outcome {
        case "silence": return "Nothing audible"
        case "steadyNoise": return "Background noise only — not transcribed"
        case "empty": return "No words recognised"
        default: return "Nothing captured"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(u.createdAt, format: .relative(presentation: .numeric))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(u.tone).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Text(u.outcome == "ok" ? "\(u.spokenWords) words · \(u.latencyMS)ms"
                                       : String(format: "%.1fs audio", Double(u.durationMS) / 1000))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if !u.guardrailPassed {
                    Label("rolled back", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                Spacer()

                // Always laid out, only revealed on hover. Inserting these on
                // hover changed the row's height and made the whole list jump.
                HStack(spacing: 10) {
                    if u.audioPath != nil {
                        Button { model.playback.toggle(u.audioPath) } label: {
                            Image(systemName: model.playback.playingPath == u.audioPath
                                  ? "stop.circle" : "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Replay what was recorded")
                    }
                    Button { model.copy(u.finalText) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help("Copy to clipboard")
                    .disabled(u.outcome != "ok")
                    Button(role: .destructive) { model.delete(u) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless).help("Delete permanently")
                }
                .opacity(hovering || model.playback.playingPath == u.audioPath ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(height: 18)          // pin it: buttons are taller than labels

            if u.outcome == "ok" {
                Text(showingOriginal ? u.rawText : u.finalText)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(showingOriginal ? Color.secondary : Color.primary)
            } else {
                // Kept deliberately: a capture that produced nothing is the one
                // worth listening back to.
                Label(failureText, systemImage: "waveform.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // The middle of the pipeline, when a polish model changed
            // something. Three stages produce this text and any of them can be
            // the one that got it wrong; a trail that shows only the ends
            // cannot tell you which.
            if u.outcome == "ok", !u.polishedText.isEmpty, u.polishedText != u.finalText {
                Label(u.polishedText, systemImage: "wand.and.sparkles")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Which models produced this, recorded per utterance rather than
            // read from the settings in force now. "No polish" is named rather
            // than left blank: a missing line and a deliberate absence read
            // identically.
            if let speech = modelName(u.speechModel) {
                HStack(spacing: 8) {
                    Label(speech, systemImage: "waveform")
                    Label(modelName(u.polishModel) ?? "No polish",
                          systemImage: "wand.and.sparkles")
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            if !ledger.isEmpty {
                ForEach(Array(ledger.enumerated()), id: \.offset) { _, e in
                    Text(e.description)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if showingOriginal {
                Text("showing what you said, before formatting")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { model.copy(u.finalText) }
            Button("Copy Original") { model.copy(u.rawText) }
            Divider()
            Button(showingOriginal ? "Show Formatted" : "Show Original") {
                showingOriginal.toggle()
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(u) }
        }
    }
}

/// A model's display name from its filename, or nil when none was recorded --
/// which is every row written before the columns existed.
private func modelName(_ filename: String) -> String? {
    guard !filename.isEmpty else { return nil }
    if let m = ModelCatalog.all.first(where: { $0.filename == filename }) {
        return m.displayName
    }
    if let m = PolishCatalog.all.first(where: { $0.filename == filename }) {
        return m.displayName
    }
    return (filename as NSString).deletingPathExtension
}
