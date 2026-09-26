import HouseScanKit
import simd
import SwiftUI

/// The 3D map over the camera: frost on the space in front of the wall the phone hasn't seen yet,
/// and one blue cue for the next view, a spot on the ground to stand on and then a ring to aim at.
///
/// The frost is FogOverlay's (the same light material, wash, blur and unseen strength) drawn from
/// the map's 0.3 m fog cubes instead of the wall strip, so it hangs in the air where the unseen
/// space is and thins as the map fills in. The cue uses WayfindingOverlay's blue: a ground disk at
/// `stand` while the homeowner walks there, then an aim ring on `target` once they arrive, with an
/// edge chevron whenever the one that matters is off screen. Only one of the two shows at a time.
///
/// Compose it inside CameraOverlays' tracking gate: drawn from a pose the phone doesn't trust,
/// the frost and cue would hang in the wrong place.
struct Map3DOverlay: View {
    var fog: FogOfWar
    var nextView: ViewSuggestion?
    var frame: MapFrame
    var projection: CameraProjection

    @State private var motion = Map3DCueMotion()
    @State private var deadline = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(paused: deadline < .now)) { timeline in
                let haze = Map3DHaze(fog: fog, frame: frame, projection: projection, size: size)
                let cue = Map3DCueLayout(
                    drawn: motion.drawn(at: timeline.date, reduceMotion: reduceMotion),
                    aimWeight: motion.aimWeight(at: timeline.date),
                    cellSize: fog.cellSize, frame: frame, projection: projection, size: size
                )
                ZStack {
                    // The frost itself, as in FogOverlay: the material blurs the camera so the
                    // haze reads on a sunlit wall and on dark brick; the canvas decides where.
                    Rectangle()
                        .fill(.thinMaterial)
                        .environment(\.colorScheme, .light)
                        .mask {
                            Canvas(rendersAsynchronously: false) { context, _ in
                                haze.draw(in: &context, color: .black, strength: 1)
                            }
                        }
                    Canvas(rendersAsynchronously: false) { context, _ in
                        haze.draw(in: &context, color: Color(white: 0.98), strength: 0.35)
                        cue.drawMarks(in: &context)
                    }
                    ForEach(cue.chevrons.indices, id: \.self) { index in
                        Map3DChevron(angle: cue.chevrons[index].angle)
                            .position(cue.chevrons[index].point)
                            .opacity(cue.chevrons[index].opacity)
                    }
                }
                .accessibilityHidden(true)
                .overlay { accessibleCue(in: size) }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            motion.seed(nextView.map(Map3DCueMotion.Pose.init), arrived: arrived(wasArrived: false))
        }
        .onChange(of: nextView) { _, next in
            extend(motion.update(to: next.map(Map3DCueMotion.Pose.init), at: .now, reduceMotion: reduceMotion))
            refreshArrival()
        }
        .onChange(of: projection) { _, _ in refreshArrival() }
        .task(id: deadline) {
            // Ends the timeline once the last cue change has finished, so a still replay frame
            // stops redrawing (FogOverlay's pattern).
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            do { try await Task.sleep(for: .seconds(remaining + 0.05)) } catch { return }
            deadline = .distantPast
        }
    }

    private func extend(_ end: Date?) {
        if let end, end > deadline { deadline = end }
    }

    // MARK: Arrival

    /// Plan distance at which the homeowner has reached the spot and the cue turns to aiming,
    /// and the larger one at which walking off turns it back. The gap stops the cue flickering
    /// while someone stands on the edge. A display choice, not tuned on a device.
    private static let arriveRadius: Float = 0.6
    private static let leaveRadius: Float = 0.9

    /// Left alone while there is no suggestion, so a cue fading out keeps its kind; flipping to
    /// "not arrived" there would flash the ground disk under a leaving ring.
    private func refreshArrival() {
        guard nextView != nil else { return }
        extend(motion.setArrived(arrived(wasArrived: motion.arrived), at: .now))
    }

    private func arrived(wasArrived: Bool) -> Bool {
        guard let nextView else { return false }
        let distance = Map3DCueLayout.planDistance(frame.world(nextView.stand), projection.cameraPosition)
        return distance < (wasArrived ? Self.leaveRadius : Self.arriveRadius)
    }

    // MARK: Accessibility

    /// One element for VoiceOver where the cue is drawn, saying what the geometry can support:
    /// how far the spot is and which way, or which way to turn the phone. The frost stays hidden.
    @ViewBuilder
    private func accessibleCue(in size: CGSize) -> some View {
        if let nextView {
            let spoken = Map3DCueLayout.spokenCue(
                nextView, arrived: motion.arrived, frame: frame, projection: projection, size: size
            )
            Color.clear
                .frame(width: 60, height: 60)
                .position(spoken.point)
                .accessibilityElement()
                .accessibilityLabel(spoken.label)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

// MARK: - Frost

/// The fog cells in view, merged into a few bands of strength so thousands of cubes cost a
/// handful of fills.
///
/// Each cell becomes a soft disc a little wider than its cube, so neighbours blur into one bank.
/// Discs are grouped by strength into `steps` bands; band k is the union of every cell at step k
/// or above, filled with the alpha that brings the stack to exactly that step. Overlapping cells
/// along a line of sight then show the strongest cell's frost, not a sum that would white out
/// the screen where the unseen space is deep.
private struct Map3DHaze {
    var bands: [Path]

    private static let steps = 4
    /// Disc radius as a share of the cube's side: a cube's half-width is 0.5, so 0.7 overlaps
    /// neighbours enough for the blur to join them.
    private static let discScale: Float = 0.7
    /// Caps a disc right at the phone, where the near fade has it almost invisible anyway.
    private static let maxDiscRadius: CGFloat = 180
    /// The homeowner stands inside the region the rules need, so cells round the phone fade
    /// out; otherwise the frost would cover the whole screen. A display choice.
    private static let nearFade: ClosedRange<Float> = 0.5...1.2
    /// LiDAR reads to 5 m (`Map3DConfig.maxDepth`), so fog past that can't be cleared from here;
    /// it thins out rather than stacking into a white wall. A display choice.
    private static let farFade: ClosedRange<Float> = 4...6

    init(fog: FogOfWar, frame: MapFrame, projection: CameraProjection, size: CGSize) {
        var bands = [Path](repeating: Path(), count: Self.steps)
        let camera = projection.cameraPosition
        let forward = projection.forward
        let focal = CGFloat(projection.intrinsics.x) * projection.scale(in: size)
        let view = CGRect(origin: .zero, size: size)
        for cell in fog.cells {
            let world = frame.world(cell.center)
            // Distance along the view axis, the same as -z in camera space, without inverting
            // the camera transform for every cell; `viewPoint` below inverts it only for the
            // few hundred cells that survive this cut.
            let depth = simd_dot(world - camera, forward)
            guard depth > Self.nearFade.lowerBound, depth < Self.farFade.upperBound else { continue }
            let fade = Self.fade(simd_distance(world, camera))
            let step = Int((Double(cell.unknown) * fade * Double(Self.steps)).rounded())
            guard step > 0, let point = projection.viewPoint(for: world, in: size) else { continue }
            let radius = min(Self.maxDiscRadius, CGFloat(Self.discScale * fog.cellSize) * focal / CGFloat(depth))
            guard view.insetBy(dx: -radius, dy: -radius).contains(point) else { continue }
            let disc = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            for band in 0..<min(step, Self.steps) { bands[band].addEllipse(in: disc) }
        }
        self.bands = bands
    }

    private static func fade(_ distance: Float) -> Double {
        let rise = (distance - nearFade.lowerBound) / (nearFade.upperBound - nearFade.lowerBound)
        let fall = (farFade.upperBound - distance) / (farFade.upperBound - farFade.lowerBound)
        return Double(min(1, max(0, min(rise, fall))))
    }

    /// Frost at `strength` of FogOverlay's unseen haze: 1 for the material's mask, 0.35 for the
    /// white wash over it, as FogOverlay draws them.
    func draw(in context: inout GraphicsContext, color: Color, strength: Double) {
        let peak = FogOverlay.haze(.unseen) * strength
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 9))
            var below = 0.0
            for (index, band) in bands.enumerated() where !band.isEmpty {
                let level = peak * Double(index + 1) / Double(Self.steps)
                layer.fill(band, with: .color(color.opacity(1 - (1 - level) / (1 - below))))
                below = level
            }
        }
    }
}

