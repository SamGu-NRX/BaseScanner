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

    @Test func overheadAndFacingAreNotWalkRequests() throws {
        #expect(GapPlanner().plan(for: try item(#"{"kind":"band","band":"overhead","span_ft":[0,1],"message":"m"}"#), leftEnd: nil, rightEnd: nil) == nil)
        #expect(GapPlanner().plan(for: try item(#"{"kind":"band","band":"facing","span_ft":[0,1],"message":"m"}"#), leftEnd: nil, rightEnd: nil) == nil)
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
