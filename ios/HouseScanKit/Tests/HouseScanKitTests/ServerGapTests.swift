import Foundation
import HouseScanKit
import Testing

/// Server missing-evidence items become capture requests (result.schema.json missing_evidence).
@Suite struct ServerGapTests {
    private func item(_ json: String) throws -> PlacementMissingEvidence {
        try JSONDecoder().decode(PlacementMissingEvidence.self, from: Data(json.utf8))
    }

    @Test func groundBandBecomesAGroundRequestInMeters() throws {
        // span_ft [3.0, 5.5] -> 0.9144...1.6764 m.
        let plan = try #require(GapPlanner().plan(for: item(#"{"kind":"band","band":"ground","span_ft":[3.0,5.5],"message":"m"}"#), leftEnd: nil, rightEnd: nil))
        #expect(plan.band == .ground)
        #expect(abs(plan.span.lowerBound - 0.9144) < 1e-4)
        #expect(abs(plan.span.upperBound - 1.6764) < 1e-4)
        #expect(plan.reason == .server)
    }

    @Test func requestsWithAReachAskForItInMeters() throws {
        let planner = GapPlanner()
        // out_ft 6.0 = 1.8288 m, 8.5 = 2.5908 m, 7.0 = 2.1336 m.
        let ground = try #require(planner.plan(for: item(#"{"kind":"band","band":"ground","span_ft":[0,2.58],"out_ft":6.0,"message":"m"}"#), leftEnd: nil, rightEnd: nil))
        #expect(ground.band == .ground)
        guard case .groundOut(let out) = ground.need else { Issue.record("\(ground.need)"); return }
        #expect(nearlyEqual(out, 1.8288))
        let facing = try #require(planner.plan(for: item(#"{"kind":"band","band":"facing","span_ft":[0,2.58],"out_ft":8.5,"message":"m"}"#), leftEnd: nil, rightEnd: nil))
        #expect(facing.band == .ground)
        guard case .walkOut(let walk) = facing.need else { Issue.record("\(facing.need)"); return }
        #expect(nearlyEqual(walk, 2.5908))
        let overhead = try #require(planner.plan(for: item(#"{"kind":"band","band":"overhead","span_ft":[0,2.58],"out_ft":7.0,"message":"m"}"#), leftEnd: nil, rightEnd: nil))
        #expect(overhead.band == .wall)
        guard case .overhead(let height?) = overhead.need else { Issue.record("\(overhead.need)"); return }
        #expect(nearlyEqual(height, 2.1336))
        #expect(planner.plan(for: try item(#"{"kind":"band","band":"wall","span_ft":[0,1],"message":"m"}"#), leftEnd: nil, rightEnd: nil)?.need == .cells)
    }

    /// Facing without out_ft means the view must reach whatever faces the wall and measure it,
    /// which walking can't show; overhead without one asks for any recorded tilt-up view.
    @Test func facingWithoutAReachIsNotACaptureRequest() throws {
        #expect(GapPlanner().plan(for: try item(#"{"kind":"band","band":"facing","span_ft":[0,1],"message":"m"}"#), leftEnd: nil, rightEnd: nil) == nil)
        #expect(GapPlanner().plan(for: try item(#"{"kind":"band","band":"overhead","span_ft":[0,1],"message":"m"}"#), leftEnd: nil, rightEnd: nil)?.need == .overhead(nil))
    }

    @Test func outFtRoundTrips() throws {
        let decoded = try item(#"{"kind":"band","band":"ground","span_ft":[0,1],"out_ft":5.13,"message":"m"}"#)
        #expect(decoded.outFt == 5.13)
        #expect(try JSONDecoder().decode(PlacementMissingEvidence.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

    @Test func groundOutIsMetOnlyWhenEveryCellIsSeenThatFar() {
        // GroundDepthTests' cameras: out 1.0 and 4.0 leave the depth at 2.1336 m (7 ft) over cells -4 to 5.
        var map = CoverageMap(wall: standardWall())
        for out: Float in [1.0, 4.0] {
            for s: Float in [0, 0.3] { map.observe(GroundDepthTests.downCamera(s: s, out: out), trackingNormal: true) }
        }
        let planner = GapPlanner()
        #expect(planner.isSatisfied(GapPlan(band: .ground, span: 0...0.6, reason: .server, need: .groundOut(7 * 0.3048)), map))
        #expect(!planner.isSatisfied(GapPlan(band: .ground, span: 0...0.6, reason: .server, need: .groundOut(7.1 * 0.3048)), map))
        // Cell 6 lies past the seen cells: 6 of 7 met would do for cells (80 %), not for a reach.
        let wider = GapPlan(band: .ground, span: 0...1.0668, reason: .server, need: .groundOut(1))
        #expect(planner.progress(of: wider, map) < 1)
        #expect(!planner.isSatisfied(wider, map))
    }

    @Test func walkOutIsMetByWalkingPastTheSpanFarEnoughOut() {
        var map = CoverageMap(wall: standardWall())
        FacingTests.walk(&map, out: 1.5, from: -1, to: 1.5)
        let planner = GapPlanner()
        // Needs 1.5 m clear: the walk at 1.5 m leaves 1.5 less the error.
        let gap = GapPlan(band: .ground, span: 0...0.786, reason: .server, need: .walkOut(1.5))
        #expect(!planner.isSatisfied(gap, map))
        FacingTests.walk(&map, out: 1.5 + CoverageMap.positionError(atS: 0.9144) + 0.01, from: -1, to: 1.5)
        #expect(planner.isSatisfied(gap, map))
    }

    @Test func overheadIsMetByARecordedViewHighEnough() {
        var map = CoverageMap(wall: standardWall())
        let planner = GapPlanner()
        let gap = GapPlan(band: .wall, span: 0...0.786, reason: .server, need: .overhead(6.5 * 0.3048))
        #expect(!planner.isSatisfied(gap, map))
        // Seen but not confirmed clear is not evidence.
        #expect(!map.overheadReach(from: OverheadTests.tiltUp(pitch: 30)).isEmpty)
        #expect(!planner.isSatisfied(gap, map))
        map.recordOverhead(OverheadTests.tiltUp(pitch: 30), trackingNormal: true)
        #expect(planner.isSatisfied(gap, map))
        #expect(!planner.isSatisfied(GapPlan(band: .wall, span: 0...0.786, reason: .server, need: .overhead(5.1)), map))
    }

    @Test func pastEndAsksForTheGroundBeyondThatEnd() throws {
        // Left end at s = -3 m: ask for -5...-3. Right end at 4 m: ask for 4...6.
        let left = try #require(GapPlanner().plan(for: item(#"{"kind":"past_end","side":"left","message":"m"}"#), leftEnd: -3, rightEnd: 4))
        #expect(left.band == .ground && left.span == -5 ... -3)
        let right = try #require(GapPlanner().plan(for: item(#"{"kind":"past_end","side":"right","message":"m"}"#), leftEnd: -3, rightEnd: 4))
        #expect(right.span == 4...6)
    }

    @Test func clearingAnEndLetsCoverageGrowPastIt() throws {
        let wall = try #require(WallFrame(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0))
        var map = CoverageMap(wall: wall)
        map.setEnd(.right, at: 1)
        #expect(map.visibleRange.upperBound == 1)
        map.clearEnd(.right)
        #expect(map.rightEnd == nil)
        // Nothing seen yet: the fog reaches 2.5 m either side of the meter again.
        #expect(map.visibleRange.upperBound == 2.5)
    }
}
