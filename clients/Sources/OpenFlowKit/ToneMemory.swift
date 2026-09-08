import Foundation

/// One learned tone: "Slack gets casual".
public struct ToneRule: Sendable, Codable, Equatable, Identifiable {
    public let key: String
    public var tone: Tone
    /// Snapshotted at write time so the list still reads like English after a
    /// restart, when the app it names may not be running.
    public var label: String
    public var updatedAt: Date

    public var id: String { key }
}

/// Where `ToneMemory` reads and writes. A protocol only so the tests can run
/// against something that is not the user's real defaults.
public protocol ToneMemoryStorage: AnyObject {
    func loadToneRules() -> Data?
    func saveToneRules(_ data: Data)
}

public final class UserDefaultsToneStorage: ToneMemoryStorage {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "toneMemory") {
        self.defaults = defaults
        self.key = key
    }

    public func loadToneRules() -> Data? { defaults.data(forKey: key) }
    public func saveToneRules(_ data: Data) { defaults.set(data, forKey: key) }
}

public final class InMemoryToneStorage: ToneMemoryStorage {
    private var data: Data?
    public init(seed: Data? = nil) { self.data = seed }
    public func loadToneRules() -> Data? { data }
    public func saveToneRules(_ data: Data) { self.data = data }
}

/// Remembers which register belongs to which app and field, and answers with
/// one for a context it has never seen.
///
/// The spec called tone a per-utterance choice, not a setting (§4.4), and that
/// is still true -- the picker overrides everything, every time. What this adds
/// is that the choice starts from the right place: you dictate a URL into an
/// address bar and it does not arrive with sentence case and a full stop.
///
/// Three layers, most specific first:
///   1. what the user taught, for this exact field, then for this app
///   2. what we suggest out of the box, so day one already behaves
///   3. the global picker, for everything else
public final class ToneMemory {
    public enum Source: Sendable, Equatable {
        /// The user chose this, for the named key.
        case remembered(String)
        /// A shipped default, not yet confirmed by the user.
        case suggested(String)
        /// Nothing matched; the global picker decides.
        case fallback
    }

    public struct Resolution: Sendable, Equatable {
        public let tone: Tone
        public let source: Source
        public var isRemembered: Bool {
            if case .remembered = source { return true }
            return false
        }
    }

    private let storage: ToneMemoryStorage
    private var rules: [String: ToneRule]

    /// The register for anywhere we have nothing to say about. Owned by the
    /// caller (it is the picker's sticky value) and set on us so `resolve`
    /// can always return an answer.
    public var fallback: Tone

    public init(storage: ToneMemoryStorage, fallback: Tone = .formal) {
        self.storage = storage
        self.fallback = fallback
        let decoded = storage.loadToneRules()
            .flatMap { try? JSONDecoder().decode([ToneRule].self, from: $0) } ?? []
        self.rules = Dictionary(decoded.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
    }

    // MARK: - reading

    public func resolve(_ context: DictationContext) -> Resolution {
        let keys = context.lookupKeys

        // Anything the user taught wins, and the app-wide lesson outranks our
        // suggestions -- someone who sets Safari to formal means it in the
        // address bar too.
        for key in keys where rules[key] != nil {
            return Resolution(tone: rules[key]!.tone, source: .remembered(key))
        }
        if let key = context.key, let tone = Self.suggestions[key] {
            return Resolution(tone: tone, source: .suggested(key))
        }
        // The rule that needs no table: you are typing a URL or a query, not
        // writing to anyone. Applies in every browser, including the one that
        // ships next year.
        if context.field.isDistinct, let key = context.key {
            return Resolution(tone: .veryCasual, source: .suggested(key))
        }
        if let key = keys.last, let tone = Self.suggestions[key] {
            return Resolution(tone: tone, source: .suggested(key))
        }
        return Resolution(tone: fallback, source: .fallback)
    }

    public func tone(for context: DictationContext) -> Tone { resolve(context).tone }

    /// Everything the user has taught. Sorted by name rather than by when it
    /// changed, so editing a rule in a list does not make it jump out from
    /// under the pointer.
    public var all: [ToneRule] {
        rules.values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    // MARK: - writing

    /// Teach this context a register. Returns false when there is no context to
    /// attach it to -- the caller should treat that as a change to `fallback`.
    @discardableResult
    public func remember(_ tone: Tone, for context: DictationContext) -> Bool {
        guard let key = context.key else { return false }
        rules[key] = ToneRule(key: key, tone: tone, label: context.label, updatedAt: Date())
        persist()
        return true
    }

    /// Change an existing rule in place, keeping the name it was written with.
    /// For editing the list; teaching a new one goes through `remember`.
    public func setTone(_ tone: Tone, forKey key: String) {
        guard var rule = rules[key] else { return }
        rule.tone = tone
        rule.updatedAt = Date()
        rules[key] = rule
        persist()
    }

    public func forget(_ key: String) {
        guard rules.removeValue(forKey: key) != nil else { return }
        persist()
    }

    public func forget(_ context: DictationContext) {
        if let key = context.key { forget(key) }
    }

    public func forgetAll() {
        guard !rules.isEmpty else { return }
        rules.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        storage.saveToneRules(data)
    }

    // MARK: - shipped suggestions

    /// Starting points, not decisions. The first time the user picks anything
    /// for one of these it becomes a rule and this table stops applying to it,
    /// so being wrong here costs exactly one correction.
    ///
    /// Keys are lower-cased bundle ids, matching `DictationContext.key`.
    public static let suggestions: [String: Tone] = [
        // Correspondence that leaves the building.
        "com.apple.mail":                    .formal,
        "com.microsoft.outlook":             .formal,
        "com.readdle.smartemail-mac":        .formal,
        "com.superhuman.electron":           .formal,
        "com.apple.iwork.pages":             .formal,
        "com.microsoft.word":                .formal,
        "com.apple.iwork.keynote":           .formal,

        // Messaging: capitals kept, line breaks instead of full stops.
        "com.apple.mobilesms":               .casual,
        "com.tinyspeck.slackmacgap":         .casual,
        "com.hnc.discord":                   .casual,
        "net.whatsapp.whatsapp":             .casual,
        "org.whispersystems.signal-desktop": .casual,
        "ru.keepcoder.telegram":             .casual,
        "com.apple.notes":                   .casual,
        "md.obsidian":                       .casual,
        "net.shinyfrog.bear":                .casual,
        "notion.id":                         .casual,

        // Nothing you type here is prose.
        "com.apple.terminal":                .veryCasual,
        "com.googlecode.iterm2":             .veryCasual,
        "dev.warp.warp-stable":              .veryCasual,
        "com.github.wez.wezterm":            .veryCasual,
    ]
}
