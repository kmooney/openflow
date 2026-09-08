import SwiftUI
import OpenFlowKit

/// Seeds a browser's vocabulary section from the domains you actually visit.
///
/// Shows the list before writing it, and writes nothing on its own. Reading
/// someone's browsing history is the most invasive thing this app does, and
/// the spec's stance on importing Contacts (§6.1) applies at least as strongly
/// here: explicit opt-in, visible result, editable afterwards.
struct SeedVocabularySheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var sources: [BrowserHistory.Source] = []
    @State private var picked: BrowserHistory.Source?
    @State private var found: [(domain: String, count: Int)] = []
    @State private var keep = 40
    @State private var error: String?
    @State private var scanning = false

    private var chosen: [String] { found.prefix(keep).map(\.domain) }

    /// What the section will hold: anything hand-added stays, and stays first.
    private var merged: [String] {
        guard let picked else { return chosen }
        let existing = VocabularyFile.section(model.vocabularyText, app: picked.bundleID)
        var seen = Set(existing.map { $0.lowercased() })
        return existing + chosen.filter { seen.insert($0.lowercased()).inserted }
    }

    private var tokens: Int {
        Vocabulary.estimatedPromptTokens(merged + model.vocabulary.global)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Seed from browser history").font(.system(size: 15, weight: .semibold))
                Text("Whisper cannot guess a domain it has never seen. Listing the sites "
                     + "you actually visit fixes them before you hit them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)

            Divider()

            if sources.isEmpty {
                message("No supported browser history found.",
                        detail: "Firefox, Chrome, Edge and Brave are read. Safari's history "
                              + "sits behind Full Disk Access, so it is not offered.")
            } else {
                controls
                Divider()
                if let error {
                    message("Could not read that history.", detail: error)
                } else if scanning {
                    message("Reading…", detail: nil)
                } else if found.isEmpty {
                    message("Nothing usable in that history yet.", detail: nil)
                } else {
                    list
                }
            }

            Divider()
            footer
        }
        .frame(width: 520, height: 520)
        .onAppear {
            sources = BrowserHistory.available()
            // Prefer the browser you actually dictate into.
            picked = sources.first { $0.bundleID == model.context.bundleID } ?? sources.first
            scan()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Browser", selection: Binding(
                get: { picked?.id ?? "" },
                set: { id in picked = sources.first { $0.id == id }; scan() })) {
                ForEach(sources) { Text($0.name).tag($0.id) }
            }
            .frame(width: 190)

            Spacer()

            Stepper("Top \(keep)", value: $keep, in: 5...120, step: 5)
                .font(.system(size: 11))
                .disabled(found.isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(found.prefix(keep).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.domain).font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Text("\(row.count)")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 18).padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 6)
            }
            budget
        }
    }

    /// The cap is silent when it bites -- whisper truncates a long prompt and
    /// says nothing -- so it has to be visible here.
    private var budget: some View {
        let over = tokens > Vocabulary.promptTokenBudget
        return HStack(spacing: 6) {
            Image(systemName: over ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(over ? Color.orange : Color.secondary)
            Text(over
                 ? "≈\(tokens) tokens — over whisper's ~\(Vocabulary.promptTokenBudget) limit. "
                   + "The tail will be silently dropped; lower the count."
                 : "≈\(tokens) of whisper's ~\(Vocabulary.promptTokenBudget) prompt tokens.")
                .font(.system(size: 10))
                .foregroundStyle(over ? Color.orange : Color.secondary)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(over ? Color.orange.opacity(0.1) : Color.clear)
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12))
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            if let picked, !found.isEmpty {
                Text("Writes \(merged.count) terms to [\(picked.bundleID)]")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Add to Vocabulary") {
                if let picked { model.seedVocabulary(merged, for: picked.bundleID) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(found.isEmpty || picked == nil)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func scan() {
        guard let picked else { return }
        scanning = true
        error = nil
        found = []
        Task {
            do {
                let rows = try BrowserHistory.domains(from: picked)
                await MainActor.run { found = rows; scanning = false }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    scanning = false
                }
            }
        }
    }
}
