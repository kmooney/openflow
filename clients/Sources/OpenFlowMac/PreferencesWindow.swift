import SwiftUI
import AppKit
import OpenFlowKit

enum PreferencesTab: Hashable {
    case general, vocabulary, model
}

struct PreferencesWindow: View {
    @ObservedObject var model: AppModel
    @State var tab: PreferencesTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "keyboard") }
                .tag(PreferencesTab.general)
            VocabularyPane(model: model)
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
                .tag(PreferencesTab.vocabulary)
            ModelPane(model: model)
                .tabItem { Label("Model", systemImage: "waveform") }
                .tag(PreferencesTab.model)
        }
        .frame(width: 520)
        .padding(.top, 8)
    }
}

// MARK: - general

private struct GeneralPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Push to talk") {
                    VStack(alignment: .leading, spacing: 6) {
                        ChordField(model: model)
                        Text("Hold the chord, speak, release. The text is pasted into "
                             + "whatever has focus.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if model.chord.isCollisionProne {
                            Label("⌘ and ⇧ are held during ordinary shortcuts, so this "
                                  + "chord will sometimes open the microphone by accident.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if model.chord != .default {
                            Button("Reset to ⌃⌥") { model.setChord(.default) }
                                .buttonStyle(.link).font(.system(size: 10))
                        }
                    }
                }
            }

            Section {
                Toggle("Noise suppression", isOn: $model.noiseSuppression)
                Text("Spectral noise reduction for steady background noise — aircraft, "
                     + "fans, HVAC. Applied after recording, so it cannot affect capture, "
                     + "and a clean recording is left untouched.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                Toggle("Keep audio for debugging", isOn: $model.keepAudio)
                Text("Store each recording on disk so you can replay it. Off by default: "
                     + "the standing rule is transcribe-and-discard.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if !model.hotkeyReady {
                Section {
                    Label("Without Accessibility permission the chord only works inside "
                          + "OpenFlow's own window.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings…") { model.onRequestAccessibility?() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

/// Records a held modifier chord.
///
/// Click, hold what you want, let go. Committing on *release* rather than on
/// each flag change is what makes it feel like the thing it configures --
/// pressing ⌃ then ⌥ would otherwise commit ⌃ alone the instant it went down.
private struct ChordField: View {
    @ObservedObject var model: AppModel
    @StateObject private var recorder = ChordRecorder()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recorder.isRecording ? recorder.stop() : recorder.start { model.setChord($0) }
            } label: {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 96)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.bordered)
            .tint(recorder.isRecording ? .accentColor : nil)

            if recorder.isRecording {
                Text(recorder.held.count < 2
                     ? "Hold at least two modifiers…"
                     : "Release to set")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .onDisappear { recorder.stop() }
    }

    private var label: String {
        if recorder.isRecording {
            return recorder.held.symbols.isEmpty ? "Listening…" : recorder.held.symbols
        }
        return model.chord.symbols
    }
}

/// Owns the event monitor for the duration of a recording. A local monitor is
/// enough: the preferences window is key while you are using it, and a global
/// one would need Accessibility permission the user may not have granted yet.
@MainActor
private final class ChordRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var held = ModifierChord(mask: 0)

    private var monitor: Any?
    private var onCommit: ((ModifierChord) -> Void)?
    /// The widest combination seen while the keys were down. Releasing three
    /// modifiers is never simultaneous, so reading the flags at release time
    /// would capture whichever one happened to lift last.
    private var peak = ModifierChord(mask: 0)

    func start(onCommit: @escaping (ModifierChord) -> Void) {
        stop()
        self.onCommit = onCommit
        isRecording = true
        held = ModifierChord(mask: 0)
        peak = ModifierChord(mask: 0)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil          // swallow it; this is a capture field
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        held = ModifierChord(mask: 0)
        peak = ModifierChord(mask: 0)
        onCommit = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = UInt(event.modifierFlags
            .intersection(.deviceIndependentFlagsMask).rawValue)
        let current = ModifierChord(mask: flags)
        held = current
        if current.count > peak.count { peak = current }

        // Everything is up again: commit what was held at its widest.
        guard current.mask == 0 else { return }
        let candidate = peak
        // Too few to be a chord -- keep listening rather than silently setting
        // something that would fire on every Control press.
        guard candidate.isUsable else {
            peak = ModifierChord(mask: 0)
            return
        }
        let commit = onCommit
        stop()
        commit?(candidate)
    }
}

// MARK: - vocabulary

/// Words whisper is biased toward, and which app each list belongs to.
///
/// The editing surface is the file itself -- a plain list is faster to edit in
/// a text editor than through any table this could offer. What the pane must
/// provide is the one thing the file cannot: the bundle id of the app you were
/// just dictating into, since that is what a `[section]` header needs and
/// there is no way to guess it.
private struct VocabularyPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("In effect right now") {
                LabeledContent("Destination") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.context.appName ?? model.context.bundleID ?? "nothing yet")
                            .font(.system(size: 12, weight: .medium))
                        if let id = model.context.bundleID {
                            HStack(spacing: 6) {
                                Text(id)
                                    .font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                                Button {
                                    model.copy("[\(id)]")
                                } label: {
                                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                                }
                                .buttonStyle(.borderless)
                                .help("Copy as a section header, ready to paste into the file")
                            }
                        } else {
                            Text("Dictate somewhere and its id appears here.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Terms") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary).font(.system(size: 11))
                        if !model.vocabularyHere.isEmpty {
                            Text(model.vocabularyHere.prefix(12).joined(separator: ", ")
                                 + (model.vocabularyHere.count > 12 ? "…" : ""))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Section {
                Text("Terms above any [section] apply everywhere. A [bundle.id] header "
                     + "starts a list used only while that app has focus — which is how "
                     + "you get “git status” in a terminal instead of “get status”. "
                     + "App terms come first, so they survive the token cap.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.vocabulary.apps.isEmpty {
                    LabeledContent("Apps with their own list") {
                        Text(model.vocabulary.apps.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Edit Vocabulary…") { model.onEditVocabulary?() }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private var summary: String {
        let here = model.vocabularyHere.count
        let specific = here - model.vocabulary.global.count
        guard model.context.bundleID != nil, specific > 0 else {
            return "\(here) term\(here == 1 ? "" : "s"), all global"
        }
        return "\(here) terms — \(specific) for this app, \(model.vocabulary.global.count) global"
    }
}

// MARK: - model

private struct ModelPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var models: ModelStore

    init(model: AppModel) {
        self.model = model
        self.models = model.models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Models run entirely on this Mac. Larger ones are more accurate and "
                 + "slower; nothing is uploaded.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ModelCatalog.all) { m in
                        Row(models: models, model: m)
                        Divider().opacity(0.4)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                if let error = models.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .lineLimit(2)
                } else if models.diskUsage() > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: models.diskUsage(), countStyle: .file)) on disk")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
        }
        .frame(height: 400)
    }

    private struct Row: View {
        @ObservedObject var models: ModelStore
        let model: WhisperModel

        private var isInstalled: Bool { models.installed.contains(model.id) }
        private var isSelected: Bool { models.selectedID == model.id }
        private var progress: ModelStore.Progress? { models.downloading[model.id] }

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 13))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName).font(.system(size: 12, weight: .medium))
                        Text(model.sizeDescription)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        if models.isBundled(model.id) {
                            Text("included").font(.system(size: 9))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(model.note)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let progress {
                        ProgressView(value: progress.fraction)
                            .controlSize(.small)
                            .padding(.top, 2)
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: 8)

                actions
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { if isInstalled { models.select(model.id) } }
        }

        @ViewBuilder
        private var actions: some View {
            HStack(spacing: 6) {
                if progress != nil {
                    Button("Cancel") { models.cancelDownload(model.id) }
                        .controlSize(.small)
                } else if !isInstalled {
                    Button("Download") { models.download(model) }
                        .controlSize(.small)
                } else if !models.isBundled(model.id) {
                    // No confirmation: it is a re-downloadable file, and the
                    // button is only reachable for one already on disk.
                    Button(role: .destructive) { models.delete(model.id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this download")
                }
            }
            .padding(.top, 1)
        }
    }
}
