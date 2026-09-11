import Foundation

/// Anything `ModelStore` can fetch and keep on disk.
///
/// Extracted so the same download, selection and deletion machinery serves the
/// speech model and the polish model. They are the same problem -- a large file
/// the user chooses, waits for, and may delete -- and were never going to stay
/// one catalogue.
public protocol DownloadableModel: Identifiable, Sendable {
    var id: String { get }
    var filename: String { get }
    var displayName: String { get }
    /// Approximate download size, for the UI to show before committing.
    var bytes: Int64 { get }
    /// Honest one-liner about the trade, not marketing.
    var note: String { get }
    var downloadURL: URL { get }
}

/// A Whisper model the user can run.
public struct WhisperModel: Identifiable, Hashable, Sendable, DownloadableModel {
    public let id: String
    public let filename: String
    public let displayName: String
    /// Approximate download size, for the UI to show before committing.
    public let bytes: Int64
    /// Honest one-liner about the trade, not marketing.
    public let note: String

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The models on offer, with what M0 actually measured rather than what the
/// model cards claim. Ordered fastest to most accurate.
public enum ModelCatalog {
    public static let bundledID = "base.en"

    public static let all: [WhisperModel] = [
        WhisperModel(
            id: "tiny.en", filename: "ggml-tiny.en.bin",
            displayName: "Tiny (English)", bytes: 77_700_000,
            note: "Fastest and least accurate. Useful on older devices; expect mistakes on names."),
        WhisperModel(
            id: "base.en", filename: "ggml-base.en.bin",
            displayName: "Base (English)", bytes: 147_950_000,
            note: "Bundled default. Fast, but substitutes words rather than admitting uncertainty — it can turn “uh” into “that”."),
        WhisperModel(
            id: "small.en", filename: "ggml-small.en.bin",
            displayName: "Small (English)", bytes: 487_600_000,
            note: "Clearly more accurate, about 2.4× slower than Base. The desktop default, and the best choice if names matter."),
        WhisperModel(
            id: "large-v3-turbo-q5_0", filename: "ggml-large-v3-turbo-q5_0.bin",
            displayName: "Large v3 Turbo (quantised)", bytes: 574_000_000,
            note: "Most accurate, and the slowest for dictation: it keeps the full large encoder, so short utterances cost over a second before it transcribes anything."),
    ]

    public static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
