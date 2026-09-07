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

    public static func parse(_ text: String) -> [String] {
        let lines: [String] = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return Array(lines.prefix(maxTerms))
    }
}
