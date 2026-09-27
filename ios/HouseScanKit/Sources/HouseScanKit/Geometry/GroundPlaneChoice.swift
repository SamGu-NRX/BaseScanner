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
    /// ARKit's anchor identifier, for the log. Empty when there is none.
    public var id: String

    public init(y: Float, kind: Kind, boundary: [SIMD2<Float>], id: String = "") {
        self.y = y
        self.kind = kind
        self.boundary = boundary
        self.id = id
    }
}

/// Which detected plane, if any, is the ground at the wall's foot. The ground is measured only
/// when one qualifies; otherwise it stays the chest-height guess and its error stays on every
/// height (`CoverageMap.heightError`). A tabletop taken for ground would move every height in the
/// scene to the wrong datum with no error to show it, so this errs toward keeping the guess.
public enum GroundPlaneChoice {
    /// How far above the ground the meter may be, meters: 0.9 to 2.0 m (about 3 ft to 6 ft 7 in).
    /// A plane that puts the meter lower is a sill, a step, a ledge or a tabletop; one that puts it
    /// higher is a lower yard or a street past the wall's own ground. A guess from where meters
    /// are usually mounted, not measured: no survey of meter heights exists for this app. It
    /// replaces the old 0.3 m minimum drop, which let a folding table 0.5 m under the meter pass
    /// (#62).
    public static let meterHeight: ClosedRange<Float> = 0.9...2.0
    /// Once the ground is measured, a later plane may not raise it by more than this, meters. A
    /// raise re-projects every coverage row, so cells the homeowner was just told were done go
    /// back to unseen (#62); a real floor ARKit refines moves by a few centimetres, not 10. A
    /// lower plane may still replace the current one. A guess, not measured.
    public static let maximumRaise: Float = 0.1
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

    /// The plane taken as ground, and why that one.
    public struct Choice: Sendable, Equatable {
        public enum Reason: String, Sendable, Equatable {
            /// Its outline contains where the phone stood when the meter was marked: the ground
            /// the homeowner was standing on.
            case underThePhone
            /// Its outline contains the point on the ground straight below the meter.
            case atTheMetersFoot
            /// Neither holds for any plane considered; the lowest of them.
            case lowest
        }

        public var plane: GroundPlaneEvidence
        public var reason: Reason

        public init(plane: GroundPlaneEvidence, reason: Reason) {
            self.plane = plane
            self.reason = reason
        }
    }

    /// The ground's y at the wall whose meter is at `meter`, running along `along`, or nil when no
    /// plane qualifies (`choose` without a phone position or a current ground).
    public static func groundY(meter: SIMD3<Float>, along: SIMD3<Float>, planes: [GroundPlaneEvidence]) -> Float? {
        choose(meter: meter, along: along, phone: nil, current: nil, planes: planes)?.plane.y
    }

    /// The ground plane at the wall whose meter is at `meter`, running along `along`, or nil when
    /// no plane qualifies. A plane qualifies when the meter is `meterHeight` above it, it is not
    /// classified as furniture or anything but floor or unclassified, and its outline comes within
    /// `footReach` of the wall's foot line within `alongMeter` of the meter. With `current`, the
    /// ground already measured, a plane more than `maximumRaise` above it doesn't qualify either.
    ///
    /// Planes classified floor are preferred. Among those considered, one whose outline contains
    /// `phone` (where the phone stood when the meter was marked, in plan) wins, then one that
    /// contains the meter's foot, then the lowest: a raised surface by the wall (a planter's rim, a
    /// low table) is higher than the ground it stands on. Containment comes first because the
    /// lowest can be wrong where the ground steps down: in a field run the ground at the wall was
    /// the higher of two planes classified floor, and the other lay 0.25 m below it.
    public static func choose(
        meter: SIMD3<Float>, along: SIMD3<Float>, phone: SIMD3<Float>?, current: Float?, planes: [GroundPlaneEvidence]
    ) -> Choice? {
        let direction = simd_normalize(SIMD2(along.x, along.z))
        let foot = SIMD2(meter.x, meter.z)
        let line = (foot - direction * alongMeter, foot + direction * alongMeter)
        let qualifying = planes.filter { plane in
            guard meterHeight.contains(meter.y - plane.y) else { return false }
            if let current, plane.y > current + maximumRaise { return false }
            switch plane.kind {
            case .floor, .unclassified: break
            case .furniture, .other: return false
            }
            return distance(from: plane.boundary, to: line) <= footReach
        }
        let floors = qualifying.filter { $0.kind == .floor }
        let lowestFirst = (floors.isEmpty ? qualifying : floors).sorted { $0.y < $1.y }
        guard let lowest = lowestFirst.first else { return nil }
        if let phone, let plane = lowestFirst.first(where: { contains($0.boundary, SIMD2(phone.x, phone.z)) }) {
            return Choice(plane: plane, reason: .underThePhone)
        }
        if let plane = lowestFirst.first(where: { contains($0.boundary, foot) }) {
            return Choice(plane: plane, reason: .atTheMetersFoot)
        }
        return Choice(plane: lowest, reason: .lowest)
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
