import Foundation
import simd

/// The frame the 3D map is stored in: gravity-aligned and anchored on the electric meter.
///
/// Origin at the meter's foot on the ground; +x runs along the meter's wall (the wall's +s),
/// +y is up and +z points out from the wall toward the homeowner. Near the meter a map point is
/// therefore (s, height, out). ARKit runs with `.gravity` alignment, so the frame differs from
/// ARKit's world only by a turn about +y and a shift. Anything stored in it moves with the meter
/// anchor when ARKit refines the anchor (`following(anchorMovedFrom:to:)`).
public struct MapFrame: Sendable, Equatable {
    /// Map point to ARKit world point. Rotation about +y and a translation only.
    public private(set) var worldFromMap: simd_float4x4
    public private(set) var mapFromWorld: simd_float4x4

    /// Nil when `outward` has no horizontal part (a floor or ceiling hit).
    public init?(meter: SIMD3<Float>, outward: SIMD3<Float>, groundY: Float) {
        let flat = SIMD3(outward.x, 0, outward.z)
        guard simd_length(flat) > 1e-3 else { return nil }
        let z = simd_normalize(flat)
        let x = simd_normalize(simd_cross(-z, SIMD3(0, 1, 0)))
        self.init(worldFromMap: simd_float4x4(
            SIMD4(x, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(meter.x, groundY, meter.z, 1)))
    }

    /// The meter's wall: origin at `wall.origin`, +x along and +z outward of the meter's piece.
    public init(wall: WallFrame) {
        // A WallFrame's outward is unit horizontal by construction, so this cannot fail.
        self.init(meter: wall.meter, outward: wall.outward, groundY: wall.groundY)!
    }

    private init(worldFromMap: simd_float4x4) {
        self.worldFromMap = worldFromMap
        mapFromWorld = worldFromMap.inverse
    }

    public func map(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = mapFromWorld * SIMD4(world, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    public func world(_ map: SIMD3<Float>) -> SIMD3<Float> {
        let p = worldFromMap * SIMD4(map, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// A world direction in map axes.
    public func mapDirection(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = mapFromWorld * SIMD4(world, 0)
        return SIMD3(p.x, p.y, p.z)
    }

    public func worldDirection(_ map: SIMD3<Float>) -> SIMD3<Float> {
        let p = worldFromMap * SIMD4(map, 0)
        return SIMD3(p.x, p.y, p.z)
    }

    /// This frame moved as the meter's ARAnchor moved from `old` to `new` (both anchor-to-world),
    /// so a map point keeps its place relative to the anchor. Any tilt in the anchor's change is
    /// dropped: the map stays gravity-aligned, and ARKit's `.gravity` alignment keeps anchor
    /// updates level anyway.
    public func following(anchorMovedFrom old: simd_float4x4, to new: simd_float4x4) -> MapFrame {
        let moved = new * old.inverse * worldFromMap
        let x = SIMD3(moved.columns.0.x, 0, moved.columns.0.z)
        guard simd_length(x) > 1e-3 else { return self }
        let along = simd_normalize(x)
        let z = simd_normalize(simd_cross(along, SIMD3(0, 1, 0)))
        let origin = moved.columns.3
        return MapFrame(worldFromMap: simd_float4x4(
            SIMD4(along, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(origin.x, origin.y, origin.z, 1)))
    }
}

/// An axis-aligned box of the map frame, meters.
public struct MapBounds: Sendable, Equatable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        precondition(simd_reduce_min(max - min) > 0, "map bounds \(min)...\(max) are empty")
        self.min = min
        self.max = max
    }

    public var size: SIMD3<Float> { max - min }

    public func contains(_ p: SIMD3<Float>) -> Bool {
        p.x >= min.x && p.y >= min.y && p.z >= min.z && p.x < max.x && p.y < max.y && p.z < max.z
    }

    /// Everything the rules can ask about around the meter. The region of interest
    /// (`Map3DConfig`) runs `alongExtent` along the wall chain either way from the meter and
    /// `outDepth` out from it; a chain can turn at corners, including back behind the meter's
    /// wall, so in plan it stays within `alongExtent + outDepth` of the meter in any direction.
    /// Heights run from `groundBelow` under the meter's ground to `top`.
    public static func around(_ config: Map3DConfig) -> MapBounds {
        let r = config.alongExtent + config.outDepth
        return MapBounds(min: SIMD3(-r, -config.groundBelow, -r), max: SIMD3(r, config.top, r))
    }
}