// MARK: - Cue

/// Where the cue lands on screen this frame: marks drawn on the canvas and chevrons as views.
private struct Map3DCueLayout {
    struct Chevron {
        var point: CGPoint
        var angle: Angle
        var opacity: Double
    }

    private enum Mark {
        case stand(Path, opacity: Double)
        case aim(CGPoint, radius: CGFloat, opacity: Double)
    }

    private var marks: [Mark] = []
    private(set) var chevrons: [Chevron] = []

    /// Radius of the ground disk: about the space two feet take, so it reads as "stand here".
    private static let standRadius: Float = 0.3

    init(
        drawn: [Map3DCueMotion.Drawn], aimWeight: Double, cellSize: Float,
        frame: MapFrame, projection: CameraProjection, size: CGSize
    ) {
        let bounds = Self.markBounds(size)
        for cue in drawn {
            let standOpacity = cue.opacity * (1 - aimWeight)
            let aimOpacity = cue.opacity * aimWeight
            if standOpacity > 0.01 {
                let stand = frame.world(cue.pose.stand)
                if let center = projection.viewPoint(for: stand, in: size), bounds.contains(center),
                   let disk = Self.groundDisk(cue.pose.stand, radius: Self.standRadius * cue.scale, frame: frame, projection: projection, size: size) {
                    marks.append(.stand(disk, opacity: standOpacity))
                } else if let chevron = Self.chevron(toward: stand, projection: projection, size: size, opacity: standOpacity) {
                    chevrons.append(chevron)
                }
            }
            if aimOpacity > 0.01 {
                let target = frame.world(cue.pose.target)
                if let center = projection.viewPoint(for: target, in: size), bounds.contains(center) {
                    marks.append(.aim(center, radius: Self.ringRadius(target, projection: projection, size: size) * CGFloat(cue.scale), opacity: aimOpacity))
                } else if let chevron = Self.chevron(toward: target, projection: projection, size: size, opacity: aimOpacity) {
                    chevrons.append(chevron)
                }
            }
        }
    }

