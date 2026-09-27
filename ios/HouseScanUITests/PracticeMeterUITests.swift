import XCTest

/// An App Store install can't reach practice meter. `-simulateAppStore` runs the Debug build as
/// an App Store install would, and `-practiceMeter YES` stands in for a switch a TestFlight build
/// left on before the App Store update. The first screen offers no developer options, and the
/// scan is a real one: no badge, the real meter's words, and the close-up reads the replay's own
/// photo, whose painted meter has no number, so it asks for a retake instead of offering the
/// sample's number.
final class PracticeMeterUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAppStoreInstallHasNoPracticeMeter() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-replay", FullFlowUITests.fixture, "-sampleResult", "-simulateAppStore", "-practiceMeter", "YES"]
        app.launch()
        let any = app.descendants(matching: .any)

        XCTAssertTrue(any["screen.onboarding"].waitForExistence(timeout: 30))
        // The Debug build shows the entry at once; give an App Store one the same chance.
        XCTAssertFalse(app.buttons["action.developerOptions"].waitForExistence(timeout: 3), "an App Store install offers the developer options")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "appStore-onboarding"
        shot.lifetime = .keepAlways
        add(shot)

        if app.buttons["action.onboardingSkip"].waitForExistence(timeout: 5) { app.buttons["action.onboardingSkip"].tap() }
        XCTAssertTrue(app.buttons["action.finishOnboarding"].waitForExistence(timeout: 10))
        app.buttons["action.finishOnboarding"].tap()
        XCTAssertTrue(any["screen.findMeter"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["action.markMeter"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["action.markMeter"].label, "This is my meter")
        XCTAssertFalse(any["practiceBadge"].exists, "the find-meter screen says practice meter")

        app.buttons["action.markMeter"].tap()
        XCTAssertTrue(any["screen.meterCloseUp"].waitForExistence(timeout: 15))
        XCTAssertTrue(any["closeUp.problem"].waitForExistence(timeout: 60), "the close-up never asked for a retake of the replay's unreadable meter")
        let sample = any.matching(NSPredicate(format: "label CONTAINS %@", FullFlowUITests.sampleNumber)).firstMatch
        XCTAssertFalse(sample.exists, "the close-up read the sample meter's number on an App Store install")
        XCTAssertFalse(any["practiceBadge"].exists, "the close-up says practice meter")
    }
}
