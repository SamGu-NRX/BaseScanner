import Foundation
import HouseScanKit
import simd
import Testing

// "Wall ends here" at the circle (B-06). The wall is z = 0 facing +z, so +s runs along +x, to the
// right as the phone faces the wall. The ground is y = 0 and the meter 1.5 m up. Synthetic
// coordinates chosen for the tests, not from a capture.

@Suite struct EndAimTests {
    static let wall = WallFrame(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)!
    /// A phone 1.75 m up, 2 m in front of the meter.
    static let phone = SIMD3<Float>(0, 1.75, 2)
    static let reach = CoverageConfig().maxDistance

    /// The verdict for the circle's ray from `phone` toward `target`.
    static func aim(
        toward target: SIMD3<Float>, askedLeft: Bool = false, groundError: Float = 0, trackingNormal: Bool = true
    ) -> EndAim.Verdict {
        let hit = wall.intersectWall(Ray(origin: phone, direction: simd_normalize(target - phone)))
        return EndAim.verdict(hit: hit, camera: phone, wall: wall, reach: reach, groundError: groundError, askedLeft: askedLeft, trackingNormal: trackingNormal)
    }

    static func endS(_ verdict: EndAim.Verdict) -> Float? {
        if case .end(let point) = verdict { return point.s }
        return nil
    }

    @Test func theAskedEndOnTheWallIsMarkedThere() throws {
        let right = try #require(Self.endS(Self.aim(toward: SIMD3(2, 1, 0))))
        #expect(abs(right - 2) < 1e-4)
        let left = try #require(Self.endS(Self.aim(toward: SIMD3(-2, 1, 0), askedLeft: true)))
        #expect(abs(left + 2) < 1e-4)
    }

    @Test func theOtherSideOfTheMeterIsRefused() {
        #expect(Self.aim(toward: SIMD3(2, 1, 0), askedLeft: true) == .otherSide)
        #expect(Self.aim(toward: SIMD3(-2, 1, 0), askedLeft: false) == .otherSide)
    }

    /// Aimed at the ground 1 m out, the ray meets the wall's plane 1.75 m under the floor.
    @Test func aimingAtTheGroundIsOffTheWall() {
        #expect(Self.aim(toward: SIMD3(1, 0, 1)) == .offWall)
    }

    /// The wall's foot, a little under the ground: within `ObjectTap.belowGroundSlack` (0.15 m),
    /// widened by the ground's own error.
    @Test func theWallsFootCountsWithinTheGroundSlack() {
        #expect(Self.endS(Self.aim(toward: SIMD3(1, -0.1, 0))) != nil)
        #expect(Self.aim(toward: SIMD3(1, -0.3, 0)) == .offWall)
        #expect(Self.endS(Self.aim(toward: SIMD3(1, -0.3, 0), groundError: 0.2)) != nil)
    }

    /// Above the wall the ray meets the plane in the column under the circle: the end goes there.
    @Test func aimingAboveTheWallKeepsTheColumnUnderTheCircle() throws {
        let s = try #require(Self.endS(Self.aim(toward: SIMD3(1, 6, 0))))
        #expect(abs(s - 1) < 1e-4)
    }

    @Test func farDownALongWallIsOffTheWall() {
        #expect(Self.aim(toward: SIMD3(Self.reach + 1, 1, 0)) == .offWall)
        #expect(Self.endS(Self.aim(toward: SIMD3(Self.reach - 0.5, 1, 0))) != nil)
    }

    @Test func aRayAwayFromTheWallIsOffTheWall() {
        #expect(Self.aim(toward: SIMD3(0, 1.75, 5)) == .offWall)
    }

    @Test func limitedTrackingWinsOverAGoodHit() {
        #expect(Self.aim(toward: SIMD3(2, 1, 0), trackingNormal: false) == .trackingLimited)
        #expect(Self.aim(toward: SIMD3(1, 0, 1), trackingNormal: false) == .trackingLimited)
    }

    /// The meter's own column belongs to the right, as `hit.s < 0` decides left everywhere else.
    @Test func theMetersColumnIsTheRight() {
        #expect(Self.endS(Self.aim(toward: SIMD3(0, 1, 0))) != nil)
        #expect(Self.aim(toward: SIMD3(0, 1, 0), askedLeft: true) == .otherSide)
    }
}