    /// The ground disk and aim ring in WayfindingOverlay's style (white halo, Signal stroke,
    /// the ring's dot), each over a faint dark halo: a white halo alone vanishes on sunlit
    /// concrete, where Signal on its own is about 3:1.
    func drawMarks(in context: inout GraphicsContext) {
        for mark in marks {
            switch mark {
            case .stand(let disk, let opacity):
                context.fill(disk, with: .color(Palette.signal.opacity(0.22 * opacity)))
                // Dark halo outside the rim only; inside, it muddied the blue fill.
                var outside = context
                outside.clip(to: disk, options: .inverse)
                outside.stroke(disk, with: .color(.black.opacity(0.28 * opacity)), style: StrokeStyle(lineWidth: 10, lineJoin: .round))
                context.stroke(disk, with: .color(.white.opacity(0.9 * opacity)), style: StrokeStyle(lineWidth: 7, lineJoin: .round))
                context.stroke(disk, with: .color(Palette.signal.opacity(opacity)), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            case .aim(let center, let radius, let opacity):
                // TargetMarker's rings are 7 and 4 pt borders inside `radius`.
                let ring = { (inset: CGFloat) in
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2).insetBy(dx: inset, dy: inset))
                }
                // The dark halo only shows outside the blue edge; centred on the white band it
                // drew a second, gray ring inside it.
                context.stroke(ring(-1), with: .color(.black.opacity(0.28 * opacity)), lineWidth: 3)
                context.stroke(ring(3.5), with: .color(.white.opacity(0.9 * opacity)), lineWidth: 7)
                context.stroke(ring(2), with: .color(Palette.signal.opacity(opacity)), lineWidth: 4)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(Palette.signal.opacity(opacity)))
            }
        }
    }

    // MARK: Geometry

    /// A circle on the ground round `stand` (map frame), projected edge by edge so it lies flat
    /// and foreshortens with the ground. Nil when any of it is behind the camera.
    private static func groundDisk(_ stand: SIMD3<Float>, radius: Float, frame: MapFrame, projection: CameraProjection, size: CGSize) -> Path? {
        var points: [CGPoint] = []
        for step in 0..<36 {
            let angle = Float(step) * 2 * .pi / 36
            let edge = stand + SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
            guard let point = projection.viewPoint(for: frame.world(edge), in: size) else { return nil }
            points.append(point)
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// WayfindingOverlay's ring size: 28 cm across the target, kept between 30 and 64 pt.
    private static func ringRadius(_ target: SIMD3<Float>, projection: CameraProjection, size: CGSize) -> CGFloat {
        let depth = simd_dot(target - projection.cameraPosition, projection.forward)
        guard depth > 0.05 else { return 64 }
        let pointsPerMeter = CGFloat(projection.intrinsics.x) * projection.scale(in: size) / CGFloat(depth)
        return min(64, max(30, pointsPerMeter * 0.28))
    }

    /// Where a mark may sit: WayfindingOverlay's ring bounds, clear of the instruction card
    /// above and the controls and tape below. Past them the chevron takes over.
    private static func markBounds(_ size: CGSize) -> CGRect {
        CGRect(x: 36, y: 150, width: size.width - 72, height: size.height - 330)
    }

    /// WayfindingOverlay's edge chevron: on the edge of the lane between the card and the
    /// controls, pointing toward the world point.
    private static func chevron(toward world: SIMD3<Float>, projection: CameraProjection, size: CGSize, opacity: Double) -> Chevron? {
        guard let direction = projection.screenDirection(toward: world) else { return nil }
        let lane = CGRect(x: 40, y: 260, width: size.width - 80, height: max(size.height - 260 - 300, 80))
        let tx = direction.dx == 0 ? CGFloat.infinity : lane.width / 2 / abs(direction.dx)
        let ty = direction.dy == 0 ? CGFloat.infinity : lane.height / 2 / abs(direction.dy)
        let t = min(tx, ty)
        return Chevron(
            point: CGPoint(x: lane.midX + direction.dx * t, y: lane.midY + direction.dy * t),
            angle: .radians(atan2(direction.dy, direction.dx)),
            opacity: opacity
        )
    }

    static func planDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(SIMD2(a.x - b.x, a.z - b.z))
    }

    // MARK: Spoken

    /// The cue in words and where its element sits. Distance is plan distance to the spot in
    /// whole feet; direction is the spot's bearing from where the phone faces, or which way to
    /// turn the phone for an aim point off screen. Nothing about what is there: the map knows
    /// the space is unseen, not what fills it.
    static func spokenCue(_ view: ViewSuggestion, arrived: Bool, frame: MapFrame, projection: CameraProjection, size: CGSize) -> (label: String, point: CGPoint) {
        let bounds = markBounds(size)
        if arrived {
            let target = frame.world(view.target)
            if let point = projection.viewPoint(for: target, in: size), bounds.contains(point) {
                return ("Aim the phone at the ring, a spot it hasn't seen yet", point)
            }
            let chevron = chevron(toward: target, projection: projection, size: size, opacity: 1)
            let turn = chevron.flatMap { turnWords($0.angle) }.map { "Turn the phone \($0)" } ?? "Look around"
            return ("\(turn) to find a spot it hasn't seen yet", chevron?.point ?? CGPoint(x: bounds.midX, y: bounds.midY))
        }
        let stand = frame.world(view.stand)
        let feet = max(1, Int((planDistance(stand, projection.cameraPosition) / (Distance.metersPerInch * 12)).rounded()))
        let distance = "about \(Distance.spoken(Float(feet) * Distance.metersPerInch * 12))"
        let place = bearingWords(to: stand, projection: projection).map { "\(distance) \($0)" } ?? "\(distance) away"
        let point = projection.viewPoint(for: stand, in: size).flatMap { bounds.contains($0) ? $0 : nil }
            ?? chevron(toward: stand, projection: projection, size: size, opacity: 1)?.point
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        return ("Next place to stand, \(place)", point)
    }

    /// "ahead", "ahead on your left", "to your right", "behind you": the plan bearing of a point
    /// from the way the phone faces. Nil when the phone points nearly straight up or down and
    /// has no heading to speak of.
    private static func bearingWords(to world: SIMD3<Float>, projection: CameraProjection) -> String? {
        let facing = SIMD2(projection.forward.x, projection.forward.z)
        let offset = SIMD2(world.x - projection.cameraPosition.x, world.z - projection.cameraPosition.z)
        guard simd_length(facing) > 0.2, simd_length(offset) > 0.05 else { return nil }
        let forward = simd_normalize(facing)
        // In plan (x, z) with -z ahead, the right of `forward` is (-forward.z, forward.x).
        let right = SIMD2(-forward.y, forward.x)
        let degrees = atan2(simd_dot(offset, right), simd_dot(offset, forward)) * 180 / .pi
        let side = degrees > 0 ? "right" : "left"
        switch abs(degrees) {
        case ..<25: return "ahead"
        case ..<70: return "ahead on your \(side)"
        case ..<115: return "to your \(side)"
        default: return "behind you"
        }
    }

    /// "up and to the left" from a chevron's screen angle (0 is right, positive turns down).
    private static func turnWords(_ angle: Angle) -> String? {
        let dx = cos(angle.radians), dy = sin(angle.radians)
        let horizontal = dx > 0.38 ? "to the right" : dx < -0.38 ? "to the left" : nil
        let vertical = dy < -0.38 ? "up" : dy > 0.38 ? "down" : nil
        switch (vertical, horizontal) {
        case let (vertical?, horizontal?): return "\(vertical) and \(horizontal)"
        case let (vertical?, nil): return vertical
        case let (nil, horizontal?): return horizontal
        case (nil, nil): return nil
        }
    }
}

