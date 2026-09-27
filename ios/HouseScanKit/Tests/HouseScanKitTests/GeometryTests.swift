import Foundation
import HouseScanKit
import simd
import Testing

@Suite struct CameraFrameTests {
    // Level portrait camera looking along -z: f = (0, 0, -1), r = cross(f, up) = (1, 0, 0),
    // u = cross(r, f) = (0, 1, 0); columns c0 = -u = (0, -1, 0), c1 = (1, 0, 0), c2 = (0, 0, 1).
    let origin = SIMD3<Float>(1, 1.5, 3)
    var level: CameraFrame { portraitCamera(at: origin, forward: SIMD3(0, 0, -1)) }

    @Test func projectsAKnownPoint() throws {
        // Offset d = (0.2, 0.1, -2): camera x = c0 . d = -0.1, y = c1 . d = 0.2, z = c2 . d = -2.
        // u = 320 + 500 * -0.1 / 2 = 295, v = 240 - 500 * 0.2 / 2 = 190.
        let pixel = try #require(level.pixel(of: origin + SIMD3(0.2, 0.1, -2)))
        #expect(nearlyEqual(pixel, SIMD2(295, 190)))
    }

    @Test func pointsBehindOrTooNearHaveNoPixel() {
        #expect(level.pixel(of: origin + SIMD3(0, 0, 2)) == nil)
        // Depth 0.04 is under the default minDepth of 0.05.
        #expect(level.pixel(of: origin + SIMD3(0, 0, -0.04)) == nil)
        #expect(level.pixel(of: origin + SIMD3(0, 0, -0.06)) != nil)
    }

    @Test func rayThroughPixelRoundTrips() throws {
        let camera = portraitCamera(at: origin, lookingAt: SIMD3(-2, 0.5, -1))
        let pixel = SIMD2<Float>(100, 400)
        let ray = camera.ray(throughPixel: pixel)
        #expect(nearlyEqual(simd_length(ray.direction), 1))
        #expect(ray.origin == camera.position)
        let back = try #require(camera.pixel(of: ray.at(3)))
        #expect(nearlyEqual(back, pixel))
    }

    @Test func principalPointLooksForward() {
        let camera = portraitCamera(at: origin, lookingAt: SIMD3(-2, 0.5, -1))
        let expected = simd_normalize(SIMD3<Float>(-2, 0.5, -1) - origin)
        #expect(nearlyEqual(camera.forward, expected))
        #expect(nearlyEqual(camera.ray(throughPixel: SIMD2(320, 240)).direction, expected))
    }

    @Test func columnMajorPutsTranslationAtTwelveToFourteen() throws {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(7, 8, 9, 1)
        let numbers = m.columnMajor
        #expect(numbers.count == 16)
        #expect(Array(numbers[12...15]) == [7, 8, 9, 1])
        #expect(numbers[0] == 1 && numbers[5] == 1 && numbers[10] == 1)
        #expect(numbers[1] == 0 && numbers[4] == 0)

        let frame = try #require(CameraFrame(columnMajorPose: level.cameraToWorld.columnMajor, intrinsics: testIntrinsics, imageSize: testImageSize))
        #expect(frame == level)
        #expect(frame.position == origin)
    }

    @Test func columnMajorPoseRejectsBadInput() {
        var pose = matrix_identity_float4x4.columnMajor
        #expect(CameraFrame(columnMajorPose: Array(pose.prefix(15)), intrinsics: testIntrinsics, imageSize: testImageSize) == nil)
        #expect(CameraFrame(columnMajorPose: pose + [0], intrinsics: testIntrinsics, imageSize: testImageSize) == nil)
        pose[13] = .nan
        #expect(CameraFrame(columnMajorPose: pose, intrinsics: testIntrinsics, imageSize: testImageSize) == nil)
        pose[13] = .infinity
        #expect(CameraFrame(columnMajorPose: pose, intrinsics: testIntrinsics, imageSize: testImageSize) == nil)
    }

    @Test func rotationAngleOfAQuarterYaw() {
        // Looking along -z versus -x: the same pose turned 90 degrees about +y.
        let a = portraitCamera(at: .zero, forward: SIMD3(0, 0, -1))
        let b = portraitCamera(at: SIMD3(5, 0, 0), forward: SIMD3(-1, 0, 0))
        #expect(nearlyEqual(a.rotationAngle(to: b), .pi / 2, 1e-3))
        #expect(nearlyEqual(a.rotationAngle(to: a), 0, 1e-3))
    }

