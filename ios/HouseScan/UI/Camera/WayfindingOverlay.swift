import simd
import SwiftUI

/// Where to stand and where to aim: a blue dotted path on the ground toward the next place to
/// stand, and a ring on the point to aim at (or an edge chevron when it is off screen).
struct WayfindingOverlay: View {
    var projection: CameraProjection
    var wall: WallGeometry?
    var path: [SIMD3<Float>]
    var target: SIMD3<Float>?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, size in
                    drawPath(in: &context, size: size)
                }
                if let target {
                    TargetMarker(placement: placement(for: target, in: size))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Path

    /// Dot spacing on the ground. A display choice: dense enough to read as a line at 3 m,
    /// sparse enough that each dot is distinct up close.
    private static let dotSpacing: Float = 0.22

    private func drawPath(in context: inout GraphicsContext, size: CGSize) {
        guard path.count >= 2 else { return }
        var samples: [SIMD3<Float>] = []
        var carry: Float = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let length = simd_distance(a, b)
            guard length > 0 else { continue }
            var d = carry
            while d < length {
                samples.append(a + (b - a) * (d / length))
                d += Self.dotSpacing
            }
            carry = d - length
        }
        samples.append(path[path.count - 1])

        for (index, sample) in samples.enumerated() {
            let local = projection.cameraSpace(sample)
            guard local.z < -0.15, let point = projection.viewPoint(for: sample, in: size) else { continue }
            let pointsPerMeter = CGFloat(projection.intrinsics.x) * projection.scale(in: size) / CGFloat(-local.z)
            // Dots are 7 cm across on the ground, so they shrink with distance like paint would.
            let radius = min(14, max(2.5, pointsPerMeter * 0.035))
            let fade = index == samples.count - 1 ? 1 : min(1, 0.55 + Double(index) / Double(max(samples.count, 1)))
            let rect = CGRect(x: point.x - radius, y: point.y - radius * 0.62, width: radius * 2, height: radius * 1.24)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -1.5)), with: .color(.white.opacity(0.7 * fade)))
            context.fill(Path(ellipseIn: rect), with: .color(Palette.signal.opacity(fade)))
        }
    }

    // MARK: Target

    private func placement(for target: SIMD3<Float>, in size: CGSize) -> TargetMarker.Placement {
        // The ring shows while its center is comfortably on screen; the chevron takes over
        // near the edges, where a half-visible ring would be ambiguous.
        let bounds = CGRect(x: 36, y: 150, width: size.width - 72, height: size.height - 330)
        if let point = projection.viewPoint(for: target, in: size), bounds.contains(point) {
            let scale = wall.flatMap { WallProjection(projection: projection, wall: $0, size: size).pointsPerMeter(at: target) }
            let radius = min(64, max(30, (scale ?? 90) * 0.28))
            return .onScreen(point, radius: radius)
        }
        guard let direction = projection.screenDirection(toward: target) else {
            return .hidden
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2
        let tx = direction.dx == 0 ? CGFloat.infinity : halfWidth / abs(direction.dx)
        let ty = direction.dy == 0 ? CGFloat.infinity : halfHeight / abs(direction.dy)
        let t = min(tx, ty)
        let edge = CGPoint(x: center.x + direction.dx * t, y: center.y + direction.dy * t)
        return .offScreen(edge, angle: .radians(atan2(direction.dy, direction.dx)))
    }
}

/// The aim ring, or a chevron at the screen edge pointing toward it.
private struct TargetMarker: View {
    enum Placement: Equatable {
        case onScreen(CGPoint, radius: CGFloat)
        case offScreen(CGPoint, angle: Angle)
        case hidden
    }

    var placement: Placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch placement {
        case .onScreen(let point, let radius):
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 7)
                Circle()
                    .strokeBorder(Palette.signal, lineWidth: 4)
                Circle()
                    .fill(Palette.signal)
                    .frame(width: 8, height: 8)
            }
            .frame(width: radius * 2, height: radius * 2)
            .phaseAnimator(reduceMotion ? [1.0] : [1.0, 1.08]) { ring, scale in
                ring.scaleEffect(scale)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
            .position(point)
            .transition(.opacity)
        case .offScreen(let point, let angle):
            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(.white)
                .rotationEffect(angle)
                .frame(width: 52, height: 52)
                .background(Palette.signal, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .position(point)
                .transition(.opacity)
        case .hidden:
            EmptyView()
        }
    }
}
