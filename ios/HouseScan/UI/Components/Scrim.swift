import SwiftUI

/// The surface every piece of chrome over the camera sits on: solid Ink with a faint edge.
///
/// Solid on purpose. Over a sunlit wall any translucency lets the photo wash out the chrome, and
/// XCUIApplication's accessibility audit flagged chalk text on camera screens even with 94% Ink
/// over the photo; with 100% it passes on every screen. Camera apps keep their controls on solid
/// bars for the same reason.
struct ScrimShape<S: InsettableShape>: View {
    var shape: S

    var body: some View {
        shape
            .fill(Palette.ink)
            .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

extension ScrimShape where S == Capsule {
    static var capsule: ScrimShape<Capsule> { ScrimShape(shape: Capsule()) }
}

extension ScrimShape where S == RoundedRectangle {
    static func rounded(_ radius: CGFloat = Metrics.cardRadius) -> ScrimShape<RoundedRectangle> {
        ScrimShape(shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Soft dark gradients at the top and bottom of camera screens, under the chrome, so the
/// status bar and the edges of cards keep contrast without boxing the camera in.
struct CameraEdgeShade: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
