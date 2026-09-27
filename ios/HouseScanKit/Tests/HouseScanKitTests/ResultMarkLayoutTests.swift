import HouseScanKit
import Testing

/// #110: the result's marks as the result card's 3D model and the AR view place them.
@Suite struct ResultMarkLayoutTests {
    /// A spot that might stand in the meter's working space shows no battery anywhere: the AR
    /// view draws the same outline the result card does.
    @Test func onlyACleanSpotGetsABattery() {
        #expect(ResultMarkLayout.spotMark(spotIsClean: true) == .battery)
        #expect(ResultMarkLayout.spotMark(spotIsClean: false) == .outline)
    }

    /// The camera faces the spot it circles: a rejected candidate round a corner (no spot, only
    /// the closest one tried) opens facing that candidate's piece of wall, not the meter's.
    @Test func focusFollowsTheSpotThenTheClosestSpot() {
        #expect(ResultMarkLayout.focusS(spot: 1...2, nearest: nil) == 1.5)
        #expect(ResultMarkLayout.focusS(spot: nil, nearest: 4...5) == 4.5)
        #expect(ResultMarkLayout.focusS(spot: 1...2, nearest: 4...5) == 1.5)
        #expect(ResultMarkLayout.focusS(spot: nil, nearest: nil) == 0)
    }

    @Test func zonesStackAStepApart() {
        #expect(ResultMarkLayout.zoneLift(index: 0, base: 0.006) == 0.006)
        #expect(abs(ResultMarkLayout.zoneLift(index: 2, base: 0.006) - 0.012) < 1e-6)
    }

    /// The outline sat at a fixed 2 cm while zones stacked 6 mm plus 3 mm each, so a sixth zone
    /// (2.1 cm) came through it. Its underside now clears the top zone whatever the count.
    @Test func outlineClearsEveryZone() {
        let thickness: Float = 0.004
        for count in 0...20 {
            let lift = ResultMarkLayout.outlineLift(zoneCount: count, base: 0.006, thickness: thickness, minimum: 0.02)
            let underside = lift - thickness / 2
            if count > 0 {
                let top = ResultMarkLayout.zoneLift(index: count - 1, base: 0.006)
                #expect(underside > top + ResultMarkLayout.zoneStep / 2, "zones: \(count)")
            }
            #expect(lift >= 0.02)
        }
        // A few zones keep the old height.
        #expect(ResultMarkLayout.outlineLift(zoneCount: 3, base: 0.006, thickness: thickness, minimum: 0.02) == 0.02)
        #expect(ResultMarkLayout.outlineLift(zoneCount: 6, base: 0.006, thickness: thickness, minimum: 0.02) > 0.02)
    }

    @Test func dashesStartAndEndAtTheCorners() throws {
        for length: Float in [0.05, 0.1, 0.13, 0.19, 0.2, 0.23, 0.5, 0.61, 1.0, 2.37] {
            let dashes = ResultMarkLayout.dashes(along: length, dash: 0.1, gap: 0.06)
            let first = try #require(dashes.starts.first)
            let last = try #require(dashes.starts.last)
            #expect(first == 0)
            #expect(abs(last + dashes.length - length) < 1e-5, "length \(length)")
            // Dashes never overlap: an overlap would read as one solid line anyway.
            for (a, b) in zip(dashes.starts, dashes.starts.dropFirst()) {
                #expect(b - a >= dashes.length - 1e-5, "length \(length)")
            }
        }
    }

    @Test func aShortEdgeIsOneSolidLine() {
        let dashes = ResultMarkLayout.dashes(along: 0.13, dash: 0.1, gap: 0.06)
        #expect(dashes.starts == [0])
        #expect(dashes.length == 0.13)
        #expect(ResultMarkLayout.dashes(along: 0, dash: 0.1, gap: 0.06).starts.isEmpty)
    }
}
