import HouseScanKit
import simd
import Testing

/// Synthetic planner and end-helper cases modeled on the symptoms of device runs 1 and 2
/// (2026-09-26), on the standard wall (s = x, meter at 0), for #24, #28 and #29. They build
/// cameras and coverage by hand and call `WalkedEnd.end` and `GuidancePlanner.update` directly:
/// they don't run the app's "Can't get there" or "Wall ends here" actions, and don't replay
/// recorded frames. Run 2's mock wall ended about 17 ft (5.18 m) right of the meter; its window
/// was about 7 ft and its AC stand-in about 16 ft right.
@Suite struct FieldRunReplayTests {
    static let wallEnd: Float = 5.18

    /// The phone at s = x, standing where `GuidancePlannerTests.homeowner` stands.
    static func phone(_ x: Float) -> SIMD3<Float> { SIMD3(x, 1.4, 2.6) }

    /// Run 2 up to 2:40: one view of the ground in front of the meter (left amber, seen once),
    /// then a walk to the wall's end on the right with the phone's position kept every 0.5 m. The
    /// walk's views look away from the wall, so they add walked path and no coverage: these cases
    /// test where an end lands, not how the wall is recorded along the way.
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

    /// #28 asked for the ground by the meter before the stretch to the right; build 4.1 then asked
    /// for it before anything else wherever the phone was, and it blocked the start of every run
    /// (#77, which supersedes #28). Changed deliberately: from 5 ft 3 in right of the meter the
    /// walk isn't held for it, and the card asks for the ground in front of the homeowner. Within
    /// 1 m of the meter it is asked for, and clears from a second spot a step away.
    @Test func run2GroundByTheMeterIsAskedForNearTheMeter() {
        var map = Self.wallCoveredRight()
        map.observe(CoverageMapTests.frontCamera(), trackingNormal: true)
        var planner = GuidancePlanner()
        let away = planner.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: 1.6), time: 0).task
        guard case .aimAtGround(let s) = away, s > 1 else {
            Issue.record("expected the ground in front of the homeowner, got \(away)")
            return
        }
        var near = GuidancePlanner()
        let close = GuidancePlannerTests.homeowner(x: 0.5)
        #expect(near.update(coverage: map, camera: close, time: 0).task == .aimAtGround(s: 0))
        #expect(near.update(coverage: map, camera: close, time: 5).task == .aimAtGround(s: 0))
        map.observe(CoverageMapTests.frontCamera(x: 0.3), trackingNormal: true)
        let next = near.update(coverage: map, camera: close, time: 5.2)
        #expect(next.task != .aimAtGround(s: 0))
        #expect(next.switched == .satisfied)
    }

    /// #28: run 2's card went 5 ft 3 in, 4 ft 9 in, 4 ft 6 in, 4 ft, 4 ft 3 in right of the meter
    /// as the homeowner drifted toward it. Each step was under half the stretch, but 5 ft 3 in to
    /// 4 ft is 0.38 m. The card now keeps its first distance while that ground is within the
    /// planner's window, and moves on once the homeowner walks away from it. With no end marked
    /// the walk goes left, so from s = 1.6 the window is [0.6, 1.9], cells 3 ... 12, whose middle
    /// is 1.2192 (it was the middle of [0.6, 2.6], 1.6002, before the window looked only ahead).
    @Test func run2AimDistanceDoesNotWalkBack() {
        let map = GuidancePlannerTests.meterGroundSkipped(Self.wallCoveredRight())
        var planner = GuidancePlanner()
        let first = planner.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: 1.6), time: 0).task
        guard case .aimAtGround(let s0) = first else {
            Issue.record("expected aimAtGround, got \(first)")
            return
        }
        #expect(abs(s0 - 1.2192) < 0.01)
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

    /// Review of #56: an aim task past a marked end must not be kept by either rule that holds
    /// one. Here the task asks for s = 1.2192 (from s = 1.6, as above), then the right end is
    /// marked at 1.2 and the homeowner steps to s = 1.8, where the ground lags over cells 5 ... 7
    /// between the ends: the preferred task asks for s = 0.9906, 0.23 m away, the same stretch by
    /// `sameStretch`. The task past the end still gives way once its dwell is up.
    @Test func anAimPastAMarkedEndGivesWayToTheSameStretchInside() {
        let map = GuidancePlannerTests.meterGroundSkipped(Self.wallCoveredRight())
        var planner = GuidancePlanner()
        let first = planner.update(coverage: map, camera: GuidancePlannerTests.homeowner(x: 1.6), time: 0).task
        guard case .aimAtGround(let s0) = first, abs(s0 - 1.2192) < 0.01 else {
            Issue.record("expected aimAtGround at 1.2192, got \(first)")
            return
        }
        var ended = map
        ended.setEnd(.right, at: 1.2)
        let camera = GuidancePlannerTests.homeowner(x: 1.8)
        var fresh = GuidancePlanner()
        guard case .aimAtGround(let inside) = fresh.update(coverage: ended, camera: camera, time: 0).task, abs(inside - 0.9906) < 0.01 else {
            Issue.record("expected aimAtGround at 0.9906 inside the ends")
            return
        }
        #expect(abs(inside - s0) < GuidancePlanner.aimHalfWidth)
        #expect(planner.update(coverage: ended, camera: camera, time: 2.9).task == first)
        let next = planner.update(coverage: ended, camera: camera, time: 3)
        #expect(next.task == .aimAtGround(s: inside))
        #expect(next.switched == .leftWindow)
    }
}
