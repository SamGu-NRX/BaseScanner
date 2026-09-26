import Testing
@testable import MeasureGeometry

struct CameraTests {
    // fx = fy = 1000 px, principal point at the center of a 1920 × 1440 image.
    let intrinsics = CameraIntrinsics(fx: 1000, fy: 1000, cx: 960, cy: 720)

    @Test func `pose round-trips through a column-major matrix`() throws {
        let pose = CameraPose(
            xAxis: SIMD3(0, 1, 0), yAxis: SIMD3(-1, 0, 0), zAxis: SIMD3(0, 0, 1), position: SIMD3(1, 2, 3)
        )
        #expect(pose.columnMajor == [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1, 2, 3, 1])
        #expect(try CameraPose(columnMajor: pose.columnMajor) == pose)
    }

    @Test func `pose rejects a malformed matrix`() {
        #expect(throws: GeometryInputError.wrongMatrixSize(expected: 16, actual: 12)) {
            try CameraPose(columnMajor: Array(repeating: 0, count: 12))
        }
        var projective = identityPose.columnMajor
        projective[3] = 0.5
        #expect(throws: GeometryInputError.notAnAffineTransform(bottomRow: [0.5, 0, 0, 1])) {
            try CameraPose(columnMajor: projective)
        }
    }

    @Test func `rotation angle between poses`() {
        #expect(identityPose.rotationDegrees(to: identityPose) == 0)
        #expect(isClose(identityPose.rotationDegrees(to: poseTurned(90)), 90))
        #expect(isClose(poseTurned(10).rotationDegrees(to: poseTurned(25)), 15))
        #expect(isClose(poseTurned(-170).rotationDegrees(to: poseTurned(170)), 20))
    }

    @Test func `distance between camera positions`() {
        #expect(poseTurned(0, at: SIMD3(1, 1, 1)).distance(to: poseTurned(40, at: SIMD3(4, 5, 1))) == 5)
    }

    @Test func `ray normalizes its direction and refuses a zero one`() throws {
        let ray = try Ray(origin: .zero, direction: SIMD3(0, 3, -4))
        #expect(isClose(ray.direction, SIMD3(0, 0.6, -0.8)))
        #expect(isClose(ray.point(at: 10), SIMD3(0, 6, -8)))
        #expect(throws: GeometryInputError.degenerateDirection) {
            try Ray(origin: .zero, direction: .zero)
        }
        #expect(throws: GeometryInputError.degenerateDirection) {
            try Ray(origin: .zero, direction: SIMD3(.nan, 0, 1))
        }
    }

    @Test(arguments: [
        (SIMD3<Double>(0, -1, -1), 45.0),
        (SIMD3<Double>(0, -1, 0), 90.0),
        (SIMD3<Double>(1, 0, 0), 0.0),
        (SIMD3<Double>(0, 1, -3.0.squareRoot()), -30.0),
    ])
    func `look-down angle below the horizon`(direction: SIMD3<Double>, expected: Double) throws {
        #expect(isClose(try Ray(origin: .zero, direction: direction).lookDownDegrees, expected))
    }

    @Test func `pixel rays for an unrotated camera`() throws {
        let frame = CameraFrame(intrinsics: intrinsics, pose: identityPose)
        // Principal point: straight ahead along −z.
        #expect(isClose(try frame.ray(throughPixel: 960, 720).direction, SIMD3(0, 0, -1)))
        // 1000 px right of center at fx = 1000: 45° to the right.
        #expect(isClose(try frame.ray(throughPixel: 1960, 720).direction, SIMD3(1, 0, -1) / 2.0.squareRoot()))
        // 1000 px below center: image v grows down, camera y grows up, so the ray points down.
        #expect(isClose(try frame.ray(throughPixel: 960, 1720).direction, SIMD3(0, -1, -1) / 2.0.squareRoot()))
        // Unequal focal lengths scale each axis separately: (500/1000, -(−200)/800, −1).
        let stretched = CameraFrame(intrinsics: CameraIntrinsics(fx: 1000, fy: 800, cx: 960, cy: 720), pose: identityPose)
        #expect(isClose(try stretched.ray(throughPixel: 1460, 520).direction, SIMD3(0.5, 0.25, -1) / 1.3125.squareRoot()))
    }

    @Test func `pixel ray uses the pose rotation and position`() throws {
        // Camera x points along world +y, camera y along world −x, camera z along world +z.
        let pose = CameraPose(
            xAxis: SIMD3(0, 1, 0), yAxis: SIMD3(-1, 0, 0), zAxis: SIMD3(0, 0, 1), position: SIMD3(1, 2, 3)
        )
        let frame = CameraFrame(intrinsics: intrinsics, pose: pose)
        // Camera direction (1, 0, −1) becomes world (0, 1, 0) − (0, 0, 1).
        let ray = try frame.ray(throughPixel: 1960, 720)
        #expect(ray.origin == SIMD3(1, 2, 3))
        #expect(isClose(ray.direction, SIMD3(0, 1, -1) / 2.0.squareRoot()))
    }

    @Test func `projection inverts the pixel ray`() throws {
        let pose = CameraPose(
            xAxis: SIMD3(0, 1, 0), yAxis: SIMD3(-1, 0, 0), zAxis: SIMD3(0, 0, 1), position: SIMD3(1, 2, 3)
        )
        let frame = CameraFrame(intrinsics: intrinsics, pose: pose)
        // (1, 4, 1) − position = (0, 2, −2): camera (2, 0, −2), depth 2, so u = 960 + 1000·2/2.
        let pixel = try #require(frame.project(SIMD3(1, 4, 1)))
        #expect(isClose(pixel.u, 1960))
        #expect(isClose(pixel.v, 720))

        let tilted = CameraFrame(intrinsics: intrinsics, pose: poseTurned(30, at: SIMD3(0.5, 1.4, 2)))
        for (u, v) in [(100.0, 50.0), (1800.0, 1400.0), (960.0, 720.0)] {
            let point = try tilted.ray(throughPixel: u, v).point(at: 7.5)
            let back = try #require(tilted.project(point))
            #expect(isClose(back.u, u, within: 1e-6))
            #expect(isClose(back.v, v, within: 1e-6))
        }
    }

    @Test func `projection refuses points behind the camera`() {
        let frame = CameraFrame(intrinsics: intrinsics, pose: identityPose)
        #expect(frame.project(SIMD3(0, 0, 1)) == nil)
        #expect(frame.project(SIMD3(1, 0, 0)) == nil)
    }
}
