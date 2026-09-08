import Foundation

/// Identifiers shared by the app and its keyboard extension. They must agree
/// exactly or the handoff container silently resolves to nil.
public enum OpenFlowIDs {
    public static let appGroup = "group.dev.openflow"
    public static let urlScheme = "openflow"
    /// The app opens here to start dictating immediately.
    public static let dictateURL = URL(string: "openflow://dictate")!
}
