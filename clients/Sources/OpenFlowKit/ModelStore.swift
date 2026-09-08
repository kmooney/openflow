import Foundation
import Combine

/// Tracks which models are present, downloads new ones, and remembers the
/// choice. Shared by both clients: nothing here is platform-specific.
@MainActor
public final class ModelStore: ObservableObject {
    public struct Progress: Equatable, Sendable {
        public let fraction: Double
        public let received: Int64
        public let total: Int64
    }

    @Published public private(set) var installed: Set<String> = []
    @Published public private(set) var downloading: [String: Progress] = [:]
    @Published public private(set) var lastError: String?
    @Published public private(set) var selectedID: String

    private let directory: URL
    private let bundle: Bundle
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var delegates: [String: DownloadDelegate] = [:]

    /// Called when the active model changes, so the engine can reload.
    public var onSelectionChanged: ((URL) -> Void)?

    public init(directory: URL, bundle: Bundle = .main) {
        self.directory = directory
        self.bundle = bundle
        self.selectedID = UserDefaults.standard.string(forKey: "selectedModel")
            ?? ModelCatalog.bundledID
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        refresh()
        // A model can be deleted out from under the selection; never leave the
        // app pointing at something that is not there.
        if location(of: selectedID) == nil, let fallback = installed.first {
            selectedID = fallback
        }
    }

    public func refresh() {
        var present = Set<String>()
        for model in ModelCatalog.all where location(of: model.id) != nil {
            present.insert(model.id)
        }
        installed = present
    }

    /// Where a model lives: bundled inside the app, or downloaded.
    public func location(of id: String) -> URL? {
        guard let model = ModelCatalog.model(id: id) else { return nil }
        let name = (model.filename as NSString).deletingPathExtension
        if let bundled = bundle.url(forResource: name, withExtension: "bin") {
            return bundled
        }
        let downloaded = directory.appendingPathComponent(model.filename)
        return FileManager.default.fileExists(atPath: downloaded.path) ? downloaded : nil
    }

    public func isBundled(_ id: String) -> Bool {
        guard let model = ModelCatalog.model(id: id) else { return false }
        let name = (model.filename as NSString).deletingPathExtension
        return bundle.url(forResource: name, withExtension: "bin") != nil
    }

    public var activeURL: URL? { location(of: selectedID) }

    public func select(_ id: String) {
        guard let url = location(of: id) else { return }
        selectedID = id
        UserDefaults.standard.set(id, forKey: "selectedModel")
        onSelectionChanged?(url)
    }

    // MARK: - download

    public func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil, location(of: model.id) == nil else { return }
        lastError = nil
        let destination = directory.appendingPathComponent(model.filename)

        let delegate = DownloadDelegate(
            onProgress: { [weak self] received, total in
                Task { @MainActor in
                    guard let self else { return }
                    // The server may not send a length; fall back to the
                    // catalog's size so the bar still moves.
                    let expected = total > 0 ? total : model.bytes
                    self.downloading[model.id] = Progress(
                        fraction: min(1, Double(received) / Double(max(expected, 1))),
                        received: received, total: expected)
                }
            },
            onFinished: { [weak self] tempURL, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.tasks[model.id] = nil
                    self.delegates[model.id] = nil
                    self.downloading[model.id] = nil
                    if let error {
                        self.lastError = error.localizedDescription
                        return
                    }
                    guard let tempURL else { return }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        // A truncated file loads as a corrupt model and fails
                        // in a way that looks like a bug in the app.
                        let attrs = try? FileManager.default
                            .attributesOfItem(atPath: destination.path)
                        let size = (attrs?[.size] as? Int64) ?? 0
                        guard size > model.bytes / 2 else {
                            try? FileManager.default.removeItem(at: destination)
                            self.lastError = "Download was incomplete. Try again."
                            return
                        }
                        self.refresh()
                        self.select(model.id)
                    } catch {
                        self.lastError = error.localizedDescription
                    }
                }
            })

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: model.downloadURL)
        tasks[model.id] = task
        delegates[model.id] = delegate
        downloading[model.id] = Progress(fraction: 0, received: 0, total: model.bytes)
        task.resume()
    }

    public func cancelDownload(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        delegates[id] = nil
        downloading[id] = nil
    }

    /// Remove a downloaded model. Bundled ones cannot be removed.
    public func delete(_ id: String) {
        guard !isBundled(id), let model = ModelCatalog.model(id: id) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(model.filename))
        refresh()
        guard selectedID == id else { return }
        // Fall back deliberately rather than via `select`, which refuses a
        // model that is not present -- that guard made the fallback a no-op and
        // left the selection pointing at the file just deleted.
        if let next = installed.contains(ModelCatalog.bundledID)
            ? ModelCatalog.bundledID : installed.sorted().first {
            select(next)
        } else {
            selectedID = ""          // nothing usable; activeURL is nil
            UserDefaults.standard.removeObject(forKey: "selectedModel")
        }
    }

    public func diskUsage() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Int64, Int64) -> Void
    private let onFinished: (URL?, Error?) -> Void
    /// The system deletes the temp file when the delegate call returns, so it
    /// must be moved somewhere durable synchronously, before hopping queues.
    private var staged: URL?

    init(onProgress: @escaping (Int64, Int64) -> Void,
         onFinished: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onFinished = onFinished
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("of-model-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: staging)
        staged = staging
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            onFinished(nil, error)
        } else {
            onFinished(staged, nil)
        }
        s.invalidateAndCancel()
    }
}
