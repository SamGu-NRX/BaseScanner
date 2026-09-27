import SwiftUI
import simd

/// The crisp lines over the live fog, which a soft mask can't draw: a dashed violet outline
/// round each stretch hidden behind something, a slate hatch where the homeowner said "I can't
/// get there", and an amber outline round the stretch a gap request asks for. The same marks
/// and dash the tape map uses, so the camera and the map read alike.
struct FogMarks: View {
    var coverage: CoverageStrip
    var wall: WallGeometry
    var projection: CameraProjection
    var highlight: GapRequest?

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let geometry = WallProjection(projection: projection, wall: wall, size: size)
            let runs = runs()
            // The map's dash, lengthened for the larger shapes on the camera.
            let dash = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: Palette.hiddenDash.map { $0 * 1.6 })
            for run in runs.hidden {
                guard let outline = outline(run.band, run.edges, geometry) else { continue }
                // A dark halo under the dash keeps it legible on a sunlit wall.
                context.stroke(outline, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                context.stroke(outline, with: .color(Palette.hidden), style: dash)
            }
            for run in runs.skipped {
                guard let quad = outline(run.band, run.edges, geometry) else { continue }
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
            if let requested = runs.requested, let outline = outline(requested.band, requested.edges, geometry) {
                context.stroke(outline, with: .color(.black.opacity(0.3)), style: StrokeStyle(lineWidth: 4, lineJoin: .round))
                context.stroke(outline, with: .color(Palette.caution), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Run {
        var band: CoverageBand
        /// The s of every cell edge along the run, clipped to the visible range.
        var edges: [Float]
    }

    /// Runs of hidden and of skipped cells in each band, and the requested cells not yet covered.
    private func runs() -> (hidden: [Run], skipped: [Run], requested: Run?) {
        var hidden: [Run] = [], skipped: [Run] = []
        var requested: Run?
        let visible = coverage.visibleRange
        guard visible.upperBound > visible.lowerBound else { return ([], [], nil) }
        for band in CoverageBand.allCases {
            let states = coverage.cells(band)
            var current: (state: CellState, run: Run)?
            func close() {
                if let current {
                    if current.state == .hidden { hidden.append(current.run) } else { skipped.append(current.run) }
                }
                current = nil
            }
            for index in states.indices {
                let range = coverage.cellRange(index)
                guard range.upperBound > visible.lowerBound, range.lowerBound < visible.upperBound else { close(); continue }
                let s0 = max(range.lowerBound, visible.lowerBound), s1 = min(range.upperBound, visible.upperBound)
                let state = states[index]
                let isRequested = highlight.map { $0.band == band && $0.span.lowerBound < range.upperBound && range.lowerBound < $0.span.upperBound } ?? false
                if isRequested, state != .covered {
                    close()
                    if var run = requested, run.band == band, let last = run.edges.last, abs(last - s0) < 1e-4 {
                        run.edges.append(s1)
                        requested = run
                    } else if requested == nil {
                        requested = Run(band: band, edges: [s0, s1])
                    }
                    continue
                }
                guard state == .hidden || state == .skipped else { close(); continue }
                if var open = current, open.state == state {
                    open.run.edges.append(s1)
                    current = open
                } else {
                    close()
                    current = (state, Run(band: band, edges: [s0, s1]))
                }
            }
            close()
        }
        return (hidden, skipped, requested)
    }

    /// The outline of a run through every cell edge, so it follows the wall round a corner. Nil
    /// when any point is behind the camera.
    private func outline(_ band: CoverageBand, _ edges: [Float], _ geometry: WallProjection) -> Path? {
        let corners: [SIMD3<Float>] = switch band {
        case .wall:
            edges.map { wall.world(s: $0, height: coverage.wallBandHeight) } + edges.reversed().map { wall.world(s: $0, height: 0) }
        case .ground:
            edges.map { wall.world(s: $0, height: 0, out: coverage.groundBandDepth) } + edges.reversed().map { wall.world(s: $0, height: 0) }
        }
        return geometry.polygon(corners)
    }
}
