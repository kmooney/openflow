import Foundation

/// A language model that tidies a transcript before the deterministic
/// formatter runs.
///
/// Chosen by the user the same way the speech model is, and for the same
/// reason: the trade between size, speed and what it can actually do is one
/// only the person holding the phone can make.
public struct PolishModel: Identifiable, Hashable, Sendable, DownloadableModel {
    public let id: String
    public let filename: String
    public let displayName: String
    public let bytes: Int64
    public let note: String
    public let downloadURL: URL

    /// Whether this model was able to rebuild a spoken web or email address in
    /// testing. It is the one capability that splits the catalogue, and it does
    /// not improve gradually — below a certain size it does not half-work, it
    /// invents a plausible wrong answer.
    public let rebuildsAddresses: Bool

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The polish models on offer.
///
/// Every note here is what was measured on real transcripts from a phone —
/// three different renderings of the same spoken web address — not what a model
/// card claims. Sizes are the real `content-length` of each file.
///
/// The ordering is smallest first, and the honest headline is that the ability
/// to rebuild an address appears somewhere between 1.5B and 3B and nowhere
/// below it. Vocabulary context does not close the gap: a 1.5B model was handed
/// `kevin-mooney.com` in its prompt and still produced "Kevin Moore's".
public enum PolishCatalog {
    /// Formatting is optional in a way transcription is not, so there is no
    /// bundled model and "none" is a real, supported choice.
    public static let offID = ""

    public static let all: [PolishModel] = [
        PolishModel(
            id: "smollm2-360m",
            filename: "SmolLM2-360M-Instruct-Q4_K_M.gguf",
            displayName: "SmolLM2 360M",
            bytes: 270_590_880,
            note: "Too small for this job: it repeats the instructions back instead of following them, measured both on a phone and on a desktop. Listed because it downloads in seconds and proves the pipeline runs.",
            downloadURL: URL(string: "https://huggingface.co/bartowski/SmolLM2-360M-Instruct-GGUF/resolve/main/SmolLM2-360M-Instruct-Q4_K_M.gguf")!,
            rebuildsAddresses: false),
        PolishModel(
            id: "qwen3-0.6b",
            filename: "Qwen3-0.6B-Q8_0.gguf",
            displayName: "Qwen3 0.6B",
            bytes: 639_446_688,
            note: "Strips filler but leaves punctuation and capitalisation alone. Dropped the scheme from a web address, giving “kevin-mooney.com” for “https://kevin-mooney.com”.",
            downloadURL: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf")!,
            rebuildsAddresses: false),
        PolishModel(
            id: "llama3.2-1b",
            filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            displayName: "Llama 3.2 1B",
            bytes: 807_694_464,
            note: "Good at prose: turns a rambling sentence into a punctuated one and removes the “uh”s. Cannot rebuild addresses — it leaves spelled-out letters as they were.",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            rebuildsAddresses: false),
        PolishModel(
            id: "qwen2.5-1.5b",
            filename: "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
            displayName: "Qwen2.5 1.5B",
            bytes: 986_048_768,
            note: "Good prose, but it rewrote a web address into a different name that reads perfectly — the worst kind of wrong. Prefer 1B for prose, or 3B if addresses matter.",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf")!,
            rebuildsAddresses: false),
        PolishModel(
            id: "qwen2.5-3b",
            filename: "Qwen2.5-3B-Instruct-Q4_K_M.gguf",
            displayName: "Qwen2.5 3B",
            bytes: 1_929_903_264,
            note: "The smallest that rebuilt every spoken address correctly, including email. Costs roughly 2 GB of memory alongside the speech model — the most capable choice, and the one most likely to be evicted on a phone.",
            downloadURL: URL(string: "https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf")!,
            rebuildsAddresses: true),
    ]

    public static func model(id: String) -> PolishModel? {
        all.first { $0.id == id }
    }
}
