import Foundation
import simd

/// What the ground is (scene.schema.json `ground[].type`).
public enum SceneGroundType: String, Sendable, CaseIterable {
    case drive, concrete, gravel, lawn, mulch, deck
}

extension SceneWall {
    /// The ground that ground coverage spans (`coverage.observed` band `ground`) vouch for, as plan
    /// polygons of [x, z] world meters, for patches of the ground type the homeowner gave.
    ///
    /// A span says the ground in front of the wall was seen over its stretch of s from the wall
    /// line out to its reach. On each piece of the chain, the spans over it that touch (within
    /// `joinGap`) make one stepped polygon: from the wall line out to each span's reach, on that
    /// piece's line and out along its outward. Where two joined spans leave a gap between them,
    /// the gap takes the smaller reach. Nothing else is drawn:
    ///
    /// - Past `extent` (the chain's ends as exported) nothing: the homeowner answered for the
    ///   ground along the wall, and past a limit end the ground may be a neighbour's.
    /// - Outside a corner that turns away from the homeowner, the wedge between the two pieces'
    ///   polygons is left out. The coverage samples each piece's ground on its own line; no
    ///   sample lies in that wedge.
    /// - At a corner that turns toward the homeowner, each polygon is cut at the neighbouring
    ///   piece's line, which it crosses when the corner is sharper than 90 degrees: past that
    ///   line is the house. The cut follows the whole line, not only the neighbour's stretch, so
    ///   beside a neighbour shorter than the reach it can also remove ground past that
    ///   neighbour's far end. It only ever removes ground.
    /// - A span that reaches no distance out (`out` of 0, negative or not finite) vouches for no
    ///   area and gives nothing. scene.json requires `out_ft` on ground spans, so a ground span
    ///   without a reach is not a valid entry and says nothing about how far out anything was
    ///   seen; `ObservedSpan` cannot express one.
    ///
    /// `inset` pulls every edge that bounds what was seen (each run's two ends, each step's top
    /// and each riser between steps, toward the lower step) that far inward, so rounding the
    /// vertices afterwards can't carry the polygon past the spans. `behind` moves the edge on
    /// the wall line (and the cut at an inside corner) that far behind the line, into the house,
    /// so rounding can't leave a sliver between the polygon and the wall either. Polygons under
    /// `minimumArea` square meters (slivers left by clipping) are dropped.
    public func groundPatchPolygons(
        over spans: [ObservedSpan], within extent: ClosedRange<Float>, joinGap: Float, inset: Float, behind: Float
    ) -> [[SIMD2<Float>]] {
        let segments = chain.segments
        let origin = SIMD2(meter.x, meter.z)
        func plan(_ v: SIMD3<Float>) -> SIMD2<Float> { SIMD2(v.x, v.z) }
        let usable = spans.filter { $0.out.isFinite && $0.out > 2 * inset }.sorted { $0.span.lowerBound < $1.span.lowerBound }
        var polygons: [[SIMD2<Float>]] = []
        for (index, piece) in segments.enumerated() {
            let clipped = usable.compactMap { item -> ObservedSpan? in
                let low = max(item.span.lowerBound, piece.span.lowerBound, extent.lowerBound)
                let high = min(item.span.upperBound, piece.span.upperBound, extent.upperBound)
                return high - low > 2 * inset ? ObservedSpan(span: low...high, out: item.out) : nil
            }
            var runs: [[ObservedSpan]] = []
            for item in clipped {
                if let last = runs.last?.last, item.span.lowerBound - last.span.upperBound <= joinGap {
                    runs[runs.count - 1].append(item)
                } else {
                    runs.append([item])
                }
            }
            let base = origin + plan(piece.anchor)
            func point(_ s: Float, _ out: Float) -> SIMD2<Float> {
                base + plan(piece.along) * (s - piece.anchorS) + plan(piece.outward) * out
            }
            for run in runs {
                var polygon = Self.steppedOutline(run, inset: inset, behind: behind).map { point($0.s, $0.out) }
                for neighbour in [index - 1, index + 1] where segments.indices.contains(neighbour) {
                    let other = segments[neighbour]
                    let (left, right) = neighbour < index ? (other, piece) : (piece, other)
                    // The right piece turns toward the homeowner: an inside corner.
                    guard simd_dot(plan(right.along), plan(left.outward)) > 0 else { continue }
                    let corner = point(neighbour < index ? piece.span.lowerBound : piece.span.upperBound, 0)
                    polygon = Self.clip(polygon, toFrontOf: corner - plan(other.outward) * behind, outward: plan(other.outward))
                }
                if polygon.count >= 3, abs(Self.signedArea(polygon)) >= Self.minimumArea { polygons.append(polygon) }
            }
        }
        return polygons
    }

