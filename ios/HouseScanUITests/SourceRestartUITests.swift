import XCTest

/// Start over after the frame source failed must start a new one. The Simulator can't run an AR
/// session, so the source here is a replay: unreadable at launch, then made readable. Start over
/// has to read it again, and its frames have to reach the close-up.
final class SourceRestartUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testStartOverAfterAFailedSourceDeliversFrames() throws {
        let files = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "housescan-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        // A session.json with none of its fields: the replay can't be read.
        try Data("{}".utf8).write(to: folder.appending(path: "session.json"))

        let app = XCUIApplication()
        // The practice meter switch can be left on by an earlier test; this one needs the real
        // close-up, whose unreadable photo asks for a retake.
        app.launchArguments = ["-replay", folder.path, "-sampleResult", "-practiceMeter", "NO"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["screen.unsupported"].waitForExistence(timeout: 30), "the unreadable replay never showed the failure")

        // The recording is readable now.
        try files.removeItem(at: folder.appending(path: "session.json"))
        let fixture = URL(fileURLWithPath: FullFlowUITests.fixture, isDirectory: true)
        for name in try files.contentsOfDirectory(atPath: fixture.path) {
            try files.copyItem(at: fixture.appending(path: name), to: folder.appending(path: name))
        }

        // Each control is found again by its identifier after the screen it is on appears.
        XCTAssertTrue(app.buttons["action.startOver"].waitForExistence(timeout: 10))
        app.buttons["action.startOver"].tap()
        XCTAssertTrue(any["screen.onboarding"].waitForExistence(timeout: 10), "Start over didn't return to the start")
        if app.buttons["action.onboardingSkip"].waitForExistence(timeout: 5) { app.buttons["action.onboardingSkip"].tap() }
        XCTAssertTrue(app.buttons["action.finishOnboarding"].waitForExistence(timeout: 10))
        app.buttons["action.finishOnboarding"].tap()
        XCTAssertTrue(any["screen.findMeter"].waitForExistence(timeout: 10))

        // Marking the meter needs the replay loaded; the close-up's shutter fires only on frames,
        // and the reader then asks for a retake (the synthetic meter has no readable number).
        XCTAssertTrue(app.buttons["action.markMeter"].waitForExistence(timeout: 10))
        app.buttons["action.markMeter"].tap()
        XCTAssertTrue(any["screen.meterCloseUp"].waitForExistence(timeout: 15), "the meter couldn't be marked: no replay after Start over")
        XCTAssertTrue(any["closeUp.problem"].waitForExistence(timeout: 60), "no frame reached the close-up after Start over")
    }
}
