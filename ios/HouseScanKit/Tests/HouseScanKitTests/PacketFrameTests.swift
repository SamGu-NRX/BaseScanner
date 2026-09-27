import Foundation
import HouseScanKit
import simd
import Testing

/// S4's synthetic fixture meter frame (packet/fixtures/synthetic/manifest.json): meter at
/// (3, 0.2, -1.5), wall facing outward (0.5, 0, 0.8660254), a wall turned 30 degrees.
private let fixtureMeter = SIMD3<Float>(3, 0.2, -1.5)
private let fixtureOutward = SIMD3<Float>(0.5, 0, 0.8660254)

private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool {
    simd_distance(a, b) <= tolerance
}

private func near(_ a: SIMD4<Double>, _ b: SIMD4<Double>, _ tolerance: Double = 1e-7) -> Bool {
    simd_distance(a, b) <= tolerance
}

private func near(_ a: simd_float4x4, _ b: simd_float4x4, _ tolerance: Float = 1e-5) -> Bool {
    let columns: [(SIMD4<Float>, SIMD4<Float>)] = [(a.columns.0, b.columns.0), (a.columns.1, b.columns.1), (a.columns.2, b.columns.2), (a.columns.3, b.columns.3)]
    return columns.allSatisfy { simd_distance($0.0, $0.1) <= tolerance }
}

private func matrix(columns x: SIMD3<Float>, _ y: SIMD3<Float>, _ z: SIMD3<Float>) -> simd_float3x3 {
    simd_float3x3(x, y, z)
}

@Suite struct MeterFrameTests {
    @Test func axesFollowTheSpecAndTheFixture() throws {
        let frame = try #require(MeterFrame(meter: fixtureMeter, outward: fixtureOutward))
        let c = frame.meterInWorld.columns
        // +x = y × z: (0, 1, 0) × (0.5, 0, 0.8660254) = (0.8660254, 0, -0.5), the fixture's first column.
        #expect(near(SIMD3(c.0.x, c.0.y, c.0.z), SIMD3(0.8660254, 0, -0.5)))
        #expect(SIMD3(c.1.x, c.1.y, c.1.z) == SIMD3<Float>(0, 1, 0))
        #expect(near(SIMD3(c.2.x, c.2.y, c.2.z), fixtureOutward))
        #expect(SIMD4(c.3.x, c.3.y, c.3.z, c.3.w) == SIMD4<Float>(3, 0.2, -1.5, 1))
    }

    /// Column by column, each Float written as its shortest decimal (0.2, not 0.20000000298).
    @Test func columnMajorLayoutAndDecimals() {
        let m = simd_float4x4(SIMD4(0.8660254, 0, -0.5, 0), SIMD4(0, 1, 0, 0), SIMD4(0.5, 0, 0.8660254, 0), SIMD4(3, 0.2, -1.5, 1))
        let expected: [Double] = [0.8660254, 0, -0.5, 0, 0, 1, 0, 0, 0.5, 0, 0.8660254, 0, 3, 0.2, -1.5, 1]
        #expect(PacketPose.columnMajor(m) == expected)
    }

    /// World (6.232051, 1.2, 0.098076) = meter + 2 x + 1 y + 3 z, worked out by hand from the axes.
    @Test func pointIsTheWorldPointInMeterAxes() throws {
        let frame = try #require(MeterFrame(meter: fixtureMeter, outward: fixtureOutward))
        let world = SIMD3<Float>(6.232051, 1.2, 0.098076)
        #expect(near(frame.point(world), SIMD3(2, 1, 3)))
        #expect(near(frame.worldPoint(SIMD3(2, 1, 3)), world))
        #expect(near(frame.point(fixtureMeter), .zero))
    }

