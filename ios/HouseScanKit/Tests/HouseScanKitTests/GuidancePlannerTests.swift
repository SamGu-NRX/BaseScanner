import HouseScanKit
import simd
import Testing

@Suite struct GuidancePlannerTests {
    /// The homeowner standing `out` m from the wall at s = x, phone pitched down 20 degrees.
    static func homeowner(x: Float = 0, out: Float = 2.6) -> CameraFrame {
        portraitCamera(at: SIMD3(x, 1.4, out), forward: forwardFacingWall(pitchedDown: 20))
    }

    /// A map whose stretch in front of the meter, the planner's own window (cells -2 ... 1), is
    /// skipped in both bands, so the walk's first request is done and no band lags there: the walk
    /// goes on to the sides. Covered cells stay covered.
    static func meterGroundSkipped(_ map: CoverageMap = CoverageMap(wall: standardWall())) -> CoverageMap {
        var map = map
        for band in SurfaceBand.allCases {
            map.markSkipped(band, -GuidancePlanner.aimHalfWidth...GuidancePlanner.aimHalfWidth)
        }
        return map
    }

    /// Wall covered and ground unseen around the meter, the ground in front of the meter skipped.
    /// Wall cameras at 0 and 0.3 cover cells -4 ... 5 ([-0.6096, 0.9144], see CoverageMapTests);
    /// they never see the ground.
    static func wallOnlyCoverage() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true)
        map.observe(wallCamera(s: 0.3), trackingNormal: true)
        return meterGroundSkipped(map)
    }

    /// The walk's first request is the ground in front of the meter, with or without a camera,
    /// before either side: every check the server runs starts beside the meter.
    @Test func firstRequestIsTheGroundByTheMeter() throws {
        let map = CoverageMap(wall: standardWall())
        var planner = GuidancePlanner()
        let output = planner.update(coverage: map, camera: Self.homeowner(), time: 0)
        #expect(output.task == .aimAtGround(s: 0))
        // The middle of the ground band in front of the meter.
        #expect(nearlyEqual(try #require(output.target), SIMD3(0, 0, 0.6)))
        var noCamera = GuidancePlanner()
        #expect(noCamera.update(coverage: map, camera: nil, time: 0).task == .aimAtGround(s: 0))
        // Once it is done the walk goes left first.
        var skipped = GuidancePlanner()
        #expect(skipped.update(coverage: Self.meterGroundSkipped(), camera: Self.homeowner(), time: 0).task == .walk(.left))
    }

    /// The two-position rule settles it: `frontCamera` sees every ground row of cells -1 and 0 and,
    /// 2.6 m out with a half-angle of 24 degrees across, cells -2 and 1 as well. One view leaves
    /// them seen; a second 0.3 m away covers all four, which satisfies the task: the planner moves
    /// on at once, well inside the dwell. (What it moves on to is the wall there, which these views
    /// see only 1.98 m up, so it lags the ground.)
    @Test func groundByTheMeterIsMetFromTwoPlaces() {
        var map = CoverageMap(wall: standardWall())
        var planner = GuidancePlanner()
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .aimAtGround(s: 0))
        map.observe(CoverageMapTests.frontCamera(), trackingNormal: true)
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0.2).task == .aimAtGround(s: 0))
        map.observe(CoverageMapTests.frontCamera(x: 0.3), trackingNormal: true)
        for index in -2...1 { #expect(map.level(.ground, index) == .covered, "cell \(index)") }
        let next = planner.update(coverage: map, camera: Self.homeowner(), time: 0.4).task
        guard case .aimAtWall = next else {
            Issue.record("expected the lagging wall next, got \(next)")
            return
        }
    }

    /// "Can't get there" on it marks the ground skipped, as the engine does, and resets the planner
    /// (`ScanEngine.resetGuidanceAfterSkip`): the walk moves on and doesn't ask for it again.
    @Test func cantGetThereOnTheGroundByTheMeterMovesOn() {
        var map = CoverageMap(wall: standardWall())
        var planner = GuidancePlanner()
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .aimAtGround(s: 0))
        map.markSkipped(.ground, -0.5...0.5)
        // Skipped is not covered: without the reset the request holds for its dwell.
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0.5).task == .aimAtGround(s: 0))
        planner.reset()
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0.6).task != .aimAtGround(s: 0))
        // Away from the meter nothing lags, and the walk goes left.
        #expect(planner.update(coverage: map, camera: Self.homeowner(x: -3), time: 10).task == .walk(.left))
    }

    /// It keeps the 3 s dwell like any other request.
    @Test func groundByTheMeterKeepsItsDwell() {
        var planner = GuidancePlanner()
        let map = CoverageMap(wall: standardWall())
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .aimAtGround(s: 0))
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 2.9).task == .aimAtGround(s: 0))
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 3).task == .stepBack)
    }

    @Test func tooCloseAsksToStepBack() {
        var planner = GuidancePlanner()
        let map = CoverageMap(wall: standardWall())
        // 1.0 m out < tooClose 1.2.
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1.0), time: 0).task == .stepBack)
    }

    @Test func laggingGroundAsksToAimDown() {
        var planner = GuidancePlanner()
        // Window s in [-1, 1] holds cells -7 ... 6; cells -4, -3 and 2 ... 5 have the wall covered
        // and the ground unseen (-2 ... 1 are skipped): 6 >= ceil(0.45 / 0.1524) = 3. Middle of the
        // first and last, (-0.6096 + 0.9144) / 2 = 0.1524.
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
        let map = Self.meterGroundSkipped()
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .walk(.left))
        // Preferred is stepBack from here on, but walking left isn't satisfied and 3 s haven't passed.
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 1).task == .walk(.left))
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 2.9).task == .walk(.left))
        #expect(planner.update(coverage: map, camera: Self.homeowner(out: 1), time: 3).task == .stepBack)
        #expect(planner.current == .stepBack)
    }

    @Test func satisfiedTaskSwitchesAtOnce() {
        var planner = GuidancePlanner()
        var map = Self.meterGroundSkipped()
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0).task == .walk(.left))
        map.setEnd(.left, at: -3)
        // The left end is marked: walk(.left) is satisfied, and the right side comes next.
        #expect(planner.update(coverage: map, camera: Self.homeowner(), time: 0.5).task == .walk(.right))
    }

    @Test func walkTargetIsOnTheWallToTheLeft() throws {
        let planner = GuidancePlanner()
        // Reach 0, so the target is s = -(0 + 1) = -1 at height 1: world (-1, 1, 0).
        let output = planner.cues(for: .walk(.left), coverage: CoverageMap(wall: standardWall()), camera: Self.homeowner())
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
        var map = Self.meterGroundSkipped()
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
        let planner = GuidancePlanner()
        let wall = standardWall()
        // From s = 0 to the goal s = -1: ceil(1 / 0.5) = 2 steps, points at s = 0, -0.5, -1.
        let path = planner.cues(for: .walk(.left), coverage: CoverageMap(wall: wall), camera: Self.homeowner()).path
        #expect(path.count == 3)
        for (point, s) in zip(path, [Float(0), -0.5, -1]) {
            #expect(nearlyEqual(point, SIMD3(s, 0, GuidanceConfig().standOff)))
        }
    }

    @Test func pathIsAtMostThreeMetres() throws {
        var planner = GuidancePlanner()
        let wall = standardWall()
        // Standing at s = 4 with the goal at s = -1: clipped to 3 m, ending at s = 1, in 6 steps.
        let path = planner.update(coverage: Self.meterGroundSkipped(CoverageMap(wall: wall)), camera: Self.homeowner(x: 4), time: 0).path
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

    /// LiDAR saw a box in front of the wall (CoverageDepthTests' box, s in [-0.5, 0.5], 0.5 to
    /// 1 m out): from `wallCamera` at s = 0 and 0.3, row 0 of every wall cell they see from -6
    /// to 5 ([-0.9144, 0.9144]) is hidden in both views, so all twelve are hidden, more than the
    /// three `lagRun` needs, and their middle is s = 0. (The ground cells there are hidden too:
    /// their row at the wall's foot is the wall's row 0, which these views see at u = 620, just
    /// inside the image margin.) Seeing behind comes before aiming.
    /// Walking off to s = 5 prefers the ground in front of the meter, hidden and so not done, which
    /// waits out the 3 s dwell; once the cells are no longer hidden the task is satisfied and
    /// switches at once.
    @Test func hiddenCellsNearTheCameraAskToSeeBehind() {
        var map = CoverageMap(wall: standardWall())
        let scene = CoverageDepthTests.boxScene
        for s: Float in [0, 0.3] {
            map.observe(wallCamera(s: s), trackingNormal: true, depth: renderDepth(scene, from: wallCamera(s: s)))
        }
        var planner = GuidancePlanner()
        let output = planner.update(coverage: map, camera: Self.homeowner(), time: 0)
        guard case .seeBehind(let s) = output.task else {
            Issue.record("expected seeBehind, got \(output.task)")
            return
        }
        #expect(nearlyEqual(s, 0))
        #expect(nearlyEqual(output.target ?? SIMD3(repeating: 9), SIMD3(0, 0, 0)))
        #expect(output.path.isEmpty)

        #expect(planner.update(coverage: map, camera: Self.homeowner(x: 5), time: 2.9).task == .seeBehind(s: s))
        #expect(planner.update(coverage: map, camera: Self.homeowner(x: 5), time: 3).task == .aimAtGround(s: 0))

        // Satisfied: nothing within 0.3 m of s is hidden once the homeowner marks it skipped.
        var planner2 = GuidancePlanner()
        #expect(planner2.update(coverage: map, camera: Self.homeowner(), time: 0).task == .seeBehind(s: s))
        map.markSkipped(.wall, -1...1)
        map.markSkipped(.ground, -1...1)
        #expect(planner2.update(coverage: map, camera: Self.homeowner(), time: 0.5).task != .seeBehind(s: s))
    }
    /// A camera at s = x, 2.6 m out, looking away from the wall: kept, so its position counts as
    /// walked, but it sees no cell, so it adds no coverage (and no lag) anywhere.
    static func walkedAway(x: Float) -> CameraFrame {
        portraitCamera(at: SIMD3(x, 1.4, 2.6), forward: SIMD3(0, 0, 1))
    }

    /// B-06: the end prompt goes by how far the walked path has gone on the side, not by unbroken
    /// coverage. Here nothing is covered past the meter (reach 0), yet a walk to 6.2 m left asks
    /// for the left end, and one to 5.9 m doesn't yet. The prompt's aim is the reticle: no ring.
    @Test func endPromptFollowsTheWalkedPath() {
        var map = Self.meterGroundSkipped()
        for x in stride(from: Float(0), through: -5.9, by: -0.5) { map.observe(Self.walkedAway(x: x), trackingNormal: true) }
        map.observe(Self.walkedAway(x: -5.9), trackingNormal: true)
        var short = GuidancePlanner()
        #expect(nearlyEqual(map.walkedFarthest(.left), 5.9))
        #expect(short.update(coverage: map, camera: Self.homeowner(x: -5.9), time: 0).task == .walk(.left))
        map.observe(Self.walkedAway(x: -6.2), trackingNormal: true)
        // Unbroken coverage reaches only over the skipped cells in front of the meter.
        #expect(nearlyEqual(GuidancePlanner().reach(.left, coverage: map), 0.3048))
        var far = GuidancePlanner()
        let output = far.update(coverage: map, camera: Self.homeowner(x: -6.2), time: 0)
        #expect(output.task == .markEnd(.left))
        #expect(output.target == nil)
        #expect(output.path.isEmpty)
    }

    /// The lag window slides with the camera, so the middle of what lags drifts. Here it moves
    /// from 0.1524 to 0 when the homeowner steps 0.5 m left (window [-1.5, 0.5]: lagging cells -4,
    /// -3, 2 and 3), less than the task's own half-width: the card keeps its distance past the
    /// dwell instead of changing it. A different stretch still switches after the dwell.
    @Test func aimTaskKeepsItsStretchWhileTheWindowDrifts() {
        var planner = GuidancePlanner()
        let map = Self.wallOnlyCoverage()
        let first = planner.update(coverage: map, camera: Self.homeowner(), time: 0).task
        guard case .aimAtGround(let s) = first, nearlyEqual(s, 0.1524) else {
            Issue.record("expected aimAtGround at 0.1524, got \(first)")
            return
        }
        #expect(planner.update(coverage: map, camera: Self.homeowner(x: -0.5), time: 3.5).task == first)
        #expect(planner.update(coverage: map, camera: Self.homeowner(x: 10), time: 3.6).task == .walk(.left))
    }
}
