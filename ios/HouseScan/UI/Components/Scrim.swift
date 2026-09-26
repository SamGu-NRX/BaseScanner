import SwiftUI

/// The dark frosted surface every piece of chrome over the camera sits on.
///
/// A plain material thins out to near-white over a bright wall in sun, so an 86% Ink layer sits
/// on top of the blur: chalk text keeps well over 4.5:1 even over a white wall (the
/// accessibility audit failed at 66%). With Reduce Transparency
/// the blur drops and the Ink layer goes nearly opaque.
struct ScrimShape<S: InsettableShape>: View {
    var shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if !reduceTransparency {
                shape.fill(.ultraThinMaterial)
            }
            shape.fill(Palette.ink.opacity(reduceTransparency ? 0.94 : 0.86))
            shape.strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
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
