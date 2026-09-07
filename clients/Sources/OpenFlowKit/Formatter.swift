import Foundation
import COpenFlow

/// One word the formatter changed, and why. Mirrors the Rust ledger.
public struct LedgerEntry: Sendable, Codable {
    public let from: String
    public let to: String
    public let why: String

    /// Human-readable for the history UI.
    public var description: String {
        to.isEmpty ? "removed “\(from)” (\(why))" : "“\(from)” → “\(to)” (\(why))"
    }
}

public extension LedgerEntry {
    /// Decode the JSON blob the store keeps per utterance.
    static func decode(_ json: String) -> [LedgerEntry] {
        guard let d = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LedgerEntry].self, from: d)) ?? []
    }
}

public struct FormatResult: Sendable, Codable {
    public let ok: Bool
    public let formatted: String
    public let raw: String
    public let note: String
    /// Words the user actually said, before any cleanup. This is the number
    /// worth reporting back to them.
    public let spokenWords: Int
    public let writtenWords: Int
    public let ledger: [LedgerEntry]
}

/// Thin wrapper over the Rust core. All the logic that has to be *correct*
/// lives on the other side of this call and is shared with every client.
public enum Formatter {
    public static func format(_ raw: String, tone: Tone) -> FormatResult {
        let json: String = raw.withCString { ptr in
            guard let out = of_format(ptr, tone.rawValue) else { return "" }
            defer { of_string_free(out) }
            return String(cString: out)
        }
        if let data = json.data(using: .utf8),
           let r = try? JSONDecoder().decode(FormatResult.self, from: data) {
            return r
        }
        // Never lose the user's words to a formatting failure.
        return FormatResult(ok: false, formatted: raw, raw: raw, note: "decode failed",
                            spokenWords: raw.split(separator: " ").count,
                            writtenWords: raw.split(separator: " ").count, ledger: [])
    }

    public static var coreVersion: String {
        guard let v = of_version() else { return "?" }
        return String(cString: v)
    }
}
