import Foundation
import HouseScanKit
import simd

// Synthetic scenes for the 3D map tests: walls, boxes and the ground, rendered into depth frames
// by exact ray casting, with the same ray casting as a ground-truth visibility oracle. World and
// map frame coincide: the meter's foot is the origin, its wall runs along +x and faces +z.

/// fx = fy = 193, cx = 128, cy = 96 on 256 x 192: ARKit's wide camera (about 1450 px focal
/// length on 1920 x 1440) scaled to the LiDAR depth size, 67 by 53 degrees.
let lidarIntrinsics = SIMD4<Float>(193, 193, 128, 96)
let lidarSize = SIMD2<Float>(256, 192)

/// A portrait phone camera at `position` looking at `target`, level side to side, with the
/// LiDAR depth intrinsics. Camera +y is the world's right and camera +x points down the world,
/// as in `makeCamera`.
func lidarCamera(at position: SIMD3<Float>, lookingAt target: SIMD3<Float>) -> CameraFrame {
    let f = simd_normalize(target - position)
    let r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
    let u = simd_cross(r, f)
    let m = simd_float4x4(SIMD4(-u, 0), SIMD4(r, 0), SIMD4(-f, 0), SIMD4(position, 1))
    return CameraFrame(cameraToWorld: m, intrinsics: lidarIntrinsics, imageSize: lidarSize)
}

struct SyntheticScene {
    /// A vertical wall from plan point `a` to `b` ((x, z)), from the ground to `height`.
    struct Wall {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var height: Float = 3
    }

    struct Box {
        var min: SIMD3<Float>
        var max: SIMD3<Float>
    }

    var walls: [Wall]
    var boxes: [Box] = []

    /// Walls joined end to end through `points`, left to right as seen from outside.
    static func chain(_ points: [SIMD2<Float>]) -> [Wall] {
        zip(points, points.dropFirst()).map { Wall(a: $0, b: $1) }
    }

    /// The nearest surface along a ray and its normal facing the ray's origin.
    func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>, maxT: Float = 50) -> (t: Float, normal: SIMD3<Float>)? {
        var best: (t: Float, normal: SIMD3<Float>)?
        func consider(_ t: Float, _ normal: SIMD3<Float>) {
            guard t > 1e-4, t < maxT, t < best?.t ?? .infinity else { return }
            best = (t, simd_dot(normal, direction) > 0 ? -normal : normal)
        }
        // The ground, y = 0.
        if direction.y < 0 { consider(-origin.y / direction.y, SIMD3(0, 1, 0)) }
        for wall in walls {
            let along = wall.b - wall.a
            let length = simd_length(along)
            let normal = SIMD3(-along.y, 0, along.x) / length
            let denominator = simd_dot(normal, direction)
            guard abs(denominator) > 1e-6 else { continue }
            let t = simd_dot(normal, SIMD3(wall.a.x, 0, wall.a.y) - origin) / denominator
            let p = origin + direction * t
            let u = simd_dot(SIMD2(p.x, p.z) - wall.a, along / length)
            guard u >= 0, u <= length, p.y >= 0, p.y <= wall.height else { continue }
            consider(t, normal)
        }
        for box in boxes {
            var near: Float = -.infinity
            var far: Float = .infinity
            var axisHit = 0
            var missed = false
            for axis in 0..<3 {
                if direction[axis] == 0 {
                    if origin[axis] < box.min[axis] || origin[axis] > box.max[axis] { missed = true }
                    continue
                }
                let a = (box.min[axis] - origin[axis]) / direction[axis]
                let b = (box.max[axis] - origin[axis]) / direction[axis]
                if min(a, b) > near {
                    near = min(a, b)
                    axisHit = axis
                }
                far = min(far, max(a, b))
            }
            guard !missed, near <= far, near > 0 else { continue }
            var normal = SIMD3<Float>.zero
            normal[axisHit] = 1
            consider(near, normal)
        }
        return best
    }

    /// Whether `point`, on a surface, is in view of `camera` with nothing in between: in front
    /// of it, inside its image, within `maxDistance` and within `maxAngle` of `normal`.
    func isVisible(_ point: SIMD3<Float>, normal: SIMD3<Float>, from camera: CameraFrame, maxDistance: Float = 5, maxAngle: Float = 65 * .pi / 180) -> Bool {
        guard let pixel = camera.pixel(of: point), camera.contains(pixel: pixel) else { return false }
        let offset = point - camera.position
        let distance = simd_length(offset)
        guard distance <= maxDistance, simd_dot(-offset / distance, normal) >= cos(maxAngle) else { return false }
        guard let hit = intersect(origin: camera.position, direction: offset / distance) else { return true }
        return hit.t >= distance - 2e-3
    }

    /// A LiDAR depth frame: every pixel's z-depth through its center, full confidence; 0 where
    /// the ray meets nothing. `noise` adds a uniform error of up to that many
    /// meters, the same for a given seed (ARKit's LiDAR is within about 1 cm at 1 m and a few
    /// cm at 5 m; 2 cm everywhere is on the rough side).
    func depthFrame(from camera: CameraFrame, noise: Float = 0, seed: UInt64 = 1) -> DepthFrame {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func uniform() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24) * 2 - 1
        }
        let width = Int(camera.imageSize.x)
        let height = Int(camera.imageSize.y)
        var depth = [Float](repeating: 0, count: width * height)
        let forward = camera.forward
        for v in 0..<height {
            for u in 0..<width {
                let ray = camera.ray(throughPixel: SIMD2(Float(u) + 0.5, Float(v) + 0.5))
                guard let hit = intersect(origin: ray.origin, direction: ray.direction) else { continue }
                depth[v * width + u] = max(0, hit.t * simd_dot(ray.direction, forward) + noise * uniform())
            }
        }
        return DepthFrame(
            camera: camera, width: width, height: height, depth: depth,
            kind: .lidar(confidence: [UInt8](repeating: 2, count: width * height)))
    }

    /// An estimated depth frame: every pixel's z-depth plus Gaussian noise of standard deviation
    /// `sigma`, independent per pixel, with `sigma` reported as every pixel's uncertainty, so the
    /// frame is honest about its error. At `sigma` = 0.07 two deviations are within
    /// `Map3DConfig.maxSurfaceSigma` and every pixel may mark a surface: the worst noise the rule
    /// lets through.
    func estimatedFrame(from camera: CameraFrame, sigma: Float, seed: UInt64) -> DepthFrame {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func uniform() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) + 0.5) / Float(1 << 24)
        }
        let exact = depthFrame(from: camera)
        let depth = exact.depth.map { d -> Float in
            guard d > 0 else { return 0 }
            // Box-Muller.
            let gaussian = (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
            return max(0, d + sigma * gaussian)
        }
        return DepthFrame(camera: camera, width: exact.width, height: exact.height, depth: depth, kind: .estimated(sigma: [Float](repeating: sigma, count: depth.count)))
    }

    /// Surface points under a `columns` x `rows` grid of pixels, standing in for the feature
    /// points ARKit would track in the frame.
    func featurePoints(from camera: CameraFrame, columns: Int, rows: Int) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let pixel = SIMD2((Float(column) + 0.5) / Float(columns), (Float(row) + 0.5) / Float(rows)) * camera.imageSize
                let ray = camera.ray(throughPixel: pixel)
                guard let hit = intersect(origin: ray.origin, direction: ray.direction), hit.t <= 5 else { continue }
                points.append(ray.at(hit.t))
            }
        }
        return points
    }
}

