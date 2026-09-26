import Foundation
import simd

/// A triangle mesh in world meters: ARKit's scene reconstruction with every anchor's vertices
/// moved into the world frame.
public struct TriangleMesh: Sendable, Equatable {
    public let vertices: [SIMD3<Float>]
    /// Three vertex indices per triangle.
    public let indices: [UInt32]

    /// Traps when `indices` is not whole triangles or names a vertex that does not exist: the
    /// adapter that built the mesh is wrong.
    public init(vertices: [SIMD3<Float>], indices: [UInt32]) {
        precondition(indices.count % 3 == 0, "\(indices.count) indices are not whole triangles")
        if let bad = indices.first(where: { Int($0) >= vertices.count }) {
            preconditionFailure("index \(bad) names a vertex past the \(vertices.count) given")
        }
        self.vertices = vertices
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }

    /// Distance along `ray` (its direction a unit vector) to the nearest triangle it meets within
    /// `range`, from either side; nil when it meets none there.
    ///
    /// Brute force: every triangle is tested (Moller-Trumbore). A facade scan is on the order of
    /// 10^5 triangles and the probes cast about 10 rays per 6 in cell, so a 12 m wall is on the
    /// order of 10^8 tests, which is export-time work, not per-frame. That size is an estimate;
    /// no capture has been timed.
    public func firstHit(_ ray: Ray, within range: ClosedRange<Float>) -> Float? {
        var best: Float?
        var index = 0
        while index + 2 < indices.count {
            let a = vertices[Int(indices[index])]
            let b = vertices[Int(indices[index + 1])]
            let c = vertices[Int(indices[index + 2])]
            index += 3
            let e1 = b - a
            let e2 = c - a
            let p = simd_cross(ray.direction, e2)
            let determinant = simd_dot(e1, p)
            // Parallel to the triangle's plane (or a degenerate triangle).
            guard abs(determinant) > 1e-12 else { continue }
            let inverse = 1 / determinant
            let offset = ray.origin - a
            let u = simd_dot(offset, p) * inverse
            guard u >= 0, u <= 1 else { continue }
            let q = simd_cross(offset, e1)
            let v = simd_dot(ray.direction, q) * inverse
            guard v >= 0, u + v <= 1 else { continue }
            let t = simd_dot(e2, q) * inverse
            guard range.contains(t), t < best ?? .infinity else { continue }
            best = t
        }
        return best
    }
}
