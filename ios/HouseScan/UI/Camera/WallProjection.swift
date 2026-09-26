import SwiftUI
import simd

/// Projects wall-frame shapes (s, height, out) onto the camera view.
///
/// Every overlay is drawn from world points through `CameraProjection`, never from cached
/// screen positions, so when ARKit corrects the meter's anchor the overlays move with the wall.
struct WallProjection {
    var projection: CameraProjection
    var wall: WallGeometry
    var size: CGSize

    func point(_ world: SIMD3<Float>) -> CGPoint? {
        projection.viewPoint(for: world, in: size)
    }

    func point(s: Float, height: Float, out: Float = 0) -> CGPoint? {
        point(wall.world(s: s, height: height, out: out))
    }

    /// A quad on the wall face, or nil when any corner is behind the camera. Cells are small
    /// (6 in wide), so dropping one that straddles the camera plane loses nothing visible.
    func wallQuad(s: ClosedRange<Float>, height: ClosedRange<Float>, out: Float = 0) -> Path? {
        polygon([
            wall.world(s: s.lowerBound, height: height.lowerBound, out: out),
            wall.world(s: s.upperBound, height: height.lowerBound, out: out),
            wall.world(s: s.upperBound, height: height.upperBound, out: out),
            wall.world(s: s.lowerBound, height: height.upperBound, out: out),
        ])
    }

    /// A quad on the ground in front of the wall.
    func groundQuad(s: ClosedRange<Float>, out: ClosedRange<Float>, height: Float = 0) -> Path? {
        polygon([
            wall.world(s: s.lowerBound, height: height, out: out.lowerBound),
            wall.world(s: s.upperBound, height: height, out: out.lowerBound),
            wall.world(s: s.upperBound, height: height, out: out.upperBound),
            wall.world(s: s.lowerBound, height: height, out: out.upperBound),
        ])
    }

    func polygon(_ corners: [SIMD3<Float>]) -> Path? {
        var points: [CGPoint] = []
        points.reserveCapacity(corners.count)
        for corner in corners {
            guard let p = point(corner) else { return nil }
            points.append(p)
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// Meters per view point at a world point, for sizing things that should shrink with
    /// distance (path dots, pins).
    func pointsPerMeter(at world: SIMD3<Float>) -> CGFloat? {
        let local = projection.cameraSpace(world)
        guard local.z < -0.05 else { return nil }
        let focal = CGFloat(projection.intrinsics.x)
        return focal * projection.scale(in: size) / CGFloat(-local.z)
    }

    /// The camera's position along the wall, in meters of s.
    var cameraS: Float {
        simd_dot(projection.cameraPosition - wall.meter, wall.along)
    }
}

extension CameraProjection {
    /// Screen direction toward a world point, as a unit vector in view space, usable even when
    /// the point is behind the camera. Camera +y (up in the sensor image) is screen right and
    /// camera +x is screen down, because the sensor image is shown rotated 90° clockwise.
    func screenDirection(toward world: SIMD3<Float>) -> CGVector? {
        let local = cameraSpace(world)
        var dx = CGFloat(local.y)
        var dy = CGFloat(local.x)
        if local.z > 0 {
            // Behind: the point is reached by turning around, so point toward the nearer side.
            dx = dx == 0 ? 1 : dx
            dy = 0
        }
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-5 else { return nil }
        return CGVector(dx: dx / length, dy: dy / length)
    }
}
