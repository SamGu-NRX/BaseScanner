import XCTest

/// Every step of the walk that asks something has a true answer, and a card that refuses says
/// what to do. Held still on the demo engine (`-uiDemoFreeze`), which mirrors the real engine's
/// choices; the real engine's own handling of each answer is covered by review and the replay
/// flows.
final class WalkRecoveryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// B-06: "Is this the right end of the wall?" had one answer, "Wall ends here", so a wall that
    /// goes on had none. "The wall keeps going" ends the side where the walk reached without
    /// asking what is there, and the walk goes on to the other side.
    @MainActor
    func testTheEndCardAnswersThatTheWallKeepsGoing() throws {
        let app = launch(["-uiDemoPhase", "wallWalk", "-uiDemoMarkEnd"])
        XCTAssertTrue(label(app, "instruction").contains("Is this the right end of the wall?"))
        snap(app, "wallWalk-markEnd-keepsGoing")
        XCTAssertTrue(element(app, "action.markEnd").exists, "Wall ends here must stay on offer")
        let keepsGoing = reply(app, "The wall keeps going")
        XCTAssertTrue(keepsGoing.waitForExistence(timeout: 5), "the end card has no way to say the wall goes on")
        tapWhenReady(keepsGoing)
        let walkLeft = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'instruction' AND label CONTAINS 'to your left'")).firstMatch
        XCTAssertTrue(walkLeft.waitForExistence(timeout: 5), "the walk must go on to the left")
        XCTAssertFalse(element(app, "action.endCorner").exists, "a wall that goes on has no end to ask about")
        XCTAssertFalse(element(app, "action.markEnd").exists)
    }

    /// B-06: "Wall ends here" with the circle off the wall did nothing. The card now says why and
    /// what to do, and both answers stay.
    @MainActor
    func testARefusedWallEndSaysWhatToDo() throws {
        let app = launch(["-uiDemoPhase", "wallWalk", "-uiDemoMarkEnd", "-uiDemoEndMarkRefusal"])
        let card = label(app, "instruction")
        snap(app, "wallWalk-markEnd-refused")
        XCTAssertTrue(card.contains("The circle isn't on the wall"), "card reads: \(card)")
        XCTAssertTrue(card.contains("Aim it at the wall where it stops or turns"), "card reads: \(card)")
        XCTAssertTrue(element(app, "action.markEnd").exists)
        XCTAssertTrue(reply(app, "The wall keeps going").waitForExistence(timeout: 5))
    }

    /// B-23: "Point at the meter like this." needs the photo it points to. The follow-up view
    /// shows the close-up as the walk does; without a close-up the card says it plainly.
    @MainActor
    func testLostPlaceSaysLikeThisOnlyWithThePhoto() throws {
        let gap = launch(["-uiDemoPhase", "gapRequest", "-uiDemoCoaching", "relocalizing"], screen: "screen.gapRequest")
        XCTAssertTrue(element(gap, "relocalize.meterPhoto").waitForExistence(timeout: 5), "the follow-up view must show the close-up")
        XCTAssertTrue(label(gap, "instruction").contains("Point at the meter like this."))
        snap(gap, "gapRequest-relocalizing")
        gap.terminate()

        let walk = launch(["-uiDemoPhase", "wallWalk", "-uiDemoCoaching", "relocalizing", "-uiDemoCloseUpSkipped"])
        let card = label(walk, "instruction")
        XCTAssertFalse(element(walk, "relocalize.meterPhoto").exists)
        snap(walk, "wallWalk-relocalizing-noCloseUp")
        XCTAssertTrue(card.contains("Point back at your meter"), "card reads: \(card)")
        XCTAssertFalse(card.contains("like this"), "no photo, so no \"like this\": \(card)")
    }

    @MainActor
    private func launch(_ arguments: [String], screen: String = "screen.wallWalk") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-practiceMeter", "NO", "-uiDemo", "-uiDemoFreeze"] + arguments
        app.launch()
        XCTAssertTrue(element(app, screen).waitForExistence(timeout: 15), "\(screen) never appeared")
        XCTAssertTrue(element(app, "instruction").waitForExistence(timeout: 5))
        return app
    }

    /// Kept in the result bundle for the PR's captures.
    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        ElementRead.snapshot(element(app, identifier))?.label ?? ""
    }

    @MainActor
    private func reply(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'action.cannotAccess' AND label == %@", title)).firstMatch
    }

    /// A new card's reply ignores taps for a moment (`InstructionCard.replyLock`).
    @MainActor
    private func tapWhenReady(_ target: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"), object: target)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 10), .completed, "\(target) never took taps")
        target.tap()
    }
}