/// WayfindingOverlay's off-screen chevron: white on a Signal disc with a white rim and a shadow.
private struct Map3DChevron: View {
    var angle: Angle

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(.white)
            .rotationEffect(angle)
            .frame(width: 52, height: 52)
            .background(Palette.signal, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}

// MARK: - Motion

/// The cue's motion, kept in the map frame so an animating cue still sits on the world.
///
/// Three changes animate, each under 250 ms with an ease-out: a cue appearing (fade, and a small
/// grow from 90% without Reduce Motion), a cue leaving (fade), and the suggestion moving (a glide
/// from where it was drawn; with Reduce Motion a crossfade when it moved far, a jump when it
/// barely moved). Arriving at the spot crossfades the ground disk into the aim ring. Nothing
/// pulses or drifts on its own.
///
/// Observable so that seeding it on appear, or arriving, redraws a still replay frame; with a
/// plain class the cue stayed blank until the pose next changed.
@MainActor @Observable
private final class Map3DCueMotion {
    struct Pose: Equatable {
        var stand: SIMD3<Float>
        var target: SIMD3<Float>

        init(stand: SIMD3<Float>, target: SIMD3<Float>) {
            self.stand = stand
            self.target = target
        }

        init(_ view: ViewSuggestion) {
            self.init(stand: view.stand, target: view.target)
        }

