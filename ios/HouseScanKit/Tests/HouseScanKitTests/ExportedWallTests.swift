import Foundation
import HouseScanKit
import simd
import Testing

/// The server answers in s along the wall scene.json described; the walk plans and draws along its
/// own. `WallFrame.s(_:along:)` carries a place from one to the other through the world.
@Suite struct ExportedWallTests {
    /// The walk's straight wall, and an exported chain with the same line that turns at s = 2 to
    /// face +x, so its s past the corner runs along -z behind the walk's line.
    static let walk = WallFrame(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)!
    static var exported: WallFrame {
        var wall = walk
        wall.turn(.right, at: WallCorner(s: 2, outward: SIMD3(1, 0, 0), source: .mesh))
        return wall
    }

    @Test func aServerSpanPastTheExportedCornerIsPlannedWhereTheWalkSeesIt() throws {
        let item = try JSONDecoder().decode(PlacementMissingEvidence.self, from: Data("""
            {"kind": "band", "band": "ground", "span_ft": [3.2808, 9.8425], "out_ft": 4, "message": "Show the ground"}
            """.utf8))
        let mapped = item.along(Self.walk, from: Self.exported)
        // 1 m and 3 m along the exported chain: 1 m is on the shared line; 3 m is 1 m past the
        // corner, at (2, 0, -1), whose foot on the walk's straight wall is s = 2.
        let span = try #require(mapped.spanFt)
        #expect(abs(span.x - 3.2808) < 1e-3)
        #expect(abs(span.y - 6.5617) < 1e-3)
        #expect(mapped.outFt == 4)
        let plan = try #require(GapPlanner().plan(for: mapped, leftEnd: nil, rightEnd: nil))
        #expect(abs(plan.span.lowerBound - 1) < 1e-3 && abs(plan.span.upperBound - 2) < 1e-3)
    }

    @Test func theSameWallMapsEverySpanToItself() throws {
        let item = try JSONDecoder().decode(PlacementMissingEvidence.self, from: Data("""
            {"kind": "band", "band": "wall", "span_ft": [-2, 5], "message": "Show the wall"}
            """.utf8))
        #expect(item.along(Self.walk, from: Self.walk) == item)
    }
}
