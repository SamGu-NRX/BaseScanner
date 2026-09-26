import Foundation

/// Pinhole intrinsics of one saved image, in pixels of that image.
///
/// For ARKit these come from `ARCamera.intrinsics` and describe the unrotated (landscape) sensor
/// image. Rotating or cropping the image changes them.
public struct CameraIntrinsics: Sendable, Equatable, Codable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double

    public init(fx: Double, fy: Double, cx: Double, cy: Double) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
    }
}

/// Camera-to-world rigid transform: the camera's axes and position in world coordinates.
///
/// Camera space follows ARKit: +x to the right of the unrotated sensor image, +y up in that image,
/// and the camera looks along -z.
public struct CameraPose: Sendable, Equatable {
    public var xAxis: SIMD3<Double>
    public var yAxis: SIMD3<Double>
    public var zAxis: SIMD3<Double>
    public var position: SIMD3<Double>

    public init(xAxis: SIMD3<Double>, yAxis: SIMD3<Double>, zAxis: SIMD3<Double>, position: SIMD3<Double>) {
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.zAxis = zAxis
        self.position = position
    }

    /// Reads a 4×4 matrix stored column by column (16 numbers), the layout `simd_float4x4` uses.
    public init(columnMajor values: [Double]) throws(GeometryInputError) {
        guard values.count == 16 else {
            throw .wrongMatrixSize(expected: 16, actual: values.count)
        }
        let bottomRow = [values[3], values[7], values[11], values[15]]
        guard bottomRow == [0, 0, 0, 1] else {
            throw .notAnAffineTransform(bottomRow: bottomRow)
        }
        xAxis = SIMD3(values[0], values[1], values[2])
        yAxis = SIMD3(values[4], values[5], values[6])
        zAxis = SIMD3(values[8], values[9], values[10])
        position = SIMD3(values[12], values[13], values[14])
    }

    /// The matrix as 16 numbers, column by column.
    public var columnMajor: [Double] {
        [
            xAxis.x, xAxis.y, xAxis.z, 0,
            yAxis.x, yAxis.y, yAxis.z, 0,
            zAxis.x, zAxis.y, zAxis.z, 0,
            position.x, position.y, position.z, 1,
        ]
    }

    /// Where the camera looks, in world coordinates.
    public var forward: SIMD3<Double> {
        -zAxis
    }

    func toWorld(_ cameraVector: SIMD3<Double>) -> SIMD3<Double> {
        xAxis * cameraVector.x + yAxis * cameraVector.y + zAxis * cameraVector.z
    }

    /// Inverse rotation. Valid because the axes are orthonormal.
    func toCamera(_ worldVector: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(xAxis.dot(worldVector), yAxis.dot(worldVector), zAxis.dot(worldVector))
    }

    /// Angle of the rotation that takes this pose's orientation to `other`'s, in degrees.
    ///
    /// For rotations A and B, the relative rotation AᵀB has trace 1 + 2·cos θ, and each diagonal
    /// entry of AᵀB is the dot product of matching axes.
    public func rotationDegrees(to other: CameraPose) -> Double {
        let trace = xAxis.dot(other.xAxis) + yAxis.dot(other.yAxis) + zAxis.dot(other.zAxis)
        return acosDegrees((trace - 1) / 2)
    }

    /// Straight-line distance between the two camera positions, in meters.
    public func distance(to other: CameraPose) -> Double {
        (other.position - position).length
    }
}

/// A half-line in world coordinates with a unit-length direction.
public struct Ray: Sendable, Equatable {
    public let origin: SIMD3<Double>
    public let direction: SIMD3<Double>

    /// Normalizes `direction`. Throws for a zero or non-finite direction.
    public init(origin: SIMD3<Double>, direction: SIMD3<Double>) throws(GeometryInputError) {
        let length = direction.length
        guard length.isFinite, length > 0 else {
            throw .degenerateDirection
        }
        self.origin = origin
        self.direction = direction / length
    }

    public func point(at t: Double) -> SIMD3<Double> {
        origin + direction * t
    }

    /// Degrees below the horizon; negative when the ray points above it.
    public var lookDownDegrees: Double {
        90 - acosDegrees(-direction.y)
    }
}

public enum GeometryInputError: Error, Sendable, Equatable {
    case wrongMatrixSize(expected: Int, actual: Int)
    case notAnAffineTransform(bottomRow: [Double])
    case degenerateDirection
}

/// Projection between image pixels and world rays for one saved frame.
///
/// Pixel coordinates are continuous: (0, 0) is the top-left corner of the saved image and
/// (width, height) its bottom-right corner, with v growing downward. That puts pixel centers at
/// half-integers; the half-pixel offset from the other convention is under 0.03° at iPhone focal
/// lengths.
public struct CameraFrame: Sendable, Equatable {
    public var intrinsics: CameraIntrinsics
    public var pose: CameraPose

    public init(intrinsics: CameraIntrinsics, pose: CameraPose) {
        self.intrinsics = intrinsics
        self.pose = pose
    }

    /// The world ray through pixel (u, v).
    ///
    /// In camera space the pixel lies along ((u − cx)/fx, −(v − cy)/fy, −1): image v grows downward
    /// while camera y grows upward, and the camera looks along −z. This is `pixel_ray` in
    /// docs/02-implementation-plan.md.
    /// Throws only for a pose whose axes are zero or non-finite.
    public func ray(throughPixel u: Double, _ v: Double) throws(GeometryInputError) -> Ray {
        let k = intrinsics
        let cameraDirection = SIMD3((u - k.cx) / k.fx, -(v - k.cy) / k.fy, -1)
        return try Ray(origin: pose.position, direction: pose.toWorld(cameraDirection))
    }

    /// The pixel a world point projects to, or nil when the point is not in front of the camera.
    /// The result can fall outside the image.
    public func project(_ point: SIMD3<Double>) -> (u: Double, v: Double)? {
        let p = pose.toCamera(point - pose.position)
        guard p.z < 0 else { return nil }
        let depth = -p.z
        let k = intrinsics
        return (k.cx + k.fx * p.x / depth, k.cy - k.fy * p.y / depth)
    }
}
