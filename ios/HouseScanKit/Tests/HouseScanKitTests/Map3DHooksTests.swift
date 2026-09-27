import Foundation
@testable import HouseScanKit
import Testing
import simd

/// The two HouseScanKit changes the app's 3D map needs: CoverageMap's covered state taken from
/// the map, and scene.json's per-wall source and error.
@Suite struct MeasuredCoveredTests {
    // `wallCamera(s:)` sees every wall row of the cells whose lower edge L has c in
    // [L - 0.7881, L + 0.9405]; two positions 0.3 m apart cover cells -2 to 7.
    static func coveredByCamera() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0.3), trackingNormal: true)
        map.observe(wallCamera(s: 0.6), trackingNormal: true)
        return map
    }

    @Test func cameraCoverageIsUntouchedWithoutMeasuredCells() {
        let map = Self.coveredByCamera()
        #expect(map.measuredCovered == nil)
        #expect(map.level(.wall, 0) == .covered)
        #expect(map.coveredIntervals(.wall).count == 1)
    }

    @Test func measuredCellsAloneAreCovered() {
        var map = Self.coveredByCamera()
        let before = map.revision
        map.setMeasuredCovered([.wall: [2, 3, 12], .ground: []])
        #expect(map.revision == before + 1)
        // Covered by the cameras but not by the map: back to seen, never covered.
        #expect(map.level(.wall, 0) == .seen)
        #expect(map.level(.wall, 2) == .covered)
        // Seen from one position only, so the cameras alone never covered it either.
        #expect(map.level(.wall, 8) == .seen)
        // Covered by the map where no camera looked (cell 12 starts 1.83 m along, out of both views).
        #expect(map.level(.wall, 12) == .covered)
        #expect(map.level(.wall, 13) == .unseen)
        #expect(map.coveredIntervals(.wall) == [map.cellRange(2).lowerBound...map.cellRange(3).upperBound, map.cellRange(12)])
        #expect(map.coveredCount == 3)
        #expect(map.coveredFraction(.wall, in: map.cellRange(2).lowerBound...map.cellRange(3).upperBound) == 1)
    }

    @Test func settingTheSameCellsIsNoChange() {
        var map = CoverageMap(wall: standardWall())
        map.setMeasuredCovered([.wall: [1]])
        let revision = map.revision
        map.setMeasuredCovered([.wall: [1]])
        #expect(map.revision == revision)
    }

    @Test func measuredCellsPastAMarkedEndAreNotCovered() {
        var map = CoverageMap(wall: standardWall())
        map.setEnd(.right, at: map.cellRange(3).upperBound)
        map.setMeasuredCovered([.wall: [3, 4]])
        #expect(map.level(.wall, 3) == .covered)
        #expect(map.level(.wall, 4) == .unseen)
        #expect(map.coveredIntervals(.wall) == [map.cellRange(3)])
    }

    @Test func skippingLeavesMeasuredCoveredCellsCovered() {
        var map = CoverageMap(wall: standardWall())
        map.setMeasuredCovered([.ground: [1]])
        map.markSkipped(.ground, map.cellRange(0).lowerBound...map.cellRange(2).upperBound)
        #expect(map.level(.ground, 0) == .skipped)
        #expect(map.level(.ground, 1) == .covered)
        #expect(map.level(.ground, 2) == .skipped)
    }

    /// The 3D map's wall cell counts as covered once its face was seen to the height the walk
    /// asks for (`wallWalkHeight`, 4.5 ft), as the camera coverage map's does, not only to
    /// headroom; the export still reports each stretch's own height.
    @Test func mapWallCellsAreCoveredAtTheWalksHeight() {
        let map = CoverageMap(wall: standardWall())
        let walk = map.config.wallWalkHeight
        let coverage = Map3DCoverage(
            wall: [], wallHeight: [ObservedSpan(span: map.cellRange(2).lowerBound...map.cellRange(3).upperBound, out: walk + 0.05),
                                   ObservedSpan(span: map.cellRange(4), out: walk - 0.1)],
            ground: [], facing: [], overhead: [])
        #expect(map.cells(seenIn: coverage)[.wall] == [2, 3])
    }

    @Test func measuredCellsCountAsSeenExtent() {
        var map = CoverageMap(wall: standardWall())
        #expect(map.seenExtent == nil)
        map.setMeasuredCovered([.wall: [5]])
        #expect(map.seenExtent == map.cellRange(5))
    }
}