        func mixed(to other: Pose, _ t: Float) -> Pose {
            Pose(stand: simd_mix(stand, other.stand, SIMD3(repeating: t)), target: simd_mix(target, other.target, SIMD3(repeating: t)))
        }
    }

    struct Drawn {
        var pose: Pose
        var opacity: Double
        /// Size of the disk and ring against their resting size.
        var scale: Float
    }

    private enum Change {
        case appear
        case leave(Pose)
        case glide(from: Pose)
        case crossfade(from: Pose)

        var duration: TimeInterval {
            switch self {
            case .appear: 0.2
            case .leave: 0.15
            case .glide: 0.25
            case .crossfade: 0.2
            }
        }
    }

    /// Under Reduce Motion a move shorter than this jumps rather than crossfading: the target
    /// drifts a little each time the map fills in, and a crossfade per drift would flicker.
    private static let crossfadeDistance: Float = 0.4
    private static let arrivalDuration: TimeInterval = 0.2

    private var pose: Pose?
    private var change: Change?
    private var changeStart = Date.distantPast
    private(set) var arrived = false
    private var arrivalStart = Date.distantPast
    private var arrivalFrom = 0.0

    func seed(_ pose: Pose?, arrived: Bool) {
        self.pose = pose
        self.arrived = arrived
        change = nil
        arrivalFrom = arrived ? 1 : 0
    }

