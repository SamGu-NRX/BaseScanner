import Foundation
@testable import HouseScanKit
import simd
import Testing

/// The phone settles a ground request on the ground entries the export writes (caretaker
/// review, GapPlanner [P2]).
@Suite struct GroundSettlementTests {
    /// 125 touching ground spans on a chain with one corner, at the entry budget (500 / 4). Every
    /// neighbouring pair differs in reach by at least 0.5 m except one, 2.5 ft and 3 ft. The
    /// export joins to 124 to leave room for the corner's cut, so that pair becomes one entry at
    /// 2.5 ft. Joined to 125, the planner kept the 3 ft span and settled a 3 ft request there.
    static let spans: [ObservedSpan] = (0..<125).map { i in
        let low = -5 + Float(i) * 0.08
        let out: Float = i == 60 ? 2.5 * 0.3048 : i == 61 ? 3 * 0.3048 : (i.isMultiple(of: 2) ? 1.5 : 2.0)
        return ObservedSpan(span: low...(low + 0.08), out: out)
    }

    @Test func theSettlementReadsTheGroundAsExported() throws {
        let wall = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0, rightCorners: [WallCorner(s: 6, outward: SIMD3(1, 0, 0))])
        let data = try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -5...7,
            coverage: SceneCoverage(leftEndMarked: false, rightEndMarked: false, wall: [], ground: Self.spans)))
        let entries = (try JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array ?? []).filter { $0["band"]?.string == "ground" }
        // Where span 61 lies (s = -0.12 to -0.04 m, -0.3937 to -0.1312 ft), the export sends 2.5 ft.
        let there = try #require(entries.first { ($0["span_ft"]?.numbers).map { $0[0] < -0.2 && $0[1] > -0.2 } == true })
        #expect(there["out_ft"]?.number == 2.5)

        let planner = GapPlanner.exportedGround(Self.spans, corners: 1)
        let covering = try #require(planner.first { $0.span.contains(-0.06) })
        #expect(SceneExport.feetDown(covering.out) == 2.5)
        // The other bands' budget, as before, kept 3 ft there.
        #expect(SceneExport.feetDown(try #require(GapPlanner.exported(Self.spans).first { $0.span.contains(-0.06) }).out) == 3)
    }
}
