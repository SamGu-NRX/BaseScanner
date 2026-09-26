import Foundation
import HouseScanKit
import simd
import Testing

// A portrait camera 2 m out at height 1.4, pitched up by θ, facing the wall. Its image spans
// atan(300.8 / 500) = 31.03 degrees above the view axis (3 % margin), and pitch without roll leaves
// a wall point's height on screen independent of its s. So the view reaches the wall at
// h = 1.4 + 2 tan(θ + 31.03°) wherever it reaches the wall at all, unless 6 m of distance ends it
// first. Sideways, a wall point at depth d along the axis is in view when |s| <= 0.4512 d.
@Suite struct OverheadTests {
    static func tiltUp(s: Float = 0, pitch: Float) -> CameraFrame {
        let a = pitch * .pi / 180
        return portraitCamera(at: SIMD3(s, 1.4, 2), forward: SIMD3(0, sin(a), -cos(a)))
    }

    /// The wall seen to the top of the band, 2.286 m, over about -3.3 to 3.2: level views every
    /// 0.3 m from -2.4 to 2.4 (`wallCamera` sees 0 to 2.40 m up). Overhead evidence starts where
    /// the walk's view of the wall ends, so it needs this first.
    static func walkedWall() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        for step in 0...16 { map.observe(wallCamera(s: -2.4 + 0.3 * Float(step)), trackingNormal: true) }
        return map
    }

    @Test func aTiltUpViewReachesTheTopOfTheImage() throws {
        let map = CoverageMap(wall: standardWall())
        // θ = 30: h = 1.4 + 2 tan(61.03°) = 5.0123. The foot of the reach, the band's top at
        // h = 2.286, is at depth 2 cos 30° + 0.886 sin 30° = 2.1751, so |s| <= 0.9814: cells -6 to 5.
        let reach = map.overheadReach(from: Self.tiltUp(pitch: 30))
        #expect(reach.count == 1)
        let first = try #require(reach.first)
        #expect(nearlyEqual(first.span, -0.9144...0.9144))
        // Rounded down to 0.1 ft, never up.
        #expect(first.out <= 5.0123 && first.out > 5.0123 - 0.0305)
    }

    @Test func distanceEndsASteepView() throws {
        // θ = 45: the image would reach 1.4 + 2 tan(76.03°) = 9.44 m, but 6 m from the camera
        // ends it at h = 1.4 + sqrt(36 - 4) = 7.0569 over s = 0 (its bottom, 14 degrees up, still
        // shows the top of the wall band, 23.9 degrees up).
        let map = CoverageMap(wall: standardWall())
        let reach = map.overheadReach(from: Self.tiltUp(pitch: 45))
        let middle = try #require(reach.first { $0.span.contains(0.07) })
        #expect(middle.out <= 7.0569 && middle.out > 7.0569 - 0.0305)
    }

    @Test func aViewThatMissesTheTopOfTheWallBandShowsNothingOverhead() {
        let map = CoverageMap(wall: standardWall())
        // Pitched down 20: the top of the image meets the wall at 1.4 + 2 tan(11.03°) = 1.79 m.
        #expect(map.overheadReach(from: Self.tiltUp(pitch: -20)).isEmpty)
        // Behind the wall's plane nothing counts.
        #expect(map.overheadReach(from: portraitCamera(at: SIMD3(0, 1.4, -2), forward: SIMD3(0, 0.5, 1))).isEmpty)
    }

    @Test func onlyRecordedViewsWithNormalTrackingCount() {
        var map = Self.walkedWall()
        #expect(map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: false).isEmpty)
        #expect(map.overheadSpans().isEmpty)
        #expect(map.overheadHeight(at: 0) == nil)
        let revision = map.revision
        #expect(!map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true).isEmpty)
        #expect(map.revision == revision + 1)
        #expect(map.overheadHeight(at: 0).map { $0 > 4.98 } == true)
    }

    @Test func theHighestViewOfACellCountsAndEndsClip() throws {
        var map = Self.walkedWall()
        map.recordOverhead(Self.tiltUp(pitch: 0), trackingNormal: true)  // reaches 1.4 + 2 tan 31.03° = 2.6
        map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true)
        #expect(map.overheadHeight(at: 0).map { $0 > 4.98 } == true)
        map.setEnd(.left, at: -0.5)
        let spans = map.overheadSpans()
        #expect(spans.first.map { nearlyEqual($0.span.lowerBound, -0.5) } == true)
        #expect(spans.allSatisfy { $0.out > 2.5 })
    }

    /// The overhead question during an overhead request comes up only for a view that settles it
    /// once recorded, alone or with the views already kept; the check itself records nothing.
    @Test func aViewSettlesAnOverheadRequestOnlyOverItsWholeSpan() {
        let planner = GapPlanner()
        let map = Self.walkedWall()
        let view = Self.tiltUp(pitch: 30)  // 5.01 m up over -0.9144 ... 0.9144
        let headroom: Float = 6.5 * 0.3048
        #expect(planner.overheadViewSettles(GapPlan(band: .wall, span: 0...0.786, reason: .server, need: .overhead(headroom)), map, camera: view))
        #expect(planner.overheadViewSettles(GapPlan(band: .wall, span: 0...0.786, reason: .server, need: .overhead(nil)), map, camera: view))
        // Past the view's side, or higher than it reaches.
        #expect(!planner.overheadViewSettles(GapPlan(band: .wall, span: 0.5...1.3, reason: .server, need: .overhead(headroom)), map, camera: view))
        #expect(!planner.overheadViewSettles(GapPlan(band: .wall, span: 0...0.786, reason: .server, need: .overhead(5.1)), map, camera: view))
        // Only overhead requests.
        #expect(!planner.overheadViewSettles(GapPlan(band: .wall, span: 0...0.786, reason: .server), map, camera: view))
        // Pitched down, the view shows nothing above the wall band.
        #expect(!planner.overheadViewSettles(GapPlan(band: .wall, span: 0...0.786, reason: .server, need: .overhead(nil)), map, camera: Self.tiltUp(pitch: -20)))

        // -1.5 ... 0.5 is wider than one view; with a view from s = -0.8 kept, this one completes it.
        let wide = GapPlan(band: .wall, span: -1.5...0.5, reason: .server, need: .overhead(headroom))
        #expect(!planner.overheadViewSettles(wide, map, camera: view))
        var kept = map
        kept.recordOverhead(Self.tiltUp(s: -0.8, pitch: 30), trackingNormal: true)
        #expect(!planner.isSatisfied(wide, kept))
        #expect(planner.overheadViewSettles(wide, kept, camera: view))
        #expect(kept.overheadCameras.count == 1 && map.overheadCameras.isEmpty)
    }

    /// A recorded view counts over a cell only from the height the walk saw its wall up to, so
    /// nothing between the two views goes unseen. Pitched up 52 degrees the view's bottom meets
    /// the wall at 1.4 + 2 tan(20.97°) = 2.17 m: above the 1.98 m the pitched-down front views
    /// reach, below the 2.286 m level views reach.
    @Test func aViewCountsOnlyFromWhereTheWalkSawTheWall() {
        var unseen = CoverageMap(wall: standardWall())
        unseen.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true)
        #expect(unseen.overheadCameras.count == 1)
        #expect(unseen.overheadHeight(at: 0) == nil && unseen.overheadSpans().isEmpty)

        var low = CoverageMap(wall: standardWall())
        low.observe(CoverageMapTests.frontCamera(), trackingNormal: true)
        low.observe(CoverageMapTests.frontCamera(x: 0.3), trackingNormal: true)
        var high = Self.walkedWall()
        low.recordOverhead(Self.tiltUp(pitch: 52), trackingNormal: true)
        high.recordOverhead(Self.tiltUp(pitch: 52), trackingNormal: true)
        #expect(low.overheadCameras.count == 1)
        #expect(low.overheadHeight(at: 0) == nil)
        #expect(high.overheadHeight(at: 0).map { $0 > 6.9 } == true)
        // The 30 degree view shows the wall down to 1.37 m, so over the lower walk it counts.
        low.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true)
        #expect(low.overheadHeight(at: 0).map { $0 > 4.98 } == true)
    }

    /// A guessed ground's error comes off the overhead height as off the wall's.
    @Test func aGuessedGroundComesOffTheOverheadHeight() throws {
        var map = Self.walkedWall()
        map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true)
        let measured = try #require(map.overheadHeight(at: 0))
        map.heightError = 0.3
        #expect(nearlyEqual(try #require(map.overheadHeight(at: 0)), measured - 0.3))
        #expect(map.overheadSpans().allSatisfy { $0.out <= measured - 0.3 + 1e-5 })
    }

    @Test func exportSendsTheHeightSeen() throws {
        var map = Self.walkedWall()
        map.recordOverhead(Self.tiltUp(pitch: 30), trackingNormal: true)
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        let data = try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -2...2, coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false)))
        #expect(try SceneSchemas.scene().validate(data) == [])
        let observed = try #require(JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array)
        let overhead = observed.filter { $0["band"]?.string == "overhead" }
        #expect(overhead.count == 1)
        let feet = try #require(overhead.first?["out_ft"]?.number)
        // 5.0123 m is 16.44 ft; rounded down to 0.1 ft of a meter's worth, then to 4 decimals.
        #expect(feet <= 16.4447 && feet > 16.3)
    }
}
