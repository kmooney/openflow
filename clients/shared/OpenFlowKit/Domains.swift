import Foundation

/// Turning browsing history into vocabulary terms.
///
/// Pure, and separate from anything that reads a browser's database, because
/// this is the half worth testing and the other half is file paths.
public enum Domains {
    /// The term for one URL, or nil if it is not worth spending prompt budget
    /// on. "https://www.doordash.com/store/1" -> "doordash.com".
    ///
    /// `www.` is stripped because whisper transcribes the spoken "www" part
    /// perfectly well on its own -- the word it cannot guess is the name.
    /// Subdomains are kept: "news.ycombinator.com" is what you would say.
    public static func term(from url: String) -> String? {
        guard let comps = URLComponents(string: url),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = comps.host?.lowercased(), !host.isEmpty
        else { return nil }

        if host.hasPrefix("www.") { host.removeFirst(4) }

        // A bare label is not a domain, and an address is not pronounceable.
        guard host.contains("."), !host.contains(":"), host != "localhost",
              !isIPv4(host)
        else { return nil }
        // Trailing dot is legal in DNS and noise here.
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// Collapse visits to one weighted entry per domain, most-visited first.
    ///
    /// Ties break alphabetically rather than by dictionary order, so seeding
    /// twice from an unchanged history produces an unchanged file.
    public static func rank(_ visits: [(url: String, count: Int)]) -> [(domain: String, count: Int)] {
        var totals: [String: Int] = [:]
        for visit in visits {
            guard let term = term(from: visit.url) else { continue }
            totals[term, default: 0] += max(visit.count, 1)
        }
        return totals
            .map { (domain: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.domain < $1.domain : $0.count > $1.count }
    }
}

public extension Vocabulary {
    /// Rough token cost of a prompt built from these terms.
    ///
    /// whisper's initial prompt is capped near 224 tokens and silently
    /// truncated past it, so a seeded list needs a number the UI can show
    /// before it writes anything. Deliberately an over-estimate: ~3.2
    /// characters per token rather than the usual 4, because domain names
    /// fragment badly ("doordash.com" is not one token).
    static func estimatedPromptTokens(_ terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let frame = 12                             // "The following names…"
        let body = terms.reduce(0) { $0 + $1.count + 2 }   // term + ", "
        return frame + Int((Double(body) / 3.2).rounded(.up))
    }

    /// What whisper will actually accept.
    static let promptTokenBudget = 224
}
