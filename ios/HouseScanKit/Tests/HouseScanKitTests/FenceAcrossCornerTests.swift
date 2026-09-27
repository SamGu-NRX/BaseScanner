import Foundation
@testable import HouseScanKit
import simd
import Testing

/// A fence whose feet are on two pieces of the wall is refused, never exported (caretaker
/// 4114652182). The counterexample: corner at (3, 0), feet A (1.4, 2) and B (5, -1.6), each 2 m
/// from its own piece. By the corner the fence's line comes within 0.9126 m of the wall over a
/// battery at s 1.7 to 2.4874 m, and the export sent 2 m there, a false pass of the 3 ft gap.
@Suite struct FenceAcrossCornerTests {
    static let wall: SceneWall = {
        SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0, rightCorners: [WallCorner(s: 3, outward: SIMD3(1, 0, 0))])
    }()

    static func input(_ feet: [SIMD3<Float>]) -> SceneInput {
        SceneInput(
            wall: wall, baselineS: -2...6, features: [.fence(foot: feet)],
            coverage: SceneCoverage(leftEndMarked: false, rightEndMarked: false, wall: [], ground: []))
    }

    @Test func theCounterexampleIsRefusedAndNotExported() {
        let feet: [SIMD3<Float>] = [SIMD3(1.4, 0, 2), SIMD3(5, 0, -1.6)]
        #expect(throws: SceneExportError.fenceAcrossCorner(feature: "features[0]")) { try SceneExport.jsonData(Self.input(feet)) }
        var frame = standardWall()
        frame.turn(.right, at: WallCorner(s: 3, outward: SIMD3(1, 0, 0)))
        #expect(!frame.onSamePiece(feet[0], feet[1]))
    }

    /// A fence on one piece still exports as before, whichever side of the corner.
    @Test func aFenceOnOnePieceIsExported() throws {
        let feet: [SIMD3<Float>] = [SIMD3(0.5, 0, 2), SIMD3(2.5, 0, 2)]
        let data = try SceneExport.jsonData(Self.input(feet))
        let facing = try #require(JSONSchemaValidator.Value.parse(data)["facing"]?.array?.first)
        #expect(facing["depth_ft"]?.number == 6.5617)
        let past: [SIMD3<Float>] = [SIMD3(5, 0, -0.5), SIMD3(5, 0, -2.5)]
        #expect(throws: Never.self) { try SceneExport.jsonData(Self.input(past)) }
    }
}
