import SwiftUI
import OpenFlowKit

/// Download, choose and remove local speech models -- the macOS counterpart to
/// the iOS models screen, over the same `ModelStore`.
///
/// Until now the Mac app took whatever `build-macos.sh` had linked into
/// Application Support, which meant changing model was a shell task and the
/// running app could not tell you which one it was using.
struct ModelsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var models: ModelStore
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        self.models = model.models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Speech Model").font(.system(size: 15, weight: .semibold))
                Text("Models run entirely on this Mac. Larger ones are more accurate "
                     + "and slower; nothing is uploaded.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ModelCatalog.all) { m in
                        Row(models: models, model: m)
                        Divider().opacity(0.4)
                    }
                }
            }
            .frame(height: 340)

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
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 480)
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
