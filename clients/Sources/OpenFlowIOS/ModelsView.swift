import SwiftUI
import OpenFlowKit

struct ModelsView: View {
    @ObservedObject var models: ModelStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ModelCatalog.all) { model in
                        row(model)
                    }
                } footer: {
                    Text("Models run entirely on this device. Larger ones are more accurate and slower; nothing is sent anywhere.")
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
            .navigationTitle("Speech Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
