import Foundation
import simd

// Facing gap and headroom measured on the LiDAR mesh, per docs/00-overview.md ("Conventions the
// code relies on"): a ray straight out from the wall at 1.5 ft for the passage in front, and a ray
// straight up from 1 ft out for what is overhead. The mesh has holes, so each measurement is the
// smallest over a small fan of rays, and a ray that meets nothing within the LiDAR's range says
// nothing: unknown, never open.

/// How the mesh is probed. Every value is a guess unless its comment says where it comes from.
public struct MeshProbeConfig: Sendable, Equatable {
    /// Height of the facing rays above the ground: 1.5 ft, the facing ray in docs/00 (Conventions).
    public var facingHeight: Float = 0.4572
    /// How far out from the wall the headroom rays start: 1 ft, the headroom ray in docs/00 (Conventions).
    public var overheadOut: Float = 0.3048
    /// A ray meeting nothing within this is unknown: about 5 m, the LiDAR range in docs/00 (Conventions).
    public var maxRange: Float = 5
    /// Hits nearer than this to a ray's start are ignored, so the wall or ground the ray starts on
    /// is not measured as an obstruction. A guess: the wall and ground planes are placed to a few
    /// centimetres and mulch or edging stands a little proud of the ground. Where the plane is off
    /// by more, the ray meets the wall or ground itself and reports a short distance, which can
    /// only fail a check, never pass one.
    public var minRange: Float = 0.15
    /// Half-angle of the fan: 3 degrees. A guess: at 2 m it spreads the rays 10 cm either side,
    /// enough to bridge a small hole, while a ray tilted down from 1.5 ft still meets flat ground
    /// only 8.7 m out, past `maxRange`, and a ray tilted from 1 ft out toward the wall meets it
    /// 5.8 m up, also past `maxRange`.
    public var fanAngle: Float = 3 * .pi / 180
    /// Measured distances are rounded down to 0.1 ft so neighbouring cells merge into few spans,
    /// as `CoverageConfig.overheadQuantum` does. It costs at most 0.1 ft.
    public var quantum: Float = 0.03048

    public init() {}
}

public extension TriangleMesh {
    /// The facing gap over one stretch of wall, meters: from each of two points (a quarter and
    /// three quarters along `cell`) at `facingHeight` on the wall, a fan of five rays (straight
    /// out along the wall piece's outward, and tilted `fanAngle` left, right, up and down), and of
    /// every hit the distance straight out from the wall. The smallest of those; nil when no ray
    /// hits within `maxRange`.
    func facingDepth(wall: WallFrame, cell: ClosedRange<Float>, config: MeshProbeConfig = MeshProbeConfig()) -> Float? {
        smallest(over: cell, config: config) { s in
            let piece = wall.segment(atS: s)
            return (wall.world(s: s, height: config.facingHeight), piece.outward, piece.along, WallFrame.up)
        }
    }

    /// The headroom over one stretch of wall, meters: from each of two points (a quarter and three
    /// quarters along `cell`) on the ground `overheadOut` from the wall, a fan of five rays (straight
    /// up, and tilted `fanAngle` along the wall both ways and toward and away from it), and of
    /// every hit the height above the ground. The smallest of those; nil when no ray hits within
    /// `maxRange`.
    func overheadClearance(wall: WallFrame, cell: ClosedRange<Float>, config: MeshProbeConfig = MeshProbeConfig()) -> Float? {
        smallest(over: cell, config: config) { s in
            let piece = wall.segment(atS: s)
            return (wall.world(s: s, height: 0, out: config.overheadOut), WallFrame.up, piece.along, piece.outward)
        }
    }

    /// `facingDepth` for each cell of width `cellWidth` (the coverage grid: cell i spans
    /// [i w, (i + 1) w]) overlapping `range`, clipped to it, rounded down to `quantum`, with
    /// touching cells of equal depth merged. Cells with no hit are left out.
    func facingSpans(
        wall: WallFrame, over range: ClosedRange<Float>, cellWidth: Float = CoverageConfig().cellWidth,
        config: MeshProbeConfig = MeshProbeConfig()
    ) -> [ObservedSpan] {
        spans(over: range, cellWidth: cellWidth, quantum: config.quantum) { facingDepth(wall: wall, cell: $0, config: config) }
    }

    /// `overheadClearance` per cell, as `facingSpans`.
    func overheadSpans(
        wall: WallFrame, over range: ClosedRange<Float>, cellWidth: Float = CoverageConfig().cellWidth,
        config: MeshProbeConfig = MeshProbeConfig()
    ) -> [ObservedSpan] {
        spans(over: range, cellWidth: cellWidth, quantum: config.quantum) { overheadClearance(wall: wall, cell: $0, config: config) }
    }

    /// The smallest distance along `main` of any hit of the fans cast from the two sample points
    /// of `cell`. `ray(s)` gives the start, the main direction and the two directions the fan
    /// tilts toward.
    private func smallest(
        over cell: ClosedRange<Float>, config: MeshProbeConfig,
        ray: (_ s: Float) -> (origin: SIMD3<Float>, main: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>)
    ) -> Float? {
        let width = cell.upperBound - cell.lowerBound
        let c = cos(config.fanAngle)
        let t = sin(config.fanAngle)
        var best: Float?
        for s in [cell.lowerBound + width * 0.25, cell.lowerBound + width * 0.75] {
            let (origin, main, a, b) = ray(s)
            for direction in [main, main * c + a * t, main * c - a * t, main * c + b * t, main * c - b * t] {
                guard let hit = firstHit(Ray(origin: origin, direction: simd_normalize(direction)), within: config.minRange...config.maxRange) else { continue }
                let along = hit * simd_dot(simd_normalize(direction), main)
                best = min(best ?? along, along)
            }
        }
        return best
    }

    private func spans(over range: ClosedRange<Float>, cellWidth: Float, quantum: Float, measure: (ClosedRange<Float>) -> Float?) -> [ObservedSpan] {
        // The tolerance keeps a range that ends on a cell edge from picking up the next cell
        // (as `CoverageMap.indices(overlapping:)`).
        let tolerance = cellWidth * 1e-3
        let first = Int(((range.lowerBound + tolerance) / cellWidth).rounded(.down))
        let last = max(first, Int(((range.upperBound - tolerance) / cellWidth).rounded(.down)))
        let items = (first...last).compactMap { index -> ObservedSpan? in
            let cell = (Float(index) * cellWidth)...(Float(index + 1) * cellWidth)
            let clipped = cell.clamped(to: range)
            guard clipped.upperBound > clipped.lowerBound, let value = measure(clipped) else { return nil }
            return ObservedSpan(span: clipped, out: (value / quantum).rounded(.down) * quantum)
        }
        return ObservedSpan.merge(items, touching: cellWidth * 0.01)
    }
}
