import Foundation
import simd

// Where the open space in front of the wall ends: the far wall of a corridor, the fence of a
// side yard. On the build 5.1 and 7.1 field tests the capture treated that surface as something
// standing in front of the wall to look past (#160), and sent the homeowner after a walk-out line
// behind it (#164). On build 7.1, a phone without LiDAR, ARKit's vertical plane detection had
// found the far wall, and it runs with and without LiDAR, so the planes are what marks it here.
// The LiDAR mesh measures it too (`TriangleMesh.facingSpans`), but only once, at upload: ray casts
// over the whole mesh take too long to run during the walk.

/// Which detected planes count as the surface where the space ends. Every value is a guess unless
/// its comment says where it comes from.
public struct FarSurfaceConfig: Sendable, Equatable {
    /// Nearer the wall than this a plane is taken for the wall itself: ARKit's plane of the house
    /// wall lies within a few centimetres to decimetres of the wall line (a tapped line is off by
    /// 0.3 ft and more), and a space narrower than this is not one anyone walks in. It holds for
    /// the whole plane, not only where a cell meets it: a wall's own plane turned a few degrees
    /// off the piece's line drifts past it a few meters along. A guess.
    public var minOut: Float = 0.5
    /// Farther than this a plane says nothing about the space in front of the wall: 5 m, the
    /// mesh probe's reach (`MeshProbeConfig.maxRange`).
    public var maxOut: Float = MeshProbeConfig().maxRange
    /// A plane turned more than this from the wall's line doesn't face it. A guess: on the build
    /// 7.1 field test the corridor's far wall was found within 6 to 11 degrees of parallel (#164).
    public var maxAngle: Float = 20 * .pi / 180
    /// A plane narrower than this along the wall is more likely a box or a bin than a fence or a
    /// wall: 1.2 m, wider than an AC unit (about 0.9 m, `SceneExport.acAssumedSide`). A guess.
    public var minWidth: Float = 1.2
    /// A plane shorter than this can be looked over, or is something low standing in the space:
    /// 1 m, above an AC unit's top and below a fence's. A guess.
    public var minHeight: Float = 1.0
    /// A plane must stand on the ground to end the space there: where a cell meets it, its
    /// outline has to cover the point this far above the ground (`WallFrame.groundY`), reaching
    /// down to within this of the ground and rising above it (`Candidate.standsOnGround`). One that stops higher, such as an eave, a
    /// bay window or an upper storey across a walkway, leaves open ground under it, or ARKit
    /// hasn't seen what stands under it. One whose top stays below that level is sunk into the
    /// ground, like the far side of a window well. 0.5 m covers the 0.3 m error of a guessed
    /// ground (`ScanEngine.estimatedGroundError`) plus 0.2 m of the foot of a fence or wall that
    /// ARKit's outline hasn't grown down to yet. The 0.2 m is a guess: no field capture has
    /// measured how close to the ground ARKit's outlines reach (review of #168). With the ground
    /// guessed 0.3 m too high, a plane whose outline stops 0.8 m above the real ground still
    /// counts, and so does one rising only 0.5 m above the ground with the rest of it below.
    public var maxGroundGap: Float = 0.5
    /// How far past a plane's outline, along it, a cell may still be in front of it: 0.15 m, one
    /// coverage cell, as ARKit's outline grows behind what the camera has seen. A guess.
    public var outlineMargin: Float = 0.15
    /// Distances are rounded down to 0.1 ft, as the mesh's are (`MeshProbeConfig.quantum`), so
    /// neighbouring cells merge into few spans. It costs at most 0.1 ft.
    public var quantum: Float = MeshProbeConfig().quantum

    public init() {}
}

