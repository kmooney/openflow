import Foundation

/// The user's word list -- names, places, jargon whisper won't know. The
/// highest-leverage quality control they have (spec §5.2).
public enum Vocabulary {
    /// whisper's prompt caps around 224 tokens, so a long list has to be
    /// trimmed rather than dumped. Most-recently-added first.
    public static let maxTerms = 120

    public static func load(from url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// The terms that apply everywhere. A file with no sections is entirely
    /// this, which is what every existing vocab.txt is.
    public static func parse(_ text: String) -> [String] {
        VocabularyBook.parse(text).global
    }
}

/// A vocabulary split by where it applies.
///
/// The prompt is rebuilt and resent on every transcription -- `whisper_full`
/// is one-shot and keeps no state between calls -- so varying the list by app
/// costs nothing beyond the tokens themselves. That is what makes per-app
/// biasing worth doing: in a terminal "git status" should beat "get status",
/// and in a mail client it should not.
///
/// One file, with sections, rather than a file per app: the vocabulary is
/// something the user edits by hand, and scattering it across a directory
/// would make "what have I taught it?" unanswerable at a glance.
///
/// ```
/// Anthropic                 # before any section: applies everywhere
/// Siobhan
///
/// [com.apple.Terminal]      # only when Terminal has focus
/// git status
/// kubectl
/// ```
public struct VocabularyBook: Sendable, Equatable {
    /// Applies wherever you dictate.
    public let global: [String]
    /// Keyed by lower-cased bundle id, matching `DictationContext.bundleID`.
    public let perApp: [String: [String]]

    public static let empty = VocabularyBook(global: [], perApp: [:])

    public init(global: [String], perApp: [String: [String]]) {
        self.global = global
        self.perApp = perApp
    }

    public static func load(from url: URL) -> VocabularyBook {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return parse(text)
    }

    public static func parse(_ text: String) -> VocabularyBook {
        var global: [String] = []
        var perApp: [String: [String]] = [:]
        var section: String?

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let id = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                // "[]" is a typo, not a section. Treat the rest of the file as
                // global rather than silently dropping every term after it.
                section = id.isEmpty ? nil : id.lowercased()
                continue
            }

            if let section {
                perApp[section, default: []].append(line)
            } else {
                global.append(line)
            }
        }

        return VocabularyBook(
            global: Array(global.prefix(Vocabulary.maxTerms)),
            perApp: perApp.mapValues { Array($0.prefix(Vocabulary.maxTerms)) })
    }

    /// The prompt terms for one destination.
    ///
    /// App terms come first because the list is truncated from the tail: when
    /// the two together exceed the token budget, the words chosen *for this
    /// app* are the ones that must survive.
    public func terms(for context: DictationContext) -> [String] {
        terms(forApp: context.bundleID)
    }

    public func terms(forApp bundleID: String?) -> [String] {
        let specific = bundleID.flatMap { perApp[$0.lowercased()] } ?? []
        var seen = Set<String>()
        var out: [String] = []
        for term in specific + global {
            // Case-insensitive: "Kubectl" and "kubectl" are one term, and
            // spending the budget twice on it helps nothing.
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
        }
        return Array(out.prefix(Vocabulary.maxTerms))
    }

    /// Apps this book says anything about, for the UI.
    public var apps: [String] { perApp.keys.sorted() }
}
