import HouseScanKit
import simd
import Testing

/// Where an aim target lies from the view (#81). The homeowner stands 2.6 m out at s = 0 with the
/// phone 1.4 m up (`GuidancePlannerTests.homeowner`); the ground by the meter is aimed at
/// (0, 0, 0.6), 35 degrees below level.
@Suite struct AimHintTests {
    static let groundByMeter = SIMD3<Float>(0, 0, 0.6)
    static let position = SIMD3<Float>(0, 1.4, 2.6)

    static func phone(pitchedDown degrees: Float) -> CameraFrame {
        portraitCamera(at: position, forward: forwardFacingWall(pitchedDown: degrees))
    }

    /// Pitched down 20 degrees the target is 15 degrees below the view's axis: on screen.
    @Test func theGroundByTheMeterIsOnScreenFromTheWalk() {
        #expect(AimHint.classify(target: Self.groundByMeter, camera: Self.phone(pitchedDown: 20)) == .onScreen)
    }

    /// #81, run 2: the homeowner tilted past the ground and looked at their feet. Pitched down 80
    /// degrees the target is 45 degrees above the view's axis, and the chevron pointed up while
    /// the card said "Tilt down".
    @Test func overTiltedTheTargetIsAbove() {
        #expect(AimHint.classify(target: Self.groundByMeter, camera: Self.phone(pitchedDown: 80)) == .above)
    }

    /// Held level, the target is 35 degrees below the view's axis.
    @Test func heldLevelTheTargetIsBelow() {
        #expect(AimHint.classify(target: Self.groundByMeter, camera: Self.phone(pitchedDown: 0)) == .below)
    }

    /// Camera +y is screen right in portrait, as the overlay's chevron reads it: +s is to the
    /// right of a homeowner facing the wall.
    @Test func alongTheWallIsLeftOrRight() {
        let camera = Self.phone(pitchedDown: 20)
        #expect(AimHint.classify(target: SIMD3(2, 0, 0.6), camera: camera) == .right)
        #expect(AimHint.classify(target: SIMD3(-2, 0, 0.6), camera: camera) == .left)
    }

    @Test func behindTheCameraIsBehind() {
        #expect(AimHint.classify(target: SIMD3(0, 0, 5), camera: Self.phone(pitchedDown: 20)) == .behind)
    }

    /// The on-screen band: 2 m along the axis, 0.6 m to the side is 16.7 degrees (inside the 18
    /// allowed sideways), 0.7 m is 19.3 (outside); 0.6 m up is 16.7 degrees (inside the 20 allowed
    /// up and down), 1 m is 26.6 (outside).
    @Test func theOnScreenBandHasItsNamedEdges() {
        let camera = Self.phone(pitchedDown: 20)
        let forward = camera.forward
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let ahead = Self.position + forward * 2
        #expect(AimHint.classify(target: ahead, camera: camera) == .onScreen)
        #expect(AimHint.classify(target: ahead + right * 0.6, camera: camera) == .onScreen)
        #expect(AimHint.classify(target: ahead + right * 0.7, camera: camera) == .right)
        #expect(AimHint.classify(target: ahead + up * 0.6, camera: camera) == .onScreen)
        #expect(AimHint.classify(target: ahead + up * 1, camera: camera) == .above)
        #expect(AimHint.classify(target: ahead - up * 1, camera: camera) == .below)
        #expect(nearlyEqual(AimHint.onScreenSideways, 18 * .pi / 180))
        #expect(nearlyEqual(AimHint.onScreenUpDown, 20 * .pi / 180))
    }

    /// Review of #120: with the frame before's hint, the edges are sticky, so a hand-held phone
    /// with the target near one doesn't swap the card's title each frame. 0.66 m to the side at
    /// 2 m is 18.3 degrees: just off screen alone, still on screen coming from on screen (inside
    /// 18 + 2), and still off screen coming from off screen. 0.6 m (16.7 degrees) stays off screen
    /// coming from off screen (outside 18 - 2). Off screen, 1.1 m up and 1 m to the side names
    /// up alone and after up, but stays right after right: up is not 1.2 times the larger.
    @Test func theEdgesAreStickyGivenTheFrameBefore() {
        let camera = Self.phone(pitchedDown: 20)
        let forward = camera.forward
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let ahead = Self.position + forward * 2
        let nearEdge = ahead + right * 0.66
        #expect(AimHint.classify(target: nearEdge, camera: camera) == .right)
        #expect(AimHint.classify(target: nearEdge, camera: camera, previous: .onScreen) == .onScreen)
        #expect(AimHint.classify(target: nearEdge, camera: camera, previous: .right) == .right)
        #expect(AimHint.classify(target: ahead + right * 0.6, camera: camera, previous: .right) == .right)
        #expect(AimHint.classify(target: ahead + right * 0.5, camera: camera, previous: .right) == .onScreen)
        let diagonal = ahead + up * 1.1 + right * 1
        #expect(AimHint.classify(target: diagonal, camera: camera) == .above)
        #expect(AimHint.classify(target: diagonal, camera: camera, previous: .above) == .above)
        #expect(AimHint.classify(target: diagonal, camera: camera, previous: .right) == .right)
        #expect(AimHint.classify(target: ahead + up * 1.3 + right * 1, camera: camera, previous: .right) == .above)
    }
}
