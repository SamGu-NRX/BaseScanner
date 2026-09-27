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

    // MARK: Objects standing on the ground (#163)

    static func place(toward target: SIMD3<Float>, from camera: SIMD3<Float> = phone, standsOnGround: Bool) -> ObjectTap.Placement {
        let ray = Ray(origin: camera, direction: simd_normalize(target - camera))
        return ObjectTap.place(ray, standsOnGround: standsOnGround, camera: camera, wall: wall, reach: reach, groundError: 0)
    }

    /// The point a placement landed on, or nil when it was refused or landed on the wall.
    static func groundPoint(_ placement: ObjectTap.Placement) -> WallPoint? {
        guard case .ground(let point) = placement else { return nil }
        return point
    }

    @Test func acAimedAtTheGroundInFrontOfTheWallLandsUnderTheAim() throws {
        // A phone 1.47 m up and 2 m out, aimed down at the foot of something standing 0.45 m out
        // from the wall, 0.3 m right of the phone. The ray meets the wall's plane 0.43 m below
        // the ground, as the refused taps of #163 did.
        let camera = SIMD3<Float>(0, 1.47, 2)
        let aim = SIMD3<Float>(0.3, 0, 0.45)
        let direction = simd_normalize(aim - camera)
        let pitch = asin(-direction.y) * 180 / .pi
        #expect(pitch > 41 && pitch < 45)
        let wallHit = try Self.hit(toward: aim, from: camera)
        guard case .belowGround(let meters) = Self.refusal(wallHit, camera: camera) else {
            Issue.record("expected the wall hit below the ground")
            return
        }
        #expect(meters > 0.35 && meters < 0.55)

        let ac = try #require(Self.groundPoint(Self.place(toward: aim, from: camera, standsOnGround: true)))
        #expect(nearlyEqual(ac.s, 0.3, 1e-3))
        #expect(nearlyEqual(ac.out, 0.45, 1e-3))
        #expect(nearlyEqual(ac.height, 0, 1e-3))
        // A window hangs on the wall: the same ray is still refused.
        #expect(Self.place(toward: aim, from: camera, standsOnGround: false) == .refused(.belowGround(meters: meters)))
    }

    @Test func acFartherOutThanThePhoneLandsOnTheGround() throws {
        // Aimed down and away from the wall, at something 2.5 m out: the ray never meets the wall.
        let camera = SIMD3<Float>(0, 1.47, 2)
        let aim = SIMD3<Float>(1, 0, 2.5)
        let ac = try #require(Self.groundPoint(Self.place(toward: aim, from: camera, standsOnGround: true)))
        #expect(nearlyEqual(ac.s, 1, 1e-3))
        #expect(nearlyEqual(ac.out, 2.5, 1e-3))
        #expect(Self.place(toward: aim, from: camera, standsOnGround: false) == .refused(.noSurface))
    }

    @Test func acAimedAtTheWallStillLandsOnTheWall() {
        // On the wall above the ground, and at its foot: the wall hit wins, as before.
        for target in [SIMD3<Float>(0.5, 0.3, 0), SIMD3<Float>(0.25, 0.02, 0)] {
            guard case .wall(let point) = Self.place(toward: target, standsOnGround: true) else {
                Issue.record("expected a wall hit toward \(target)")
                continue
            }
            #expect(nearlyEqual(point.s, target.x, 1e-3))
            #expect(nearlyEqual(point.height, target.y, 1e-3))
        }
    }

    @Test func aGuessedGroundWidensTheWallSlackBeforeTheGroundFallback() throws {
        // A wall hit 0.25 m under a guessed ground can still be at the real ground, 0.3 m lower at
        // most: it stays on the wall. Once the ground is measured it's under the floor, and the AC
        // lands where the ray crosses the ground, 0.25 m out.
        let target = SIMD3<Float>(0.5, -0.25, 0)
        let ray = Ray(origin: Self.phone, direction: simd_normalize(target - Self.phone))
        let guessed = ObjectTap.place(ray, standsOnGround: true, camera: Self.phone, wall: Self.wall, reach: Self.reach, groundError: 0.3)
        guard case .wall(let onWall) = guessed else {
            Issue.record("expected a wall hit under a guessed ground")
            return
        }
        #expect(nearlyEqual(onWall.height, -0.25, 1e-3))
        let measured = ObjectTap.place(ray, standsOnGround: true, camera: Self.phone, wall: Self.wall, reach: Self.reach, groundError: 0)
        let ac = try #require(Self.groundPoint(measured))
        #expect(nearlyEqual(ac.s, 0.5 * 1.75 / 2, 1e-3))
        #expect(nearlyEqual(ac.out, 2 - 2 * 1.75 / 2, 1e-3))
    }

    @Test func grazingAcTap30MetersAlongIsStillRefused() {
        // #140's grazing ray: a plausible height, out of reach. The ground is no nearer.
        guard case .refused(.tooFarAlong(let meters)) = Self.place(toward: SIMD3(30, 1, 0), standsOnGround: true) else {
            Issue.record("expected tooFarAlong")
            return
        }
        #expect(nearlyEqual(meters, 30, 1e-3))
    }

    @Test func deepUnderGroundAcTapNeverPinsFarAlongTheWall() throws {
        // #140's steep ray meets the wall's plane 20 m along and 8.5 m under the ground. Refused
        // for a window. For an AC it lands where it crosses the ground, 3.4 m along and 1.7 m out,
        // within a camera's reach: never at the far wall hit.
        let target = Self.wall.meter + SIMD3(-20, -10, 0)
        guard case .refused(.belowGround) = Self.place(toward: target, standsOnGround: false) else {
            Issue.record("expected belowGround for a window")
            return
        }
        let ac = try #require(Self.groundPoint(Self.place(toward: target, standsOnGround: true)))
        #expect(nearlyEqual(ac.s, -20 * 1.75 / 10.25, 1e-3))
        #expect(nearlyEqual(ac.out, 2 - 2 * 1.75 / 10.25, 1e-3))
    }

    @Test func acGroundHitOutOfReachIsRefused() {
        // Aimed at the ground 10 m along the wall: the wall hit is below the ground, and the
        // ground hit is past the camera's reach.
        guard case .refused(.tooFarAlong(let along)) = Self.place(toward: SIMD3(-10, 0, 1), standsOnGround: true) else {
            Issue.record("expected tooFarAlong")
            return
        }
        #expect(nearlyEqual(along, 10, 1e-3))
        // 11 m out from the wall: no wall hit, and past the ground-tap bound.
        guard case .refused(.tooFarOut(let out)) = Self.place(toward: SIMD3(0, 0, 11), standsOnGround: true) else {
            Issue.record("expected tooFarOut")
            return
        }
        #expect(nearlyEqual(out, 11, 1e-3))
        // Aimed up and away from the wall: neither surface.
        #expect(Self.place(toward: SIMD3(0, 3, 6), standsOnGround: true) == .refused(.noSurface))
    }
}
