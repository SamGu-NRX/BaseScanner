import Foundation
@testable import HouseScanKit
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

    /// Ground past the deepest sampled row (17 ft) can't be captured: no request is built, so the
    /// app sends it to review. 17 ft itself can be.
    @Test func groundDeeperThanTheMapSamplesIsBeyondCapture() throws {
        let planner = GapPlanner()
        let deepest = try item(#"{"kind":"band","band":"ground","span_ft":[0,2.58],"out_ft":17.0,"message":"m"}"#)
        #expect(!planner.isBeyondCapture(deepest))
        #expect(planner.plan(for: deepest, leftEnd: nil, rightEnd: nil) != nil)
        let deeper = try item(#"{"kind":"band","band":"ground","span_ft":[0,2.58],"out_ft":17.000001,"message":"m"}"#)
        #expect(planner.isBeyondCapture(deeper))
        #expect(planner.plan(for: deeper, leftEnd: nil, rightEnd: nil) == nil)
        // Only ground has a sampling limit.
        #expect(!planner.isBeyondCapture(try item(#"{"kind":"band","band":"facing","span_ft":[0,1],"out_ft":30,"message":"m"}"#)))
        #expect(planner.config.groundDepthReach == CoverageConfig().groundDepthReach)
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
        #expect(planner.isSatisfied(GapPlan(band: .ground, span: 0...0.6, reason: .server, need: .groundOut(7 * 0.3048), requestedOutFt: 7), map))
        #expect(!planner.isSatisfied(GapPlan(band: .ground, span: 0...0.6, reason: .server, need: .groundOut(7.1 * 0.3048), requestedOutFt: 7.1), map))
        // Cell 6 lies past the seen cells: 6 of 7 met would do for cells (80 %), not for a reach.
        let wider = GapPlan(band: .ground, span: 0...1.0668, reason: .server, need: .groundOut(1))
        #expect(planner.progress(of: wider, map) < 1)
        #expect(!planner.isSatisfied(wider, map))
    }

    /// The server asks for the smallest 6-decimal value strictly above its rule (solver.py
    /// `_above` on origin/t3/server): D + r for facing is 4.833333 ft, so it asks for 4.833334.
    /// The export reports 4.8333 ft for a clearance just under that, which does not settle the
    /// request; 4.8334 does. Rounding the request to the export's four decimals called both met.
    @Test func aReachJustUnderAStrictlyAboveRequestIsNotMet() throws {
        let plan = try #require(GapPlanner().plan(
            for: item(#"{"kind":"band","band":"facing","span_ft":[0,1],"out_ft":4.833334,"message":"m"}"#), leftEnd: nil, rightEnd: nil))
        #expect(plan.requestedOutFt == 4.833334)
        // A walk that leaves 4.83332 ft clear at cell 1's far edge (0.3048 m): feet down, 4.8333.
        let under: Float = 4.83332 * 0.3048
        let over: Float = 4.83345 * 0.3048
        for (clear, met) in [(under, false), (over, true)] {
            var map = CoverageMap(wall: standardWall())
            FacingTests.walk(&map, out: clear + ServerErrorDefaults.wall(.tap, atS: 0.3048), from: -1, to: 1.5)
            let exported = try #require(map.walkedClearance(at: 1))
            #expect(SceneExport.feetDown(exported) == (met ? 4.8334 : 4.8333))
            let cell = GapPlan(band: .ground, span: 0.1524...0.3048, reason: .server, need: plan.need, requestedOutFt: plan.requestedOutFt)
            #expect(GapPlanner().isSatisfied(cell, map) == met)
        }
    }

    /// A reach request is met over its whole span as the export reports it. The export stops at
    /// a marked end, so a request reaching past it stays open on the server; counting only the
    /// cells inside the ends called it met.
    @Test func aReachRequestPastAMarkedEndIsNotMet() {
        let planner = GapPlanner()
        var ground = CoverageMap(wall: standardWall())
        for out: Float in [1.0, 4.0] {
            for s: Float in [0, 0.3] { ground.observe(GroundDepthTests.downCamera(s: s, out: out), trackingNormal: true) }
        }
        let deep = GapPlan(band: .ground, span: 0...0.6, reason: .server, need: .groundOut(7 * 0.3048), requestedOutFt: 7)
        #expect(planner.isSatisfied(deep, ground))
        ground.setEnd(.right, at: 0.5)
        #expect(!planner.isSatisfied(deep, ground))
        #expect(abs(planner.progress(of: deep, ground) - 0.5 / 0.6) < 1e-3)

        var walked = CoverageMap(wall: standardWall())
        FacingTests.walk(&walked, out: 1.6 + ServerErrorDefaults.wall(.tap, atS: 0.9144), from: -1, to: 1.5)
        let facing = GapPlan(band: .ground, span: 0...0.786, reason: .server, need: .walkOut(1.5))
        #expect(planner.isSatisfied(facing, walked))
        walked.setEnd(.right, at: 0.5)
        #expect(!planner.isSatisfied(facing, walked))
    }

    /// The request's span is read as the server sent it and the export as written. Ground seen up
    /// to an end at 0.5 m (1.64042 ft) is written to 1.6404 ft, rounded inward. The server reads
    /// a shortfall under its 0.01 ft tolerance as rounding, so a request to 1.64042 ft is met, but
    /// one 0.02 ft past what was seen is not. Past the (unexplored) end by that much, it has no
    /// capture request at all (`reachesPastEnd`), so it is planned here as if no end were marked.
    @Test func aRequestSpanIsReadInTheServersFeet() throws {
        var map = CoverageMap(wall: standardWall())
        for out: Float in [1.0, 4.0] {
            for s: Float in [0, 0.3] { map.observe(GroundDepthTests.downCamera(s: s, out: out), trackingNormal: true) }
        }
        map.setEnd(.right, at: 0.5)
        let rounding = try #require(GapPlanner().plan(
            for: item(#"{"kind":"band","band":"ground","span_ft":[0,1.64042],"out_ft":7.0,"message":"m"}"#), leftEnd: nil, rightEnd: map.rightEnd))
        #expect(GapPlanner().isSatisfied(rounding, map))
        let pastEnd = try item(#"{"kind":"band","band":"ground","span_ft":[0,1.66042],"out_ft":7.0,"message":"m"}"#)
        #expect(GapPlanner().plan(for: pastEnd, leftEnd: nil, rightEnd: map.rightEnd) == nil)
        let short = try #require(GapPlanner().plan(for: pastEnd, leftEnd: nil, rightEnd: nil))
        #expect(!GapPlanner().isSatisfied(short, map))
        let exact = try #require(GapPlanner().plan(
            for: item(#"{"kind":"band","band":"ground","span_ft":[0,1.6404],"out_ft":7.0,"message":"m"}"#), leftEnd: nil, rightEnd: map.rightEnd))
        #expect(GapPlanner().isSatisfied(exact, map))
    }

    @Test func walkOutIsMetByWalkingPastTheSpanFarEnoughOut() {
        var map = CoverageMap(wall: standardWall())
        FacingTests.walk(&map, out: 1.5, from: -1, to: 1.5)
        let planner = GapPlanner()
        // Needs 1.5 m clear: the walk at 1.5 m leaves 1.5 less the error.
        let gap = GapPlan(band: .ground, span: 0...0.786, reason: .server, need: .walkOut(1.5))
        #expect(!planner.isSatisfied(gap, map))
        // A second pass later on: poses join in the order they were captured, so it needs its own times.
        FacingTests.walk(&map, out: 1.5 + ServerErrorDefaults.wall(.tap, atS: 0.9144) + 0.01, from: -1, to: 1.5, startTime: 100)
        #expect(planner.isSatisfied(gap, map))
    }

    @Test func overheadIsMetByARecordedViewHighEnough() {
        var map = OverheadTests.walkedWall()
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

    /// wallCamera(s: c) sees a wall cell with lower edge L exactly when c is in [L - 0.7881,
    /// L + 0.9405], and cameras 0.3 m apart are far enough apart to cover it. Views at -1.5 ...
    /// 0 cover cells up to 3 (L = 0.4572; cell 4 at 0.6096 has only the view at 0).
    static func walkedWall(to last: Float) -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        for c in stride(from: Float(-1.5), through: last + 1e-3, by: 0.3) { map.observe(wallCamera(s: c), trackingNormal: true) }
        return map
    }

    @Test func aServerWallRequestNeedsItsWholeSpanAsExported() {
        let planner = GapPlanner()
        var map = Self.walkedWall(to: 0)
        #expect((0...3).allSatisfy { map.level(.wall, $0) == .covered } && map.level(.wall, 4) == .seen)
        // Cells 0 ... 4 lie over 0.05 ... 0.7: 4 of 5 covered, enough for the phone's own request.
        #expect(planner.isSatisfied(GapPlan(band: .wall, span: 0.05...0.7, reason: .wallNearMeter), map))
        // The export lists the wall up to 0.6096 m (2 ft) of the requested 0.1640 ... 2.2966 ft.
        let server = GapPlan(band: .wall, span: 0.05...0.7, reason: .server)
        #expect(abs(planner.progress(of: server, map) - (2 - 0.164) / (2.2966 - 0.164)) < 1e-3)
        #expect(!planner.isSatisfied(server, map))
        // A view at 0.3 covers cell 4 as well.
        map.observe(wallCamera(s: 0.3), trackingNormal: true)
        #expect(planner.progress(of: server, map) == 1)
        #expect(planner.isSatisfied(server, map))
    }

    /// The export stops at a marked end, so a request reaching past it stays open whatever is
    /// covered; counting only the cells inside the ends called it met.
    @Test func aServerRequestPastAMarkedEndIsNotMet() {
        let planner = GapPlanner()
        var map = Self.walkedWall(to: 0.3)
        map.setEnd(.right, at: 0.5)
        #expect(planner.isSatisfied(GapPlan(band: .wall, span: 0.05...0.7, reason: .wallNearMeter), map))
        #expect(!planner.isSatisfied(GapPlan(band: .wall, span: 0.05...0.7, reason: .server), map))
    }

    /// A request in feet that ends exactly at a marked end is met once covered, although its
    /// span went through Float meters on the way.
    @Test func aServerRequestEndingAtTheEndIsMetInFeet() throws {
        let planner = GapPlanner()
        var map = Self.walkedWall(to: 0.3)
        map.setEnd(.right, at: 2 * 0.3048)
        let plan = try #require(planner.plan(for: item(#"{"kind":"band","band":"wall","span_ft":[0.5,2.0],"message":"m"}"#), leftEnd: nil, rightEnd: map.rightEnd))
        #expect(planner.isSatisfied(plan, map))
    }

    /// A band request reaching past a marked end can't be met: the map records nothing past an
    /// end, except ground past a limit end, so its bar would stay at 0 % (issue #35). It has no
    /// request and goes to review. Reaching the end, within the server's 0.01 ft, is not past it.
    @Test func aBandRequestPastAMarkedEndIsNotACaptureRequest() throws {
        let planner = GapPlanner()
        // Ends at -1 m and 1 m (3.28084 ft).
        let wall = try item(#"{"kind":"band","band":"wall","span_ft":[2.0,4.0],"message":"m"}"#)
        #expect(planner.plan(for: wall, leftEnd: -1, rightEnd: 1) == nil)
        #expect(planner.plan(for: wall, leftEnd: -1, rightEnd: 1, limitEnds: [.right]) == nil)
        #expect(planner.plan(for: wall, leftEnd: -1, rightEnd: nil) != nil)
        let ground = try item(#"{"kind":"band","band":"ground","span_ft":[-4.0,-2.0],"out_ft":2.5,"message":"m"}"#)
        #expect(planner.plan(for: ground, leftEnd: -1, rightEnd: 1) == nil)
        #expect(planner.plan(for: ground, leftEnd: -1, rightEnd: 1, limitEnds: [.right]) == nil)
        #expect(planner.plan(for: ground, leftEnd: -1, rightEnd: 1, limitEnds: [.left]) != nil)
        // A walk past a limit end records nothing facing the wall there.
        let facing = try item(#"{"kind":"band","band":"facing","span_ft":[2.0,4.0],"out_ft":5.0,"message":"m"}"#)
        #expect(planner.plan(for: facing, leftEnd: -1, rightEnd: 1, limitEnds: [.right]) == nil)
        // The server rounds a span outward: 3.2809 ft ends at the right end.
        let toEnd = try item(#"{"kind":"band","band":"wall","span_ft":[0.5,3.2809],"message":"m"}"#)
        #expect(planner.plan(for: toEnd, leftEnd: -1, rightEnd: 1) != nil)
    }

    @Test func pastEndAsksForTheGroundBeyondThatEnd() throws {
        // Left end at s = -3 m: ask for -5...-3. Right end at 4 m: ask for 4...6.
        let left = try #require(GapPlanner().plan(for: item(#"{"kind":"past_end","side":"left","message":"m"}"#), leftEnd: -3, rightEnd: 4))
        #expect(left.band == .ground && left.span == -5 ... -3)
        let right = try #require(GapPlanner().plan(for: item(#"{"kind":"past_end","side":"right","message":"m"}"#), leftEnd: -3, rightEnd: 4))
        #expect(right.span == 4...6)
    }

    /// A met past_end request moves its end on past the ground it showed, and the next one asks
    /// for the 2 m after that. With the end left cleared, the next request asked for the ground
    /// at the meter (issue #35).
    @Test func aMetPastEndRequestMovesItsEndOn() throws {
        let planner = GapPlanner()
        let pastLeft = try item(#"{"kind":"past_end","side":"left","message":"m"}"#)
        let first = try #require(planner.plan(for: pastLeft, leftEnd: -3, rightEnd: 4))
        let moved = planner.endAfterPastEnd(first, side: .left, clearedAt: -3)
        #expect(moved == -5)
        #expect(planner.plan(for: pastLeft, leftEnd: moved, rightEnd: 4)?.span == -7 ... -5)
        #expect(planner.plan(for: pastLeft, leftEnd: nil, rightEnd: 4)?.span == -2 ... 0)
        let pastRight = try item(#"{"kind":"past_end","side":"right","message":"m"}"#)
        let right = try #require(planner.plan(for: pastRight, leftEnd: -3, rightEnd: 4))
        #expect(planner.endAfterPastEnd(right, side: .right, clearedAt: 4) == 6)
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
