import Foundation
import simd

/// A rigid move about gravity: a turn about +y, then a translation. ARKit's `.gravity` world
/// alignment keeps +y up, so the correction it makes to an anchor as it refines its map is one of
/// these (any tilt left over is noise and is dropped).
public struct YawCorrection: Sendable, Equatable {
    /// Radians, counterclockwise seen from above (+y toward the viewer).
    public var yaw: Float
    public var translation: SIMD3<Float>

    public static let identity = YawCorrection(yaw: 0, translation: .zero)

    public init(yaw: Float, translation: SIMD3<Float>) {
        self.yaw = yaw
        self.translation = translation
    }

    /// The correction that takes an anchor at `old` to `new`, keeping only the turn about +y: it
    /// maps the old anchor's origin onto the new one's and turns the old axes by the yaw between
    /// them. The yaw is read from both horizontal axes, so an anchor whose own axes are tilted (a
    /// wall hit's, whose y axis is the wall's normal) gives the same answer.
    public init(from old: simd_float4x4, to new: simd_float4x4) {
        let turn = Self.rotation(new) * Self.rotation(old).transpose
        let x = turn * SIMD3<Float>(1, 0, 0)
        let z = turn * SIMD3<Float>(0, 0, 1)
        // A turn by θ about +y takes x to (cos θ, 0, -sin θ) and z to (sin θ, 0, cos θ).
        let yaw = atan2(z.x - x.z, x.x + z.z)
        let oldOrigin = SIMD3(old.columns.3.x, old.columns.3.y, old.columns.3.z)
        let newOrigin = SIMD3(new.columns.3.x, new.columns.3.y, new.columns.3.z)
        self.init(yaw: yaw, translation: .zero)
        translation = newOrigin - direction(oldOrigin)
    }

    public func direction(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z)
    }

    public func point(_ p: SIMD3<Float>) -> SIMD3<Float> { direction(p) + translation }

    /// A camera-to-world pose moved with the world.
    public func pose(_ m: simd_float4x4) -> simd_float4x4 { matrix * m }

    /// A camera moved with the world; its lens is unchanged.
    public func moved(_ camera: CameraFrame) -> CameraFrame {
        CameraFrame(cameraToWorld: pose(camera.cameraToWorld), intrinsics: camera.intrinsics, imageSize: camera.imageSize)
    }

    public var matrix: simd_float4x4 {
        let x = direction(SIMD3(1, 0, 0)), z = direction(SIMD3(0, 0, 1))
        return simd_float4x4(SIMD4(x, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(translation, 1))
    }

    private static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }
}

/// The meter anchor's pose that the captured geometry (the wall, its corners, the kept cameras,
/// the tapped marks) currently agrees with, and the corrections to apply to all of it as ARKit
/// refines the anchor. Everything captured moves with the anchor as one rigid body, so the
/// relations between the wall and what was seen of it never change: nothing has to be rebuilt,
/// and a later correction can't undo an earlier one.
public struct MeterAnchorTracking: Sendable, Equatable {
    /// The anchor pose the captured geometry agrees with. The AR result is attached in this pose's
    /// frame (`LiveCapture.showResult`), so it follows the anchor however far it has moved since.
    public private(set) var pose: simd_float4x4

    /// A correction is applied once it moves the meter 2 cm, or turns the wall 0.4 degrees, which
    /// moves a point 3 m from the meter (about where a battery stands) 2 cm. ARKit nudges the
    /// anchor by millimetres most frames, and each correction redraws the overlays; 2 cm is far
    /// below the 6 in cell and doesn't show. Smaller ones add up until they reach it.
    public static let minimumMove: Float = 0.02
    public static let minimumTurn: Float = 0.4 * .pi / 180

    public init(pose: simd_float4x4) {
        self.pose = pose
    }

    /// The correction from `pose` to `anchor`, when it is large enough to apply; the pose then
    /// becomes `anchor`. Nil, and nothing changes, otherwise.
    public mutating func update(to anchor: simd_float4x4) -> YawCorrection? {
        let correction = YawCorrection(from: pose, to: anchor)
        let origin = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let moved = simd_distance(correction.point(origin), origin)
        guard moved > Self.minimumMove || abs(correction.yaw) > Self.minimumTurn else { return nil }
        pose = anchor
        return correction
    }
}

extension WallFrame {
    /// Moves the wall with the world: the meter and the ground with the translation, the meter's
    /// piece and every corner's piece turned by the yaw. Every s (the ends, the corners, what was
    /// seen) is measured along the chain from the meter, so none of them changes.
    public mutating func apply(_ correction: YawCorrection) {
        meter = correction.point(meter)
        groundY += correction.translation.y
        turn(by: correction)
    }
}
