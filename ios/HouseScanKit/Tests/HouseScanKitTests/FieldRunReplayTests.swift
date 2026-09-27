import HouseScanKit
import simd
import Testing

/// Device runs 1 and 2 (2026-09-26) replayed on the standard wall (s = x, meter at 0), for #24,
/// #28 and #29. Run 2's mock wall ended about 17 ft (5.18 m) right of the meter; its window was
/// about 7 ft and its AC stand-in about 16 ft right.
@Suite struct FieldRunReplayTests {
    static let wallEnd: Float = 5.18

    /// The phone at s = x, standing where `GuidancePlannerTests.homeowner` stands.
    static func phone(_ x: Float) -> SIMD3<Float> { SIMD3(x, 1.4, 2.6) }

    /// Run 2 up to 2:40: one view of the ground in front of the meter (left amber, seen once),
    /// then a walk to the wall's end on the right with views kept every 0.5 m.
    static func run2Walk() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        map.observe(CoverageMapTests.frontCamera(), trackingNormal: true)
        for x in stride(from: Float(0.5), through: wallEnd, by: 0.5) {
            map.observe(GuidancePlannerTests.walkedAway(x: x), trackingNormal: true)
        }
        map.observe(GuidancePlannerTests.walkedAway(x: wallEnd), trackingNormal: true)
        return map
    }

    /// #24: "Can't get there" at 2:40, at the wall's physical end, put the right end at 0 ft 6 in
    /// because unbroken coverage stopped at the amber cell by the meter. It now lands under the
    /// phone, and the window and AC are inside the scan.
    @Test func run2CantGetThereAtTheWallsEndLandsAtThePhone() {
        let map = Self.run2Walk()
        #expect(GuidancePlanner().reach(.right, coverage: map) < 0.2)
        let right = WalkedEnd.end(.right, phone: Self.phone(Self.wallEnd), walked: map.walkedPositions, wall: map.wall)
        #expect(nearlyEqual(right, Self.wallEnd))
        // At 0:53 nothing had been walked left: the left end at the meter is expected, and the
        // server's past-end request asks for the rest.
        let left = WalkedEnd.end(.left, phone: Self.phone(0.1), walked: map.walkedPositions, wall: map.wall)
        #expect(nearlyEqual(left, 0))
        for feature: Float in [2.13, 4.88] { #expect((left...right).contains(feature)) }
        // A phone that lost its place still gets the walked stretch, not the meter.
        #expect(nearlyEqual(WalkedEnd.end(.right, phone: nil, walked: map.walkedPositions, wall: map.wall), Self.wallEnd))
    }

    /// #24, left side: had the homeowner walked 3 ft left before the tap, the end is there even
    /// with the ground by the meter still amber.
    @Test func cantGetThereAfterAShortWalkLeftLandsAtThePhone() {
        var map = Self.run2Walk()
        map.observe(GuidancePlannerTests.walkedAway(x: -0.9), trackingNormal: true)
        #expect(GuidancePlanner().reach(.left, coverage: map) == 0)
        #expect(nearlyEqual(WalkedEnd.end(.left, phone: Self.phone(-0.9), walked: map.walkedPositions, wall: map.wall), -0.9))
    }

    /// #29: on a 17 ft wall the 20 ft end prompt never comes; the walk stays on "Walk slowly to
    /// your right", which is where the app offers "Wall ends here" at the phone. Past 6.1 m the
    /// prompt comes.
    @Test func run2SeventeenFootWallStaysOnTheWalkWithTheEndAtThePhone() {
        var map = GuidancePlannerTests.meterGroundSkipped(Self.run2Walk())
        map.setEnd(.left, at: 0)
        var planner = GuidancePlanner()
        #expect(planner.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: Self.wallEnd), time: 0).task == .walk(.right))
        #expect(nearlyEqual(WalkedEnd.end(.right, phone: Self.phone(Self.wallEnd), walked: map.walkedPositions, wall: map.wall), Self.wallEnd))
        map.observe(GuidancePlannerTests.walkedAway(x: 6.2), trackingNormal: true)
        var far = GuidancePlanner()
        #expect(far.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: 6.2), time: 0).task == .markEnd(.right))
    }

    /// Wall covered from s = -0.6 to about 4 and the ground never seen: the ground lags wherever
    /// the homeowner stands on the right.
    static func wallCoveredRight() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        for c in stride(from: Float(0), through: 3.6, by: 0.3) {
            map.observe(wallCamera(s: c), trackingNormal: true)
        }
        return map
    }

    /// #28: run 2's tilt prompts asked only for ground 4 to 5 ft right while the ground by the
    /// meter was amber. That request now comes first wherever the homeowner stands, and clears
    /// from a second spot a step away.
    @Test func run2GroundByTheMeterComesBeforeTheStretchToTheRight() {
        var map = Self.wallCoveredRight()
        map.observe(CoverageMapTests.frontCamera(), trackingNormal: true)
        var planner = GuidancePlanner()
        let away = GuidancePlannerTests.homeowner(x: 1.6)
        #expect(planner.update(coverage: map, camera: away, time: 0).task == .aimAtGround(s: 0))
        #expect(planner.update(coverage: map, camera: away, time: 5).task == .aimAtGround(s: 0))
        map.observe(CoverageMapTests.frontCamera(x: 0.3), trackingNormal: true)
        let next = planner.update(coverage: map, camera: away, time: 5.2).task
        guard case .aimAtGround(let s) = next, s > 1 else {
            Issue.record("expected the ground right of the meter next, got \(next)")
            return
        }
    }

    /// #28: run 2's card went 5 ft 3 in, 4 ft 9 in, 4 ft 6 in, 4 ft, 4 ft 3 in right of the meter
    /// as the homeowner drifted toward it. Each step was under half the stretch, but 5 ft 3 in to
    /// 4 ft is 0.38 m. The card now keeps 5 ft 3 in while that ground is within the planner's
    /// window, and moves on once the homeowner walks away from it.
    @Test func run2AimDistanceDoesNotWalkBack() {
        let map = GuidancePlannerTests.meterGroundSkipped(Self.wallCoveredRight())
        var planner = GuidancePlanner()
        let first = planner.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: 1.6), time: 0).task
        guard case .aimAtGround(let s0) = first else {
            Issue.record("expected aimAtGround, got \(first)")
            return
        }
        #expect(abs(s0 - 1.6) < 0.05)
        var fresh = GuidancePlanner()
        guard case .aimAtGround(let drifted) = fresh.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: 1.1), time: 0).task else {
            Issue.record("expected aimAtGround at s = 1.1")
            return
        }
        #expect(abs(drifted - s0) > GuidancePlanner.aimHalfWidth)
        for (time, x) in [(2.0, Float(1.45)), (4, 1.37), (6, 1.1), (8, 1.2)] {
            #expect(planner.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: x), time: time).task == first, "at \(time) s")
        }
        // Past a marked end the stretch can never be met, so it isn't held.
        var ended = map
        ended.setEnd(.right, at: 1.2)
        var endedPlanner = planner
        #expect(endedPlanner.update(coverage: ended, camera: GuidancePlannerTests.homeowner(x: 1.1), time: 9).task != first)
        let moved = planner.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: 2.8), time: 10).task
        guard case .aimAtGround(let s) = moved, s > 2 else {
            Issue.record("expected the ground by the homeowner at s = 2.8, got \(moved)")
            return
        }
    }
}
