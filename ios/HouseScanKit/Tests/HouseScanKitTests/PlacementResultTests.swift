import Foundation
import HouseScanKit
import Testing
import simd

@Suite struct PlacementResultTests {
    /// ios/HouseScan/Runtime/SampleResult.json, the app's offline sample.
    static func sampleData(file: String = #filePath) throws -> Data {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // HouseScanKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // HouseScanKit
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("HouseScan/Runtime/SampleResult.json")
        return try Data(contentsOf: url)
    }

    /// The sample with one exact substring replaced; fails the test if the substring is absent.
    static func sample(replacing target: String, with replacement: String) throws -> Data {
        let text = String(decoding: try sampleData(), as: UTF8.self)
        try #require(text.contains(target), "sample no longer contains \(target)")
        return Data(text.replacingOccurrences(of: target, with: replacement).utf8)
    }

    private func expectError(_ expected: PlacementDecodingError, _ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, sourceLocation: sourceLocation) { try PlacementResult.decode(data) }
    }

    @Test func sampleMatchesResultSchema() throws {
        #expect(try SceneSchemas.result().validate(Self.sampleData()) == [])
    }

    @Test func sampleDecodes() throws {
        let result = try PlacementResult.decode(Self.sampleData())
        #expect(result.decision == .manualReview)
        #expect(result.policy.id == nil && result.policy.sources == ["public"] && !result.policy.autoApprove)
        let spot = try #require(result.spot)
        #expect(spot.spanFt == SIMD2(3.0, 5.5))
        #expect(spot.footprint.count == 4)
        #expect(result.checks.map(\.outcome) == [.pass, .unsure, .unsure, .pass])
        #expect(result.checks[1].unsureCause == .margin)
        #expect(result.checks[2].unsureCause == .unobserved && result.checks[2].measuredFt == nil)
        #expect(result.checks[2].comparison == .atLeast && result.checks[2].subject == nil)
        #expect(result.nearestConsidered == nil)
        #expect(result.missingEvidence.map(\.kind) == [.band, .pastEnd])
        #expect(result.missingEvidence[1].side == .left && result.missingEvidence[1].spanFt == nil)
        #expect(result.ends.left.kind == .unexplored && result.ends.right.kind == .limit)
    }

    @Test func encodingRoundTripsAndStaysInSchema() throws {
        let result = try PlacementResult.decode(Self.sampleData())
        let encoded = try JSONEncoder().encode(result)
        #expect(try SceneSchemas.result().validate(encoded) == [])
        #expect(try PlacementResult.decode(encoded) == result)
    }

    @Test func routePolylineMapsOntoTheWall() throws {
        let result = try PlacementResult.decode(Self.sampleData())
        let route = try #require(result.route)
        // Sample wall: along +x, meter at world (0, 1.5, 0), outward +z.
        let wall = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)
        let end = wall.wallCoordinates(ofPlanPointFeet: try #require(route.polyline.last))
        #expect(abs(end.s - 0.9144) < 1e-5 && abs(end.out) < 1e-5)  // 3 ft
    }

    /// The server adds optional fields within schema 1.0; the phone must keep decoding.
    @Test func ignoresUnknownKeys() throws {
        _ = try PlacementResult.decode(
            try Self.sample(replacing: #""schema_version": "1.0","#, with: #""schema_version": "1.0", "extra": true,"#))
        _ = try PlacementResult.decode(
            try Self.sample(replacing: #""key": "sample_window_clearance_ft""#, with: #""key": "sample_window_clearance_ft", "bogus": 1"#))
    }

    /// A real answer from the server branch (origin/t3/server at 6fdb440) to the synthetic replay's
    /// scene, carrying fields newer than the first published schema.
    @Test func decodesARealServerAnswer() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Schemas/server-answer-synthetic-wall.json")
        let data = try Data(contentsOf: url)
        #expect(try SceneSchemas.result().validate(data) == [])
        let result = try PlacementResult.decode(data)
        #expect(result.decision == .manualReview)
        #expect(!result.checks.isEmpty)
    }

    @Test func rejectsUnknownEnumValues() throws {
        expectError(.unknownEnumValue(path: "checks[1].unsure_cause", value: "tight"),
                    try Self.sample(replacing: #""unsure_cause": "margin""#, with: #""unsure_cause": "tight""#))
        expectError(.unknownEnumValue(path: "decision", value: "maybe"),
                    try Self.sample(replacing: #""decision": "manual_review""#, with: #""decision": "maybe""#))
        expectError(.unknownEnumValue(path: "route.outcome", value: "maybe"),
                    try Self.sample(replacing: #""outcome": "pass",\#n    "length_ft""#, with: #""outcome": "maybe",\#n    "length_ft""#))
    }

    /// Enums the app never reads take any string, so a value the server adds doesn't stop the
    /// result screen.
    @Test func acceptsNewValuesTheAppDoesNotRead() throws {
        let reason = try PlacementResult.decode(
            try Self.sample(replacing: #""code": "unsure_checks""#, with: #""code": "new_reason""#))
        #expect(reason.reasons.contains { $0.code == "new_reason" })
        let source = try PlacementResult.decode(
            try Self.sample(replacing: #""sources": ["public"]"#, with: #""sources": ["public", "regional"]"#))
        #expect(source.policy.sources == ["public", "regional"])
        let crossing = try PlacementResult.decode(
            try Self.sample(replacing: #""crossings": []"#, with: #""crossings": [{"subject": "gate", "span_ft": [1, 2], "effect": "bridge"}]"#))
        #expect(crossing.route?.crossings.first?.effect == "bridge")
    }

    @Test func rejectsOtherSchemaVersions() throws {
        expectError(.unsupportedSchemaVersion("2.0"),
                    try Self.sample(replacing: #""schema_version": "1.0""#, with: #""schema_version": "2.0""#))
    }

    @Test func requiredNullableKeysMustBePresent() throws {
        let data = try Self.sample(replacing: #""measured_ft": null,"#, with: "")
        expectError(.missingKey(path: "checks[2].measured_ft"), data)
    }

    @Test func pairsMustHaveTwoNumbers() throws {
        expectError(.wrongArrayLength(path: "spot.center", expected: 2, actual: 1),
                    try Self.sample(replacing: #""center": [4.25, 0.5]"#, with: #""center": [4.25]"#))
    }
}
