import Foundation
import HouseScanKit
import simd
import Testing

// Ground depth rows sit every 0.1524 m from the wall foot (row 0) out to 5.1816 m (row 34, 17 ft).
//
// `downCamera(s:out:)` hangs 2 m up looking straight down, image +y along +s. A ground point
// (s', 0, o) is 2 m deep and lands on u = 320 + 250 (o - out), v = 240 - 250 (s' - s); with the
// 3 % margin it is in view when |o - out| <= 1.2032 and |s' - s| <= 0.9024. The steepest view
// needed below, 1.2 m sideways from 2 m up, is 31 degrees from the ground's normal, under 65.
@Suite struct GroundDepthTests {
    static func downCamera(s: Float, out: Float) -> CameraFrame {
        makeCamera(at: SIMD3(s, 2, out), forward: SIMD3(0, -1, 0), right: SIMD3(1, 0, 0))
    }

    /// Every camera from two positions 0.3 m apart along the wall, so each row it sees is covered.
    static func map(outs: [Float]) -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        for out in outs {
            for s: Float in [0, 0.3] { map.observe(downCamera(s: s, out: out), trackingNormal: true) }
        }
        return map
    }

    @Test func rowsFromDifferentViewsAddUpToTheFullDepth() {
        // out 1.0 sees 0...2.2 m, out 3.3 sees 2.1...4.5 m, out 4.0 sees 2.8...5.2 m.
        let map = Self.map(outs: [1.0, 3.3, 4.0])
        #expect(map.groundDepthRows.count == 35)
        #expect(map.groundDepth(at: 0).map { nearlyEqual($0, 5.1816) } == true)
    }

    @Test func depthStopsAtTheFirstRowNotCovered() {
        // Without the middle view, rows 15 to 18 (2.29...2.74 m) are unseen: the depth is row 14,
        // 2.1336 m, though rows beyond 2.8 m are covered.
        let map = Self.map(outs: [1.0, 4.0])
        #expect(map.groundDepth(at: 0).map { nearlyEqual($0, 2.1336) } == true)
    }

    @Test func onePositionOrLimitedTrackingSeesNoDepth() {
        var map = CoverageMap(wall: standardWall())
        map.observe(Self.downCamera(s: 0, out: 1.0), trackingNormal: true)
        map.observe(Self.downCamera(s: 0.1, out: 1.0), trackingNormal: true)  // under the 0.25 m baseline
        map.observe(Self.downCamera(s: 0.3, out: 1.0), trackingNormal: false)
        #expect(map.groundDepth(at: 0) == nil)
        #expect(map.groundDepthSpans().isEmpty)
    }

    /// The near band the strip draws keeps its three rows out to 1.2 m: far views change nothing there.
    @Test func farViewsLeaveTheNearBandAlone() {
        let far = Self.map(outs: [4.0])
        #expect(far.level(.ground, 0) == .unseen)
        #expect(far.groundDepth(at: 0) == nil)
        let near = Self.map(outs: [1.0])
        #expect(near.level(.ground, 0) == .covered)
    }

    @Test func spansGroupCellsOfEqualDepthAndStopAtAnEnd() {
        var map = Self.map(outs: [1.0, 3.3, 4.0])
        // Both cameras see s in [-0.6024, 0.9024]: cells -4 (from -0.6096, samples at -0.5715 and
        // -0.4953) to 5 (to 0.9144).
        let spans = map.groundDepthSpans()
        #expect(spans.count == 1)
        #expect(nearlyEqual(spans[0].span, -0.6096...0.9144))
        #expect(nearlyEqual(spans[0].out, 5.1816))
        map.setEnd(.right, at: 0.5)
        #expect(nearlyEqual(map.groundDepthSpans()[0].span, -0.6096...0.5))
    }

    /// The deepest row reaches the pool request the public rules make at the edge of cable
    /// reach: D + r + e = 1.8333 + 10 + 0.3 + 0.16 x 27.60 = 16.55 ft (CoverageConfig's
    /// derivation), and 15 ft fell short of it.
    @Test func theDeepestRowReachesTheFarthestPublicPoolRequest() {
        let map = CoverageMap(wall: standardWall())
        let deepestFt = Double(map.groundDepthRows.last ?? 0) * SceneUnits.feetPerMeter
        let farEdge = (20 + 0.3 + 0.3 + 0.16 * 2.583333) / (1 - 0.16) + 2.583333
        #expect(deepestFt >= 1.833333 + 10 + 0.3 + 0.16 * farEdge)
    }

    // Ground past a right end at s = 0.5. `downCamera(s:out:)` at out 0.3 sees the ground from
    // 0.9032 m behind the wall's line to 1.5032 m in front, within 0.9024 m along it.

    static func pastEnd(cameraS: [Float], out: Float, limit: Bool) -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        map.setEnd(.right, at: 0.5)
        map.setEndIsLimit(.right, limit)
        for s in cameraS { map.observe(downCamera(s: s, out: out), trackingNormal: true) }
        return map
    }

    /// Past a limit end the ground counts once both sides of the continued line are seen, as far
    /// out as the nearer side reaches: rows 0 to 5 (0.762 m) behind, 0 to 9 in front. Cameras at
    /// 0.9 and 1.2 both see s from 0.2976 to 1.8024, so past cells 0 to 7 (0.5 to 1.7192).
    @Test func groundPastALimitEndCountsWhereBothSidesWereSeen() throws {
        let map = Self.pastEnd(cameraS: [0.9, 1.2], out: 0.3, limit: true)
        #expect(map.groundDepthPastLimit(.right, 0).map { nearlyEqual($0, 0.762) } == true)
        #expect(map.groundDepthPastLimit(.right, 7).map { nearlyEqual($0, 0.762) } == true)
        #expect(map.groundDepthPastLimit(.right, 8) == nil)
        let past = try #require(map.groundDepthSpans().first { $0.span.upperBound > 0.5 + 1e-4 })
        // It starts exactly at the end, where the ground inside the ends is clipped.
        #expect(past.span.lowerBound == 0.5)
        #expect(nearlyEqual(past.span.upperBound, 0.5 + 8 * 0.1524))
        #expect(nearlyEqual(past.out, 0.762))
    }

    /// Past an unexplored end nothing is reported, and a limit end that moves or is cleared is
    /// unexplored again.
    @Test func pastAnUnexploredEndNothingChanges() {
        let unexplored = Self.pastEnd(cameraS: [0.9, 1.2], out: 0.3, limit: false)
        #expect(unexplored.groundDepthPastLimit(.right, 0) == nil)
        #expect(unexplored.groundDepthSpans().allSatisfy { $0.span.upperBound <= 0.5 })
        var moved = Self.pastEnd(cameraS: [0.9, 1.2], out: 0.3, limit: true)
        moved.setEnd(.right, at: 0.6)
        #expect(!moved.limitEnds.contains(.right))
        #expect(moved.groundDepthSpans().allSatisfy { $0.span.upperBound <= 0.6 })
        var cleared = Self.pastEnd(cameraS: [0.9, 1.2], out: 0.3, limit: true)
        cleared.clearEnd(.right)
        #expect(cleared.limitEnds.isEmpty)
        // Marking the end a limit after the walk replays the walk against it.
        var later = Self.pastEnd(cameraS: [0.9, 1.2], out: 0.3, limit: false)
        later.setEndIsLimit(.right, true)
        #expect(later.groundDepthPastLimit(.right, 0).map { nearlyEqual($0, 0.762) } == true)
    }

    /// From 1.1 m out the cameras see the front of the line out to 2.3 m but only its first row
    /// behind it (0.1 m): one side is not the ground the server credits, so nothing past the end.
    @Test func oneSideOfTheContinuedLineIsNotEnough() {
        let map = Self.pastEnd(cameraS: [0.9, 1.2], out: 1.1, limit: true)
        #expect(map.groundDepthPastLimit(.right, 0) == nil)
        #expect(map.groundDepthSpans().allSatisfy { $0.span.upperBound <= 0.5 })
    }

    /// Cameras in front of the scanned wall short of the end see the ground behind the line past
    /// the end only through the house: a sight line from s = 0.2 to (0.538, -0.1524) crosses the
    /// line at s = 0.42, short of the end. The same rows seen from past the end count.
    @Test func groundBehindTheLineIsNotSeenThroughTheHouse() {
        let map = Self.pastEnd(cameraS: [-0.1, 0.2], out: 0.3, limit: true)
        #expect(map.groundDepthPastLimit(.right, 0) == nil)
    }

    /// The export reports ground past a limit end as a span beyond the chain's end, and a server
    /// request there closes on the phone only past a limit.
    @Test func groundPastALimitEndIsExportedAndSettlesARequest() throws {
        let map = Self.pastEnd(cameraS: [0.9, 1.2], out: 0.3, limit: true)
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        let data = try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -2...0.5, coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: true)))
        #expect(try SceneSchemas.scene().validate(data) == [])
        let observed = try #require(JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array)
        let past = observed.filter { $0["band"]?.string == "ground" && ($0["span_ft"]?.numbers?.last ?? 0) > 1.6405 }
        #expect(past.count == 1)
        // 0.5 m (1.64042 ft) to 1.7192 m (5.64042 ft), each end rounded inward.
        #expect(past.first?["span_ft"]?.numbers == [1.6405, 5.6404])
        #expect(past.first?["out_ft"]?.number == 2.5)

        let item = try JSONDecoder().decode(PlacementMissingEvidence.self, from: Data(
            #"{"kind":"band","band":"ground","span_ft":[1.7,5.6],"out_ft":2.5,"message":"m"}"#.utf8))
        let plan = try #require(GapPlanner().plan(for: item, leftEnd: nil, rightEnd: 0.5))
        #expect(GapPlanner().isSatisfied(plan, map))
        #expect(!GapPlanner().isSatisfied(plan, Self.pastEnd(cameraS: [0.9, 1.2], out: 0.3, limit: false)))
    }

    @Test func exportReportsTheDepthInFeetNeverRoundedUp() throws {
        let map = Self.map(outs: [1.0, 4.0])
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        let input = SceneInput(wall: wall, baselineS: -2...2, coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false))
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let observed = try #require(JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array)
        let ground = observed.filter { $0["band"]?.string == "ground" }
        // 14 rows of 6 in: exactly 7 ft.
        #expect(ground.count == 1)
        #expect(ground.first?["out_ft"]?.number == 7.0)
    }
}
