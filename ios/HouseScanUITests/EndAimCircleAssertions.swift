import XCTest

/// The circle "Wall ends here" marks at (`endAimCircle`, identifier `aim.circle`), read from the
/// production layout: the app's own view, as VoiceOver sees it, not a test-only overlay.
extension XCTestCase {
    /// Checks the circle is drawn in the middle of the window, where the ray "Wall ends here" uses
    /// goes through (`ScanEngine.circleEnd`: the middle of the sensor image, which the camera view
    /// fills and centres), is wholly on screen, and is under none of `covers`: the card's words,
    /// its Details, and the actions. The card's scrim runs `cardPadding` below the last of its
    /// parts, so the circle must clear that too.
    @MainActor
    func assertEndCircleOpen(
        _ app: XCUIApplication, covers: [String], _ context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        let circle = app.descendants(matching: .any)["aim.circle"].firstMatch
        XCTAssertTrue(circle.waitForExistence(timeout: 5), "\(context): no aiming circle", file: file, line: line)
        let frame = circle.frame
        XCTAssertEqual(frame.midX, window.midX, accuracy: 1, "\(context): the circle \(frame) must be the middle of the camera", file: file, line: line)
        XCTAssertEqual(frame.midY, window.midY, accuracy: 1, "\(context): the circle \(frame) must be the middle of the camera", file: file, line: line)
        XCTAssertTrue(window.contains(frame), "\(context): the circle \(frame) is not wholly on screen", file: file, line: line)
        let card = ["instruction", "instruction.details"].map { app.descendants(matching: .any)[$0].firstMatch }.filter(\.exists)
        if let cardBottom = card.map(\.frame.maxY).max() {
            XCTAssertGreaterThanOrEqual(frame.minY, cardBottom + Self.cardPadding, "\(context): the circle \(frame) is under the card, which ends at \(cardBottom + Self.cardPadding)", file: file, line: line)
        }
        for identifier in covers {
            let cover = app.descendants(matching: .any)[identifier].firstMatch
            guard cover.exists else { continue }
            XCTAssertFalse(frame.intersects(cover.frame), "\(context): the circle \(frame) is under \(identifier) \(cover.frame)", file: file, line: line)
        }
    }

    /// The card's scrim below Details without a reply (`InstructionCard.details`, bottom padding).
    static var cardPadding: CGFloat { 8 }
}
