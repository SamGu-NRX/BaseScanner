import HouseScanKit
import simd

// Shared fixtures for the engine tests. World meters, +y up. Every camera uses ARKit's convention:
// camera +x is the landscape sensor's right, +y its up, and it looks along -z.

/// fx = fy = 500, cx = 320, cy = 240 on a 640 x 480 sensor image.
let testIntrinsics = SIMD4<Float>(500, 500, 320, 240)
let testImageSize = SIMD2<Float>(640, 480)

/// A camera looking along `forward` whose camera +y is `right`. With u = cross(right, forward), the
/// columns are (-u, right, -forward): a phone held upright in portrait, whose landscape sensor has
/// +x pointing down the world.
func makeCamera(at position: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>) -> CameraFrame {
    let f = simd_normalize(forward)
    let r = simd_normalize(right)
    let u = simd_cross(r, f)
    let m = simd_float4x4(
        SIMD4(-u, 0),
        SIMD4(r, 0),
        SIMD4(-f, 0),
        SIMD4(position, 1)
    )
    return CameraFrame(cameraToWorld: m, intrinsics: testIntrinsics, imageSize: testImageSize)
}

/// A portrait camera looking along `forward`, level side to side: right = normalize(cross(f, up)).
/// `forward` must not be vertical.
func portraitCamera(at position: SIMD3<Float>, forward: SIMD3<Float>) -> CameraFrame {
    let f = simd_normalize(forward)
    return makeCamera(at: position, forward: f, right: simd_cross(f, SIMD3(0, 1, 0)))
}

func portraitCamera(at position: SIMD3<Float>, lookingAt target: SIMD3<Float>) -> CameraFrame {
    portraitCamera(at: position, forward: target - position)
}

/// Forward of a camera facing -z and pitched down by `degrees`: (0, -sin, -cos).
func forwardFacingWall(pitchedDown degrees: Float) -> SIMD3<Float> {
    let a = degrees * .pi / 180
    return SIMD3(0, -sin(a), -cos(a))
}

/// The wall most tests use: the face is the plane z = 0, outward +z (so along = +x and s = x),
/// meter at (0, 1.5, 0), ground at y = 0.
func standardWall() -> WallFrame {
    WallFrame(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)!
}

// Two cameras with simple footprints on the standard wall, used to build coverage maps whose cells
// can be worked out by hand. Image margin 3 % leaves u in [19.2, 620.8] and v in [14.4, 465.6].

/// Level camera at (c, 1.2, 2.0) facing the wall. A wall sample (s, h, 0) is 2 m deep and lands on
/// u = 320 + 250 (1.2 - h) = 520, 320, 120 for h = 0.4, 1.2, 2.0, and v = 240 - 250 (s - c), so it
/// sees every wall sample with |s - c| <= 225.6 / 250 = 0.9024. A ground sample (s, 0, o) has
/// camera x = 1.2 at depth 2 - o <= 1.8, so u >= 320 + 500 * 1.2 / 1.8 = 653 > 620.8: never seen.
/// A wall cell with lower edge L (samples at L + 0.0381 and L + 0.1143) is therefore seen exactly
/// when c is in [L - 0.7881, L + 0.9405].
func wallCamera(s c: Float) -> CameraFrame {
    makeCamera(at: SIMD3(c, 1.2, 2.0), forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0))
}

/// Camera at (c, 1.0, 0.6) looking straight down, image +y (camera y) along +x. A ground sample
/// (s, 0, o) is 1 m deep and lands on u = 320 + 500 (o - 0.6) = 120, 320, 520 for o = 0.2, 0.6, 1.0
/// and v = 240 - 500 (s - c), so it sees every ground sample with |s - c| <= 225.6 / 500 = 0.4512.
/// The wall sample at h = 0.4 lands on u = 320 - 500 * 0.6 / 0.6 = -180 and higher ones are behind
/// it: the wall is never seen. A ground cell with lower edge L is seen exactly when c is in
/// [L - 0.3369, L + 0.4893].
func groundCamera(s c: Float) -> CameraFrame {
    makeCamera(at: SIMD3(c, 1.0, 0.6), forward: SIMD3(0, -1, 0), right: SIMD3(1, 0, 0))
}

func nearlyEqual(_ a: Float, _ b: Float, _ tolerance: Float = 1e-4) -> Bool {
    abs(a - b) <= tolerance
}

func nearlyEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ tolerance: Float = 1e-3) -> Bool {
    simd_distance(a, b) <= tolerance
}

func nearlyEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool {
    simd_distance(a, b) <= tolerance
}

func nearlyEqual(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>, _ tolerance: Float = 1e-4) -> Bool {
    nearlyEqual(a.lowerBound, b.lowerBound, tolerance) && nearlyEqual(a.upperBound, b.upperBound, tolerance)
}