    /// Starts the change to `next`. Returns when it ends, or nil when nothing animates.
    func update(to next: Pose?, at now: Date, reduceMotion: Bool) -> Date? {
        guard next != pose else { return nil }
        let shown = shownPose(at: now)
        switch (shown, next) {
        case (nil, _?):
            change = .appear
        case (let old?, nil):
            change = .leave(old)
        case (let old?, let new?):
            let moved = max(simd_distance(old.stand, new.stand), simd_distance(old.target, new.target))
            change = !reduceMotion ? .glide(from: old) : moved >= Self.crossfadeDistance ? .crossfade(from: old) : nil
        case (nil, nil):
            change = nil
        }
        pose = next
        changeStart = now
        return change.map { now.addingTimeInterval($0.duration) }
    }

    /// Switches between the ground disk and the aim ring. Returns when the crossfade ends, or
    /// nil when nothing changed.
    func setArrived(_ value: Bool, at now: Date) -> Date? {
        guard value != arrived else { return nil }
        arrivalFrom = aimWeight(at: now)
        arrived = value
        arrivalStart = now
        return now.addingTimeInterval(Self.arrivalDuration)
    }

    /// 0 draws the ground disk, 1 the aim ring; in between both, crossfading.
    func aimWeight(at now: Date) -> Double {
        let eased = Self.easeOut(now.timeIntervalSince(arrivalStart) / Self.arrivalDuration)
        return arrivalFrom + ((arrived ? 1 : 0) - arrivalFrom) * eased
    }

    func drawn(at now: Date, reduceMotion: Bool) -> [Drawn] {
        guard let change else { return pose.map { [Drawn(pose: $0, opacity: 1, scale: 1)] } ?? [] }
        let eased = Self.easeOut(now.timeIntervalSince(changeStart) / change.duration)
        switch change {
        case .appear:
            return pose.map { [Drawn(pose: $0, opacity: eased, scale: reduceMotion ? 1 : 0.9 + 0.1 * Float(eased))] } ?? []
        case .leave(let old):
            return eased < 1 ? [Drawn(pose: old, opacity: 1 - eased, scale: 1)] : []
        case .glide(let from):
            return pose.map { [Drawn(pose: from.mixed(to: $0, Float(eased)), opacity: 1, scale: 1)] } ?? []
        case .crossfade(let from):
            return [Drawn(pose: from, opacity: 1 - eased, scale: 1)] + (pose.map { [Drawn(pose: $0, opacity: eased, scale: 1)] } ?? [])
        }
    }

    /// Where the cue is drawn now, so a change that interrupts a glide starts from there.
    private func shownPose(at now: Date) -> Pose? {
        guard case .glide(let from) = change, let pose else { return pose }
        return from.mixed(to: pose, Float(Self.easeOut(now.timeIntervalSince(changeStart) / 0.25)))
    }

    /// FogOverlay's cubic ease-out, clamped to 0...1.
    private static func easeOut(_ t: Double) -> Double {
        let clamped = min(1, max(0, t))
        return 1 - pow(1 - clamped, 3)
    }
}

// MARK: - Preview

#if DEBUG
/// A synthetic yard for the preview: a flat wall, flat ground and a round bush, walked along the
/// left half only, run through the real map so the fog and next view are what the app would get.
enum Map3DOverlayDemo {
    struct Scene {
        var fog: FogOfWar
        var nextView: ViewSuggestion?
        var frame: MapFrame
        /// Standing back from the wall, facing right of the meter.
        var approach: CameraProjection
        /// At the suggested spot, aimed where it says.
        var arrived: CameraProjection?
    }

    static let intrinsics = SIMD4<Float>(1450, 1450, 960, 720)
    static let imageSize = SIMD2<Float>(1920, 1440)
    static let groundY: Float = -1.1
    static let bush = (center: SIMD3<Float>(1.3, -0.65, 0.6), radius: Float(0.5))

