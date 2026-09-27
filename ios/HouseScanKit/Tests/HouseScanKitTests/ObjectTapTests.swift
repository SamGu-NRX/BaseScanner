import Foundation
import HouseScanKit
import simd
import Testing

// Synthetic cases for #140: a downward or grazing ray must not create a distant object pin.
// The wall is z = 0 facing +z, the ground is y = 0, and the meter is 1.5 m up.
// These coordinates are chosen for the tests and do not come from a capture.

@Suite struct ObjectTapTests {
    static let wall = WallFrame(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)!
    /// A synthetic phone pose 1.75 m up, 2 m in front of the meter.
    static let phone = SIMD3<Float>(0, 1.75, 2)
    static let reach = CoverageConfig().maxDistance

    static func refusal(_ hit: WallPoint, camera: SIMD3<Float> = phone, groundError: Float = 0) -> ObjectTap.Refusal? {
        ObjectTap.refusal(hit, camera: camera, wall: wall, reach: reach, groundError: groundError)
    }

    /// Where the ray from `camera` toward `target` meets the wall.
    static func hit(toward target: SIMD3<Float>, from camera: SIMD3<Float> = phone) throws -> WallPoint {
        try #require(wall.intersectWall(Ray(origin: camera, direction: simd_normalize(target - camera))))
    }

    @Test(arguments: [
        // Just above the ground, beside the meter.
        (SIMD3<Float>(0.25, -1.4, 0), true),
        // A nearby point slightly below the ground is within the slack.
        (SIMD3<Float>(-1, -1.55, 0), true),
        // A distant point well below the ground.
        (SIMD3<Float>(-20, -10, 0), false),
        // An off-plane point with an implausible height and along-wall distance.
        (SIMD3<Float>(-40, -25, 5), false),
    ])
    func syntheticPoints(offset: SIMD3<Float>, accepted: Bool) {
        let point = Self.wall.wallPoint(Self.wall.meter + offset)
        #expect((Self.refusal(point) == nil) == accepted)
    }

    @Test(arguments: [
        (SIMD3<Float>(0.25, -1.4, 0), true),
        (SIMD3<Float>(-1, -1.55, 0), true),
        (SIMD3<Float>(-20, -10, 0), false),
    ])
    func syntheticTaps(offset: SIMD3<Float>, accepted: Bool) throws {
        // The same points as taps: rays from the phone through them meet the wall's plane there.
        let hit = try Self.hit(toward: Self.wall.meter + offset)
        #expect(nearlyEqual(hit.s, offset.x, 1e-3))
        #expect((Self.refusal(hit) == nil) == accepted)
    }

    @Test func downwardRayMeetingTheGroundFirstIsRefused() throws {
        // The ray crosses the ground before meeting the wall's plane 0.6 m below it.
        // Even a guessed ground's 0.3 m error doesn't cover this synthetic tap.
        let hit = try Self.hit(toward: SIMD3(0.5, -0.6, 0))
        #expect(nearlyEqual(hit.height, -0.6, 1e-4))
        guard case .belowGround(let meters) = Self.refusal(hit) else {
            Issue.record("expected belowGround")
            return
        }
        #expect(nearlyEqual(meters, 0.6, 1e-4))
        #expect(Self.refusal(hit, groundError: 0.3) != nil)
    }

    @Test func groundErrorWidensTheSlackBelowAGuessedGround() {
        // 0.25 m under a guessed ground can still be at the real ground, 0.3 m lower at most.
        let point = WallPoint(s: 0.5, height: -0.25, out: 0)
        #expect(Self.refusal(point) != nil)
        #expect(Self.refusal(point, groundError: 0.3) == nil)
    }

    @Test func grazingRayMeetingTheWall30MetersAlongIsRefused() throws {
        // Nearly along the wall: meets it at (30, 1, 0), at a plausible height but 30 m from the phone.
        let far = try Self.hit(toward: SIMD3(30, 1, 0))
        #expect(nearlyEqual(far.height, 1, 1e-3))
        guard case .tooFarAlong(let meters) = Self.refusal(far) else {
            Issue.record("expected tooFarAlong")
            return
        }
        #expect(nearlyEqual(meters, 30, 1e-3))
        // 5 m along is within a camera's reach.
        let near = try Self.hit(toward: SIMD3(5, 1, 0))
        #expect(Self.refusal(near) == nil)
    }

    @Test func reachIsMeasuredFromThePhoneNotTheMeter() throws {
        // A phone 20 m along the wall may mark something 22 m from the meter.
        let camera = SIMD3<Float>(20, 1.4, 2)
        let hit = try Self.hit(toward: SIMD3(22, 1, 0), from: camera)
        #expect(Self.refusal(hit, camera: camera) == nil)
        #expect(Self.refusal(hit) != nil)
    }
}
