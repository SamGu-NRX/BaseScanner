import Foundation
import HouseScanKit
import simd
import Testing

// Ground depth rows sit every 0.1524 m from the wall foot (row 0) out to 4.572 m (row 30, 15 ft).
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
        #expect(map.groundDepthRows.count == 31)
        #expect(map.groundDepth(at: 0).map { nearlyEqual($0, 4.572) } == true)
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
        #expect(nearlyEqual(spans[0].out, 4.572))
        map.setEnd(.right, at: 0.5)
        #expect(nearlyEqual(map.groundDepthSpans()[0].span, -0.6096...0.5))
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