    @Test func containsHonoursTheMargin() {
        // Margin 0.1 of 640 x 480 insets 64 px and 48 px.
        #expect(level.contains(pixel: SIMD2(64, 48), margin: 0.1))
        #expect(!level.contains(pixel: SIMD2(63, 240), margin: 0.1))
        #expect(!level.contains(pixel: SIMD2(320, 433), margin: 0.1))
        #expect(level.contains(pixel: SIMD2(640, 480)))
    }
}

@Suite struct WallFrameTests {
    @Test func alongIsRightWhenFacingTheWall() throws {
        // cross(-(0, 0, 1), up) = cross((0, 0, -1), (0, 1, 0)) = (1, 0, 0).
        #expect(standardWall().along == SIMD3(1, 0, 0))
        // cross(-(1, 0, 0), up) = cross((-1, 0, 0), (0, 1, 0)) = (0, 0, -1).
        let east = try #require(WallFrame(meter: .zero, outward: SIMD3(1, 0, 0), groundY: 0))
        #expect(east.along == SIMD3(0, 0, -1))
    }

    @Test func outwardIsFlattenedAndNormalized() throws {
        let wall = try #require(WallFrame(meter: .zero, outward: SIMD3(0, 3, 2), groundY: 0))
        #expect(wall.outward == SIMD3(0, 0, 1))
    }

    @Test func verticalOutwardIsRejected() {
        #expect(WallFrame(meter: .zero, outward: SIMD3(0, 1, 0), groundY: 0) == nil)
        #expect(WallFrame(meter: .zero, outward: SIMD3(0.0005, -1, 0.0005), groundY: 0) == nil)
    }

    @Test func worldAndWallPointRoundTrip() throws {
        // Origin (2, 0.2, 3), along (0, 0, -1), outward (1, 0, 0).
        // (s 1, height 0.7, out 0.4) -> (2 + 0.4, 0.2 + 0.7, 3 - 1) = (2.4, 0.9, 2).
        let wall = try #require(WallFrame(meter: SIMD3(2, 1.5, 3), outward: SIMD3(1, 0, 0), groundY: 0.2))
        #expect(nearlyEqual(wall.meterHeight, 1.3))
        let point = WallPoint(s: 1, height: 0.7, out: 0.4)
        let world = wall.world(point)
        #expect(nearlyEqual(world, SIMD3(2.4, 0.9, 2)))
        let back = wall.wallPoint(world)
        #expect(nearlyEqual(back.s, 1) && nearlyEqual(back.height, 0.7) && nearlyEqual(back.out, 0.4))
    }

    @Test func intersectWall() throws {
        let wall = standardWall()
        // Straight in from (1, 1, 2): hits (1, 1, 0).
        let straight = try #require(wall.intersectWall(Ray(origin: SIMD3(1, 1, 2), direction: SIMD3(0, 0, -1))))
        #expect(nearlyEqual(straight.s, 1) && nearlyEqual(straight.height, 1) && nearlyEqual(straight.out, 0))
        // From (0, 1.6, 2) along (1, -0.5, -2): z reaches 0 after one unit of that vector, at (1, 1.1, 0).
        let slanted = try #require(wall.intersectWall(Ray(origin: SIMD3(0, 1.6, 2), direction: simd_normalize(SIMD3(1, -0.5, -2)))))
        #expect(nearlyEqual(slanted.s, 1) && nearlyEqual(slanted.height, 1.1) && nearlyEqual(slanted.out, 0))
        // Pointing away and running parallel both miss.
        #expect(wall.intersectWall(Ray(origin: SIMD3(0, 1, 2), direction: SIMD3(0, 0, 1))) == nil)
        #expect(wall.intersectWall(Ray(origin: SIMD3(0, 1, 2), direction: SIMD3(1, 0, 0))) == nil)
    }

    @Test func intersectGround() throws {
        let wall = standardWall()
        // From (0.5, 1.6, 2) along (0, -1.6, -1): y reaches 0 after one unit, at (0.5, 0, 1).
        let hit = try #require(wall.intersectGround(Ray(origin: SIMD3(0.5, 1.6, 2), direction: simd_normalize(SIMD3(0, -1.6, -1)))))
        #expect(nearlyEqual(hit.s, 0.5) && nearlyEqual(hit.height, 0) && nearlyEqual(hit.out, 1))
        #expect(wall.intersectGround(Ray(origin: SIMD3(0, 1.6, 2), direction: SIMD3(0, 1, 0))) == nil)
    }
}
