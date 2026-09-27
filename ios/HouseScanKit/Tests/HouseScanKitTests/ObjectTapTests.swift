import Foundation
import HouseScanKit
import simd
import Testing

// #140: marking an AC pinned it 105 ft and 276 ft from the meter, tens of meters below the floor.
// The wall is the plane z = 0 facing +z, so s is x; the ground is y = 0 and the meter 1.23 m up,
// as in the field run. Field points are offsets from the meter, from that run's manifest.

@Suite struct ObjectTapTests {
    static let wall = WallFrame(meter: SIMD3(0, 1.23, 0), outward: SIMD3(0, 0, 1), groundY: 0)!
    /// A phone held 1.4 m up, 2 m in front of the meter.
    static let phone = SIMD3<Float>(0, 1.4, 2)
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
        (SIMD3<Float>(0.16, -1.14, 0), true),
        // 0.10 m under the ground, just past the left end: within the slack.
        (SIMD3<Float>(-1.89, -1.33, 0), true),
        // 105 ft left, 28 m below the meter.
        (SIMD3<Float>(-31.89, -28.04, 0), false),
        // 70 m below the meter.
        (SIMD3<Float>(-77.78, -70.34, 6.58), false),
    ])
    func fieldRunPoints(offset: SIMD3<Float>, accepted: Bool) {
        let point = Self.wall.wallPoint(Self.wall.meter + offset)
        #expect((Self.refusal(point) == nil) == accepted)
    }

    @Test(arguments: [
        (SIMD3<Float>(0.16, -1.14, 0), true),
        (SIMD3<Float>(-1.89, -1.33, 0), true),
        (SIMD3<Float>(-31.89, -28.04, 0), false),
    ])
    func fieldRunTaps(offset: SIMD3<Float>, accepted: Bool) throws {
        // The same points as taps: rays from the phone through them meet the wall's plane there.
        let hit = try Self.hit(toward: Self.wall.meter + offset)
        #expect(nearlyEqual(hit.s, offset.x, 1e-3))
        #expect((Self.refusal(hit) == nil) == accepted)
    }

    @Test func downwardRayMeetingTheGroundFirstIsRefused() throws {
        // Aimed at (0.5, -0.6, 0): the ray crosses y = 0 at z = 0.6, before the wall, and meets the
        // wall's plane 0.6 m under the ground. Even a guessed ground's 0.3 m error doesn't cover it.
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
