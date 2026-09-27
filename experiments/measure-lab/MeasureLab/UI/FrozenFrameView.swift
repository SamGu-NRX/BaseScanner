import SwiftUI

/// A held frame drawn exactly as `PortraitFillMapping` assumes: rotated upright, scaled to fill
/// and centered. For the second view of a two-view pair it also draws the first tap's ray; the
/// same feature lies somewhere along that line.
struct FrozenFrameView: View {
    let frozen: CaptureController.FrozenFrame
    let size: CGSize
    let guide: [CGPoint]?

    var body: some View {
        Image(uiImage: frozen.image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay {
                if let guide {
                    Path { path in path.addLines(guide) }
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                }
            }
            .accessibilityLabel("Frozen camera frame \(frozen.snapshot.keyframeID)")
    }
}
