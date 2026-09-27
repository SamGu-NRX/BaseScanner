import Foundation
import simd

/// A horizontal plane ARKit detected, as the ground choice needs it: its height, what ARKit
/// classified it as, and its outline. World meters.
public struct GroundPlaneEvidence: Sendable, Equatable {
    /// ARKit's plane classifications that matter here (`ARPlaneAnchor.Classification`).
    public enum Kind: Sendable, Equatable {
        case floor
        /// Furniture: `.table` or `.seat`.
        case furniture
        /// `.none`: not classified, which is every plane on a phone without classification.
        case unclassified
        /// Anything else (a ceiling, or a class added after iOS 26).
        case other
    }

    public var y: Float
    public var kind: Kind
    /// The plane's boundary in plan, [x, z] per vertex, in order around it.
    public var boundary: [SIMD2<Float>]

    public init(y: Float, kind: Kind, boundary: [SIMD2<Float>]) {
        self.y = y
        self.kind = kind
        self.boundary = boundary
    }
}

/// Which detected plane, if any, is the ground at the wall's foot. The ground is measured only
/// when one qualifies; otherwise it stays the chest-height guess and its error stays on every
/// height (`CoverageMap.heightError`). A tabletop taken for ground would move every height in the
/// scene to the wrong datum with no error to show it, so this errs toward keeping the guess.
public enum GroundPlaneChoice {
    /// The ground lies at least this far below the meter. A meter sits well above the ground; a
    /// plane nearer it is a sill, a step or a ledge. Unchanged from before.
    public static let minimumDrop: Float = 0.3
    /// How far along the wall either side of the meter the plane's edge is looked for, meters: the
    /// stretch where batteries are tried first, and where the meter's own foot is.
    public static let alongMeter: Float = 2
    /// How far from the wall's foot line the plane's outline may stop, meters. ARKit grows a plane
    /// over the ground the camera has seen, and the walk looks at the ground from the wall's foot
    /// out (the ground band starts at the foot), so ground at the wall reaches the wall or stops
    /// short of it where the foot is planted or lumpy. 0.5 m allows that and is under the ground
    /// band's 1.2 m; a table standing 1 m out from the wall does not reach. A guess; no
    /// measurement of ARKit's plane edges at a wall exists.
    public static let footReach: Float = 0.5

    /// The ground's y at the wall whose meter is at `meter`, running along `along`, or nil when no
    /// plane qualifies. A plane qualifies when it lies at least `minimumDrop` below the meter, is
    /// not classified as furniture or anything but floor or unclassified, and its outline comes
    /// within `footReach` of the wall's foot line within `alongMeter` of the meter. Planes
    /// classified floor are preferred; among those considered, the lowest wins: a raised surface
    /// by the wall (a planter's rim, a low table) is higher than the ground it stands on.
    public static func groundY(meter: SIMD3<Float>, along: SIMD3<Float>, planes: [GroundPlaneEvidence]) -> Float? {
        let direction = simd_normalize(SIMD2(along.x, along.z))
        let foot = SIMD2(meter.x, meter.z)
        let line = (foot - direction * alongMeter, foot + direction * alongMeter)
        let qualifying = planes.filter { plane in
            guard plane.y <= meter.y - minimumDrop else { return false }
            switch plane.kind {
            case .floor, .unclassified: break
            case .furniture, .other: return false
            }
            return distance(from: plane.boundary, to: line) <= footReach
        }
        let floors = qualifying.filter { $0.kind == .floor }
        return (floors.isEmpty ? qualifying : floors).map(\.y).min()
    }

    /// Plan distance between a polygon and a segment: 0 when the segment crosses or lies inside it.
    static func distance(from polygon: [SIMD2<Float>], to segment: (SIMD2<Float>, SIMD2<Float>)) -> Float {
        guard polygon.count >= 3 else { return .infinity }
        if contains(polygon, segment.0) || contains(polygon, segment.1) { return 0 }
        var best = Float.infinity
        for (index, a) in polygon.enumerated() {
            let b = polygon[(index + 1) % polygon.count]
            best = min(best, segmentDistance(a, b, segment.0, segment.1))
        }
        return best
    }

    /// Even-odd point in polygon.
    static func contains(_ polygon: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        for (index, a) in polygon.enumerated() {
            let b = polygon[(index + 1) % polygon.count]
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) { inside.toggle() }
        }
        return inside
    }

    static func segmentDistance(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Float {
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        let r = b - a, s = d - c
        let denominator = cross(r, s)
        if denominator != 0 {
            let t = cross(c - a, s) / denominator, u = cross(c - a, r) / denominator
            if (0...1).contains(t), (0...1).contains(u) { return 0 }
        }
        func toSegment(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let ab = b - a
            let t = simd_length_squared(ab) > 0 ? min(max(simd_dot(p - a, ab) / simd_length_squared(ab), 0), 1) : 0
            return simd_distance(p, a + ab * t)
        }
        return min(toSegment(a, c, d), toSegment(b, c, d), toSegment(c, a, b), toSegment(d, a, b))
    }
}
