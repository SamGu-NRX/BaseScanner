import Foundation
import HouseScanKit
import Testing

/// A check's review line (`review_threshold_ft`): decoded only when the answer sends one, and
/// read by `ResultReading.reviewBandApplies` only when it explains an UNSURE outcome.
@Suite struct ReviewBandTests {
    // MARK: Decoding

    /// The UI tests' review-band answer: the cable run measures 16 ft (± 6 in), past the 15 ft
    /// review line and under the 20 ft maximum, as server/tests/test_review_regressions.py's
    /// start at 16 ft gives it.
    @Test func theReviewLineSurvivesDecoding() throws {
        let result = try PlacementResult.decode(Data(contentsOf: Self.uiResultFile("review-band")))
        let route = try #require(result.checks.first { $0.id == "route_length" })
        #expect(route.outcome == .unsure)
        #expect(route.unsureCause == .ruleRequiresReview)
        #expect(route.measuredFt == 16)
        #expect(route.plusMinusFt == 0.5)
        #expect(route.thresholdFt == 20)
        #expect(route.reviewThresholdFt == 15)
        #expect(route.comparison == .atMost)
        // The other checks have no review line, and stay without one.
        #expect(result.checks.filter { $0.id != "route_length" }.allSatisfy { $0.reviewThresholdFt == nil })
    }

    /// The hosted server's own answer carries the line on its cable run check.
    @Test func aRealServerAnswerKeepsItsReviewLine() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Schemas/server-answer-synthetic-wall.json")
        let result = try PlacementResult.decode(Data(contentsOf: url))
        #expect(result.checks.first { $0.id == "route_length" }?.reviewThresholdFt == 15)
    }

    /// Encoding writes the line back only where the answer had one: an absent line stays absent
    /// rather than becoming null, which the schema doesn't allow.
    @Test func encodingKeepsAnAbsentLineAbsent() throws {
        let result = try PlacementResult.decode(Data(contentsOf: Self.uiResultFile("review-band")))
        let encoded = try JSONEncoder().encode(result)
        #expect(try SceneSchemas.result().validate(encoded) == [])
        #expect(try PlacementResult.decode(encoded) == result)
        let checks = try #require(
            (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["checks"] as? [[String: Any]])
        for check in checks {
            let id = try #require(check["id"] as? String)
            #expect((check["review_threshold_ft"] != nil) == (id == "route_length"), "\(id)")
        }
    }

    // MARK: When the line explains the outcome

    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var outcome: PlacementOutcome = .unsure
        var measured: Double? = 16
        var plusMinus: Double? = 0.5
        var threshold: Double? = 20
        var review: Double? = 15
        var comparison: PlacementComparison? = .atMost
        var applies: Bool

        var testDescription: String { name }
    }

    @Test(arguments: [
        // The solver's review band: past the confident reach, under the maximum.
        Case(name: "16 ft between 15 ft and 20 ft", applies: true),
        // Within its error of the review line, which the solver calls a margin: still past it.
        Case(name: "14 ft 10 in, error reaches 15 ft", measured: 14.8, applies: true),
        Case(name: "exactly reaching the line", measured: 14.5, applies: true),
        // Within its error of the maximum: still unsure, and the line still applies.
        Case(name: "20 ft 4 in, within error of the maximum", measured: 20.3, applies: true),
        // The server's outcome decides; the app never reads the band into a pass or a fail.
        Case(name: "a pass", outcome: .pass, applies: false),
        Case(name: "a fail", outcome: .fail, measured: 24, applies: false),
        // Clears the line by the schema's test: unsure for some other reason.
        Case(name: "clears the line", measured: 14, applies: false),
        Case(name: "no error, under the line", measured: 14.9, plusMinus: nil, applies: false),
        Case(name: "a negative error counts as none", measured: 14.9, plusMinus: -1, applies: false),
        // Anything missing: nothing to explain.
        Case(name: "no review line", review: nil, applies: false),
        Case(name: "no limit", threshold: nil, applies: false),
        Case(name: "no measurement", measured: nil, applies: false),
        Case(name: "no direction", comparison: nil, applies: false),
        // A line on the failing side of the limit, or on it, leaves no band.
        Case(name: "review line past the maximum", review: 25, applies: false),
        Case(name: "review line on the maximum", review: 20, applies: false),
        // A minimum mirrors it: the review line sits above the limit.
        Case(name: "at least: between 3 ft and 4 ft", measured: 3.5, plusMinus: 0.2, threshold: 3, review: 4,
             comparison: .atLeast, applies: true),
        Case(name: "at least: clears the line", measured: 4.5, plusMinus: 0.2, threshold: 3, review: 4,
             comparison: .atLeast, applies: false),
        Case(name: "at least: review line under the minimum", measured: 3.5, plusMinus: 0.2, threshold: 3, review: 2,
             comparison: .atLeast, applies: false),
    ])
    func reviewBandApplies(_ c: Case) {
        #expect(ResultReading.reviewBandApplies(
            outcome: c.outcome, measured: c.measured, plusMinus: c.plusMinus, threshold: c.threshold,
            reviewThreshold: c.review, comparison: c.comparison) == c.applies)
    }

    /// The UI tests' answers: the line explains the review band's cable run, and not the passing
    /// cable run in no-clean-spot, which carries the same line.
    @Test func theUIResultFilesReadAsExpected() throws {
        func applies(_ file: String) throws -> Bool {
            let result = try PlacementResult.decode(Data(contentsOf: Self.uiResultFile(file)))
            let route = try #require(result.checks.first { $0.id == "route_length" })
            #expect(route.reviewThresholdFt == 15, "\(file)")
            return ResultReading.reviewBandApplies(
                outcome: route.outcome, measured: route.measuredFt, plusMinus: route.plusMinusFt,
                threshold: route.thresholdFt, reviewThreshold: route.reviewThresholdFt, comparison: route.comparison)
        }
        #expect(try applies("review-band"))
        #expect(try !applies("no-clean-spot"))
    }

    private static func uiResultFile(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // HouseScanKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // HouseScanKit
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("HouseScanUITests/Fixtures/results/\(name).json")
    }
}
