import Foundation
import simd

/// The perspective transform that takes a `width` by `height` rectangle onto a quadrilateral,
/// for drawing a flat picture onto a wall seen at an angle. Heckbert's square-to-quad mapping
/// ("Fundamentals of Texture Mapping and Image Warping", 1989, section 2.2.3) with the rectangle
/// scaled to the unit square first.
///
/// The matrix is for row vectors, as SwiftUI's `ProjectionTransform` and `CGAffineTransform`
/// use: `[x y 1] * m` gives `[X Y W]`, and the point is `(X / W, Y / W)`. Its columns are
/// `m.columns.0` = (m11, m21, m31) and so on, so `m[column][row]`.
public enum QuadHomography {
    /// Corners are the rectangle's top left (0, 0), top right (width, 0), bottom right
    /// (width, height) and bottom left (0, height), in that order. Nil when the rectangle is empty
    /// or the quad is degenerate (three corners in a line), where no such transform exists.
    public static func mapping(width: Double, height: Double, to quad: [SIMD2<Double>]) -> simd_double3x3? {
        guard quad.count == 4, width > 0, height > 0 else { return nil }
        let (p0, p1, p2, p3) = (quad[0], quad[1], quad[2], quad[3])
        let sum = p0 - p1 + p2 - p3
        var g = 0.0
        var h = 0.0
        if abs(sum.x) > 1e-12 || abs(sum.y) > 1e-12 {
            let d1 = p1 - p2
            let d2 = p3 - p2
            let det = d1.x * d2.y - d2.x * d1.y
            guard abs(det) > 1e-12 else { return nil }
            g = (sum.x * d2.y - d2.x * sum.y) / det
            h = (d1.x * sum.y - sum.x * d1.y) / det
        }
        // Unit square (u, v) to the quad: X = a u + b v + c, Y = d u + e v + f, W = g u + h v + 1.
        let a = p1.x - p0.x + g * p1.x
        let b = p3.x - p0.x + h * p3.x
        let d = p1.y - p0.y + g * p1.y
        let e = p3.y - p0.y + h * p3.y
        let unit = simd_double3x3(rows: [
            SIMD3(a, d, g),
            SIMD3(b, e, h),
            SIMD3(p0.x, p0.y, 1),
        ])
        guard abs(unit.determinant) > 1e-12 else { return nil }
        // u = x / width, v = y / height, applied first.
        let scale = simd_double3x3(diagonal: SIMD3(1 / width, 1 / height, 1))
        return scale * unit
    }

    /// Where `m` sends the point (x, y); nil when it goes to infinity.
    public static func apply(_ m: simd_double3x3, to point: SIMD2<Double>) -> SIMD2<Double>? {
        let row = SIMD3(point.x, point.y, 1)
        // Row vector times matrix: component i is the dot product with column i.
        let out = SIMD3(simd_dot(row, m.columns.0), simd_dot(row, m.columns.1), simd_dot(row, m.columns.2))
        guard abs(out.z) > 1e-12 else { return nil }
        return SIMD2(out.x / out.z, out.y / out.z)
    }
}
