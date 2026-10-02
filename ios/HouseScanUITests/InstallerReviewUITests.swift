import XCTest

/// The result says what it needs from a person, never that one was contacted: the app only shows
/// the server's answer. Held still on the demo's review sample (`DemoEngine.reviewSample`), whose
/// window check needs a person and whose ground check needs a photo.
final class InstallerReviewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheResultSaysAnInstallerIsNeededNotArranged() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-practiceMeter", "NO", "-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "result"]
        app.launch()
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 15))
        XCTAssertEqual(element(app, "result.headline").label, "Needs an installer's review")
        XCTAssertEqual(element(app, "result.installerConfirms").label, "Before any battery goes in, an installer has to confirm where it goes on site.")

        // The full list of checks sits under Details, below the footnotes.
        let details = element(app, "result.details")
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        for _ in 0..<4 where !details.isHittable { app.swipeUp() }
        details.tap()
        let window = element(app, "detail.check.window")
        let ground = element(app, "detail.check.ground")
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the window check never appeared under Details")
        // The two unsure checks keep their difference: a person settles one, a photo the other.
        XCTAssertTrue(value(window).contains("Needs an installer to check"), "window check reads: \(value(window))")
        XCTAssertTrue(value(ground).contains("One more photo would settle this"), "ground check reads: \(value(ground))")
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func value(_ element: XCUIElement) -> String {
        element.value as? String ?? ""
    }
}
