import SwiftUI
import simd

/// The haze over the parts of the wall and ground the phone hasn't seen yet: the frosted strip
/// that `LiveFogView` replaced. It still draws while the live fog's shaders compile at launch,
/// and for good if Metal fails, so unseen wall never shows clear.
///
/// Unseen cells carry a soft frosted haze, seen cells a thinner one, covered cells none. When a
/// cell's state changes (a new `coverage.revision`), its haze fades and drifts upward over
/// `Motion.fogLift`, like mist lifting: the signature moment that tells the homeowner "the phone
/// saw that" without a word. With Reduce Motion the haze only fades. The haze is guidance, never
/// proof that space is clear.
///
/// A gap request replaces the fog on its cells with an amber highlight, so the camera itself
/// shows where to aim.
///
/// On a phone with depth, a stretch the camera looked at through something nearer (a bush, a
/// bin) is hidden: no frost, since the phone did look, but a soft dark veil with a dashed violet
/// outline round the whole stretch. It fades in without rising: the rising drift belongs to
/// "the phone saw that", which a hidden stretch is not.
struct FogOverlay: View {
    var coverage: CoverageStrip
    var wall: WallGeometry
    var projection: CameraProjection
    var highlight: GapRequest?

    @State private var memory = FogMemory()

    @State private var liftDeadline = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: liftDeadline < .now)) { timeline in
            let frame = FogFrame(
                coverage: coverage, wall: wall, projection: projection, highlight: highlight,
                lifts: memory.lifts, now: timeline.date, drift: reduceMotion ? 0 : 10
            )
            ZStack {
                // The frost itself: a material blurs whatever the camera shows, so the haze
                // reads on a white wall in sun as well as on dark brick. The canvas only
                // decides where, and how thick.
                Rectangle()
                    .fill(.thinMaterial)
                    .environment(\.colorScheme, .light)
                    .mask {
                        Canvas(rendersAsynchronously: false) { context, size in
                            frame.drawHaze(in: &context, size: size, color: .black)
                        }
                    }
                Canvas(rendersAsynchronously: false) { context, size in
                    frame.drawHaze(in: &context, size: size, color: Color(white: 0.98).opacity(0.35))
                    frame.drawMarks(in: &context, size: size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { memory.seed(coverage) }
        .onChange(of: coverage.revision) { _, _ in
            if memory.update(to: coverage, at: .now, highlight: highlight) {
                liftDeadline = Date.now.addingTimeInterval(Motion.fogLift)
            }
        }
        .task(id: liftDeadline) {
            // Ends the timeline once the last lift has finished, so a still replay frame
            // stops redrawing.
            let remaining = liftDeadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            // A newer revision replaces this task; it must not pause the timeline for the lifts
            // that revision started, so cancellation ends it here.
            do { try await Task.sleep(for: .seconds(remaining + 0.05)) } catch { return }
            memory.prune(at: .now)
            liftDeadline = .distantPast
        }
    }

    // MARK: Drawing

    /// Haze strength per state. Hypothesis, picked by eye on the demo wall and the synthetic
    /// replay: unseen must read as "not done" over a bright wall; seen must be visibly lighter
    /// than unseen but still clearly not clear. Full strength (with the regular material and a
    /// 50% wash) whited out the wall the homeowner is walking toward, so unseen stays below it
    /// and the wall's shapes show through. Tune on device in sun.
    nonisolated static func haze(_ state: CellState) -> Double {
        switch state {
        case .unseen: 0.75
        case .seen: 0.35
        // Hidden is drawn by `veil`: frost would say "not looked at yet", and it was.
        case .covered, .skipped, .hidden: 0
        }
    }

    /// Strength of the dark veil and outline per state: only a hidden stretch has one.
    nonisolated static func veil(_ state: CellState) -> Double {
        state == .hidden ? 1 : 0
    }

}

/// One frame of fog: which cells are hazy, lifting, veiled, skipped or requested, at a moment in time.
private struct FogFrame {
    var coverage: CoverageStrip
    var wall: WallGeometry
    var projection: CameraProjection
    var highlight: GapRequest?
    var lifts: [FogMemory.Key: FogMemory.Lift]
    var now: Date
    /// Points a lifting cell rises; zero with Reduce Motion, which keeps only the fade.
    var drift: CGFloat

    private struct Cell {
        var quad: Path
        var level: Double
        var lift: CGFloat
    }

    private struct Layers {
        var haze: [Cell] = []
        var skipped: [Path] = []
        var amber: [Path] = []
        /// Per-cell veil fills, blurred together so a stretch reads as one shadow.
        var veil: [(quad: Path, level: Double)] = []
        /// One outline per run of hidden cells in a band, so the dash runs on unbroken.
        var outlines: [(path: Path, level: Double)] = []
    }

    private func layers(size: CGSize) -> Layers {
        let geometry = WallProjection(projection: projection, wall: wall, size: size)
        let visible = coverage.visibleRange
        var layers = Layers()
        guard visible.upperBound > visible.lowerBound else { return layers }
        for band in CoverageBand.allCases {
            let states = coverage.cells(band)
            // The hidden run being collected: its clipped s edges and its strongest veil.
            var run: (edges: [Float], level: Double)?
            func closeRun() {
                if let edges = run?.edges, let level = run?.level, let outline = outline(band, edges, geometry) {
                    layers.outlines.append((outline, level))
                }
                run = nil
            }
            for index in states.indices {
                let range = coverage.cellRange(index)
                guard FogMemory.interiorsOverlap(range, visible) else { closeRun(); continue }
                let clipped = max(range.lowerBound, visible.lowerBound)...min(range.upperBound, visible.upperBound)
                guard let quad = quad(band, clipped, geometry) else { closeRun(); continue }
                let state = states[index]
                if let gap = highlight, gap.band == band, FogMemory.interiorsOverlap(gap.span, range), state != .covered {
                    layers.amber.append(quad)
                    closeRun()
                    continue
                }
                if state == .skipped { layers.skipped.append(quad) }
                let hazeTarget = FogOverlay.haze(state)
                let veilTarget = FogOverlay.veil(state)
                var haze = hazeTarget, veil = veilTarget, rise: CGFloat = 0
                if let lift = lifts[FogMemory.Key(band: band, index: index)], let progress = lift.progress(at: now), progress < 1 {
                    let eased = 1 - pow(1 - progress, 3)
                    haze = lift.from + (hazeTarget - lift.from) * eased
                    veil = lift.fromVeil + (veilTarget - lift.fromVeil) * eased
                    rise = lift.drifts ? CGFloat(eased) : 0
                }
                if haze > 0 { layers.haze.append(Cell(quad: quad, level: haze, lift: rise)) }
                if veil > 0 { layers.veil.append((quad, veil)) }
                if state == .hidden {
                    var current = run ?? ([clipped.lowerBound], 0)
                    current.edges.append(clipped.upperBound)
                    current.level = max(current.level, veil)
                    run = current
                } else {
                    closeRun()
                }
            }
            closeRun()
        }
        return layers
    }

    /// Haze cells in one blurred layer, so neighbours merge into one bank of fog; lifting cells
    /// rise a few points as they thin out.
    func drawHaze(in context: inout GraphicsContext, size: CGSize, color: Color) {
        let haze = layers(size: size).haze
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 9))
            for cell in haze {
                var shifted = layer
                shifted.translateBy(x: 0, y: -drift * cell.lift)
                shifted.fill(cell.quad, with: .color(color.opacity(cell.level)))
            }
        }
    }

    /// Skipped cells get a slate hatch, so "can't get there" never reads as clear or as fog;
    /// hidden stretches get a dark veil and a dashed violet outline; requested cells glow amber.
    func drawMarks(in context: inout GraphicsContext, size: CGSize) {
        let layers = layers(size: size)
        if !layers.veil.isEmpty {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                for cell in layers.veil {
                    layer.fill(cell.quad, with: .color(.black.opacity(0.42 * cell.level)))
                }
            }
        }
        // The map's dash, lengthened for the larger shapes on the camera.
        let dash = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: Palette.hiddenDash.map { $0 * 1.6 })
        for outline in layers.outlines {
            // A dark halo under the dash keeps it legible on a sunlit wall.
            context.stroke(outline.path, with: .color(.black.opacity(0.35 * outline.level)), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
            context.stroke(outline.path, with: .color(Palette.hidden.opacity(outline.level)), style: dash)
        }
        for quad in layers.skipped {
            context.fill(quad, with: .color(Palette.skipped.opacity(0.3)))
            var hatched = context
            hatched.clip(to: quad)
            let bounds = quad.boundingRect
            var lines = Path()
            var x = bounds.minX - bounds.height
            while x < bounds.maxX {
                lines.move(to: CGPoint(x: x, y: bounds.maxY))
                lines.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
                x += 10
            }
            hatched.stroke(lines, with: .color(.white.opacity(0.55)), lineWidth: 1.5)
        }
        for quad in layers.amber {
            context.fill(quad, with: .color(Palette.caution.opacity(0.34)))
            context.stroke(quad, with: .color(Palette.caution.opacity(0.9)), lineWidth: 1.5)
        }
    }

    /// The outline of a run of cells whose s edges are `edges`, through every cell edge so it
    /// follows the wall round a corner. Nil when any point is behind the camera.
    private func outline(_ band: CoverageBand, _ edges: [Float], _ geometry: WallProjection) -> Path? {
        let corners: [SIMD3<Float>] = switch band {
        case .wall:
            edges.map { wall.world(s: $0, height: coverage.wallBandHeight) } + edges.reversed().map { wall.world(s: $0, height: 0) }
        case .ground:
            edges.map { wall.world(s: $0, height: 0, out: coverage.groundBandDepth) } + edges.reversed().map { wall.world(s: $0, height: 0) }
        }
        return geometry.polygon(corners)
    }

    private func quad(_ band: CoverageBand, _ range: ClosedRange<Float>, _ geometry: WallProjection) -> Path? {
        switch band {
        case .wall:
            geometry.wallQuad(s: range, height: 0...coverage.wallBandHeight)
        case .ground:
            geometry.groundQuad(s: range, out: 0...coverage.groundBandDepth)
        }
    }
}

