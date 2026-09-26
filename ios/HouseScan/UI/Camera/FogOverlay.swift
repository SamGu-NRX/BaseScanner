import SwiftUI

/// The haze over the parts of the wall and ground the phone hasn't seen yet.
///
/// Unseen cells carry a soft frosted haze, seen cells a thinner one, covered cells none. When a
/// cell's state changes (a new `coverage.revision`), its haze fades and drifts upward over
/// `Motion.fogLift`, like mist lifting: the signature moment that tells the homeowner "the phone
/// saw that" without a word. The haze is guidance, never proof that space is clear.
///
/// A gap request replaces the fog on its cells with an amber highlight, so the camera itself
/// shows where to aim.
struct FogOverlay: View {
    var coverage: CoverageStrip
    var wall: WallGeometry
    var projection: CameraProjection
    var highlight: GapRequest?

    @State private var memory = FogMemory()
    @State private var liftDeadline = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || liftDeadline < .now)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { memory.seed(coverage) }
        .onChange(of: coverage.revision) { _, _ in
            if memory.update(to: coverage, at: .now, animate: !reduceMotion) {
                liftDeadline = Date.now.addingTimeInterval(Motion.fogLift)
            }
        }
        .task(id: liftDeadline) {
            // Ends the timeline once the last lift has finished, so a still replay frame
            // stops redrawing.
            let remaining = liftDeadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(remaining + 0.05))
            memory.prune(at: .now)
            liftDeadline = .distantPast
        }
    }

    // MARK: Drawing

    /// Haze strength per state. Hypothesis, picked by eye on the demo wall: unseen must read
    /// as "not done" over a bright wall; seen must be visibly lighter than unseen but still
    /// clearly not clear. Tune on device in sun.
    static func haze(_ state: CellState) -> Double {
        switch state {
        case .unseen: 1
        case .seen: 0.42
        case .covered, .skipped: 0
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let geometry = WallProjection(projection: projection, wall: wall, size: size)
        let visible = coverage.visibleRange
        guard visible.upperBound > visible.lowerBound else { return }
        let fogColor = Color(white: 0.97)
        let gapCells = highlight.map { gap in
            (band: gap.band, span: gap.span)
        }

        var steady: [(Path, Double)] = []
        var lifting: [(Path, Double, CGFloat)] = []
        var amber: [Path] = []
        var skipped: [Path] = []

        for band in CoverageBand.allCases {
            let states = coverage.cells(band)
            for index in states.indices {
                let range = coverage.cellRange(index)
                guard range.overlaps(visible) else { continue }
                let clipped = max(range.lowerBound, visible.lowerBound)...min(range.upperBound, visible.upperBound)
                guard let quad = quad(band, clipped, geometry) else { continue }
                let state = states[index]

                if let gapCells, gapCells.band == band, gapCells.span.overlaps(range), state != .covered {
                    amber.append(quad)
                    continue
                }
                if state == .skipped {
                    skipped.append(quad)
                }
                let key = FogMemory.Key(band: band, index: index)
                let target = Self.haze(state)
                if let lift = memory.lifts[key], let progress = lift.progress(at: now), progress < 1 {
                    let eased = 1 - pow(1 - progress, 3)
                    let level = lift.from + (target - lift.from) * eased
                    lifting.append((quad, level, CGFloat(eased)))
                } else if target > 0 {
                    steady.append((quad, target))
                }
            }
        }

        // Soft, merged haze: one blurred layer so neighbouring cells read as one bank of fog.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 10))
            for (quad, level) in steady {
                layer.fill(quad, with: .color(fogColor.opacity(0.55 * level)))
            }
        }
        // Lifting cells rise a few points as they thin out.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 12))
            for (quad, level, eased) in lifting {
                var shifted = layer
                shifted.translateBy(x: 0, y: -10 * eased)
                shifted.fill(quad, with: .color(fogColor.opacity(0.55 * level)))
            }
        }
        // Skipped cells: a slate hatch, so "can't get there" never reads as clear or as fog.
        for quad in skipped {
            context.fill(quad, with: .color(Palette.skipped.opacity(0.28)))
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
        for quad in amber {
            context.fill(quad, with: .color(Palette.caution.opacity(0.34)))
            context.stroke(quad, with: .color(Palette.caution.opacity(0.9)), lineWidth: 1.5)
        }
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
        var from: Double
        var start: Date

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

    /// Records a lift for every cell whose haze went down. Returns true when any lift started.
    func update(to coverage: CoverageStrip, at now: Date, animate: Bool) -> Bool {
        // The strip can grow to the left, which shifts every index; realign by s.
        let shift = Int(((firstCellS - coverage.firstCellS) / coverage.cellWidth).rounded())
        let next = Self.snapshot(coverage)
        if shift != 0 {
            lifts = Dictionary(uniqueKeysWithValues: lifts.map { (Key(band: $0.key.band, index: $0.key.index + shift), $0.value) })
        }
        var started = false
        if animate {
            for (key, state) in next {
                let oldKey = Key(band: key.band, index: key.index - shift)
                let old = states[oldKey] ?? .unseen
                if FogOverlay.haze(state) < FogOverlay.haze(old) {
                    lifts[key] = Lift(from: FogOverlay.haze(old), start: now)
                    started = true
                }
            }
        }
        states = next
        firstCellS = coverage.firstCellS
        return started
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
