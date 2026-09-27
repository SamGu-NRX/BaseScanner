import Foundation
import simd

// Where the open space in front of the wall ends: the far wall of a corridor, the fence of a
// side yard. On the build 5.1 and 7.1 field tests the capture treated that surface as something
// standing in front of the wall to look past (#160), and sent the homeowner after a walk-out line
// behind it (#164). ARKit's vertical plane detection had found the surface on both phones, with
// and without LiDAR, so the planes are what marks it here. The LiDAR mesh measures it too
// (`TriangleMesh.facingSpans`), but only once, at upload: ray casts over the whole mesh take too
// long to run during the walk.

/// Which detected planes count as the surface where the space ends. Every value is a guess unless
/// its comment says where it comes from.
public struct FarSurfaceConfig: Sendable, Equatable {
    /// Nearer the wall than this a plane is taken for the wall itself: ARKit's plane of the house
    /// wall lies within a few centimetres to decimetres of the wall line (a tapped line is off by
    /// 0.3 ft and more), and a space narrower than this is not one anyone walks in. A guess.
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
    /// `minHeight` tall, of any class but a door or a window) and whose outline, along the plane,
    /// reaches the point it is met at. The smaller of the two, rounded down to `quantum`, with
    /// touching cells of equal distance merged. Cells with no such plane are left out.
    ///
    /// A plane is ARKit's fit to a surface, not a measurement of what stands between it and the
    /// wall: it says where the space ends, never that the space before it is clear.
    public static func spans(
        planes: [WallPlaneEvidence], wall: WallFrame, over range: ClosedRange<Float>,
        cellWidth: Float = CoverageConfig().cellWidth, config: FarSurfaceConfig = FarSurfaceConfig()
    ) -> [ObservedSpan] {
        let facing = planes.compactMap { Candidate($0, config: config) }
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

        init?(_ plane: WallPlaneEvidence, config: FarSurfaceConfig) {
            guard plane.kind != .other, let normal = plane.horizontalNormal, !plane.boundary.isEmpty else { return nil }
            let along = SIMD3(-normal.z, 0, normal.x)
            let offsets = plane.boundary.map { simd_dot($0 - plane.center, along) }
            let heights = plane.boundary.map(\.y)
            guard let first = offsets.min(), let last = offsets.max(), let bottom = heights.min(), let top = heights.max(),
                  last - first >= config.minWidth, top - bottom >= config.minHeight else { return nil }
            self.center = plane.center
            self.normal = normal
            self.along = along
            self.first = first
            self.last = last
        }
    }
}
