import simd
import SwiftUI

/// Where to stand and where to aim: a blue dotted path on the ground toward the next place to
/// stand, and a ring on the point to aim at (or an edge arrow when it is off screen).
///
/// Each part sets its own accessibility: the path and arrow are hidden, while the filling ring
/// and the legend are read (#81). A new part is read by VoiceOver unless it hides itself.
struct WayfindingOverlay: View {
    var projection: CameraProjection
    var wall: WallGeometry?
    var path: [SIMD3<Float>]
    var target: SIMD3<Float>?
    /// How far the aim task is toward done, 0...1 (`ScanViewState.aimProgress`): the ring fills
    /// with it. Nil when the target only marks a place.
    var progress: Double? = nil
    /// An aim step's target that was just completed, drawn as a full ring in place of `target`
    /// while it is on screen (`CameraOverlays` holds it for a moment).
    var completed: SIMD3<Float>? = nil
    /// One line saying what the ring is for, drawn beside it while it is on screen.
    var legend: String? = nil
    /// A shorter legend, drawn where `legend` doesn't fit between the ring and the lane's edge.
    var legendShort: String? = nil
    /// Called when the legend is drawn.
    var onLegendShown: (() -> Void)? = nil

    /// The side of the ring the legend keeps to once shown: true for below.
    @State private var legendBelow: Bool? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Canvas { context, size in
                    drawPath(in: &context, size: size)
                }
                .accessibilityHidden(true)
                // One marker either way, so a ring that completes keeps its identity and animates
                // from its last fill to green.
                if let shown = marker(in: size) {
                    TargetMarker(placement: shown.placement, progress: shown.progress)
                    if let legend, case .onScreen(let point, let radius) = shown.placement {
                        legendView(legend, beside: point, radius: radius, in: size)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Lane

    /// The band clear of the instruction card above and the buttons and map below, which are
    /// drawn over this layer. The off-screen arrows and the legend both keep to it.
    private static let laneTop: CGFloat = 260
    private static let laneBottomInset: CGFloat = 300

    // MARK: Legend

    /// How much more room the other side of the ring needs before the legend moves there. The
    /// two sides are equal near the middle of the screen, where the ring is held, and pose
    /// jitter there would otherwise flip the legend across the ring every few frames.
    private static let legendSwitchMargin: CGFloat = 40

    /// The gap between the ring and the legend.
    private static let legendGap: CGFloat = 12

    /// The legend goes above or below the ring, whichever has more room in the lane, and moves
    /// with the ring without covering it. Once shown, it changes sides only when the other side
    /// has `legendSwitchMargin` more room.
    ///
    /// It keeps to the lane: the longest wording that fits between the ring and the lane's edge
    /// on its side is drawn, and none when neither fits. At the largest text sizes the full line
    /// runs to eight lines or more, and past the lane it went under the instruction card or the
    /// controls, which are drawn over this layer.
    private func legendView(_ text: String, beside point: CGPoint, radius: CGFloat, in size: CGSize) -> some View {
        let width = max(120, min(300, size.width - 48))
        let x = min(max(point.x, 24 + width / 2), size.width - 24 - width / 2)
        let roomAbove = point.y - radius - Self.laneTop
        let roomBelow = size.height - Self.laneBottomInset - (point.y + radius)
        let below: Bool
        if let kept = legendBelow {
            below = kept
                ? roomAbove - roomBelow < Self.legendSwitchMargin
                : roomBelow - roomAbove >= Self.legendSwitchMargin
        } else {
            below = roomBelow >= roomAbove
        }
        // The room on the legend's side, pinned at the edge nearer the ring, so the text's height
        // (it wraps, and grows with Dynamic Type) never moves its near edge onto the ring.
        let reach = max(0, (below ? roomBelow : roomAbove) - Self.legendGap)
        return ViewThatFits(in: .vertical) {
            legendText(text)
            if let legendShort { legendText(legendShort) }
            Color.clear.frame(width: 0, height: 0)
        }
        .onAppear {
            legendBelow = below
            onLegendShown?()
        }
        .onChange(of: below) { _, side in legendBelow = side }
        .onDisappear { legendBelow = nil }
        .frame(width: width, height: reach, alignment: below ? .top : .bottom)
        .position(
            x: x,
            y: below ? point.y + radius + Self.legendGap + reach / 2 : point.y - radius - Self.legendGap - reach / 2
        )
        .transition(.opacity)
    }

    private func legendText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("aim.legend")
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

    /// The completed ring while it is on screen, else the target's ring or arrow.
    private func marker(in size: CGSize) -> (placement: TargetMarker.Placement, progress: Double?)? {
        if let completed {
            let held = placement(for: completed, in: size)
            if case .onScreen = held { return (placement: held, progress: 1.0) }
        }
        guard let target else { return nil }
        return (placement: placement(for: target, in: size), progress: progress)
    }

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
        // Arrows keep to the lane, clear of the card and the controls.
        let lane = CGRect(
            x: 40,
            y: Self.laneTop,
            width: size.width - 80,
            height: max(size.height - Self.laneTop - Self.laneBottomInset, 80)
        )
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
