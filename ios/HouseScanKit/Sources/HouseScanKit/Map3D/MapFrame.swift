import Foundation
import simd

/// The frame the 3D map is stored in: the capture packet's meter frame (packet/README.md, "Units,
/// frames and clocks", on t3/packet).
///
/// Origin at the meter anchor, the point tapped on the meter. +y is up, +z is the wall's
/// outward normal, horizontal, toward the homeowner, and +x = y × z runs along the wall to the
/// right as seen facing it (scene.json's +s). ARKit runs with `.gravity` alignment, so the frame
/// differs from ARKit's world only by a turn about +y and a shift. `groundY` is the height of the
/// ground at the meter in this frame (negative), the packet's `ground_y_m`. Anything stored in
/// the frame moves with the meter anchor when ARKit refines it
/// (`following(anchorMovedFrom:to:)`).
public struct MapFrame: Sendable, Equatable {
    /// Map point to ARKit world point: the packet's `session.meter_anchor.pose_in_world`.
    public private(set) var poseInWorld: simd_float4x4
    public private(set) var mapFromWorld: simd_float4x4
    /// Height of the ground at the meter, map frame, meters.
    public let groundY: Float

    /// `meter` and `worldGroundY` in ARKit world. Nil when `outward` has no horizontal part (a
    /// floor or ceiling hit).
    public init?(meter: SIMD3<Float>, outward: SIMD3<Float>, worldGroundY: Float) {
        let flat = SIMD3(outward.x, 0, outward.z)
        guard simd_length(flat) > 1e-3 else { return nil }
        let z = simd_normalize(flat)
        let x = simd_normalize(simd_cross(SIMD3(0, 1, 0), z))
        self.init(
            poseInWorld: simd_float4x4(SIMD4(x, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(meter, 1)),
            groundY: worldGroundY - meter.y)
    }

    /// The meter's wall: origin at `wall.meter`, +x along and +z outward of the meter's piece.
    public init(wall: WallFrame) {
        // A WallFrame's outward is unit horizontal by construction, so this cannot fail.
        self.init(meter: wall.meter, outward: wall.outward, worldGroundY: wall.groundY)!
    }

    /// A packet's `session.meter_anchor`: `poseInWorld` must be a rotation about +y and a shift.
    public init(poseInWorld: simd_float4x4, groundY: Float) {
        let up = SIMD3(poseInWorld.columns.1.x, poseInWorld.columns.1.y, poseInWorld.columns.1.z)
        precondition(abs(up.y - 1) < 1e-3, "meter frame \(poseInWorld) is not gravity-aligned: its +y is \(up)")
        self.poseInWorld = poseInWorld
        mapFromWorld = poseInWorld.inverse
        self.groundY = groundY
    }

    public func map(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = mapFromWorld * SIMD4(world, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    public func world(_ map: SIMD3<Float>) -> SIMD3<Float> {
        let p = poseInWorld * SIMD4(map, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    /// A world direction in map axes.
    public func mapDirection(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = mapFromWorld * SIMD4(world, 0)
        return SIMD3(p.x, p.y, p.z)
    }

    public func worldDirection(_ map: SIMD3<Float>) -> SIMD3<Float> {
        let p = poseInWorld * SIMD4(map, 0)
        return SIMD3(p.x, p.y, p.z)
    }

    /// This frame moved as the meter's ARAnchor moved from `old` to `new` (both anchor-to-world),
    /// so a map point keeps its place relative to the anchor. Any tilt in the anchor's change is
    /// dropped: the map stays gravity-aligned, and ARKit's `.gravity` alignment keeps anchor
    /// updates level anyway.
    public func following(anchorMovedFrom old: simd_float4x4, to new: simd_float4x4) -> MapFrame {
        let moved = new * old.inverse * poseInWorld
        let x = SIMD3(moved.columns.0.x, 0, moved.columns.0.z)
        guard simd_length(x) > 1e-3 else { return self }
        let along = simd_normalize(x)
        let z = simd_normalize(simd_cross(along, SIMD3(0, 1, 0)))
        let origin = moved.columns.3
        return MapFrame(
            poseInWorld: simd_float4x4(SIMD4(along, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(origin.x, origin.y, origin.z, 1)),
            groundY: groundY)
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
    /// Heights run from `groundBelow` under the meter's ground to `top` above it.
    public static func around(_ config: Map3DConfig, groundY: Float) -> MapBounds {
        let r = config.alongExtent + config.outDepth
        return MapBounds(min: SIMD3(-r, groundY - config.groundBelow, -r), max: SIMD3(r, groundY + config.top, r))
    }
}
