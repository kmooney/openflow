import SwiftUI
import OpenFlowKit

struct ModelsView: View {
    @ObservedObject var models: ModelStore
    @ObservedObject var polish: ModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelCatalog.all) { model in
                        row(model)
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Models run entirely on this device. Larger ones are more accurate and slower; nothing is sent anywhere.")
                }

                Section {
                    // "None" is a real choice, not an absence. Formatting is
                    // optional in a way transcription is not: without a model
                    // the deterministic rules still run and still produce text.
                    Button {
                        polish.select(PolishCatalog.offID)
                    } label: {
                        HStack {
                            Image(systemName: polish.selectedID == PolishCatalog.offID
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(polish.selectedID == PolishCatalog.offID
                                                 ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("None").font(.body)
                                Text("Rules only. Fast, predictable, and cannot invent a word you did not say.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(PolishCatalog.all) { model in
                        polishRow(model)
                    }
                } header: {
                    Text("Polish")
                } footer: {
                    Text("A language model that tidies the transcript before formatting. Every note is what was measured on real dictation from a phone — not what the model card claims. Only the largest rebuilt spoken web and email addresses correctly.")
                }

                if models.diskUsage() > 0 {
                    Section {
                        LabeledContent("Downloaded models",
                                       value: ByteCountFormatter.string(
                                        fromByteCount: models.diskUsage(), countStyle: .file))
                    }
                }

                if let error = models.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The polish catalogue's own row. Same mechanics as the speech rows, plus
    /// the one capability that actually splits the list — a model that cannot
    /// rebuild an address does not half-do it, it invents a plausible wrong
    /// answer, and that is worth saying on the row rather than in a footnote.
    @ViewBuilder
    private func polishRow(_ model: PolishModel) -> some View {
        let isInstalled = polish.installed.contains(model.id)
        let isSelected = polish.selectedID == model.id
        let progress = polish.downloading[model.id]

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName).font(.body)
                        if model.rebuildsAddresses {
                            Text("rebuilds addresses")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(model.sizeDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let progress {
                    ProgressView(value: progress.fraction).frame(width: 60)
                } else if isInstalled {
                    Button("Delete", role: .destructive) { polish.delete(model.id) }
                        .font(.caption)
                } else {
                    Button("Download") { polish.download(model) }
                        .font(.caption)
                }
            }
            Text(model.note).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if isInstalled { polish.select(model.id) } }
    }

    @ViewBuilder
    private func row(_ model: WhisperModel) -> some View {
        let isInstalled = models.installed.contains(model.id)
        let isSelected = models.selectedID == model.id
        let progress = models.downloading[model.id]

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName).font(.body)
                        if models.isBundled(model.id) {
                            Text("included")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(model.sizeDescription)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action(model, isInstalled: isInstalled, progress: progress)
            }

            Text(model.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress {
                ProgressView(value: progress.fraction)
                Text("\(ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if isInstalled { models.select(model.id) } }
        .swipeActions(edge: .trailing) {
            if isInstalled && !models.isBundled(model.id) {
                Button(role: .destructive) { models.delete(model.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func action(_ model: WhisperModel, isInstalled: Bool,
                        progress: ModelStore.Progress?) -> some View {
        if progress != nil {
            Button("Cancel") { models.cancelDownload(model.id) }
                .buttonStyle(.bordered).controlSize(.small)
        } else if !isInstalled {
            Button {
                models.download(model)
            } label: {
                Label("Get", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
