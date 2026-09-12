import Foundation
import Combine

/// A plain text file the user owns, loaded into memory and written back.
///
/// Both word lists are files rather than database rows on purpose: they are
/// something a person edits, copies between machines, and keeps in a dotfile
/// repo. macOS opens them in a text editor; iOS has no editor to open, so it
/// edits the same bytes in a text view.
@MainActor
public final class WordListStore: ObservableObject {
    /// Written back on every change, debounced — a text view emits a change per
    /// keystroke, and a word list is small enough that the debounce is about
    /// the flash wear, not the time.
    @Published public var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleSave()
        }
    }

    public let url: URL
    private var saveWork: DispatchWorkItem?

    public init(url: URL, seed: String = "") {
        self.url = url
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            text = existing
        } else if !seed.isEmpty {
            text = seed
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func reload() {
        text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Also called when the app leaves the foreground: a debounce that has not
    /// fired yet is a file that has not been written.
    public func save() {
        saveWork?.cancel()
        saveWork = nil
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Vocabulary terms in this file, for the count in the UI.
    public var terms: [String] { Vocabulary.parse(text) }

    /// Dictionary entries in this file, for the list in the UI.
    ///
    /// Display only. The expansion that actually happens is Rust's — see
    /// `openflow_core::dictionary` — and this must never become a second
    /// implementation of it. It is here because showing the user what the app
    /// thinks it parsed is how a typo in their file becomes visible.
    public var shortcuts: [(phrase: String, replacement: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { return nil }
            let phrase = line[..<eq].trimmingCharacters(in: .whitespaces)
            let replacement = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
            guard !phrase.isEmpty, !replacement.isEmpty else { return nil }
            return (phrase, replacement)
        }
    }
}

/// What a new dictionary file says, so the format is obvious without
/// documentation. Comments only: an example that expanded real text would put
/// words into someone's message that they never typed.
public let dictionarySeed = """
# Your dictionary: say the phrase on the left, get the text on the right.
# One entry per line. The replacement is used exactly as written.
#
#   my email = you@example.com
#   my number = (555) 123-4567
#   my sign off = Best,\\nKevin
#
# \\n makes a line break. Lines starting with # are ignored.

"""

/// What a new vocabulary file says.
public let vocabularySeed = """
# Words to expect: names, places, jargon, product spellings.
# One per line. These are given to the speech model before it listens,
# so they change what it hears — not what it writes afterwards.
#
#   Siobhan
#   Anthropic
#   kubectl

"""
