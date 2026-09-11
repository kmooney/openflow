import SwiftUI
import OpenFlowKit

/// Both model pickers, over one row implementation.
///
/// The polish section had its own copy of the row for a while and it drifted
/// immediately — a different button, a different label, a different tap target.
/// There was never a reason for them to differ: downloading, selecting and
/// deleting a large file is the same job whichever catalogue it came from, and
/// a second copy is only a second place for a bug to hide.
struct ModelsView: View {
    @ObservedObject var models: ModelStore
    @ObservedObject var polish: ModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelCatalog.all) { model in
                        row(model, in: models)
                    }
                } header: {
                    Text("Speech")
                } footer: {
                    Text("Models run entirely on this device. Larger ones are more accurate and slower; nothing is sent anywhere.")
                }

                Section {
                    offRow
                    ForEach(PolishCatalog.all) { model in
                        row(model, in: polish,
                            badge: model.rebuildsAddresses ? "rebuilds addresses" : nil)
                    }
                } header: {
                    Text("Polish")
                } footer: {
                    Text("A language model that tidies the transcript before formatting. Every note is what was measured on real dictation — not what the model card claims. Only the largest rebuilt spoken web and email addresses correctly.")
                }

                let used = models.diskUsage() + polish.diskUsage()
                if used > 0 {
                    Section {
                        LabeledContent("Downloaded models",
                                       value: ByteCountFormatter.string(
                                        fromByteCount: used, countStyle: .file))
                    }
                }

                // Both stores. Only the speech store's errors were shown, so a
                // failed polish download reported nothing at all — which looks
                // exactly like a button that does not work.
                ForEach([models.lastError, polish.lastError].compactMap { $0 }, id: \.self) { error in
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

    /// "None" is a real choice, not an absence: without a model the
    /// deterministic rules still run and still produce text.
    private var offRow: some View {
        let isSelected = polish.selectedID == PolishCatalog.offID
        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("None").font(.body)
                Text("Rules only. Fast, predictable, and cannot invent a word you did not say.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { polish.selectNone() }
    }

    @ViewBuilder
    private func row(_ model: any DownloadableModel, in store: ModelStore,
                     badge: String? = nil) -> some View {
        let isInstalled = store.installed.contains(model.id)
        let isSelected = store.selectedID == model.id
        let progress = store.downloading[model.id]
        let label = store.isBundled(model.id) ? "included" : badge

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName).font(.body)
                        if let label {
                            Text(label)
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action(model, in: store, isInstalled: isInstalled, progress: progress)
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
        .onTapGesture { if isInstalled { store.select(model.id) } }
        .swipeActions(edge: .trailing) {
            if isInstalled && !store.isBundled(model.id) {
                Button(role: .destructive) { store.delete(model.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func action(_ model: any DownloadableModel, in store: ModelStore,
                        isInstalled: Bool, progress: ModelStore.Progress?) -> some View {
        if progress != nil {
            Button("Cancel") { store.cancelDownload(model.id) }
                .buttonStyle(.bordered).controlSize(.small)
        } else if !isInstalled {
            Button {
                store.download(model)
            } label: {
                Label("Get", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
