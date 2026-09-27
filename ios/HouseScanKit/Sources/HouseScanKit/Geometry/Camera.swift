import Foundation
import simd

// Camera geometry for ARKit-convention frames. The ray and projection formulas are the ones in
// Measure Lab's Geometry package (experiments/measure-lab on t3/measure-lab), ported to Float.

/// One camera frame: where the camera was and how it maps the world onto its image.
///
/// Camera space: +x right and +y up in the unrotated landscape sensor image, looking along -z.
/// Pixels: (0, 0) is the image's top-left corner and v grows down.
public struct CameraFrame: Sendable, Equatable {
    /// Camera-to-world transform, column-major like `simd_float4x4`.
    public let cameraToWorld: simd_float4x4
    /// fx, fy, cx, cy in pixels of the sensor image.
    public let intrinsics: SIMD4<Float>
    /// Sensor image width and height in pixels.
    public let imageSize: SIMD2<Float>
    /// Kept alongside because coverage projects thousands of points per frame.
    public let worldToCamera: simd_float4x4

    public init(cameraToWorld: simd_float4x4, intrinsics: SIMD4<Float>, imageSize: SIMD2<Float>) {
        self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics
        self.imageSize = imageSize
        worldToCamera = cameraToWorld.inverse
    }

    /// Builds a frame from 16 column-major numbers, the layout of scene.json and session.json.
    public init?(columnMajorPose pose: [Float], intrinsics: SIMD4<Float>, imageSize: SIMD2<Float>) {
        guard pose.count == 16, pose.allSatisfy(\.isFinite) else { return nil }
        let columns = (0..<4).map { SIMD4(pose[$0 * 4], pose[$0 * 4 + 1], pose[$0 * 4 + 2], pose[$0 * 4 + 3]) }
        self.init(cameraToWorld: simd_float4x4(columns), intrinsics: intrinsics, imageSize: imageSize)
    }

    public var position: SIMD3<Float> {
        SIMD3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
    }

    /// Unit direction the camera looks along, in world coordinates.
    public var forward: SIMD3<Float> {
        simd_normalize(-SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z))
    }

    public func cameraSpace(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let local = worldToCamera * SIMD4(world, 1)
        return SIMD3(local.x, local.y, local.z)
    }

    /// The pixel a world point lands on, or nil when it is less than `minDepth` in front of the
    /// camera. The pixel may lie outside the image.
    public func pixel(of world: SIMD3<Float>, minDepth: Float = 0.05) -> SIMD2<Float>? {
        let p = cameraSpace(world)
        guard -p.z >= minDepth else { return nil }
        let depth = -p.z
        return SIMD2(intrinsics.z + intrinsics.x * p.x / depth, intrinsics.w - intrinsics.y * p.y / depth)
    }

    /// Whether a pixel is inside the image, at least `margin` (a fraction of each side) from its edges.
    public func contains(pixel: SIMD2<Float>, margin: Float = 0) -> Bool {
        let inset = imageSize * margin
        return pixel.x >= inset.x && pixel.y >= inset.y
            && pixel.x <= imageSize.x - inset.x && pixel.y <= imageSize.y - inset.y
    }

    /// The world ray through a pixel. Its direction is a unit vector.
    public func ray(throughPixel pixel: SIMD2<Float>) -> Ray {
        let local = SIMD3((pixel.x - intrinsics.z) / intrinsics.x, -(pixel.y - intrinsics.w) / intrinsics.y, -1)
        let rotated = cameraToWorld * SIMD4(local, 0)
        return Ray(origin: position, direction: simd_normalize(SIMD3(rotated.x, rotated.y, rotated.z)))
    }

    /// Angle in radians between this frame's rotation and another's.
    public func rotationAngle(to other: CameraFrame) -> Float {
        let a = simd_quatf(Self.rotation(cameraToWorld))
        let b = simd_quatf(Self.rotation(other.cameraToWorld))
        let dot = min(1, abs(simd_dot(a.vector, b.vector)))
        return 2 * acos(dot)
    }

    static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }
}

public struct Ray: Sendable, Equatable {
    public var origin: SIMD3<Float>
    public var direction: SIMD3<Float>

    public init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
        self.origin = origin
        self.direction = direction
    }

    public func at(_ t: Float) -> SIMD3<Float> { origin + direction * t }

    /// Distance along the ray to a plane, or nil when the ray is parallel to it (within 1e-6) or
    /// the plane is behind the origin.
    public func intersect(planePoint: SIMD3<Float>, normal: SIMD3<Float>) -> Float? {
        let denominator = simd_dot(normal, direction)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = simd_dot(normal, planePoint - origin) / denominator
        return t > 0 ? t : nil
    }
}

public extension simd_float4x4 {
    /// The 16 numbers column by column, the layout of scene.json and session.json.
    var columnMajor: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
