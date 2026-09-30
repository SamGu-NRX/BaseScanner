import simd
import SwiftUI

/// Where to stand and where to aim: a blue dotted path on the ground toward the next place to
/// stand, and a ring on the point to aim at (or an edge arrow when it is off screen).
///
/// Each part sets its own accessibility: the path and arrow are hidden, while the filling ring
/// is read (#81). A new part is read by VoiceOver unless it hides itself. The ring's legend is
/// drawn under the instruction card (`CameraChrome.legend`), not here.
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
    /// Called with whether an aim step's filling ring has its target on screen, each time that
    /// changes (`CameraOverlays` shows the ring's legend once one has). On screen, not in the
    /// open camera: at the largest text sizes the card can cover the ring's place until the
    /// chrome scrolls, and the legend under the card still says what the ring is for.
    var onFillingRingShown: ((Bool) -> Void)? = nil
    /// The open camera between the instruction card and the actions (`CameraChrome`). The ring
    /// shows only inside it and the edge arrows keep to it. Until the chrome has been laid out,
    /// fixed bands stand in.
    var cameraWindow: CameraWindow? = nil

    var body: some View {
        // Read here, in this view's body, so a change redraws this overlay alone.
        let clearArea = cameraWindow?.frame
        GeometryReader { proxy in
            let size = proxy.size
            let band = Self.verticalBand(clearArea, origin: proxy.frame(in: .global).origin, height: size.height)
            ZStack {
                Canvas { context, size in
                    drawPath(in: &context, size: size)
                }
                .accessibilityHidden(true)
                // One marker either way, so a ring that completes keeps its identity and animates
                // from its last fill to green.
                if let shown = marker(in: size, band: band) {
                    TargetMarker(placement: shown.placement, progress: shown.progress)
                }
                if fillingTargetOnScreen(in: size) {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .onAppear { onFillingRingShown?(true) }
                        .onDisappear { onFillingRingShown?(false) }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Lane

    /// The top and bottom of the camera left open by the instruction card above and the
    /// buttons and map below, which are drawn over this layer, in this view's coordinates.
    struct Band: Equatable {
        var top: CGFloat
        var bottom: CGFloat
    }

    /// The edge arrow's disc (`TargetMarker`).
    static let arrowDiameter: CGFloat = 52
    /// How far inside the band the edge arrows sit: half the arrow's disc and a margin.
    static let arrowInset: CGFloat = 32

    /// The measured window in this view's coordinates, cut to the part on screen: scrolling the
    /// chrome at large text sizes can carry the window partly past an edge.
    private static func verticalBand(_ clearArea: CGRect?, origin: CGPoint, height: CGFloat) -> Band? {
        clearArea.map {
            let top = min(max($0.minY - origin.y, 0), height)
            return Band(top: top, bottom: max(min($0.maxY - origin.y, height), top))
        }
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

    /// Whether an aim step's target is where a filling ring would show without the card: the
    /// fixed rectangle used before the chrome reported its open camera.
    private func fillingTargetOnScreen(in size: CGSize) -> Bool {
        guard progress != nil, completed == nil, let target, let point = projection.viewPoint(for: target, in: size) else {
            return false
        }
        return Self.ringBounds(in: size, band: nil, radius: 0).contains(point)
    }

    /// The completed ring while it is on screen, else the target's ring or arrow.
    private func marker(in size: CGSize, band: Band?) -> (placement: TargetMarker.Placement, progress: Double?)? {
        if let completed {
            let held = placement(for: completed, in: size, band: band)
            if case .onScreen = held { return (placement: held, progress: 1.0) }
        }
        guard let target else { return nil }
        return (placement: placement(for: target, in: size, band: band), progress: progress)
    }

    private func placement(for target: SIMD3<Float>, in size: CGSize, band: Band?) -> TargetMarker.Placement {
        // Less of the open camera on screen than an arrow's disc: at the largest text sizes the
        // chrome has scrolled it away, and anything drawn would sit on the card or the actions.
        if let band, band.bottom - band.top < Self.arrowDiameter { return .hidden }
        if let point = projection.viewPoint(for: target, in: size) {
            let scale = wall.flatMap { WallProjection(projection: projection, wall: $0, size: size).pointsPerMeter(at: target) }
            let radius = min(64, max(30, (scale ?? 90) * 0.28))
            if Self.ringBounds(in: size, band: band, radius: radius).contains(point) {
                return .onScreen(point, radius: radius)
            }
            // On screen but under the card or the actions. The camera's own direction to it
            // starts at the optical axis, which can be the target itself, so the arrow points
            // from the lane to where the target is drawn.
            if band != nil, CGRect(origin: .zero, size: size).contains(point) {
                let lane = Self.lane(in: size, band: band)
                let offset = CGVector(dx: point.x - lane.midX, dy: point.y - lane.midY)
                let length = (offset.dx * offset.dx + offset.dy * offset.dy).squareRoot()
                // At the lane's middle there is no way to point, and the ring doesn't fit: the
                // open camera is too short to guide in, so neither shows until it grows.
                guard length > 1 else { return .hidden }
                let direction = CGVector(dx: offset.dx / length, dy: offset.dy / length)
                return .offScreen(Self.arrowPoint(toward: direction, in: size, band: band), angle: .radians(atan2(direction.dy, direction.dx)))
            }
        }
        guard let direction = projection.screenDirection(toward: target) else {
            return .hidden
        }
        return .offScreen(Self.arrowPoint(toward: direction, in: size, band: band), angle: .radians(atan2(direction.dy, direction.dx)))
    }

    /// Where a ring's centre may be for the ring to show: with the whole ring, at the largest
    /// point of its pulse, on screen and in the open camera. Near the edges or partly under the
    /// card, the arrow takes over, since a half-visible ring would be ambiguous and one under
    /// the card can't be seen at all. Without a band, the fixed rectangle used before the chrome
    /// reported one, sized for the default text.
    static func ringBounds(in size: CGSize, band: Band?, radius: CGFloat) -> CGRect {
        guard let band else {
            return CGRect(x: 36, y: 150, width: size.width - 72, height: size.height - 330)
        }
        // `TargetMarker`'s plain ring pulses to 108 percent.
        let reach = radius * 1.08
        let inset = max(36, reach)
        return CGRect(
            x: inset,
            y: band.top + reach,
            width: max(size.width - 2 * inset, 0),
            height: max(band.bottom - band.top - 2 * reach, 0)
        )
    }

    /// Where the edge arrows keep: the band inset by `arrowInset`. A band too short for that
    /// leaves a lane of no height on the band's middle line, where the arrow overlaps the band
    /// least. Without a band, the fixed lane used before the chrome reported one.
    static func lane(in size: CGSize, band: Band?) -> CGRect {
        guard let band else {
            return CGRect(x: 40, y: 260, width: size.width - 80, height: max(size.height - 560, 80))
        }
        let middle = (band.top + band.bottom) / 2
        let top = min(band.top + arrowInset, middle)
        let bottom = max(band.bottom - arrowInset, middle)
        return CGRect(x: 40, y: top, width: max(size.width - 80, 0), height: bottom - top)
    }

    /// The edge arrow's centre: where a line from the middle of the lane toward the target
    /// leaves the lane.
    static func arrowPoint(toward direction: CGVector, in size: CGSize, band: Band?) -> CGPoint {
        let lane = lane(in: size, band: band)
        let center = CGPoint(x: lane.midX, y: lane.midY)
        let tx = direction.dx == 0 ? CGFloat.infinity : (lane.width / 2) / abs(direction.dx)
        let ty = direction.dy == 0 ? CGFloat.infinity : (lane.height / 2) / abs(direction.dy)
        let t = min(tx, ty)
        return CGPoint(x: center.x + direction.dx * t, y: center.y + direction.dy * t)
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
