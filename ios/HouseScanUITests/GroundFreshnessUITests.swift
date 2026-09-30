import XCTest

/// A ground refine after the answer is shown takes it down and sends the scan again
/// (`GroundFreshness`, `ScanEngine.answerAfter`). The real engine plays the synthetic wall to the
/// result; `-injectGroundRise` then hands it a detected floor 5 cm above its ground each time the
/// test drops `inject-ground` in the gate folder, as ARKit refining the ground would. Replays
/// carry no plane evidence, so nothing else can reach this path in the Simulator.
final class GroundFreshnessUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAGroundRefineAfterTheResultResendsAndASecondOneFails() throws {
        let files = FileManager.default
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: gate, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: gate) }
        // Every screen before the result is let through; the result's gate stays shut, so the
        // autopilot never leaves for the camera view and the test drives from here.
        for phase in ["onboarding", "findMeter", "meterCloseUp", "wallWalk", "markFeatures", "gapRequest", "spotConfirm"] {
            try Data().write(to: gate.appending(path: phase))
        }
        let uploadGate = gate.appending(path: "uploading")
        let uploadHeld = gate.appending(path: "uploading.held")
        try Data().write(to: uploadGate)

        let app = XCUIApplication()
        app.launchArguments = [
            "-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "1.5", "-autopilotGate", gate.path,
            "-practiceMeter", "NO", "-sampleResult", "-injectGroundRise", "0.05",
        ]
        app.launch()
        let any = app.descendants(matching: .any)
        let result = any["screen.result"]
        let uploading = any["screen.uploading"]
        XCTAssertTrue(result.waitForExistence(timeout: 300), "the replay never reached the result")
        // The autopilot is parked at the shut result gate, so it no longer answers spot checks or
        // retries uploads: otherwise it could retry the failure step 4 looks for.
        let resultHeld = gate.appending(path: "result.held")
        XCTAssertTrue(waitUntil(timeout: 30) { files.fileExists(atPath: resultHeld.path) }, "the autopilot never finished with the result")

        /// Shuts the upload gate, so the next upload holds its answer on the upload screen.
        func holdNextUpload() throws {
            try files.removeItem(at: uploadGate)
            try? files.removeItem(at: uploadHeld)
        }
        func injectGround() throws {
            let trigger = gate.appending(path: "inject-ground")
            try Data().write(to: trigger)
            XCTAssertTrue(waitUntil(timeout: 10) { !files.fileExists(atPath: trigger.path) }, "the app never took the injected ground")
        }
        func waitForHeldUpload(_ what: String) {
            XCTAssertTrue(waitUntil(timeout: 60) { files.fileExists(atPath: uploadHeld.path) }, "\(what): the scan was not sent again")
        }

        // 1. A refine on the result takes the answer down and sends the scan again.
        try holdNextUpload()
        try injectGround()
        XCTAssertTrue(uploading.waitForExistence(timeout: 10), "a ground refine left the old answer on the result")
        XCTAssertFalse(result.exists)
        waitForHeldUpload("first refine")
        XCTAssertFalse(result.exists, "the result came back before the new answer was let through")

        // 2. Only the new answer brings the result back. The earlier "It's clear" settles the same
        // spot; a check asked again is answered the same way.
        try Data().write(to: uploadGate)
        let spotClear = app.buttons["action.spotClear"]
        XCTAssertTrue(waitUntil(timeout: 30) { result.exists || spotClear.exists }, "the new answer never showed")
        if spotClear.exists { spotClear.tap() }
        XCTAssertTrue(result.waitForExistence(timeout: 20), "the new answer never reached the result")

        // 3. A refine on the new result sends again: it starts a new resend.
        try holdNextUpload()
        try injectGround()
        XCTAssertTrue(uploading.waitForExistence(timeout: 10), "a refine on the new result left it up")
        waitForHeldUpload("refine on the new result")

        // 4. A second refine before that resend's answer shows fails in words, never the answer.
        try injectGround()
        XCTAssertTrue(app.buttons["action.retryUpload"].waitForExistence(timeout: 10), "a second refine didn't show the failure")
        let failure = any.matching(NSPredicate(format: "label CONTAINS %@", "still measuring the ground")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "the failure doesn't say why")
        try Data().write(to: uploadGate)
        // The cancelled resend's answer must not arrive once its gate opens.
        XCTAssertFalse(result.waitForExistence(timeout: 8), "the cancelled resend's answer was shown")
        XCTAssertTrue(app.buttons["action.retryUpload"].exists)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition()
    }
}
