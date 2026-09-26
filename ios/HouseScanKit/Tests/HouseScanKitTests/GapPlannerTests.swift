import HouseScanKit
import simd
import Testing

// Coverage built from the two hand-analysable cameras in TestSupport, with ends at -3 and 3.
// Cell i has lower edge L = 0.1524 i. A ground cell is covered when at least two ground cameras lie in
// [L - 0.3369, L + 0.4893] (0.83 m wide), a wall cell when two wall cameras lie in [L - 0.7881, L + 0.9405].
// Cameras sit 0.3 m apart, over the 0.25 m covering baseline, so any two of them count as two positions.
// Evenly spaced every 0.3 m, every window holds at least two cameras, so only removed cameras leave gaps.
@Suite struct GapPlannerTests {
    static func positions(_ ks: ClosedRange<Int>, except removed: Set<Int> = []) -> [Float] {
        ks.filter { !removed.contains($0) }.map { Float($0) * 0.3 }
    }

    static func map(ground: [Float], wall: [Float] = positions(-13...13)) -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        map.setEnd(.left, at: -3)
        map.setEnd(.right, at: 3)
        for s in wall { map.observe(wallCamera(s: s), trackingNormal: true) }
        for s in ground { map.observe(groundCamera(s: s), trackingNormal: true) }
        return map
    }

    /// Ground cameras every 0.3 m from -3.3 to 3.3 without -2.4, -2.1 (k -8, -7) and 1.2, 1.5 (k 4, 5).
    ///
    /// Right hole, cameras 0.3, 0.6, 0.9 | 1.8, 2.1:
    ///   cell 6  L 0.9144 window [0.5775, 1.4037]: 0.6, 0.9 -> covered
    ///   cell 7  L 1.0668 window [0.7299, 1.5561]: 0.9      -> seen
    ///   cell 8  L 1.2192 window [0.8823, 1.7085]: 0.9      -> seen
    ///   cell 9  L 1.3716 window [1.0347, 1.8609]: 1.8      -> seen
    ///   cell 10 L 1.5240 window [1.1871, 2.0133]: 1.8      -> seen
    ///   cell 11 L 1.6764 window [1.3395, 2.1657]: 1.8, 2.1 -> covered
    /// So [1.0668, 1.6764], 0.61 m. Left hole, by the same count with cameras -3.0, -2.7 | -1.8, -1.5:
    /// cells -17 ... -14, [-2.5908, -1.9812]. The right one is nearer the meter.
    static func twoGroundHoles() -> CoverageMap {
        map(ground: positions(-11...11, except: [-8, -7, 4, 5]))
    }

    static let rightHole: ClosedRange<Float> = 1.0668...1.6764
    static let leftHole: ClosedRange<Float> = -2.5908...(-1.9812)

    @Test func handBuiltMapHasTheExpectedLevels() {
        let map = Self.twoGroundHoles()
        #expect((7...10).allSatisfy { map.level(.ground, $0) == .seen })
        #expect(map.level(.ground, 6) == .covered && map.level(.ground, 11) == .covered)
        #expect((-17...(-14)).allSatisfy { map.level(.ground, $0) == .seen })
        #expect(map.level(.ground, -18) == .covered && map.level(.ground, -13) == .covered)
        #expect((-20...19).allSatisfy { map.level(.wall, $0) == .covered })
    }

    @Test func picksTheGroundGapNearestTheMeter() throws {
        let planner = GapPlanner()
        let map = Self.twoGroundHoles()
        #expect(planner.searchRange(map) == -3...3)
        let runs = planner.missingRuns(.ground, in: -3...3, coverage: map)
        #expect(runs.count == 2)
        #expect(nearlyEqual(runs[0], Self.leftHole))
        #expect(nearlyEqual(runs[1], Self.rightHole))
        let gap = try #require(planner.plan(map))
        #expect(gap.band == .ground)
        #expect(gap.reason == .groundNearMeter)
        #expect(nearlyEqual(gap.span, Self.rightHole))
    }

    @Test func shortRunsAreIgnored() {
        // Cameras ..., -0.3, 0 | 0.75, 1.05, ...: a 0.75 m gap.
        //   cell 1 L 0.1524 window [-0.1845, 0.6417]: 0          -> seen
        //   cell 2 L 0.3048 window [-0.0321, 0.7941]: 0, 0.75    -> covered
        //   cell 3 L 0.4572 window [0.1203, 0.9465]:  0.75       -> seen
        //   cell 4 L 0.6096 window [0.2727, 1.0989]:  0.75, 1.05 -> covered
        // Two one-cell runs of 0.1524 m, both under minRun 0.45.
        let ground = Self.positions(-11...0) + (0...9).map { 0.75 + Float($0) * 0.3 }
        let map = Self.map(ground: ground)
        #expect(map.level(.ground, 1) == .seen && map.level(.ground, 3) == .seen)
        #expect(map.level(.ground, 2) == .covered)
        let planner = GapPlanner()
        #expect(planner.missingRuns(.ground, in: -3...3, coverage: map).isEmpty)
        #expect(planner.plan(map) == nil)
    }

    @Test func wallGapOnceTheGroundIsComplete() throws {
        // Wall cameras without -1.5 ... -0.3 (k -5 ... -1), so -1.8 | 0.0, 0.3:
        //   cell -9 L -1.3716 window [-2.1597, -0.4311]: -2.1, -1.8 -> covered
        //   cell -8 L -1.2192 window [-2.0073, -0.2787]: -1.8       -> seen
        //   cell -7 L -1.0668 window [-1.8549, -0.1263]: -1.8       -> seen
        //   cell -6 L -0.9144 window [-1.7025, 0.0261]:  0          -> seen
        //   cell -5 L -0.7620 window [-1.5501, 0.1785]:  0          -> seen
        //   cell -4 L -0.6096 window [-1.3977, 0.3309]:  0, 0.3     -> covered
        let map = Self.map(ground: Self.positions(-11...11), wall: Self.positions(-13...13, except: Set(-5...(-1))))
        let planner = GapPlanner()
        #expect(planner.missingRuns(.ground, in: -3...3, coverage: map).isEmpty)
        let gap = try #require(planner.plan(map))
        #expect(gap.band == .wall)
        #expect(gap.reason == .wallNearMeter)
        #expect(nearlyEqual(gap.span, -1.2192...(-0.6096)))
    }

    @Test func skippedCellsAreNotRequested() throws {
        var map = Self.twoGroundHoles()
        // Marks cells 7 ... 10, the right hole.
        map.markSkipped(.ground, 1.1...1.6)
        #expect((7...10).allSatisfy { map.level(.ground, $0) == .skipped })
        let gap = try #require(GapPlanner().plan(map))
        #expect(nearlyEqual(gap.span, Self.leftHole))
    }

    @Test func satisfiedAtEightyPercent() throws {
        let planner = GapPlanner()
        var map = Self.twoGroundHoles()
        let gap = try #require(planner.plan(map))
        #expect(planner.progress(of: gap, map) == 0)
        #expect(!planner.isSatisfied(gap, map))

        // A camera at 1.16 lies in the windows of cells 7, 8 and 9 but not 10 (which starts at 1.1871),
        // and is 0.26 m from 0.9, over the baseline: cells 7 ... 9 covered, 10 still seen. 3 of 4 = 75 %.
        map.observe(groundCamera(s: 1.16), trackingNormal: true)
        #expect((7...9).allSatisfy { map.level(.ground, $0) == .covered })
        #expect(map.level(.ground, 10) == .seen)
        #expect(planner.progress(of: gap, map) == 0.75)
        #expect(!planner.isSatisfied(gap, map))

        // Over cells 6 ... 10, 4 of 5 are covered: exactly 80 %.
        let wider = GapPlan(band: .ground, span: 0.95...1.65, reason: .server)
        #expect(planner.progress(of: wider, map) == 0.8)
        #expect(planner.isSatisfied(wider, map))

        // 1.5 is 0.3 from 1.8 and lies in cell 10's window: 4 of 4.
        map.observe(groundCamera(s: 1.5), trackingNormal: true)
        #expect(planner.isSatisfied(gap, map))
    }
}
