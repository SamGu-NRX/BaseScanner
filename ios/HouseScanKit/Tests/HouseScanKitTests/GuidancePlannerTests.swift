import HouseScanKit
import simd
import Testing

@Suite struct GuidancePlannerTests {
    /// The homeowner standing `out` m from the wall at s = x, phone pitched down 20 degrees.
    static func homeowner(x: Float = 0, out: Float = 2.6) -> CameraFrame {
        portraitCamera(at: SIMD3(x, 1.4, out), forward: forwardFacingWall(pitchedDown: 20))
    }

    /// Wall covered and ground unseen around the meter. Wall cameras at 0 and 0.3 cover cells -4 ... 5
    /// ([-0.6096, 0.9144], see CoverageMapTests); they never see the ground.
    static func wallOnlyCoverage() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true)
        map.observe(wallCamera(s: 0.3), trackingNormal: true)
        return map
    }

    @Test func emptyMapAsksToWalkLeft() {
        var planner = GuidancePlanner()
        let map = CoverageMap(wall: standardWall())
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .walk(.left))
        var noCamera = GuidancePlanner()
        #expect(noCamera.update(coverage: map, camera: nil, time: 0).task == .walk(.left))
    }

    @Test func tooCloseAsksToStepBack() {
        var planner = GuidancePlanner()
        let map = CoverageMap(wall: standardWall())
        // 1.0 m out < tooClose 1.2.
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1.0), time: 0).task == .stepBack)
    }

    @Test func laggingGroundAsksToAimDown() {
        var planner = GuidancePlanner()
        // Window s in [-1, 1] holds cells -7 ... 6; cells -4 ... 5 have the wall covered and the
        // ground unseen: 10 >= ceil(0.45 / 0.1524) = 3. Middle (-0.6096 + 0.9144) / 2 = 0.1524.
        let output = planner.update(coverage: Self.wallOnlyCoverage(), camera: Self.homeowner(), time: 0)
        guard case .aimAtGround(let s) = output.task else {
            Issue.record("expected aimAtGround, got \(output.task)")
            return
        }
        #expect(nearlyEqual(s, 0.1524))
        // Target: the middle of the ground band there, (0.1524, 0, 0.6).
        #expect(nearlyEqual(output.target ?? .zero, SIMD3(0.1524, 0, 0.6)))
    }

    @Test func hysteresisHoldsATaskForThreeSeconds() {
        var planner = GuidancePlanner()
        let map = CoverageMap(wall: standardWall())
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .walk(.left))
        // Preferred is stepBack from here on, but walking left isn't satisfied and 3 s haven't passed.
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 1).task == .walk(.left))
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 2.9).task == .walk(.left))
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 3).task == .stepBack)
        #expect(planner.current == .stepBack)
    }

    @Test func satisfiedTaskSwitchesAtOnce() {
        var planner = GuidancePlanner()
        var map = CoverageMap(wall: standardWall())
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .walk(.left))
        map.setEnd(.left, at: -3)
        // The left end is marked: walk(.left) is satisfied, and the right side comes next.
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0.5).task == .walk(.right))
    }

    @Test func walkTargetIsOnTheWallToTheLeft() throws {
        var planner = GuidancePlanner()
        // Reach 0, so the target is s = -(0 + 1) = -1 at height 1: world (-1, 1, 0).
        let output = planner.update(coverage: CoverageMap(wall: standardWall()), camera: Self.homeowner(), time: 0)
        let target = try #require(output.target)
        #expect(nearlyEqual(target, SIMD3(-1, 1, 0)))
        let point = standardWall().wallPoint(target)
        #expect(point.s < 0 && nearlyEqual(point.out, 0))
    }

    /// Reach stops at the first hole, so a homeowner can be past it. The walk right must then aim
    /// ahead of them: the target to their right on screen (camera +y is screen right in portrait)
    /// and the path heading toward +s.
    @Test func walkTargetLeadsAHomeownerAlreadyPastTheReach() throws {
        var planner = GuidancePlanner()
        var map = CoverageMap(wall: standardWall())
        map.setEnd(.left, at: -3)
        let camera = Self.homeowner(x: 3)
        let output = planner.update(coverage: map, camera: camera, time: 0)
        #expect(output.task == .walk(.right))
        let target = try #require(output.target)
        // Reach is 0 here; the old target was s = 1, 2 m behind the camera at s = 3.
        #expect(nearlyEqual(target, SIMD3(4, 1, 0)))
        #expect(camera.cameraSpace(target).y > 0)
        let first = try #require(output.path.first)
        let last = try #require(output.path.last)
        #expect(standardWall().wallPoint(last).s > standardWall().wallPoint(first).s)

        let left = planner.cues(for: .walk(.left), coverage: CoverageMap(wall: standardWall()), camera: Self.homeowner(x: -2))
        #expect(nearlyEqual(left.target ?? .zero, SIMD3(-3, 1, 0)))
        #expect(Self.homeowner(x: -2).cameraSpace(left.target ?? .zero).y < 0)
    }

    @Test func pathRunsAlongTheStandOffLine() {
        var planner = GuidancePlanner()
        let wall = standardWall()
        // From s = 0 to the goal s = -1: ceil(1 / 0.5) = 2 steps, points at s = 0, -0.5, -1.
        let path = planner.update(coverage: CoverageMap(wall: wall), camera: Self.homeowner(), time: 0).path
        #expect(path.count == 3)
        for (point, s) in zip(path, [Float(0), -0.5, -1]) {
            #expect(nearlyEqual(point, SIMD3(s, 0, GuidanceConfig().standOff)))
        }
    }

    @Test func pathIsAtMostThreeMetres() throws {
        var planner = GuidancePlanner()
        let wall = standardWall()
        // Standing at s = 4 with the goal at s = -1: clipped to 3 m, ending at s = 1, in 6 steps.
        let path = planner.update(coverage: CoverageMap(wall: wall), camera: Self.homeowner(x: 4), time: 0).path
        #expect(path.count == 7)
        for point in path {
            let p = wall.wallPoint(point)
            #expect(nearlyEqual(p.out, GuidanceConfig().standOff) && nearlyEqual(p.height, 0))
        }
        let first = try #require(path.first)
        let last = try #require(path.last)
        #expect(nearlyEqual(wall.wallPoint(first).s, 4))
        #expect(nearlyEqual(wall.wallPoint(last).s, 1))
        #expect(simd_distance(first, last) <= 3 + 1e-4)
    }

    /// Checklist I6: instructions never go A, B, A within 3 s. The camera alternates every 0.5 s
    /// between s = 0 (preferred: aimAtGround) and s = 10 (no lag there, preferred: walk(.left));
    /// neither task can be satisfied, since the map never changes. Hand trace with minDwell 3:
    /// aim from 0; at 3.0 the preference is aim again; at 3.5 it is walk and 3.5 s have passed, so
    /// walk; then aim again at 7.0 (3.5 s later). Switches at exactly 3.5 and 7.0.
    @Test func neverFlipsBackWithinThreeSeconds() {
        var planner = GuidancePlanner()
        let map = Self.wallOnlyCoverage()
        var history: [(time: Double, task: GuidanceTask)] = []
        for step in 0...20 {
            let time = Double(step) * 0.5
            let camera = step.isMultiple(of: 2) ? Self.homeowner() : Self.homeowner(x: 10)
            history.append((time, planner.update(coverage: map, camera: camera, time: time).task))
        }
        let switches = zip(history, history.dropFirst()).filter { $0.task != $1.task }.map(\.1.time)
        #expect(switches == [3.5, 7.0])
        for i in history.indices {
            for j in history.indices where j > i {
                for k in history.indices where k > j && history[k].time - history[i].time < 3 {
                    let flipped = history[i].task == history[k].task && history[j].task != history[i].task
                    #expect(!flipped, "A, B, A at \(history[i].time), \(history[j].time), \(history[k].time)")
                }
            }
        }
    }
}
