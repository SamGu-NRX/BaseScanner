import HouseScanKit
import simd

// Synthetic scenes for the LiDAR tests: meshes built from quads and boxes, and depth images
// rendered from them by casting one ray per pixel centre.

struct MeshBuilder {
    var vertices: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    /// Two triangles, a b c and a c d.
    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
        let base = UInt32(vertices.count)
        vertices += [a, b, c, d]
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    /// The six faces of an axis-aligned box.
    mutating func box(_ low: SIMD3<Float>, _ high: SIMD3<Float>) {
        func p(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, y, z) }
        let (x0, y0, z0, x1, y1, z1) = (low.x, low.y, low.z, high.x, high.y, high.z)
        quad(p(x0, y0, z1), p(x1, y0, z1), p(x1, y1, z1), p(x0, y1, z1))  // front, +z
        quad(p(x0, y0, z0), p(x0, y1, z0), p(x1, y1, z0), p(x1, y0, z0))  // back, -z
        quad(p(x0, y1, z0), p(x0, y1, z1), p(x1, y1, z1), p(x1, y1, z0))  // top
        quad(p(x0, y0, z0), p(x1, y0, z0), p(x1, y0, z1), p(x0, y0, z1))  // bottom
        quad(p(x0, y0, z0), p(x0, y0, z1), p(x0, y1, z1), p(x0, y1, z0))  // left, -x
        quad(p(x1, y0, z0), p(x1, y1, z0), p(x1, y1, z1), p(x1, y0, z1))  // right, +x
    }

    var mesh: TriangleMesh { TriangleMesh(vertices: vertices, indices: indices) }
}

/// The standard wall's surroundings (see `standardWall()`): the wall face z = 0 for x in
/// [-10, 10] up to 4 m, the ground y = 0 in front of it out to z = 10, and `boxes`.
func standardScene(boxes: [(SIMD3<Float>, SIMD3<Float>)] = []) -> TriangleMesh {
    var builder = MeshBuilder()
    builder.quad(SIMD3(-10, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 4, 0), SIMD3(-10, 4, 0))
    builder.quad(SIMD3(-10, 0, 0), SIMD3(-10, 0, 10), SIMD3(10, 0, 10), SIMD3(10, 0, 0))
    for (low, high) in boxes { builder.box(low, high) }
    return builder.mesh
}

/// The z-depth `camera` would read of `mesh`: a 128 x 96 image (a fifth of the 640 x 480 test
/// sensor, fx = fy = 100, cx = 64, cy = 48), one ray through each pixel centre, high confidence
/// everywhere, 0 where the ray meets nothing within 20 m.
func renderDepth(_ mesh: TriangleMesh, from camera: CameraFrame, width: Int = 128, height: Int = 96) -> DepthImage {
    let intrinsics = DepthImage.intrinsics(scaling: camera.intrinsics, from: camera.imageSize, toWidth: width, height: height)
    let depthCamera = CameraFrame(cameraToWorld: camera.cameraToWorld, intrinsics: intrinsics, imageSize: SIMD2(Float(width), Float(height)))
    var millimeters: [UInt16] = []
    millimeters.reserveCapacity(width * height)
    for v in 0..<height {
        for u in 0..<width {
            let ray = depthCamera.ray(throughPixel: SIMD2(Float(u) + 0.5, Float(v) + 0.5))
            guard let t = mesh.firstHit(ray, within: 0.01...20) else {
                millimeters.append(0)
                continue
            }
            millimeters.append(UInt16((t * simd_dot(ray.direction, camera.forward) * 1000).rounded()))
        }
    }
    return DepthImage(width: width, height: height, millimeters: millimeters, confidence: Array(repeating: 2, count: width * height), intrinsics: intrinsics)
}

/// A 128 x 96 depth image reading `millimeters` everywhere, with the rendered images' intrinsics.
func uniformDepth(_ millimeters: UInt16, confidence: UInt8? = 2) -> DepthImage {
    DepthImage(
        width: 128, height: 96, millimeters: Array(repeating: millimeters, count: 128 * 96),
        confidence: confidence.map { Array(repeating: $0, count: 128 * 96) }, intrinsics: SIMD4(100, 100, 64, 48))
}
