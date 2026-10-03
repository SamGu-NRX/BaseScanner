import Foundation
import XCTest

/// A spot whose checks all pass is shown as a possible spot, never as a fit: the server's checks
/// read space beyond what the homeowner confirms in the spot check (B17). Every surface agrees:
/// the card, Details, the AR view and the 3D model. The answer itself is never changed.
final class ProvisionalPlacementUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    private static let candidate = "A possible battery spot"

    /// Words that would say the scan established a fit, or celebrate a pass as confirmed space.
    private static let fitWords = ["fits here", "fits every", "could go here", "looks good", "your battery spot", "confirmed clear"]

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: The real engine

    /// The real engine on the synthetic replay, the test answering as the server through the gate
    /// folder (`-answersFromGate`). The first answer names another scene, so "Try again" asks
    /// again; the second is the bundled sample turned into a pass naming the scene sent. The
    /// autopilot answers the spot check "It's clear". The result is a possible spot, and so is
    /// the AR view's title: a retry and a clear answer don't make it a fit.
    @MainActor
    func testAPassAfterTryAgainAndItsClearIsAPossibleSpot() throws {
        let gate = try Self.gate()
        defer { try? FileManager.default.removeItem(at: gate) }
        let server = GateServer(gate: gate) { body, index in
            Self.passingAnswer(binding: index == 0 ? Data("another scene".utf8) : body)
        }
        defer { server.stop() }
        let app = Self.launchEngine(gate: gate)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)

        let tryAgain = app.buttons["action.retryUpload"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 300), "the unbound answer never offered Try again")
        tryAgain.tap()
        XCTAssertTrue(any["screen.result"].waitForExistence(timeout: 120), "the passing answer never reached the result")
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(any["result.headline"].label, Self.candidate)
        XCTAssertFalse(any["result.spotRefused"].exists)
        assertCandidateCard(app)
        attach(app, name: "result-candidate-engine")

        // The autopilot opens the AR view once the result's gate opens.
        try Data().write(to: gate.appending(path: "result"))
        let instruction = any["instruction"]
        XCTAssertTrue(any["screen.resultAR"].waitForExistence(timeout: 20))
        XCTAssertTrue(instruction.waitForExistence(timeout: 10))
        XCTAssertTrue(instruction.label.contains(Self.candidate), instruction.label)
        XCTAssertTrue(instruction.label.contains("An installer needs to check the fit on site."), instruction.label)
        assertNoFitWords(instruction.label)
        attach(app, name: "resultAR-candidate-engine")
    }

    /// "Something's there" withdraws the area and sends the scan again; the passing answer that
    /// comes back names the same spot, so the earlier answer settles it and the result shows
    /// without asking (`SpotConfirmations.settling`). That shortcut still shows a possible spot,
    /// beside the notice that the homeowner said something stands there.
    @MainActor
    func testASpotSettledByAnEarlierAnswerIsStillAPossibleSpot() throws {
        let gate = try Self.gate()
        defer { try? FileManager.default.removeItem(at: gate) }
        let server = GateServer(gate: gate) { body, _ in Self.passingAnswer(binding: body) }
        defer { server.stop() }
        let app = Self.launchEngine(gate: gate, extra: ["-autopilotSomethingThere"])
        defer { app.terminate() }
        let any = app.descendants(matching: .any)

        XCTAssertTrue(any["screen.result"].waitForExistence(timeout: 420), "the second passing answer never reached the result")
        XCTAssertEqual(server.requests.count, 2, "the spot check's answer should send the scan once more")
        XCTAssertEqual(any["result.headline"].label, Self.candidate)
        XCTAssertTrue(any["result.spotRefused"].exists, "the settled answer's notice is missing")
        assertCandidateCard(app)
        attach(app, name: "result-candidate-settled")
    }

    // MARK: Server answers in Fixtures/results

    /// pass.json, every check passing: the card, Details and the AR overlay at the default size.
    @MainActor
    func testAPassingAnswerReadsAsAPossibleSpotEverywhere() throws {
        try checkPassFixture(textSize: [], name: "result-candidate")
    }

    @MainActor
    func testAPassingAnswerReadsAsAPossibleSpotAtLargestTextSize() throws {
        try checkPassFixture(textSize: Self.largestText, name: "result-candidate-AX5")
    }

    /// A rejected wall keeps its negative answer and its reasons.
    @MainActor
    func testARejectStaysNegative() throws {
        let app = Self.launchFixture("reject-nearest", textSize: [])
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertEqual(any["result.headline"].label, "Not on this wall")
        XCTAssertFalse(any["result.candidateNote"].exists)
        XCTAssertTrue(any["result.nearest"].label.hasPrefix("The closest spot"))
        attach(app, name: "result-reject")
    }

    @MainActor
    private func checkPassFixture(textSize: [String], name: String) throws {
        let app = Self.launchFixture("pass", textSize: textSize)
        defer { app.terminate() }
        let any = app.descendants(matching: .any)
        XCTAssertEqual(any["result.headline"].label, Self.candidate)
        assertCandidateCard(app)
        let model = any.matching(NSPredicate(format: "label == '3D view of your wall'")).firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        let modelValue = model.value as? String ?? ""
        XCTAssertTrue(modelValue.hasPrefix("Proposed battery spot"), modelValue)
        attach(app, name: name)

        // Details: the checks as calculations on the recorded scan, a pass without the server's
        // positive reason, and no server summary that says the spot fits.
        let details = any["result.details"]
        scroll(to: details, in: app)
        details.tap()
        let note = any["result.calculatedNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertFalse(any["result.summary"].exists, "a possible spot's summary is the server's pass")
        let row = any["detail.check.gas_clearance"]
        XCTAssertTrue(row.exists)
        XCTAssertEqual(row.label, "Distance from gas equipment: Passes on recorded data", row.label)
        let rowValue = row.value as? String ?? ""
        XCTAssertFalse(rowValue.contains("well clear"), "a pass kept the server's reason: \(rowValue)")
        scroll(to: note, in: app)
        attach(app, name: "\(name)-details")

        // The AR view draws the proposed spot. The demo's answer is a sample, so the AR title
        // says so (`ResultARScreen`); the drawing names the spot as proposed.
        scroll(to: any["action.showAR"], in: app)
        app.buttons["action.showAR"].tap()
        let overlay = any["ar.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        XCTAssertEqual(overlay.label, "A proposed battery spot, drawn on your wall")
        assertNoFitWords(any["instruction"].label)
        attach(app, name: "\(name)-AR")
    }

    // MARK: Helpers

    /// The card of a possible spot: headline, placement, the note that says what isn't confirmed,
    /// no passing check lines, no repeat of the installer footnote, and the AR button's words.
    @MainActor
    private func assertCandidateCard(_ app: XCUIApplication) {
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["result.placement"].exists)
        let note = any["result.candidateNote"]
        XCTAssertTrue(note.exists, "the candidate note is missing")
        XCTAssertTrue(note.label.contains("couldn't confirm all the space a battery needs"), note.label)
        let lines = any.matching(NSPredicate(format: "identifier BEGINSWITH 'check.'"))
        XCTAssertEqual(lines.count, 0, "a passing check reached the card")
        XCTAssertFalse(any["result.installerConfirms"].exists)
        XCTAssertEqual(app.buttons["action.showAR"].label, "See this spot on your wall")
        // Details' scope note says, truthfully, that a pass is "not ... confirmed clear": the sweep
        // leaves that one qualified sentence out, whether or not Details is open.
        let texts = app.staticTexts.allElementsBoundByIndex
            .filter { $0.identifier != "result.calculatedNote" }
            .map(\.label).joined(separator: " | ")
        assertNoFitWords(texts)
    }

    private func assertNoFitWords(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lowered = text.lowercased()
        for words in Self.fitWords {
            XCTAssertFalse(lowered.contains(words), "says \"\(words)\": \(text)", file: file, line: line)
        }
    }

    /// The bundled sample turned into a pass: every check passing, nothing more needed, naming
    /// `binding` as the scene it answers.
    private static func passingAnswer(binding: Data) -> Data {
        let sample = try! Data(contentsOf: UploadRecoveryUITests.sampleResult)
        var object = try! JSONSerialization.jsonObject(with: sample) as! [String: Any]
        object["decision"] = "pass"
        object["checks"] = (object["checks"] as! [[String: Any]]).map { check in
            var check = check
            check["outcome"] = "pass"
            check["unsure_cause"] = NSNull()
            return check
        }
        object["missing_evidence"] = [Any]()
        var stats = object["stats"] as! [String: Any]
        stats["input_sha256"] = UploadRecoveryUITests.sha256(binding)
        object["stats"] = stats
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// A gate folder with every screen up to the spot check let through; the result's stays shut.
    private static func gate() throws -> URL {
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        for phase in ["onboarding", "findMeter", "meterCloseUp", "wallWalk", "markFeatures", "gapRequest", "uploading", "spotConfirm"] {
            try Data().write(to: gate.appending(path: phase))
        }
        return gate
    }

    @MainActor
    private static func launchEngine(gate: URL, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "1.5", "-autopilotGate", gate.path,
            "-practiceMeter", "NO", "-serverURL", "http://placement.invalid", "-answersFromGate",
        ] + extra
        app.launch()
        return app
    }

    @MainActor
    private static func launchFixture(_ name: String, textSize: [String]) -> XCUIApplication {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/results/\(name).json").path
        let app = XCUIApplication()
        app.launchArguments = ["-practiceMeter", "NO", "-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "result",
                               "-uiDemoResultFile", file] + textSize
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["screen.result"].waitForExistence(timeout: 15))
        return app
    }

    /// Scrolls until the element is inside the window, a third of the window at most per drag.
    @MainActor
    private func scroll(to target: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let start = app.scrollViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        for _ in 0..<12 where !window.contains(target.frame) {
            let frame = target.frame
            let shift: CGFloat = frame.maxY > window.maxY
                ? -min(frame.maxY - window.maxY + 24, window.height / 3)
                : min(window.minY - frame.minY + 24, window.height / 3)
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)))
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
