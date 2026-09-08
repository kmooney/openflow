import Foundation

/// Editing vocab.txt without destroying what the user wrote in it.
///
/// The file is theirs -- hand-written terms, comments, ordering that may mean
/// something to them. Seeding writes into one section and must leave every
/// other byte alone, so this is a text edit rather than a parse-and-rewrite.
public enum VocabularyFile {
    /// Replace the term lines of `[app]` with `terms`, preserving comments
    /// inside that section and everything outside it.
    ///
    /// Appends the section if absent. Removes it if `terms` is empty, so
    /// clearing a seeded list does not leave a dangling header that silently
    /// captures whatever the user types after it.
    public static func replacingSection(in text: String, app: String,
                                        terms: [String]) -> String {
        let wanted = app.lowercased()
        var out: [String] = []
        var lines = text.components(separatedBy: "\n")
        var inSection = false
        var wrote = false
        // A trailing newline shows up as a final empty component; hold it back
        // so appending does not drift the file down by a line each time.
        let hadTrailingNewline = lines.last?.isEmpty ?? false
        if hadTrailingNewline { lines.removeLast() }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeader = trimmed.hasPrefix("[") && trimmed.hasSuffix("]")

            if isHeader {
                let id = trimmed.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespaces).lowercased()
                if inSection { inSection = false }      // leaving ours
                if id == wanted {
                    inSection = true
                    wrote = true
                    if terms.isEmpty { continue }       // drop the header too
                    out.append(line)                    // keep it as written
                    continue
                }
                out.append(line)
                continue
            }

            guard inSection else { out.append(line); continue }

            // Inside our section: comments and blank lines are the user's,
            // term lines are ours to replace.
            if terms.isEmpty {
                if trimmed.hasPrefix("#") { out.append(line) }
                continue
            }
            if trimmed.hasPrefix("#") || trimmed.isEmpty { out.append(line) }
        }

        if wrote, !terms.isEmpty {
            // Re-emit the terms directly after the header (and any comments
            // that followed it), which is where they were.
            out = reinsert(terms, into: out, app: wanted)
        } else if !wrote, !terms.isEmpty {
            if let last = out.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("")
            }
            out.append("[\(app)]")
            out.append(contentsOf: terms)
        }

        var result = out.joined(separator: "\n")
        if hadTrailingNewline || !result.isEmpty { result += "\n" }
        return result
    }

    private static func reinsert(_ terms: [String], into lines: [String],
                                 app: String) -> [String] {
        var out = lines
        guard let header = out.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), t.hasSuffix("]") else { return false }
            return t.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                .lowercased() == app
        }) else { return out }

        // Past the header, skip the comment block that belongs to it.
        var at = header + 1
        while at < out.count {
            let t = out[at].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { at += 1; continue }
            break
        }
        out.insert(contentsOf: terms, at: at)
        return out
    }

    /// Terms already written under `[app]`, in file order. Used to keep a
    /// user's hand-added entries ahead of anything seeded.
    public static func section(_ text: String, app: String) -> [String] {
        VocabularyBook.parse(text).perApp[app.lowercased()] ?? []
    }
}
