import SwiftUI
import OpenFlowKit

/// The one key on this keyboard that is not a `UIButton`, and the reason is the
/// whole of it: **a `Link` is the only thing left that can open the containing
/// app from a keyboard extension.**
///
/// Every other route is dead on iOS 18 and later. `extensionContext.open`
/// returns false. The responder-chain walk to the deprecated `openURL:`
/// selector finds a responder, calls it, and does nothing — UIKit logs "the
/// caller of UIApplication.openURL(_:) needs to migrate to the non-deprecated
/// UIApplication.open(_:options:completionHandler:)" — and walking the chain to
/// *that* selector instead fails as well, because `UIApplication` is explicitly
/// unavailable to app extensions and reaching it through the Objective-C
/// runtime is exactly what the restriction exists to prevent.
///
/// SwiftUI's `Link` does not go looking for `UIApplication`. It resolves
/// `OpenURLAction` from the environment, which the extension host provides, so
/// it is a sanctioned path rather than a hole. It also has to be a real `Link`:
/// a `Button` whose action calls `openURL` from the environment does not work
/// either, because the action is only honoured for the view that declares it.
struct OpenAppKey: View {
    var body: some View {
        Link(destination: OpenFlowIDs.dictateURL) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                Text("Open OpenFlow")
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel("Open OpenFlow")
    }
}
