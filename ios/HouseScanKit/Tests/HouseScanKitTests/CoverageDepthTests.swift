import HouseScanKit
import simd
import Testing

// Coverage with LiDAR depth on the standard wall (face z = 0, s = x, ground y = 0). Cell 0 spans
// s [0, 0.1524]; its samples sit at s = 0.0381 and 0.1143. Wall rows are at heights 0, 0.9906 and
// 1.9812; ground rows at 0, 0.6 and 1.2 out. Depth images are rendered from the scene mesh
// (`renderDepth`), 128 x 96, so a pixel is 0.01 rad: every margin below is several pixels wide.
@Suite struct CoverageDepthTests {
    /// A box standing in front of the wall: s in [-0.5, 0.5], 0.5 to 1.0 m out, 1.5 m tall.
    static let box = (SIMD3<Float>(-0.5, 0, 0.5), SIMD3<Float>(0.5, 1.5, 1.0))
    static let boxScene = standardScene(boxes: [box])

    @discardableResult
    static func observe(_ map: inout CoverageMap, _ camera: CameraFrame, scene: TriangleMesh) -> CoverageMap.Delta {
        map.observe(camera, trackingNormal: true, depth: renderDepth(scene, from: camera))
    }

    /// Straight on from `wallCamera(s: 0)` at (0, 1.2, 2.0): the sight line to a wall sample
    /// (s, h, 0) crosses the box's front (z = 1) halfway, at s / 2 and height (1.2 + h) / 2.
    /// For cell 0 that is s <= 0.06 and heights 0.6 (row 0) and 1.10 (row 1), inside the box: both
    /// hidden. Row 2 (h = 1.98) crosses z = 1 at 1.59 and z = 0.5 at 1.79, above the box's
    /// 1.5 m top: seen. From `wallCamera(s: 0.3)` rows 0 and 1 cross z = 1 at s <= 0.21: hidden
    /// too. So row 2 is seen twice and rows 0 and 1 never: the cell is hidden, not covered.
    ///
    /// From (2.2, 1.2, 2.0) a sight line to s = 0.0381 is at s = 1.12 when it reaches z = 1 and
    /// s = 0.58 at z = 0.5, clear of the box's s <= 0.5 all the way; from (2.5, 1.2, 2.0) it is
    /// farther still. Both views are 51 to 54 degrees off the wall's normal, under 65, and 0.3 m
    /// apart, so every row gains two positions: covered.
    @Test func wallBehindABoxIsHiddenUntilSeenFromAClearAngle() {
        var map = CoverageMap(wall: standardWall())
        let first = Self.observe(&map, wallCamera(s: 0), scene: Self.boxScene)
        #expect(first.newlyHidden > 0)
        #expect(map.level(.wall, 0) == .hidden)
        Self.observe(&map, wallCamera(s: 0.3), scene: Self.boxScene)
        #expect(map.level(.wall, 0) == .hidden)
        #expect(map.coveredIntervals(.wall).isEmpty)

        let target = SIMD3<Float>(0.08, 1.0, 0)
        Self.observe(&map, portraitCamera(at: SIMD3(2.2, 1.2, 2.0), lookingAt: target), scene: Self.boxScene)
        // One clear position is not two: still hidden.
        #expect(map.level(.wall, 0) == .hidden)
        Self.observe(&map, portraitCamera(at: SIMD3(2.5, 1.2, 2.0), lookingAt: target), scene: Self.boxScene)
        #expect(map.level(.wall, 0) == .covered)
    }

