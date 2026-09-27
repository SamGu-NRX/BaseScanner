import simd
import SwiftUI

/// Where to stand and where to aim: a blue dotted path on the ground toward the next place to
/// stand, and a ring on the point to aim at (or an edge arrow when it is off screen).
struct WayfindingOverlay: View {
    var projection: CameraProjection
    var wall: WallGeometry?
    var path: [SIMD3<Float>]
    var target: SIMD3<Float>?
    /// How far the aim task is toward done, 0...1 (`ScanViewState.aimProgress`): the ring fills
    /// with it. Nil when the target only marks a place.
    var progress: Double? = nil
    /// One line saying what the ring is for, drawn beside it while it is on screen.
    var legend: String? = nil
    /// Called when the legend is drawn.
    var onLegendShown: (() -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, size in
                    drawPath(in: &context, size: size)
                }
                .accessibilityHidden(true)
                if let target {
                    let marker = placement(for: target, in: size)
                    TargetMarker(placement: marker, progress: progress)
                    if let legend, case .onScreen(let point, let radius) = marker {
                        legendView(legend, beside: point, radius: radius, in: size)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Legend

    /// The legend goes above or below the ring, whichever has more room between the instruction
    /// card and the controls (the band the off-screen arrows keep to), and moves with the ring
    /// without covering it.
    private func legendView(_ text: String, beside point: CGPoint, radius: CGFloat, in size: CGSize) -> some View {
        let width = max(120, min(300, size.width - 48))
        let x = min(max(point.x, 24 + width / 2), size.width - 24 - width / 2)
        let roomAbove = point.y - radius - 260
        let roomBelow = size.height - 300 - (point.y + radius)
        let below = roomBelow >= roomAbove
        // A tall frame pinned at the edge nearer the ring, so the text's height (it wraps, and
        // grows with Dynamic Type) never moves its near edge onto the ring.
        let reach: CGFloat = 400
        return Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("aim.legend")
            .onAppear { onLegendShown?() }
            .frame(width: width, height: reach, alignment: below ? .top : .bottom)
            .position(x: x, y: below ? point.y + radius + 12 + reach / 2 : point.y - radius - 12 - reach / 2)
            .transition(.opacity)
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
        // Chevrons stay clear of the instruction card above and the buttons and map below,
        // which are drawn over this layer.
        let lane = CGRect(x: 40, y: 260, width: size.width - 80, height: max(size.height - 260 - 300, 80))
        let center = CGPoint(x: lane.midX, y: lane.midY)
        let halfWidth = lane.width / 2
        let halfHeight = lane.height / 2
        let tx = direction.dx == 0 ? CGFloat.infinity : halfWidth / abs(direction.dx)
        let ty = direction.dy == 0 ? CGFloat.infinity : halfHeight / abs(direction.dy)
        let t = min(tx, ty)
        let edge = CGPoint(x: center.x + direction.dx * t, y: center.y + direction.dy * t)
        return .offScreen(edge, angle: .radians(atan2(direction.dy, direction.dx)))
    }
}

/// The aim ring, or an arrow at the screen edge pointing toward it. Also the arrow toward the
/// battery spot on "See it on your wall" (`ResultARScreen`).
struct TargetMarker: View {
    enum Placement: Equatable {
        case onScreen(CGPoint, radius: CGFloat)
        case offScreen(CGPoint, angle: Angle)
        case hidden
    }

    var placement: Placement
    /// 0...1 toward the aim task being done. The ring fills with it, then turns green with a tick
    /// at 1, like the meter photo's ring; nil draws the plain pulsing ring. A ring that never
    /// changed while it was held on target gave no sign of what it wanted (#81).
    var progress: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch placement {
        case .onScreen(let point, let radius):
            Group {
                if let progress {
                    progressRing(min(max(progress, 0), 1), radius: radius)
                } else {
                    plainRing(radius: radius)
                }
            }
            .position(point)
            .transition(.opacity)
        case .offScreen(let point, let angle):
            // An arrow with a shaft: a bare chevron in a blue disc, turned to point down, can
            // read as a tick (#81).
            Image(systemName: "arrow.right")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .rotationEffect(angle)
                .frame(width: 52, height: 52)
                .background(Palette.signal, in: .circle)
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .position(point)
                .transition(.opacity)
                .accessibilityHidden(true)
        case .hidden:
            EmptyView()
        }
    }

    private func plainRing(radius: CGFloat) -> some View {
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
        .accessibilityHidden(true)
    }

    /// No pulse: the fill is what moves. VoiceOver (and the UI tests) read its percent.
    private func progressRing(_ progress: Double, radius: CGFloat) -> some View {
        let done = progress >= 1
        return ZStack {
            Circle()
                .strokeBorder(.black.opacity(0.3), lineWidth: 11)
            Circle()
                .strokeBorder(.white.opacity(0.85), lineWidth: 7)
            Circle()
                .inset(by: 3.5)
                .trim(from: 0, to: done ? 1 : progress)
                .stroke(done ? Palette.covered : Palette.signal, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: max(14, radius * 0.5), weight: .black))
                    .foregroundStyle(.white)
                    .padding(radius * 0.2)
                    .background(Palette.covered, in: .circle)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            } else {
                Circle()
                    .fill(Palette.signal)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .animation(Motion.pin, value: done)
        .accessibilityElement()
        .accessibilityLabel("Spot to show")
        .accessibilityValue(done ? "Captured" : "\(Int((progress * 100).rounded())) percent captured")
        .accessibilityIdentifier("aim.ring")
    }
}