public enum FarSurface {
    /// How far out from the wall the space in front of it visibly ends, per cell of width
    /// `cellWidth` (the coverage grid) overlapping `range`, clipped to it, meters: from each of two
    /// points (a quarter and three quarters along the cell) on the wall's line, straight out along
    /// the piece's outward, the distance to the nearest detected plane that faces the wall
    /// (within `maxAngle` of parallel, `minOut` to `maxOut` out, at least `minWidth` wide and
    /// `minHeight` tall, standing on the ground within `maxGroundGap`, of any class but a door or
    /// a window) and whose outline, along the plane, reaches the point it is met at. The smaller
    /// of the two, rounded down to `quantum`, with touching cells of equal distance merged. Cells
    /// with no such plane are left out.
    ///
    /// A plane whose outline comes within `minOut` of the line of the nearest piece parallel to
    /// it, or crosses it, at either end is the wall's own, or runs into it, and never counts
    /// (`Candidate.clearsWall`): replayed on the build 7.1 corridor, the corridor wall's own
    /// plane, turned about 11 degrees off the chain's piece, passed `minOut` two thirds of the
    /// way along and came out as a far surface under 3 ft out. Nor does the plane the meter's
    /// wall was refit to (`excluding`, by id).
    ///
    /// A plane is ARKit's fit to a surface, not a measurement of what stands between it and the
    /// wall: it says where the space ends, never that the space before it is clear.
    public static func spans(
        planes: [WallPlaneEvidence], wall: WallFrame, over range: ClosedRange<Float>,
        cellWidth: Float = CoverageConfig().cellWidth, excluding ids: Set<String> = [],
        config: FarSurfaceConfig = FarSurfaceConfig()
    ) -> [ObservedSpan] {
        let facing = planes.filter { !ids.contains($0.id) }.compactMap { Candidate($0, wall: wall, config: config) }
        guard !facing.isEmpty else { return [] }
        let cosLimit = cos(config.maxAngle)
        func distance(atS s: Float) -> Float? {
            let piece = wall.segment(atS: s)
            let foot = wall.world(s: s, height: 0)
            var best: Float?
            for plane in facing {
                // Both are unit and horizontal: the cosine of the angle between the wall's line
                // and the plane's.
                let turn = simd_dot(piece.outward, plane.normal)
                guard abs(turn) >= cosLimit else { continue }
                let out = simd_dot(plane.center - foot, plane.normal) / turn
                guard out >= config.minOut, out <= config.maxOut else { continue }
                let along = simd_dot(foot + piece.outward * out - plane.center, plane.along)
                guard along >= plane.first - config.outlineMargin, along <= plane.last + config.outlineMargin else { continue }
                guard plane.standsOnGround(at: along, groundY: wall.groundY, config: config) else { continue }
                best = min(best ?? out, out)
            }
            return best
        }
        // The tolerance keeps a range that ends on a cell edge from picking up the next cell
        // (as `CoverageMap.indices(overlapping:)`).
        let tolerance = cellWidth * 1e-3
        let first = Int(((range.lowerBound + tolerance) / cellWidth).rounded(.down))
        let last = max(first, Int(((range.upperBound - tolerance) / cellWidth).rounded(.down)))
        let items = (first...last).compactMap { index -> ObservedSpan? in
            let cell = (Float(index) * cellWidth)...(Float(index + 1) * cellWidth)
            let clipped = cell.clamped(to: range)
            guard clipped.upperBound > clipped.lowerBound else { return nil }
            let width = cell.upperBound - cell.lowerBound
            let found = [cell.lowerBound + width * 0.25, cell.lowerBound + width * 0.75].compactMap(distance(atS:))
            guard let nearest = found.min() else { return nil }
            return ObservedSpan(span: clipped, out: (nearest / config.quantum).rounded(.down) * config.quantum)
        }
        return ObservedSpan.merge(items, touching: cellWidth * 0.01)
    }

    /// A plane that is large enough and upright enough to end the space, in the terms `spans`
    /// measures it by.
    private struct Candidate {
        var center: SIMD3<Float>
        /// Horizontal unit normal, either way round.
        var normal: SIMD3<Float>
        /// Horizontal unit direction along the plane.
        var along: SIMD3<Float>
        /// The outline's extent along `along`, from the centre.
        var first: Float
        var last: Float
        /// The outline in the plane, in order around it: x along `along` from the centre, y the
        /// world height.
        var outline: [SIMD2<Float>]

