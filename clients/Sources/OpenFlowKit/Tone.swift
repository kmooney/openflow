import Foundation

/// Register for the finished text. A per-utterance choice, not a setting --
/// you dictate a work email and a text to your partner minutes apart.
public enum Tone: UInt32, CaseIterable, Sendable {
    case formal = 0
    case casual = 1
    case veryCasual = 2

    public var name: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }
}
