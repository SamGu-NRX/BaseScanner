import simd
import SwiftUI

/// "See it on your wall": the battery drawn onto the live camera at the chosen spot, with the
/// cable run from the meter and the clearance footprint tinted by outcome. This screen projects
/// it from the meter-anchored wall frame (`BatteryOverlay`) unless the engine has seen the AR
/// scene drawing it (`state.resultInCamera`). Either way it stays put as the homeowner moves.
/// While the spot can't be seen, a chevron at the edge points toward it and a caption above Done
/// says which way.
struct ResultARScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var appeared = false
    /// Where the card and the Done button cover the camera (`CameraChrome`), for the chevron.
    @State private var cover = ChromeCover()
    /// Which way the spot is while it can't be seen, in eighths of a turn from "right",
    /// clockwise (`SpotDirection`); nil while it is in view.
    @State private var spotOctant: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if state.tracking == .normal, let projection = state.projection, let wall = state.wall, let result = state.result {
                if state.resultInCamera {
                    // The AR scene draws the result in the camera view; this only names it for
                    // VoiceOver and the UI tests, as the overlay below does.
                    Color.clear
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel(Self.overlayLabel(result))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("ar.overlay")
                } else {
                    BatteryOverlay(projection: projection, wall: wall, result: result, rise: appeared ? 1 : 0)
                        .ignoresSafeArea()
                        .accessibilityElement()
                        .accessibilityLabel(Self.overlayLabel(result))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityIdentifier("ar.overlay")
                }
                if let spot = result.spotCenter(on: wall) {
                    SpotDirection(projection: projection, spot: spot, cover: cover, octant: $spotOctant)
                }
            }
            CameraChrome(
                instruction: instruction,
                isReplay: state.isReplay,
                isAutopilot: state.isAutopilot,
                cover: $cover
            ) {
                VStack(spacing: 10) {
                    if state.tracking == .normal, let spotOctant {
                        SpotDirectionCaption(octant: spotOctant)
                    }
                    Button("Done") { actions.closeAR() }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("action.closeAR")
                }
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.7, bounce: 0.15)) { appeared = true }
        }
    }

    private static func overlayLabel(_ result: ResultPresentation) -> String {
        result.spot == nil ? "The cable run and clearances, drawn on your wall" : "The battery, drawn on your wall at its spot"
    }

    private var instruction: Instruction {
        if state.tracking != .normal {
            return Instruction(title: "Point at your meter", detail: "The battery comes back once your phone finds its place.")
        }
        guard let result = state.result, result.spot != nil else {
            return Instruction(title: "Point at your meter", detail: nil)
        }
        // Only a pass under approved rules may sound settled; a spot an installer still has to
        // check says so, as the result screen does.
        let title = result.decision == .pass && result.policyApproved
            ? "Your battery could go here"
            : "The spot an installer will check"
        let placement = ScanCopy.placement(result)
        guard !result.isSample else {
            // A sample spot drawn on the homeowner's real wall must not pass for their result.
            return Instruction(title: "Example spot, not your result", detail: ["No server checked this scan.", placement].compactMap { $0 }.joined(separator: " "))
        }
        return Instruction(title: title, detail: placement)
    }
}

extension ResultPresentation {
    /// The middle of the battery on `wall`, in world meters; nil without a spot. The point
    /// "See it on your wall" has to get on screen: the edge chevron points to it while it is off
    /// screen, and the engine checks the AR scene puts it in view (`LiveCapture.resultIsDrawn`).
    func spotCenter(on wall: WallGeometry) -> SIMD3<Float>? {
        guard let spot else { return nil }
        let middle = (spot.span.lowerBound + spot.span.upperBound) / 2
        return wall.world(s: middle, height: spot.height / 2, out: spot.offsetFromWall + spot.depth / 2)
    }
}

/// While the battery spot can't be seen, an edge chevron toward it in the clear part of the
/// camera, and which way it is (`octant`) for the caption above the Done button
/// (`SpotDirectionCaption`). The caption sits in the chrome's own stack rather than over the
/// camera: at the largest text sizes the card and the button leave no camera clear, and a
/// caption drawn there went under them (review of #100). The chevron shows only where it fits.
private struct SpotDirection: View {
    var projection: CameraProjection
    var spot: SIMD3<Float>
    /// Where the card and the Done button cover the camera, as `CameraChrome` measured them.
    var cover: ChromeCover
    /// Which way the spot is, in eighths of a turn clockwise from "right"; nil while in view.
    @Binding var octant: Int?