/// What a scene exported from the 3D map adds: walls found on the LiDAR mesh with their line's
/// error, and wall spans with the height the map saw each to.
@Suite struct Map3DSceneTests {
    /// A measured chain with one right corner at s = 2: two mesh pieces.
    static func meshWall() -> SceneWall {
        SceneWall(
            meter: SIMD3(0, 1.2, 0), outward: SIMD3(0, 0, 1), groundY: 0,
            rightCorners: [WallCorner(s: 2, outward: SIMD3(1, 0, 0), source: .mesh)], source: .mesh)
    }

    static func input(plusMinus: [Float?] = [0.03048, nil]) -> SceneInput {
        SceneInput(
            wall: meshWall(), baselineS: -1...3,
            coverage: SceneCoverage(
                leftEndMarked: false, rightEndMarked: true,
                wall: [ObservedSpan(span: -1...1, out: 0.9), ObservedSpan(span: 1...3, out: 2.0)],
                ground: [ObservedSpan(span: -1...3, out: 1.2)], facing: [ObservedSpan(span: -1...3, out: 0.6)],
                overhead: [ObservedSpan(span: -1...1, out: 2.4)]),
            wallPlusMinus: plusMinus)
    }

    @Test func aMap3DSceneValidatesAgainstTheSchema() throws {
        let data = try SceneExport.jsonData(Self.input())
        #expect(try SceneSchemas.scene().validate(data) == [])
        let v = try JSONSchemaValidator.Value.parse(data)
        let walls = try #require(v["walls"]?.array)
        #expect(walls.map { $0["source"]?.string } == ["mesh", "mesh"])
        #expect(walls[0]["plus_minus_ft"] == .number(0.1))
        #expect(walls[1]["plus_minus_ft"] == nil)
        let wallEntries = (v["coverage"]?["observed"]?.array ?? []).filter { $0["band"] == .string("wall") }
        // 0.9 m is 2.95276 ft and 2.0 m is 6.56168 ft, each rounded down to four decimals.
        #expect(wallEntries.map { $0["out_ft"]?.number } == [2.9527, 6.5616])
    }

    /// A meter tapped on a box 0.25 m proud of a measured wall: the wall stays on its line and
    /// the meter's position is where it was tapped, projecting onto the wall at s = 0.
    @Test func theMeterKeepsItsOwnPositionOffAMeasuredWall() throws {
        var input = Self.input()
        input.meterPosition = input.wall.world(s: 0, height: 1.2, out: 0.25)
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let v = try JSONSchemaValidator.Value.parse(data)
        // (0, 1.2, 0.25) m in feet; the wall's baseline stays on z = 0.
        #expect(v["meter"]?["pos"]?.numbers == [0, 3.937, 0.8202])
        let baseline = try #require(v["walls"]?.array?.first?["baseline"]?.array)
        #expect(baseline.compactMap { $0.numbers?[1] } == [0, 0])
    }

    @Test func aMeterPositionAwayFromTheChainsOriginIsRefused() {
        var input = Self.input()
        input.meterPosition = input.wall.world(s: 0.5, height: 1.2, out: 0.25)
        #expect(throws: SceneExportError.meterOffChainOrigin(s: 0.5)) { try SceneExport.jsonData(input) }
    }

    @Test func noErrorsWriteNoPlusMinus() throws {
        let data = try SceneExport.jsonData(Self.input(plusMinus: []))
        let walls = try #require(try JSONSchemaValidator.Value.parse(data)["walls"]?.array)
        #expect(walls.count == 2)
        #expect(walls.allSatisfy { $0["plus_minus_ft"] == nil })
    }

    @Test func errorsOfTheWrongCountAreRefused() {
        #expect(throws: SceneExportError.countMismatch(field: "wallPlusMinus", expected: 2, actual: 1)) {
            try SceneExport.jsonData(Self.input(plusMinus: [0.1]))
        }
    }

    @Test func aNegativeErrorIsRefused() {
        #expect(throws: SceneExportError.negativeValue(field: "wallPlusMinus[1]", value: -0.1)) {
            try SceneExport.jsonData(Self.input(plusMinus: [nil, -0.1]))
        }
    }
}
