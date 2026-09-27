import Foundation
@testable import HouseScanKit
import simd
import Testing

/// A gas meter and an AC unit are marked at two corners, as a window is, and sent with only
/// what the taps measured: no nominal width and no assumed depth.
@Suite struct TwoCornerObjectTests {
    static func input(_ features: [SceneFeature], wall: SceneWall = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)) -> SceneInput {
        SceneInput(
            wall: wall, baselineS: -2...6, features: features,
            coverage: SceneCoverage(leftEndMarked: false, rightEndMarked: false, wall: [], ground: []))
    }

    private func expectClose(_ actual: [Double]?, _ expected: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actual, actual.count == expected.count, zip(actual, expected).allSatisfy({ abs($0 - $1) <= 2e-4 }) else {
            Issue.record("expected \(expected), got \(String(describing: actual))", sourceLocation: sourceLocation)
            return
        }
    }

    static func object(_ features: [SceneFeature]) throws -> JSONSchemaValidator.Value {
        let data = try SceneExport.jsonData(input(features))
        let value = try JSONSchemaValidator.Value.parse(data)
        #expect(try SceneSchemas.scene().validate(value) == [])
        return try #require(value["objects"]?.array?.first)
    }

    /// The AC's front corners, 1.2 m and 1.0 m out: the footprint reaches from the wall to that
    /// line and no farther, over exactly the tapped stretch.
    @Test func anACsFootprintEndsAtItsTappedFrontEdge() throws {
        let ac = try Self.object([.groundObject(kind: .ac, front: [SIMD3(1.0, 0, 1.2), SIMD3(2.0, 0, 1.0)])])
        #expect(ac["type"] == .string("ac"))
        expectClose(ac["span_ft"]?.numbers, [3.2808, 6.5617])
        let footprint = (ac["footprint"]?.array ?? []).compactMap(\.numbers)
        try #require(footprint.count == 4)
        expectClose(footprint[0], [3.2808, 0])
        expectClose(footprint[1], [6.5617, 0])
        expectClose(footprint[2], [6.5617, 3.2808])
        expectClose(footprint[3], [3.2808, 3.9370])
        #expect(ac["bottom_ft"] == nil && ac["top_ft"] == nil)
    }

    /// The gas meter's corners where it meets the wall: its span and heights, and no footprint.
    @Test func aGasMeterGoesOutAsItsStretchOfWall() throws {
        let gas = try Self.object([.wallObject(kind: .gasMeter, span: -1.3 ... -1.0, bottom: 0.35, top: 0.75)])
        #expect(gas["type"] == .string("gas_meter"))
        expectClose(gas["span_ft"]?.numbers, [-4.2651, -3.2808])
        expectClose([gas["bottom_ft"]?.number ?? .nan, gas["top_ft"]?.number ?? .nan], [1.1483, 2.4606])
        #expect(gas["footprint"] == nil)
    }

    /// Two taps on one spot, or a single tap, give no size: refused, never sent as a sized
    /// object.
    @Test func aCollapsedOrOneTapMarkIsRefused() {
        let spot = SIMD3<Float>(1, 0, 1)
        #expect(throws: SceneExportError.degenerateSegment(feature: "features[0] ac")) {
            try SceneExport.jsonData(Self.input([.groundObject(kind: .ac, front: [spot, spot])]))
        }
        #expect(throws: SceneExportError.wrongPointCount(feature: "features[0] ac", expected: 2, actual: 1)) {
            try SceneExport.jsonData(Self.input([.groundObject(kind: .ac, front: [spot])]))
        }
        #expect(throws: SceneExportError.degenerateSegment(feature: "features[0] gas_meter")) {
            try SceneExport.jsonData(Self.input([.wallObject(kind: .gasMeter, span: 1...1, bottom: 0.3, top: 0.7)]))
        }
        #expect(throws: SceneExportError.degenerateSegment(feature: "features[0] gas_meter")) {
            try SceneExport.jsonData(Self.input([.wallObject(kind: .gasMeter, span: 1...1.3, bottom: 0.5, top: 0.5)]))
        }
    }

    /// Front corners in front of two pieces of the wall make no one rectangle: refused.
    @Test func anACAcrossACornerIsRefused() {
        let wall = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0, rightCorners: [WallCorner(s: 3, outward: SIMD3(1, 0, 0))])
        #expect(throws: SceneExportError.objectAcrossCorner(feature: "features[0]")) {
            try SceneExport.jsonData(Self.input([.groundObject(kind: .ac, front: [SIMD3(2.5, 0, 0.8), SIMD3(3.8, 0, -0.5)])], wall: wall))
        }
    }
}