    /// Half the chevron's disc (52 pt) and a gap.
    private static let chevronReach: CGFloat = 34

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let clear = clearArea(in: size)
            let chevron = chevronPlacement(in: size, clear: clear)
            ZStack {
                Color.clear
                if let chevron, clear.height >= 2 * Self.chevronReach {
                    TargetMarker(placement: .offScreen(chevron.point, angle: chevron.angle))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: size.width, height: size.height)
            .onChange(of: chevron.map { Self.octant($0.angle) }, initial: true) { _, new in octant = new }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onDisappear { octant = nil }
    }

    /// `angle` (screen axes, y down) in eighths of a turn clockwise from "right", 0...7.
    private static func octant(_ angle: Angle) -> Int {
        let eighths = Int((angle.radians / (.pi / 4)).rounded())
        return ((eighths % 8) + 8) % 8
    }

    /// The part of the screen the chrome leaves clear, as `CameraChrome` measured it: between the
    /// instruction card's bottom edge and the Done button's top edge. At the largest text sizes
    /// the card reaches far further down than at the default size, so fixed insets hid the
    /// chevron while the spot was under the card (review of #100). Before the first layout,
    /// the default-size card (about 220 pt with a two-line detail) and button (about 100 pt up).
    /// Empty when the chrome covers it all.
    private func clearArea(in size: CGSize) -> CGRect {
        let top = (cover.cardBottom ?? 252) + 8
        let bottom = (cover.controlsTop ?? size.height - 152) - 8
        return CGRect(x: 24, y: top, width: max(size.width - 48, 0), height: max(bottom - top, 0))
    }

    /// Where the chevron goes and which way it points, or nil while the spot is in view: in the
    /// clear area. A spot under the card or the Done button can't be seen, so it gets the
    /// chevron too. The chevron keeps to the clear area, toward the spot's side of it.
    private func chevronPlacement(in size: CGSize, clear: CGRect) -> (point: CGPoint, angle: Angle)? {
        if let point = projection.viewPoint(for: spot, in: size), clear.contains(point) { return nil }
        guard let direction = projection.screenDirection(toward: spot) else { return nil }
        let lane = clear.insetBy(dx: 16, dy: min(Self.chevronReach, clear.height / 2))
        let tx = direction.dx == 0 ? CGFloat.infinity : lane.width / 2 / abs(direction.dx)
        let ty = direction.dy == 0 ? CGFloat.infinity : lane.height / 2 / abs(direction.dy)
        let t = min(tx, ty)
        let point = CGPoint(x: lane.midX + direction.dx * t, y: lane.midY + direction.dy * t)
        return (point, .radians(atan2(direction.dy, direction.dx)))
    }
}

/// "Your battery spot is this way" with an arrow toward it, above the Done button while the
/// spot can't be seen (`SpotDirection`). VoiceOver hears which way.
private struct SpotDirectionCaption: View {
    /// Eighths of a turn clockwise from "right", 0...7.
    var octant: Int

    private static let words = ["to the right", "down and to the right", "down", "down and to the left",
                                "to the left", "up and to the left", "up", "up and to the right"]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right")
                .font(.body.weight(.heavy))
                .rotationEffect(.degrees(Double(octant) * 45))
            Text("Your battery spot is this way")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.chalk)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Solid, as the other camera captions: see-through black over a bright wall can fail
        // the accessibility audit's contrast check.
        .background(ScrimShape.rounded(20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your battery spot is off screen, \(Self.words[octant % 8]). Turn the phone that way.")
        .accessibilityIdentifier("ar.spotDirection")
    }
}

/// Canvas drawing of the battery box, cable and footprint. `rise` 0...1 lifts the box out of the
/// ground for the entrance.
struct BatteryOverlay: View, Animatable {
    var projection: CameraProjection
    var wall: WallGeometry
    var result: ResultPresentation
    var rise: Double

