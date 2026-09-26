import Foundation
import simd

/// A point in wall coordinates: meters along the wall from the meter (`s`, negative to the left
/// for someone facing the wall), above the ground (`height`) and out from the wall (`out`).
public struct WallPoint: Sendable, Equatable {
    public var s: Float
    public var height: Float
    public var out: Float

    public init(s: Float, height: Float, out: Float) {
        self.s = s
        self.height = height
        self.out = out
    }
}

/// The straight wall the scan measures, anchored on the electric meter.
///
/// `outward` is horizontal and points from the wall toward the homeowner. `along` is
/// cross(-outward, up): facing the wall you look along -outward, so right is cross(forward, up).
public struct WallFrame: Sendable, Equatable {
    public static let up = SIMD3<Float>(0, 1, 0)

    /// The meter, on the wall face.
    public var meter: SIMD3<Float>
    public private(set) var outward: SIMD3<Float>
    /// World y of the ground at the foot of the wall.
    public var groundY: Float

    /// Returns nil when `outward` has no horizontal component to speak of (a floor or ceiling hit).
    public init?(meter: SIMD3<Float>, outward: SIMD3<Float>, groundY: Float) {
        let flat = SIMD3(outward.x, 0, outward.z)
        guard simd_length(flat) > 1e-3 else { return nil }
        self.meter = meter
        self.outward = simd_normalize(flat)
        self.groundY = groundY
    }

    public var along: SIMD3<Float> { simd_normalize(simd_cross(-outward, Self.up)) }

    /// The meter's foot on the ground: the origin of wall coordinates.
    public var origin: SIMD3<Float> { SIMD3(meter.x, groundY, meter.z) }

    public var meterHeight: Float { meter.y - groundY }

    public func world(_ p: WallPoint) -> SIMD3<Float> {
        origin + along * p.s + outward * p.out + Self.up * p.height
    }

    public func world(s: Float, height: Float, out: Float = 0) -> SIMD3<Float> {
        world(WallPoint(s: s, height: height, out: out))
    }

    public func wallPoint(_ world: SIMD3<Float>) -> WallPoint {
        let d = world - origin
        return WallPoint(s: simd_dot(d, along), height: d.y, out: simd_dot(d, outward))
    }

    /// Where a ray meets the wall face, or nil when it misses (parallel, or the wall is behind).
    public func intersectWall(_ ray: Ray) -> WallPoint? {
        guard let t = ray.intersect(planePoint: meter, normal: outward) else { return nil }
        return wallPoint(ray.at(t))
    }

    /// Where a ray meets the ground plane, or nil when it misses.
    public func intersectGround(_ ray: Ray) -> WallPoint? {
        guard let t = ray.intersect(planePoint: origin, normal: Self.up) else { return nil }
        return wallPoint(ray.at(t))
    }
}
