import SwiftUI

/// The OpenFlow mark — a ring with a waveform inside it — as a view.
///
/// Deliberately built from shapes rather than shipped as an image. The mark
/// appears on the Dynamic Island and the lock screen, where the background is
/// black, the foreground colour changes with state, and the whole thing may be
/// 16 points across. A PNG of a dark mark on an off-white ground is wrong in
/// every one of those places; shapes inherit `foregroundStyle`, so the same
/// view is correct in red while recording and secondary while idle.
///
/// The proportions match `tools/icon.swift`, rescaled so the ring fills the
/// frame rather than sitting at 71% of a square canvas the way an app icon
/// must. If one changes, change the other: they are the same mark.
///
/// **Give it a frame.** It fills what it is offered, because a `GeometryReader`
/// is greedy and a `.font()` modifier cannot size a shape — an unframed mark in
/// the Dynamic Island expands until it wrecks the layout around it.
public struct OpenFlowMark: View {
    /// Half-heights become full heights here, since SwiftUI sizes a capsule by
    /// its total length rather than from a centre line.
    private static let heights: [CGFloat] = [0.239, 0.422, 0.605, 0.422, 0.239]

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .strokeBorder(lineWidth: s * 0.082)
                HStack(spacing: s * 0.0535) {
                    ForEach(Array(Self.heights.enumerated()), id: \.offset) { _, h in
                        Capsule().frame(width: s * 0.0775, height: s * h)
                    }
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("OpenFlow")
    }
}