    /// With Reduce Motion the box stands at full height from the start and `rise` only fades it in.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Lets `withAnimation` interpolate the rise; a Canvas alone would jump to the end value.
    var animatableData: Double {
        get { rise }
        set { rise = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let geometry = WallProjection(projection: projection, wall: wall, size: size)
            drawClearances(in: &context, geometry)
            drawCable(in: &context, geometry)
            if let spot = result.spot {
                drawShadow(spot, in: &context, geometry)
                drawBox(spot, in: &context, geometry)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawClearances(in context: inout GraphicsContext, _ geometry: WallProjection) {
        for zone in result.clearances {
            guard let quad = geometry.groundQuad(s: zone.span, out: 0...zone.depth, height: 0.01) else { continue }
            let color = Palette.outcome(zone.outcome)
            context.fill(quad, with: .color(color.opacity(0.28 * rise)))
            context.stroke(quad, with: .color(color.opacity(0.9 * rise)), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        }
    }

    private func drawCable(in context: inout GraphicsContext, _ geometry: WallProjection) {
        let points = result.cableRoute.compactMap { geometry.point(s: $0.x, height: $0.y, out: 0.03) }
        guard points.count >= 2 else { return }
        var line = Path()
        line.addLines(points)
        context.stroke(line, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
        context.stroke(line, with: .color(Palette.signal), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
    }

    private func drawShadow(_ spot: BatterySpot, in context: inout GraphicsContext, _ geometry: WallProjection) {
        let out0 = spot.offsetFromWall - 0.05
        let out1 = spot.offsetFromWall + spot.depth + 0.12
        let span = (spot.span.lowerBound - 0.06)...(spot.span.upperBound + 0.1)
        guard let shadow = geometry.groundQuad(s: span, out: out0...out1, height: 0.005) else { return }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 14))
            layer.fill(shadow, with: .color(.black.opacity(0.45 * rise)))
        }
    }

    private func drawBox(_ spot: BatterySpot, in context: inout GraphicsContext, _ geometry: WallProjection) {
        let height = reduceMotion ? spot.height : spot.height * Float(max(rise, 0.02))
        let fade = reduceMotion ? rise : 1
        let s0 = spot.span.lowerBound, s1 = spot.span.upperBound
        let o0 = spot.offsetFromWall, o1 = spot.offsetFromWall + spot.depth
        func corner(_ s: Float, _ h: Float, _ o: Float) -> SIMD3<Float> { wall.world(s: s, height: h, out: o) }

        struct Face {
            var corners: [SIMD3<Float>]
            /// Outward normal in world space.
            var normal: SIMD3<Float>
            var shade: Double
            var isFront: Bool
        }
        let up = SIMD3<Float>(0, 1, 0)
        // The piece of wall the box stands against, which is round a corner when the walk followed one.
        let middle = (s0 + s1) / 2
        let outward = wall.outward(atS: middle), along = wall.along(atS: middle)
        let faces = [
            Face(corners: [corner(s0, 0, o1), corner(s1, 0, o1), corner(s1, height, o1), corner(s0, height, o1)],
                 normal: outward, shade: 1.0, isFront: true),
            Face(corners: [corner(s0, height, o0), corner(s1, height, o0), corner(s1, height, o1), corner(s0, height, o1)],
                 normal: up, shade: 0.93, isFront: false),
            Face(corners: [corner(s0, 0, o0), corner(s0, 0, o1), corner(s0, height, o1), corner(s0, height, o0)],
                 normal: -along, shade: 0.8, isFront: false),
            Face(corners: [corner(s1, 0, o0), corner(s1, 0, o1), corner(s1, height, o1), corner(s1, height, o0)],
                 normal: along, shade: 0.8, isFront: false),
            Face(corners: [corner(s0, 0, o0), corner(s1, 0, o0), corner(s1, height, o0), corner(s0, height, o0)],
                 normal: -outward, shade: 0.7, isFront: false),
        ]
        // The box is convex, so drawing only the faces that point at the camera needs no depth
        // sorting (sorting by face centers can paint a hidden face over a visible one).
        for face in faces {
            let center = face.corners.reduce(SIMD3<Float>.zero, +) / Float(face.corners.count)
            guard simd_dot(projection.cameraPosition - center, face.normal) > 0,
                  let path = geometry.polygon(face.corners) else { continue }
            let base = Color(white: 0.97 * face.shade)
            context.fill(path, with: .color(base.opacity(0.96 * fade)))
            context.stroke(path, with: .color(.black.opacity(0.18 * fade)), lineWidth: 1)
            if face.isFront {
                // The blue light bar across the front, a third of the way down.
                let barTop = height * 0.72, barBottom = height * 0.66
                if let bar = geometry.polygon([
                    corner(s0 + (s1 - s0) * 0.2, barBottom, o1 + 0.002), corner(s1 - (s1 - s0) * 0.2, barBottom, o1 + 0.002),
                    corner(s1 - (s1 - s0) * 0.2, barTop, o1 + 0.002), corner(s0 + (s1 - s0) * 0.2, barTop, o1 + 0.002),
                ]) {
                    context.fill(bar, with: .color(Palette.signal.opacity(fade)))
                }
            }
        }
    }
}