        init?(_ plane: WallPlaneEvidence, wall: WallFrame, config: FarSurfaceConfig) {
            guard plane.kind != .other, let normal = plane.horizontalNormal, !plane.boundary.isEmpty else { return nil }
            let along = SIMD3(-normal.z, 0, normal.x)
            let offsets = plane.boundary.map { simd_dot($0 - plane.center, along) }
            let heights = plane.boundary.map(\.y)
            guard let first = offsets.min(), let last = offsets.max(), let bottom = heights.min(), let top = heights.max(),
                  last - first >= config.minWidth, top - bottom >= config.minHeight else { return nil }
            guard Self.clearsWall(plane.center + along * first, normal: normal, wall: wall, config: config),
                  Self.clearsWall(plane.center + along * last, normal: normal, wall: wall, config: config) else { return nil }
            self.center = plane.center
            self.normal = normal
            self.along = along
            self.first = first
            self.last = last
            self.outline = zip(offsets, heights).map { SIMD2($0, $1) }
        }

        /// Whether the outline stands on the ground where a cell meets it, `offset` along the
        /// plane from its centre (held to the outline's ends): the outline covers the point
        /// `maxGroundGap` above the ground there, so it reaches down to within that of the ground
        /// and rises above it in one piece. The height span alone let a plane hanging well above
        /// the ground end the space under it (review of #168). The outline's lowest and highest
        /// points would still let a plane end it across a gap at that height, or, taken over the
        /// whole outline, past where its lower edge climbs away from the ground.
        func standsOnGround(at offset: Float, groundY: Float, config: FarSurfaceConfig) -> Bool {
            let point = SIMD2(min(max(offset, first), last), groundY + config.maxGroundGap)
            var inside = false
            for (a, b) in zip(outline, outline.dropFirst() + outline.prefix(1)) {
                if Self.distance(from: point, toEdge: a, b) <= 1e-4 { return true }
                // Even-odd rule, casting the ray up from the point.
                guard (a.x > point.x) != (b.x > point.x) else { continue }
                if a.y + (b.y - a.y) * (point.x - a.x) / (b.x - a.x) > point.y { inside.toggle() }
            }
            return inside
        }

        private static func distance(from point: SIMD2<Float>, toEdge a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let edge = b - a
            let length = simd_length_squared(edge)
            let t = length > 0 ? min(max(simd_dot(point - a, edge) / length, 0), 1) : 0
            return simd_distance(point, a + edge * t)
        }

        /// Whether one horizontal end of a plane's outline stands at least `minOut` in front of
        /// the wall it could be the wall's own plane of: the piece nearest the end in plan among
        /// those within `maxAngle` of parallel to the plane, measured against that piece's whole
        /// line, however far along it the end lies. A plane is straight, so with both ends clear
        /// of the line all of it is. Pieces turned further from the plane are left out, as they
        /// are when a cell meets it: a corridor's far wall is never held to the wall across the
        /// corridor's mouth, nor a fence parallel to the meter's wall to a side wall it runs up
        /// to. Holding an end to whichever piece's stretch it lay along let the corridor wall's
        /// own plane, running past the corner, be judged against the meter's wall instead
        /// (review of #168). With no piece near parallel the plane faces no cell anyway.
        static func clearsWall(_ end: SIMD3<Float>, normal: SIMD3<Float>, wall: WallFrame, config: FarSurfaceConfig) -> Bool {
            let offset = end - wall.origin
            let cosLimit = cos(config.maxAngle)
            let nearest = wall.segments
                .filter { abs(simd_dot($0.outward, normal)) >= cosLimit }
                .min { $0.planDistance(toOffset: offset) < $1.planDistance(toOffset: offset) }
            guard let nearest else { return true }
            return nearest.coordinates(ofOffset: offset).out >= config.minOut
        }
    }
}