    static func make() -> Scene {
        // The meter frame is turned and shifted from ARKit's world so the preview exercises
        // `frame.world` and not an identity.
        let meter = SIMD3<Float>(0.4, 1.1, -0.3)
        let outward = simd_normalize(SIMD3<Float>(0.35, 0, 1))
        let frame = MapFrame(meter: meter, outward: outward, worldGroundY: 0)!
        let wall = WallFrame(meter: meter, outward: outward, groundY: 0)!
        var map = Map3D(frame: frame)
        for x in Swift.stride(from: Float(-4), through: 0.2, by: 0.4) {
            for aim in [SIMD3<Float>(x, 0, 0), SIMD3(x, groundY, 1.2), SIMD3(x, 1.2, 0)] {
                map.integrate(depthFrame(eye: SIMD3(x, groundY + 1.4, 3), aim: aim, frame: frame))
            }
        }
        let next = map.nextBestView(along: wall)
        let arrived = next.map { camera(eye: $0.eye, aim: $0.target, frame: frame) }
        return Scene(
            fog: map.fogOfWar(along: wall), nextView: next, frame: frame,
            approach: camera(eye: SIMD3(-1.2, groundY + 1.4, 3.2), aim: SIMD3(1.2, groundY + 0.5, 0.4), frame: frame),
            arrived: arrived
        )
    }

    /// A portrait-held phone at `eye` looking at `aim`, both map frame. Camera +x (sensor right)
    /// is screen down and +y (sensor up) is screen right.
    static func camera(eye: SIMD3<Float>, aim: SIMD3<Float>, frame: MapFrame) -> CameraProjection {
        let forward = simd_normalize(aim - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let down = simd_cross(forward, right)
        let inMap = simd_float4x4(SIMD4(down, 0), SIMD4(right, 0), SIMD4(-forward, 0), SIMD4(eye, 1))
        return CameraProjection(cameraToWorld: frame.poseInWorld * inMap, intrinsics: intrinsics, imageSize: imageSize)
    }

    /// LiDAR-like depth of the wall (map z = 0), ground and bush, ray cast in the map frame.
    private static func depthFrame(eye: SIMD3<Float>, aim: SIMD3<Float>, frame: MapFrame) -> DepthFrame {
        let view = camera(eye: eye, aim: aim, frame: frame)
        let photo = CameraFrame(cameraToWorld: view.cameraToWorld, intrinsics: intrinsics, imageSize: imageSize)
        let inMap = frame.poseInWorld.inverse * view.cameraToWorld
        let width = 64, height = 48
        let k = intrinsics * SIMD4(Float(width) / imageSize.x, Float(height) / imageSize.y, Float(width) / imageSize.x, Float(height) / imageSize.y)
        var depth = [Float](repeating: 0, count: width * height)
        for v in 0..<height {
            for u in 0..<width {
                let ray = SIMD4((Float(u) + 0.5 - k.z) / k.x, -((Float(v) + 0.5) - k.w) / k.y, -1, 0)
                let d = inMap * ray
                let direction = SIMD3(d.x, d.y, d.z)
                var t = Float.infinity
                if direction.z < 0 { t = min(t, -eye.z / direction.z) }
                if direction.y < 0 { t = min(t, (groundY - eye.y) / direction.y) }
                let toBush = eye - bush.center
                let b = simd_dot(toBush, direction), a = simd_length_squared(direction)
                let disc = b * b - a * (simd_length_squared(toBush) - bush.radius * bush.radius)
                if disc > 0 { let hit = (-b - disc.squareRoot()) / a; if hit > 0 { t = min(t, hit) } }
                // With the ray's camera z at -1, the hit's ray parameter is its depth.
                if t < 5 { depth[v * width + u] = t }
            }
        }
        return DepthFrame(photo: photo, width: width, height: height, depth: depth, kind: .lidar(confidence: nil))
    }
}

#Preview("Walking to the next spot") {
    let scene = Map3DOverlayDemo.make()
    ZStack {
        Color(red: 0.62, green: 0.60, blue: 0.56)
        Map3DOverlay(fog: scene.fog, nextView: scene.nextView, frame: scene.frame, projection: scene.approach)
    }
}

#Preview("At the spot, aiming") {
    let scene = Map3DOverlayDemo.make()
    ZStack {
        Color(red: 0.62, green: 0.60, blue: 0.56)
        Map3DOverlay(fog: scene.fog, nextView: scene.nextView, frame: scene.frame, projection: scene.arrived ?? scene.approach)
    }
}
#endif