    /// A camera 2.5 m out from the meter looking straight at the wall (camera -z = -outward) has
    /// the meter frame's axes, so its meter-frame pose is identity rotation at (0, 0, 2.5).
    @Test func poseOfACameraFacingTheMeter() throws {
        let frame = try #require(MeterFrame(meter: fixtureMeter, outward: fixtureOutward))
        let axes = frame.meterInWorld.columns
        let position = fixtureMeter + 2.5 * fixtureOutward
        let camera = simd_float4x4(axes.0, axes.1, axes.2, SIMD4(position, 1))
        let expected = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 2.5, 1))
        let pose = frame.pose(camera)
        #expect(near(pose, expected))
        #expect(pose.columns.3.w == 1 && pose.columns.0.w == 0)
        #expect(PacketPose.isRigid(pose))
    }

    @Test func tiltedNormalUsesItsHorizontalPartAndVerticalHasNoFrame() throws {
        let tilted = try #require(MeterFrame(meter: fixtureMeter, outward: SIMD3(0.25, 0.4, 0.4330127)))
        let flat = try #require(MeterFrame(meter: fixtureMeter, outward: fixtureOutward))
        #expect(near(tilted.meterInWorld, flat.meterInWorld))
        #expect(MeterFrame(meter: fixtureMeter, outward: SIMD3(0, 1, 0)) == nil)
        #expect(MeterFrame(meter: SIMD3(.nan, 0, 0), outward: fixtureOutward) == nil)
    }

    /// The standard wall: meter (0, 1.5, 0), outward +z, ground at 0. Meter-frame x is scene s, y
    /// is height less the meter's 1.5 m, z is out.
    @Test func wallCoordinatesOnTheMetersWall() throws {
        let wall = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)
        let frame = try #require(MeterFrame(wall: wall))
        #expect(near(frame.point(on: wall, s: 2, height: 0.5, out: 1), SIMD3(2, -1, 1)))
        // The frame's +x is scene.json's +s on any wall.
        for angle in stride(from: Float(0), to: 6.28, by: 0.7) {
            let turned = SceneWall(meter: SIMD3(1, 1.2, -2), outward: SIMD3(sin(angle), 0, cos(angle)), groundY: 0.1)
            let turnedFrame = try #require(MeterFrame(wall: turned))
            let x = turnedFrame.meterInWorld.columns.0
            #expect(near(SIMD3(x.x, x.y, x.z), turned.along))
        }
    }

    /// Round a right corner at s = 3 the wall faces +x, so its +s runs along -z: s = 4 is 1 m past
    /// the corner, at world (3, y, -1) from the meter's foot.
    @Test func wallCoordinatesRoundACorner() throws {
        let wall = SceneWall(
            meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0,
            rightCorners: [WallCorner(s: 3, outward: SIMD3(1, 0, 0))])
        let frame = try #require(MeterFrame(wall: wall))
        #expect(near(frame.point(on: wall, s: 4, height: 1.5, out: 0), SIMD3(3, 0, -1)))
        #expect(near(frame.point(on: wall, s: 4, height: 0, out: 0.5), SIMD3(3.5, -1.5, -1)))
    }

    @Test func meshMovesIntoTheFrame() throws {
        let frame = try #require(MeterFrame(meter: fixtureMeter, outward: fixtureOutward))
        let world = TriangleMesh(vertices: [fixtureMeter, SIMD3(6.232051, 1.2, 0.098076), fixtureMeter + fixtureOutward], indices: [0, 1, 2])
        let moved = frame.mesh(world)
        #expect(moved.indices == [0, 1, 2])
        #expect(near(moved.vertices[0], .zero) && near(moved.vertices[1], SIMD3(2, 1, 3)) && near(moved.vertices[2], SIMD3(0, 0, 1)))
    }

    @Test func rigidRejectsScaleReflectionAndABadLastRow() {
        #expect(PacketPose.isRigid(matrix_identity_float4x4))
        var scaled = matrix_identity_float4x4
        scaled.columns.0.x = 1.01
        #expect(!PacketPose.isRigid(scaled))
        var mirrored = matrix_identity_float4x4
        mirrored.columns.2.z = -1
        #expect(!PacketPose.isRigid(mirrored))
        var projective = matrix_identity_float4x4
        projective.columns.0.w = 0.1
        #expect(!PacketPose.isRigid(projective))
    }
}

@Suite struct PacketQuaternionTests {
    private let half = 0.5.squareRoot()

    @Test func identityAndQuarterTurns() {
        #expect(near(PacketPose.quaternion(matrix_identity_float3x3), SIMD4(0, 0, 0, 1)))
        // 90 degrees about +y: x -> -z, z -> x.
        let aboutY = matrix(columns: SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0))
        #expect(near(PacketPose.quaternion(aboutY), SIMD4(0, half, 0, half)))
        // -90 degrees about +y comes out with w >= 0 and a negative axis.
        let backY = matrix(columns: SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(-1, 0, 0))
        #expect(near(PacketPose.quaternion(backY), SIMD4(0, -half, 0, half)))
    }

    /// Half turns take the three branches where the trace is not positive; w is 0.
    @Test func halfTurnsTakeEachBranch() {
        #expect(near(PacketPose.quaternion(simd_float3x3(diagonal: SIMD3(1, -1, -1))), SIMD4(1, 0, 0, 0)))
        #expect(near(PacketPose.quaternion(simd_float3x3(diagonal: SIMD3(-1, 1, -1))), SIMD4(0, 1, 0, 0)))
        #expect(near(PacketPose.quaternion(simd_float3x3(diagonal: SIMD3(-1, -1, 1))), SIMD4(0, 0, 1, 0)))
    }

    /// 120 degrees about (1, 1, 1)/√3 maps x -> y -> z: q = (sin 60°/√3 (1, 1, 1), cos 60°) =
    /// (0.5, 0.5, 0.5, 0.5). Its inverse (240 degrees) reaches the last branch with w = -0.5 and is
    /// flipped to w >= 0.
    @Test func thirdTurnsAndTheSignConvention() {
        let forward = matrix(columns: SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        #expect(near(PacketPose.quaternion(forward), SIMD4(0.5, 0.5, 0.5, 0.5)))
        #expect(near(PacketPose.quaternion(forward.transpose), SIMD4(-0.5, -0.5, -0.5, 0.5)))
    }

    /// Any rotation: the quaternion is unit, w >= 0, and turns vectors as the matrix does.
    @Test func arbitraryRotationsRoundTrip() {
        let axes: [SIMD3<Float>] = [SIMD3(1, 2, 3), SIMD3(-2, 0.5, 1), SIMD3(0, -1, 0.2), SIMD3(3, -1, -2)]
        for axis in axes {
            for angle in stride(from: Float(0.3), to: 6.2, by: 0.9) {
                let r = simd_float3x3(simd_quatf(angle: angle, axis: simd_normalize(axis)))
                let q = PacketPose.quaternion(r)
                #expect(abs(simd_length(q) - 1) < 1e-12)
                #expect(q.w >= 0)
                let turn = simd_quatd(vector: q)
                let v = SIMD3<Double>(0.3, -0.7, 0.9)
                let byMatrix = SIMD3<Double>(r * SIMD3<Float>(v))
                #expect(simd_distance(turn.act(v), byMatrix) < 1e-5)
            }
        }
    }

    /// Length on the ground plane only: y changes do not count.
    @Test func horizontalDistance() {
        let path: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(3, 5, 4), SIMD3(3, -2, 4), SIMD3(3, 0, 6)]
        #expect(PacketPose.horizontalDistance(path) == 7)
        #expect(PacketPose.horizontalDistance([SIMD3(1, 1, 1)]) == 0)
    }
}
