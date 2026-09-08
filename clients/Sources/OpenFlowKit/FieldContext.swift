import Foundation

/// What kind of field has focus, at the only resolution we can read reliably
/// across every app. Deliberately coarse: Accessibility exposes a hundred
/// roles, and a taxonomy we cannot populate correctly is worse than four
/// buckets we can.
public enum FieldKind: String, Sendable, Codable, CaseIterable {
    case urlBar = "url"
    case search = "search"
    case singleLine = "line"
    case multiLine = "body"
    case unknown = "any"

    /// Kinds that earn a memory slot of their own, separate from the app's.
    ///
    /// An address bar is a genuinely different register from the page below it
    /// -- you type search terms into one and prose into the other. A subject
    /// line is not: it wants the same register as the mail body, so
    /// `singleLine` and `multiLine` share the app's slot rather than splitting
    /// it and making the user teach the same thing twice.
    public var isDistinct: Bool { self == .urlBar || self == .search }

    public var label: String {
        switch self {
        case .urlBar:     return "address bar"
        case .search:     return "search field"
        case .singleLine: return "text field"
        case .multiLine:  return "text area"
        case .unknown:    return ""
        }
    }
}

public extension FieldKind {
    /// Classify from whatever Accessibility gave us. Pure, so the interesting
    /// half of focus detection is testable without a running app.
    ///
    /// `hints` is every scrap of naming we could read -- identifier, title,
    /// description, placeholder -- concatenated and matched case-insensitively.
    static func classify(role: String?, subrole: String?, hints: [String?]) -> FieldKind {
        let hint = hints.compactMap { $0 }.joined(separator: " ").lowercased()
        let role = (role ?? "").lowercased()
        let subrole = (subrole ?? "").lowercased()

        // Address before search, and it is not a tie-break for tidiness:
        // Chrome calls its omnibox "Address and search bar" and Safari's
        // identifier is WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD, so both match
        // "search" too. The URL reading is the right one for both.
        if isAddressHint(hint) { return .urlBar }
        if subrole.contains("searchfield") || role.contains("searchfield")
            || hint.contains("search") { return .search }

        switch role {
        case "axtextarea":                 return .multiLine
        case "axtextfield", "axcombobox":  return .singleLine
        default:                           return .unknown
        }
    }

    private static func isAddressHint(_ hint: String) -> Bool {
        ["address", "url", "omnibox", "location bar"].contains { hint.contains($0) }
    }
}

/// Where an utterance is headed: the app, and the field inside it. This is the
/// key tone is remembered against.
public struct DictationContext: Sendable, Equatable {
    /// Lower-cased bundle id. Nil means we could not tell -- dictating to the
    /// clipboard, or Accessibility declined to answer.
    public let bundleID: String?
    /// For display only. Bundle ids are the identity; this is the name a human
    /// recognises in a list.
    public let appName: String?
    public let field: FieldKind

    public static let unknown = DictationContext(bundleID: nil)

    public init(bundleID: String?, appName: String? = nil, field: FieldKind = .unknown) {
        // Normalise once, here, so every key derived from this agrees. Bundle
        // ids are case-insensitive in practice and inconsistent in the wild
        // (com.apple.MobileSMS, com.tinyspeck.slackmacgap).
        let id = bundleID?.trimmingCharacters(in: .whitespaces).lowercased()
        self.bundleID = (id?.isEmpty ?? true) ? nil : id
        self.appName = appName
        self.field = field
    }

    /// The slot a tone chosen here is written to.
    public var key: String? {
        guard let bundleID else { return nil }
        return field.isDistinct ? "\(bundleID)#\(field.rawValue)" : bundleID
    }

    /// Slots to consult, most specific first. A tone remembered for the app
    /// answers for its address bar too, until the address bar is taught
    /// something of its own.
    public var lookupKeys: [String] {
        guard let bundleID, let key else { return [] }
        return key == bundleID ? [bundleID] : [key, bundleID]
    }

    /// "Safari address bar", "Mail", "anywhere else".
    public var label: String {
        guard let bundleID else { return "anywhere else" }
        let app = appName ?? bundleID
        return field.isDistinct ? "\(app) \(field.label)" : app
    }
}
