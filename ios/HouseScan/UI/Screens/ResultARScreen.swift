import simd
import SwiftUI

/// "See it on your wall": the battery drawn onto the live camera at the chosen spot, with the
/// cable run from the meter and the clearance footprint tinted by outcome. On the live camera the
/// engine draws it into the AR scene (`state.resultInCamera`); over a replay this screen projects
/// it from the meter-anchored wall frame. Either way it stays put as the homeowner moves.
struct ResultARScreen: View {
    let state: ScanViewState
    let actions: any ScanActions

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !state.resultInCamera, state.tracking == .normal, let projection = state.projection, let result = state.result, let wall = result.wall ?? state.wall {
                BatteryOverlay(projection: projection, wall: wall, result: result, rise: appeared ? 1 : 0)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            CameraChrome(
                instruction: instruction,
                isReplay: state.isReplay,
                isAutopilot: state.isAutopilot
            ) {
                Button("Done") { actions.closeAR() }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("action.closeAR")
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.7, bounce: 0.15)) { appeared = true }
        }
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