    /// The same two straight-on views without depth cover the cell: the box is not modelled.
    @Test func withoutDepthTheBoxIsNotModelled() {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true)
        map.observe(wallCamera(s: 0.3), trackingNormal: true)
        #expect(map.level(.wall, 0) == .covered)
    }

    /// A bin 1.5 to 1.9 m out, s in [-0.3, 0.3], 0.75 m tall, between the front cameras
    /// ((x, 1.4, 2.6) pitched down 16 degrees, x = 0 and 0.3; see CoverageMapTests) and the ground
    /// band. The sight line to a ground sample (s, 0, o) is at height 1.4 (z - o) / (2.6 - o) at z,
    /// and within the bin's s range there:
    ///   o = 1.2: 0.70 at the bin's front (z = 1.9), under its 0.75 top: hidden.
    ///   o = 0.6: 0.75 at z = 1.67, over the bin's top (z 1.5 to 1.9): hidden.
    ///   o = 0 (the wall's foot): 0.81 at z = 1.5, still above the top when it leaves the bin: seen.
    /// The wall rows' sight lines are higher still, so the wall is seen and the ground hidden.
    /// The ground depth rows stop at the bin as well: every row from 0.3048 m out is hidden
    /// (0.73 m high at z = 1.5), where without depth both views reach row 8, 1.2192 m (row 9 is
    /// 32.7 degrees below the view axis, past the image's 31).
    ///
    /// Cameras at (1.2, 1.4, 1.4) and (1.5, 1.4, 1.4) stand nearer the wall than the bin, so their
    /// sight lines to the band (out <= 1.2) never reach z = 1.5; the steepest is 55 degrees off
    /// vertical, under 65. They cover the ground.
    @Test func groundBehindABinIsHiddenUntilSeenFromAClearAngle() throws {
        let scene = standardScene(boxes: [(SIMD3(-0.3, 0, 1.5), SIMD3(0.3, 0.75, 1.9))])
        var map = CoverageMap(wall: standardWall())
        var noDepth = map
        for x: Float in [0, 0.3] {
            Self.observe(&map, CoverageMapTests.frontCamera(x: x), scene: scene)
            noDepth.observe(CoverageMapTests.frontCamera(x: x), trackingNormal: true)
        }
        #expect(map.level(.ground, 0) == .hidden)
        // The front views never reach the top wall rows, but every row up to 1.9812 m is seen.
        #expect(nearlyEqual(map.wallSeenHeight(at: 0) ?? .nan, 1.9812))
        #expect(noDepth.level(.ground, 0) == .covered)
        // Row 1 (0.1524 m) clears the bin's top by 2 cm, too close to call at this resolution:
        // the reach is row 1 or nothing.
        #expect((map.groundDepth(at: 0) ?? 0) < 0.3)
        #expect(nearlyEqual(try #require(noDepth.groundDepth(at: 0)), 1.2192))

        let target = SIMD3<Float>(0.08, 0, 0.6)
        Self.observe(&map, portraitCamera(at: SIMD3(1.2, 1.4, 1.4), lookingAt: target), scene: scene)
        Self.observe(&map, portraitCamera(at: SIMD3(1.5, 1.4, 1.4), lookingAt: target), scene: scene)
        #expect(map.level(.ground, 0) == .covered)
    }

    /// `wallCamera(s: 0)` faces the wall square on from 2 m, so every wall sample it sees has
    /// z-depth 2.0 and the default tolerance there is 0.10 + 0.02 x 2 = 0.14 m.
    @Test(arguments: [
        (UInt16(2139), CoverageLevel.seen),   // 0.139 farther: within
        (UInt16(2141), CoverageLevel.unseen), // 0.141 farther: not the wall, no evidence
        (UInt16(1861), CoverageLevel.seen),   // 0.139 nearer: within
        (UInt16(1859), CoverageLevel.hidden), // 0.141 nearer: something in front
    ])
    func toleranceEdges(millimeters: UInt16, level: CoverageLevel) {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true, depth: uniformDepth(millimeters))
        #expect(map.level(.wall, 0) == level)
    }

    /// No reading, or one below medium confidence, is no evidence either way: the cell neither
    /// counts as seen nor hides. A missing confidence map lets every reading count.
    @Test func missingOrLowConfidenceDepthIsNoEvidence() {
        var map = CoverageMap(wall: standardWall())
        let none = map.observe(wallCamera(s: 0), trackingNormal: true, depth: uniformDepth(0))
        #expect(!none.changed)
        #expect(map.revision == 0)
        map.observe(wallCamera(s: 0), trackingNormal: true, depth: uniformDepth(1500, confidence: 0))
        #expect(map.level(.wall, 0) == .unseen)
        map.observe(wallCamera(s: 0), trackingNormal: true, depth: uniformDepth(2000, confidence: nil))
        #expect(map.level(.wall, 0) == .seen)
    }

    /// A rebuild replays each camera with the depth it was kept with. Moving the meter down the
    /// wall changes no cell, so the box still hides cell 0; without the depth the replay would
    /// cover it (withoutDepthTheBoxIsNotModelled).
    @Test func rebuildKeepsDepth() {
        var map = CoverageMap(wall: standardWall())
        Self.observe(&map, wallCamera(s: 0), scene: Self.boxScene)
        Self.observe(&map, wallCamera(s: 0.3), scene: Self.boxScene)
        let revision = map.revision
        map.updateWall(WallFrame(meter: SIMD3(0, 1.4, 0), outward: SIMD3(0, 0, 1), groundY: 0)!)
        #expect(map.revision > revision)
        #expect(map.level(.wall, 0) == .hidden)
    }

    /// Stored depth is at most 128 wide: ARKit's 256 x 192 is halved.
    @Test func storedDepthIsHalvedFromARKitSize() {
        let full = DepthImage(
            width: 256, height: 192, millimeters: Array(repeating: 1000, count: 256 * 192), confidence: nil,
            intrinsics: SIMD4(200, 200, 128, 96))
        let stored = CoverageMap.storedDepth(full)
        #expect(stored.width == 128 && stored.height == 96)
        #expect(stored.intrinsics == SIMD4(100, 100, 64, 48))
        #expect(CoverageMap.storedDepth(stored) == stored)
    }

    /// Each 2 x 2 block keeps its nearest reading and the lowest confidence among its readings; a
    /// block with no reading stays 0. The last column is a partial block.
    @Test func downsamplingKeepsTheNearestReading() {
        let image = DepthImage(
            width: 5, height: 2,
            millimeters: [
                3000, 1200, 0, 0, 900,
                2500, 0, 0, 0, 800,
            ],
            confidence: [
                2, 1, 0, 0, 2,
                0, 2, 2, 2, 2,
            ],
            intrinsics: SIMD4(10, 12, 2.5, 1))
        let small = image.downsampled(by: 2)
        #expect(small.width == 3 && small.height == 1)
        #expect(small.millimeters == [1200, 0, 800])
        // Block 0's readings are 3000 (2), 1200 (1) and 2500 (0): lowest 0. The empty block keeps 0.
        #expect(small.confidence == [0, 0, 2])
        #expect(small.intrinsics == SIMD4(5, 6, 1.25, 0.5))
    }

    /// Pixels sample the image by flooring: pixel (1.9, 0.2) is column 1, row 0.
    @Test func readingsAreLookedUpByFlooring() {
        let image = DepthImage(width: 2, height: 2, millimeters: [1000, 2000, 0, 4000], confidence: [2, 2, 2, 0], intrinsics: SIMD4(1, 1, 1, 1))
        #expect(image.meters(atPixel: SIMD2(1.9, 0.2), minimumConfidence: 1) == 2)
        #expect(image.meters(atPixel: SIMD2(0.5, 1.5), minimumConfidence: 1) == nil)
        #expect(image.meters(atPixel: SIMD2(1.5, 1.5), minimumConfidence: 1) == nil)
        #expect(image.meters(atPixel: SIMD2(1.5, 1.5), minimumConfidence: 0) == 4)
        #expect(image.meters(atPixel: SIMD2(2.0, 0), minimumConfidence: 0) == nil)
        #expect(image.meters(atPixel: SIMD2(-0.1, 0), minimumConfidence: 0) == nil)
    }

    /// Hidden cells are gaps: the gap planner asks for them like unseen ones.
    @Test func hiddenCellsAreMissing() {
        var map = CoverageMap(wall: standardWall())
        Self.observe(&map, wallCamera(s: 0), scene: Self.boxScene)
        Self.observe(&map, wallCamera(s: 0.3), scene: Self.boxScene)
        let runs = GapPlanner().missingRuns(.wall, in: -0.3...0.3, coverage: map)
        #expect(runs.count == 1)
        #expect(nearlyEqual(runs.first ?? 0...0, -0.3...0.3))
    }
}