/// Remembers the last cell states so a new revision can be diffed into lifts.
@MainActor
final class FogMemory {
    struct Key: Hashable {
        var band: CoverageBand
        var index: Int
    }

    struct Lift {
        /// Haze and veil strength when the change began.
        var from: Double
        var fromVeil: Double
        var start: Date
        /// Rises as it thins: only fog lifting off something the phone saw.
        var drifts: Bool

        func progress(at now: Date) -> Double? {
            let t = now.timeIntervalSince(start) / Motion.fogLift
            return t < 0 ? 0 : t
        }
    }

    private var firstCellS: Float = 0
    private var states: [Key: CellState] = [:]
    private(set) var lifts: [Key: Lift] = [:]

    func seed(_ coverage: CoverageStrip) {
        firstCellS = coverage.firstCellS
        states = Self.snapshot(coverage)
    }

    /// Records a lift for every cell whose haze went down or whose veil changed. Returns true
    /// when any lift started.
    /// Cells inside `highlight` are drawn amber, not fogged, so they get no lift.
    func update(to coverage: CoverageStrip, at now: Date, highlight: GapRequest?) -> Bool {
        // The strip can grow to the left, which shifts every index; realign by s.
        let shift = Int(((firstCellS - coverage.firstCellS) / coverage.cellWidth).rounded())
        let next = Self.snapshot(coverage)
        if shift != 0 {
            lifts = Dictionary(uniqueKeysWithValues: lifts.map { (Key(band: $0.key.band, index: $0.key.index + shift), $0.value) })
        }
        var started = false
        for (key, state) in next {
            let oldKey = Key(band: key.band, index: key.index - shift)
            let old = states[oldKey] ?? .unseen
            if let highlight, highlight.band == key.band,
               Self.interiorsOverlap(highlight.span, coverage.cellRange(key.index)) {
                continue
            }
            let thinned = FogOverlay.haze(state) < FogOverlay.haze(old)
            if thinned || FogOverlay.veil(state) != FogOverlay.veil(old) {
                lifts[key] = Lift(
                    from: FogOverlay.haze(old), fromVeil: FogOverlay.veil(old), start: now,
                    drifts: thinned && state != .hidden
                )
                started = true
            }
        }
        states = next
        firstCellS = coverage.firstCellS
        return started
    }

    /// True when the ranges share more than an endpoint. `ClosedRange.overlaps` is also true
    /// for ranges that only touch, which would tint the cells either side of a gap.
    nonisolated static func interiorsOverlap(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    func prune(at now: Date) {
        lifts = lifts.filter { ($0.value.progress(at: now) ?? 1) < 1 }
    }

    private static func snapshot(_ coverage: CoverageStrip) -> [Key: CellState] {
        var result: [Key: CellState] = [:]
        for band in CoverageBand.allCases {
            for (index, state) in coverage.cells(band).enumerated() {
                result[Key(band: band, index: index)] = state
            }
        }
        return result
    }
}