/// The map frame for these scenes, with its anchor at the meter's foot so map and world
/// coincide: origin on the ground at the wall, wall along +x, facing +z.
func sceneFrame() -> MapFrame {
    MapFrame(meter: .zero, outward: SIMD3(0, 0, 1), worldGroundY: 0)!
}

/// A straight wall along x from -5 to 6 with a bush in front of it: x 1 to 2, out 0.4 to 1.0,
/// 0.9 m tall.
func bushScene() -> SyntheticScene {
    SyntheticScene(
        walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(6, 0))],
        boxes: [SyntheticScene.Box(min: SIMD3(1, 0, 0.4), max: SIMD3(2, 0.9, 1.0))])
}

/// The bush scene's walk: every 0.3 m from x = -3 to 5, 2.5 m out, the phone at chest height,
/// once aimed at the wall and once down at the ground in front of it.
func bushWalk() -> [CameraFrame] {
    Swift.stride(from: Float(-3), through: 5, by: 0.3).flatMap { x in
        [
            lidarCamera(at: SIMD3(x, 1.4, 2.5), lookingAt: SIMD3(x, 1.0, 0)),
            lidarCamera(at: SIMD3(x, 1.4, 2.5), lookingAt: SIMD3(x, 0, 0.9)),
        ]
    }
}

/// A facade with pilasters: a wall along x from -5 to 7 with pilasters 0.5 m wide standing
/// 0.36 m proud, as ETH3D electro's do, full height, every 2.5 m, none at the meter (x = 0).
func pilasterScene() -> SyntheticScene {
    SyntheticScene(
        walls: [SyntheticScene.Wall(a: SIMD2(-5, 0), b: SIMD2(7, 0))],
        boxes: [Float(-4), -1.5, 1, 3.5, 6].map { x in SyntheticScene.Box(min: SIMD3(x - 0.25, 0, 0), max: SIMD3(x + 0.25, 3, 0.36)) })
}

/// The pilaster facade's walk: every 0.3 m from x = -4 to 6, 2.5 m out, aimed at the wall
/// straight on, and 30 degrees to either side, so the faces between pilasters are seen.
func pilasterWalk() -> [CameraFrame] {
    Swift.stride(from: Float(-4), through: 6, by: 0.3).flatMap { x in
        [Float(0), -1.4, 1.4].map { dx in lidarCamera(at: SIMD3(x, 1.4, 2.5), lookingAt: SIMD3(x + dx, 1.0, 0)) }
    }
}

