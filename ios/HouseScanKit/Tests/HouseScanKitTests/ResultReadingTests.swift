import Foundation
import HouseScanKit
import Testing
import simd

@Suite struct ResultReadingTests {
    /// The app's offline sample as a JSON object, to edit before decoding.
    private static func sampleObject() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: PlacementResultTests.sampleData()) as? [String: Any])
    }

    /// A real answer from the hosted server under the demo policy (see PlacementResultTests).
    private static func serverAnswer() throws -> PlacementResult {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Schemas/server-answer-synthetic-wall.json")
        return try PlacementResult.decode(Data(contentsOf: url))
    }

    /// Encodes `object`, checks it against the result schema and decodes it.
    private static func decode(_ object: [String: Any]) throws -> PlacementResult {
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try SceneSchemas.result().validate(data) == [])
        return try PlacementResult.decode(data)
    }

    private static func check(_ id: String, _ outcome: String, measured: Double? = nil, threshold: Double? = nil) -> [String: Any] {
        [
            "id": id, "label": "Made-up check \(id)", "outcome": outcome, "reason": "Made up for a test.",
            "measured_ft": measured ?? NSNull(), "plus_minus_ft": measured == nil ? NSNull() : 0.3,
            "threshold_ft": threshold ?? NSNull(), "comparison": threshold == nil ? NSNull() : "at_least",
            "rule": ["key": "made_up_\(id)_ft", "source": "Made up for a test", "placeholder": true],
        ] as [String: Any]
    }

    /// The sample with one more check at its spot.
    private static func sample(adding extra: [String: Any]) throws -> PlacementResult {
        var object = try Self.sampleObject()
        object["checks"] = [extra] + (try #require(object["checks"] as? [[String: Any]]))
        return try decode(object)
    }

    // MARK: A. The nearest rejected spot

    @Test func rejectNamesTheNearestSpotAndTheCheckItFails() throws {
        var object = try Self.sampleObject()
        var nearest = try #require(object["spot"] as? [String: Any])
        nearest["outcome"] = "fail"
        nearest["span_ft"] = [-5.3, -2.7]
        object["decision"] = "reject"
        object["spot"] = NSNull()
        object["route"] = NSNull()
        object["nearest_considered"] = nearest
        object["missing_evidence"] = [Any]()
        object["checks"] = [
            Self.check("wall_backing", "pass"),
            Self.check("gas_clearance", "fail", measured: 2.33, threshold: 3),
            Self.check("route_length", "fail", measured: 24, threshold: 20),
        ]
        let result = try Self.decode(object)

        #expect(result.nearestConsidered?.spanFt == SIMD2(-5.3, -2.7))
        let failure = try #require(result.nearestFailure)
        #expect(failure.id == "gas_clearance" && failure.measuredFt == 2.33 && failure.thresholdFt == 3)
        #expect(result.answer { _ in true } == .notHere)
    }

    /// The outline uses the server's size for the nearest spot, not a battery size of the app's.
    @Test func theNearestSpotCarriesItsOwnSize() throws {
        var object = try Self.sampleObject()
        var nearest = try #require(object["spot"] as? [String: Any])
        nearest["width_ft"] = 2.6
        nearest["depth_ft"] = 1.8
        nearest["height_ft"] = 3.3
        object["spot"] = NSNull()
        object["route"] = NSNull()
        object["nearest_considered"] = nearest
        let spot = try #require(try Self.decode(object).nearestConsidered)
        #expect(spot.widthFt == 2.6 && spot.depthFt == 1.8 && spot.heightFt == 3.3)
    }

    /// No default size stands in for a missing one: the answer is refused, naming the key.
    @Test(arguments: ["width_ft", "depth_ft", "height_ft", "span_ft"])
    func aNearestSpotWithoutADimensionIsRefused(key: String) throws {
        var object = try Self.sampleObject()
        var nearest = try #require(object["spot"] as? [String: Any])
        nearest[key] = nil
        object["spot"] = NSNull()
        object["route"] = NSNull()
        object["nearest_considered"] = nearest
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: PlacementDecodingError.missingKey(path: "nearest_considered.\(key)")) { try PlacementResult.decode(data) }
    }

    @Test func aSpotHasNoNearestFailure() throws {
        let result = try PlacementResult.decode(PlacementResultTests.sampleData())
        #expect(result.spot != nil && result.nearestFailure == nil)
    }

    // MARK: B. No clean spot

    @Test(arguments: ["unsure", "fail"])
    func aSpotThatMightStandInTheWorkingSpaceGoesToAnInstaller(outcome: String) throws {
        let result = try Self.sample(adding: Self.check(ResultReading.meterWorkingSpaceCheckID, outcome, measured: -0.5, threshold: 0))
        #expect(!result.spotIsClean)
        // The sample also has an unsure check a capturable view settles; the spot still goes to a person.
        #expect(result.answer { _ in true } == .installer)
    }

    @Test func aSpotClearOfTheWorkingSpaceIsClean() throws {
        let result = try Self.sample(adding: Self.check(ResultReading.meterWorkingSpaceCheckID, "pass", measured: 1.2, threshold: 0))
        #expect(result.spotIsClean)
        #expect(result.answer { _ in true } == .oneMoreLook)
    }

    /// A manual_review held back only by unapproved rules, with every check passing, fits.
    @Test func allPassUnderUnapprovedRulesFits() throws {
        var object = try Self.sampleObject()
        object["checks"] = [
            Self.check("wall_backing", "pass"),
            Self.check(ResultReading.meterWorkingSpaceCheckID, "pass", measured: 1.2, threshold: 0),
        ]
        object["missing_evidence"] = [Any]()
        let result = try Self.decode(object)
        #expect(result.decision == .manualReview && !result.policy.autoApprove && result.spot != nil)
        #expect(result.spotIsClean)
        #expect(result.answer { _ in true } == .fits)
    }

    /// The same answer with `checks: []`, which the schema allows: no evidence is not a fit.
    @Test func aSpotWithNoChecksGoesToAnInstaller() throws {
        var object = try Self.sampleObject()
        object["checks"] = [Any]()
        object["missing_evidence"] = [Any]()
        let result = try Self.decode(object)
        #expect(result.decision == .manualReview && !result.policy.autoApprove && result.spot != nil && result.checks.isEmpty)
        #expect(!result.spotIsClean)
        #expect(result.answer { _ in true } == .installer)
    }

    @Test func checksThisAppDoesNotKnowNeverCountAgainstTheSpot() throws {
        let result = try Self.sample(adding: Self.check("some_future_check", "fail", measured: 1, threshold: 3))
        #expect(result.spotIsClean)
    }

    @Test func noSpotIsNeverClean() throws {
        #expect(!ResultReading.spotIsClean(hasSpot: false, checks: []))
    }

    /// The hosted server's answer to the synthetic wall: the working-space check is unsure.
    @Test func theServerAnswerSpotIsNotClean() throws {
        let result = try Self.serverAnswer()
        #expect(result.decision == .manualReview && result.spot != nil)
        #expect(!result.spotIsClean)
        #expect(result.answer { _ in true } == .installer)
    }

    // MARK: C. Answer first

    @Test func theNoticeComesOffTheSummary() throws {
        let result = try Self.serverAnswer()
        let notice = try #require(result.policy.notice)
        #expect(notice.hasPrefix("Demo rules:"))
        #expect(result.summary.hasSuffix(notice))
        #expect(result.summaryWithoutNotice == "More views are needed around the best spot, 1 ft 6 in right of the meter: 7 checks depend on areas the scan did not see.")
    }

    @Test func aSummaryWithoutTheNoticeStaysAsItIs() throws {
        let result = try PlacementResult.decode(PlacementResultTests.sampleData())
        #expect(result.policy.notice == nil)
        #expect(result.summaryWithoutNotice == result.summary)
    }

    @Test func theNoticeSurvivesEncoding() throws {
        let result = try Self.serverAnswer()
        let encoded = try JSONEncoder().encode(result)
        #expect(try SceneSchemas.result().validate(encoded) == [])
        #expect(try PlacementResult.decode(encoded).policy.notice == result.policy.notice)
    }

    @Test func theRulesHashIsItsFirstEightCharacters() throws {
        #expect(try Self.serverAnswer().policy.rulesShortHash == "2f52ec35")
    }

    // MARK: D. Each unsure check linked to its view

    @Test func aViewLinksEveryCheckItSettles() throws {
        var object = try Self.sampleObject()
        var missing = try #require(object["missing_evidence"] as? [[String: Any]])
        missing[0]["checks"] = ["front_clearance", "window_clearance"]
        object["missing_evidence"] = missing
        let result = try Self.decode(object)

        #expect(result.evidenceIndex(settling: "front_clearance") == 0)
        #expect(result.evidenceIndex(settling: "window_clearance") == 0)
        #expect(result.evidenceIndex(settling: "gas_clearance") == nil)
    }

    @Test func theServerAnswerLinksItsFiveChecksToTheFirstView() throws {
        let result = try Self.serverAnswer()
        for id in ["ac_clearance", "drive_clearance", "gas_clearance", "opening_clearance", "pool_clearance"] {
            #expect(result.evidenceIndex(settling: id) == 0, "\(id)")
        }
        #expect(result.evidenceIndex(settling: "wall_backing") == nil)
    }

    // MARK: The UI tests' result files

    /// ios/HouseScanUITests/Fixtures/results, the answers the screenshots and UI tests show
    /// through `-uiDemoResultFile`. Each must stay in the schema and read as its name says.
    @Test(arguments: [
        ("pass", ResultReading.Answer.fits), ("reject-nearest", .notHere),
        ("unsure-view", .oneMoreLook), ("no-clean-spot", .installer),
    ])
    func uiResultFilesReadAsNamed(file: String, answer: ResultReading.Answer) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HouseScanKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // HouseScanKit
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("HouseScanUITests/Fixtures/results/\(file).json")
        let data = try Data(contentsOf: url)
        #expect(try SceneSchemas.result().validate(data) == [])
        #expect(try PlacementResult.decode(data).answer { _ in true } == answer)
    }

    // MARK: The answer

    @Test func theAnswerReadsTheChecks() {
        typealias Check = ResultReading.Check
        let pass = Check(id: "a", outcome: .pass)
        let byView = Check(id: "b", outcome: .unsure, needsPerson: false, viewCapturable: true)
        let skippedView = Check(id: "c", outcome: .unsure, needsPerson: false, viewCapturable: false)
        let byPerson = Check(id: "d", outcome: .unsure, needsPerson: true)
        let answer = { (decision: PlacementDecision, approved: Bool, spot: Bool, checks: [Check]) in
            ResultReading.answer(decision: decision, policyApproved: approved, hasSpot: spot, checks: checks)
        }

        #expect(answer(.pass, true, true, [pass]) == .fits)
        // Only the rules' approval holds it back.
        #expect(answer(.manualReview, false, true, [pass]) == .fits)
        #expect(answer(.manualReview, false, false, [pass]) == .installer)
        #expect(answer(.manualReview, true, true, [pass, byView, byPerson]) == .oneMoreLook)
        #expect(answer(.manualReview, true, true, [pass, byPerson]) == .installer)
        // A view the homeowner already couldn't take settles nothing.
        #expect(answer(.manualReview, true, true, [pass, skippedView]) == .installer)
        #expect(answer(.reject, true, false, [Check(id: "e", outcome: .fail)]) == .notHere)
    }

    /// Review of #52: a scan with a battery or box marked, whose depth nobody measured, never
    /// reads as settled. The server measured to its stretch of wall line, so its pass and its
    /// reject both go to a person; a view the camera can take still comes first.
    @Test func aScanWithAnUnmeasuredMarkGoesToAPerson() {
        typealias Check = ResultReading.Check
        let pass = Check(id: "battery_clearance", outcome: .pass)
        let byView = Check(id: "b", outcome: .unsure, needsPerson: false, viewCapturable: true)
        let answer = { (decision: PlacementDecision, approved: Bool, spot: Bool, checks: [Check]) in
            ResultReading.answer(decision: decision, policyApproved: approved, hasSpot: spot, checks: checks, unmeasuredMarks: true)
        }
        #expect(answer(.pass, true, true, [pass]) == .installer)
        #expect(answer(.manualReview, false, true, [pass]) == .installer)
        #expect(answer(.reject, true, false, [Check(id: "battery_clearance", outcome: .fail)]) == .installer)
        #expect(answer(.manualReview, true, true, [pass, byView]) == .oneMoreLook)
    }

    /// The same through a whole answer: the UI tests' passing result, read for a scan with a
    /// battery marked.
    @Test func aPassingAnswerToAScanWithABatteryMarkedGoesToAPerson() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // HouseScanKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // HouseScanKit
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("HouseScanUITests/Fixtures/results/pass.json")
        let result = try PlacementResult.decode(Data(contentsOf: url))
        #expect(result.answer { _ in true } == .fits)
        #expect(result.answer(unmeasuredMarks: true) { _ in true } == .installer)
    }

    @Test func needsPersonFollowsTheUnsureCause() throws {
        let result = try PlacementResult.decode(PlacementResultTests.sampleData())
        #expect(result.checks.map(\.needsPerson) == [false, true, false, false])  // pass, margin, unobserved, pass
        var unexplained = result.checks[2]
        unexplained.unsureCause = nil
        #expect(unexplained.needsPerson)
    }

    // MARK: The card's check lines

    @Test func cardLinesPutFailuresFirstThenUnsureThenTheClosestPasses() {
        typealias Check = ResultReading.Check
        let checks = [
            Check(id: "wide", outcome: .pass, margin: 9),
            Check(id: "unsure", outcome: .unsure),
            Check(id: "close", outcome: .pass, margin: 0.5),
            Check(id: "fail", outcome: .fail),
            Check(id: "unmeasured", outcome: .pass),
            Check(id: "closer", outcome: .pass, margin: 0.2),
        ]
        #expect(ResultReading.cardLines(checks) == [3, 1, 5])
        let passes = checks.filter { $0.outcome == .pass }
        #expect(ResultReading.cardLines(passes) == [3, 1])  // closer, close: two passes at most
    }

    @Test func marginIsInUnitsOfTheErrorWhenThereIsOne() throws {
        #expect(abs(try #require(ResultReading.margin(measured: 3.6, threshold: 3, plusMinus: 0.3, comparison: .atLeast)) - 2) < 1e-9)
        #expect(ResultReading.margin(measured: 18, threshold: 20, plusMinus: nil, comparison: .atMost) == 2)
        #expect(ResultReading.margin(measured: 2.5, threshold: 3, plusMinus: 0, comparison: .atLeast) == -0.5)
        #expect(ResultReading.margin(measured: 2.5, threshold: 3, plusMinus: nil, comparison: nil) == 0.5)
        #expect(ResultReading.margin(measured: nil, threshold: 3, plusMinus: 0.3, comparison: .atLeast) == nil)
    }
}