    /// The outline of a run of spans on one piece, in (s, out), counterclockwise from the wall
    /// line's left end: along the line (at `-behind`), up the right end, then back leftward over
    /// each span's top with a riser between neighbours. See `groundPatchPolygons` for `inset`.
    static func steppedOutline(_ run: [ObservedSpan], inset: Float, behind: Float) -> [(s: Float, out: Float)] {
        guard let first = run.first, let last = run.last else { return [] }
        // Risers: between spans i and i + 1, at the edge of the gap on the lower one's far side,
        // moved `inset` toward the higher one, so the higher reach never overhangs the lower span.
        var edges = [first.span.lowerBound + inset]
        for (a, b) in zip(run, run.dropFirst()) {
            if a.out < b.out {
                edges.append(b.span.lowerBound + inset)
            } else if a.out > b.out {
                edges.append(a.span.upperBound - inset)
            } else {
                edges.append((a.span.upperBound + b.span.lowerBound) / 2)
            }
        }
        edges.append(last.span.upperBound - inset)
        var outline: [(s: Float, out: Float)] = [(edges[0], -behind), (edges[run.count], -behind)]
        for step in run.indices.reversed() {
            outline.append((edges[step + 1], run[step].out - inset))
            outline.append((edges[step], run[step].out - inset))
        }
        return outline
    }

    /// 1 cm². A clipped rectangle smaller than this is a sliver along a corner's line.
    static let minimumArea: Float = 1e-4

    /// The part of a polygon on the front side of a line (Sutherland-Hodgman, one edge). Exact
    /// for a convex polygon, and for a stepped outline, whose every cross-section along its wall
    /// is one interval.
    static func clip(_ polygon: [SIMD2<Float>], toFrontOf point: SIMD2<Float>, outward: SIMD2<Float>) -> [SIMD2<Float>] {
        let side = { (p: SIMD2<Float>) in simd_dot(p - point, outward) }
        var result: [SIMD2<Float>] = []
        for (index, current) in polygon.enumerated() {
            let next = polygon[(index + 1) % polygon.count]
            let a = side(current)
            let b = side(next)
            if a >= 0 { result.append(current) }
            // Only a strict crossing: an end on the line is a vertex already.
            if (a > 0 && b < 0) || (a < 0 && b > 0) { result.append(current + (next - current) * (a / (a - b))) }
        }
        // A vertex within Float noise of the line can come out twice.
        var distinct: [SIMD2<Float>] = []
        for p in result where distinct.last.map({ simd_distance($0, p) > 1e-6 }) ?? true { distinct.append(p) }
        if distinct.count > 1, let first = distinct.first, let last = distinct.last, simd_distance(first, last) <= 1e-6 {
            distinct.removeLast()
        }
        return distinct
    }

    /// Shoelace area, positive when the points run counterclockwise in [x, z].
    static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        var twice: Float = 0
        for (index, p) in polygon.enumerated() {
            let q = polygon[(index + 1) % polygon.count]
            twice += p.x * q.y - q.x * p.y
        }
        return twice / 2
    }
}
