import XCTest

/// B-20: a meter close-up the phone couldn't save read "Hold still", as if the homeowner's hand
/// had blurred it, and retaking with a steadier hand could never help. `-failCloseUpSave` makes
/// every close-up's save fail on a replay, through the real engine and `KeyframeStore.saveStill`.
final class CloseUpSaveFailureUITests: XCTestCase {
    static let notSaved = "Your phone couldn't save that photo. Hold on the meter to try again."

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAPhotoThatDidNotSaveSaysSoAndCanBeSkipped() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-replay", FullFlowUITests.fixture, "-sampleResult", "-failCloseUpSave"]
        app.launch()
        let any = app.descendants(matching: .any)

        XCTAssertTrue(any["screen.onboarding"].waitForExistence(timeout: 30))
        if app.buttons["action.onboardingSkip"].waitForExistence(timeout: 5) { app.buttons["action.onboardingSkip"].tap() }
        XCTAssertTrue(app.buttons["action.finishOnboarding"].waitForExistence(timeout: 10))
        app.buttons["action.finishOnboarding"].tap()
        XCTAssertTrue(app.buttons["action.markMeter"].waitForExistence(timeout: 20))
        app.buttons["action.markMeter"].tap()
        XCTAssertTrue(any["screen.meterCloseUp"].waitForExistence(timeout: 15))

        // Under `-failCloseUpSave` the reason stays up 10 s rather than 2 before the gate's own
        // "Move closer" replaces it, so this query can't miss it.
        let saidNotSaved = any.matching(identifier: "closeUp.problem").matching(NSPredicate(format: "label == %@", Self.notSaved)).firstMatch
        XCTAssertTrue(saidNotSaved.waitForExistence(timeout: 60), "a close-up that didn't save never said so")
        snap(app, "meterCloseUp-photoNotSaved")

        // The save failure counted as one failed attempt; the next one (another failed save, or
        // `CloseUpGate.failAfter` without a photo) brings the way out.
        let skip = app.buttons["action.skipCloseUp"]
        XCTAssertTrue(skip.waitForExistence(timeout: 90), "no way past a close-up that can't be saved")
        skip.tap()
        XCTAssertTrue(any["screen.wallWalk"].waitForExistence(timeout: 15), "skipping the unsaved close-up didn't lead on to the walk")
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
