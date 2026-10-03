import XCTest

/// The spot check names the space the homeowner judges, with or without an outline to show it.
///
/// With a kept photo and a wall, the area is outlined on the photo and the question points at the
/// outline. Without either, nothing is drawn, so the question must not mention an outline and the
/// area is given in words: along the wall from the meter, out from the wall, and up it. Held still
/// on the demo (`-uiDemoFreeze`), whose review sample's spot runs 0.55 to 1.34 m right of the
/// meter, stands 0.03 m off the wall and 0.56 m deep (out to 0.59 m), and is 1.1 m high. The demo
/// asks about the footprint alone, so its area is the footprint. Fixtures/results/spot-left.json
/// and spot-straddle.json put the spot left of the meter and across it.
final class SpotConfirmUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// The words-only card's three lines as VoiceOver reads them (units spelled out).
    private struct Lines {
        var along: String
        var out: String
        var up: String
    }

    /// The review sample's area, read aloud: one sentence on the photo, three lines in words.
    private static let sampleLines = Lines(
        along: "From 1 foot 10 inches to 4 feet 5 inches right of your meter",
        out: "From the wall out to 1 foot 11 inches", up: "From the ground up to 3 feet 7 inches")
    private static let sampleSpace = "From 1 foot 10 inches to 4 feet 5 inches right of your meter, from the wall out to 1 foot 11 inches, and from the ground up to 3 feet 7 inches."

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testTheOutlinedPhotoNamesTheOutlineAndWhereItRuns() throws {
        let app = launch([])
        defer { app.terminate() }
        let photo = element(app, "spot.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "the demo's spot check shows its photo")
        let read = ElementRead.snapshot(photo)
        XCTAssertEqual(read?.label, "Photo of your wall")
        XCTAssertEqual(read?.value as? String, "A blue outline marks where the battery would stand and the space around it. \(Self.sampleSpace)")
        let question = ElementRead.snapshot(element(app, "spot.question"))?.label ?? ""
        XCTAssertTrue(question.contains("Is anything standing in the marked area?"), question)
        XCTAssertTrue(question.contains("inside the blue outline"), question)
        XCTAssertFalse(element(app, "spot.area").exists, "the words-only area shows only without an outline")
        attach(app, name: "spotConfirm-photo")
    }

    @MainActor
    func testWithoutAPhotoTheAreaIsGivenInWords() throws {
        try checkInWords(["-uiDemoSpotNoPhoto"], name: "spotConfirm-noPhoto", spoken: Self.sampleLines)
        try checkInWords(["-uiDemoSpotNoPhoto"] + Self.largestText, name: "spotConfirm-noPhoto-AX5", spoken: Self.sampleLines)
    }

    /// A photo with no wall to draw the area with is shown as no photo: VoiceOver used to call
    /// the words-only card "Photo of your wall" and describe an outline that wasn't drawn.
    @MainActor
    func testWithoutAWallThePhotoIsNotShownUnmarked() throws {
        try checkInWords(["-uiDemoSpotNoWall"], name: "spotConfirm-noWall", spoken: Self.sampleLines)
    }

    @MainActor
    func testTheAreaInWordsNamesTheSideOfTheMeter() throws {
        try checkInWords(["-uiDemoResultFile", Self.resultFile("spot-left"), "-uiDemoSpotNoPhoto"], name: "spotConfirm-noPhoto-left",
                         spoken: Lines(along: "From 3 feet 6 inches to 6 feet left of your meter",
                                       out: "From the wall out to 2 feet", up: "From the ground up to 3 feet 6 inches"))
        try checkInWords(["-uiDemoResultFile", Self.resultFile("spot-straddle"), "-uiDemoSpotNoPhoto"], name: "spotConfirm-noPhoto-straddle",
                         spoken: Lines(along: "From 1 foot 3 inches left to 1 foot 6 inches right of your meter",
                                       out: "From the wall out to 2 feet", up: "From the ground up to 3 feet 6 inches"))
    }

    /// Answering works the same without a photo: "Something's there" is taken and acknowledged.
    @MainActor
    func testTheAnswerIsTakenWithoutAPhoto() throws {
        let app = launch(["-uiDemoSpotNoPhoto"])
        defer { app.terminate() }
        let answer = app.buttons["action.spotSomethingThere"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: answer)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed, "Something's there can't be tapped")
        answer.tap()
        let answered = element(app, "spot.answered")
        XCTAssertTrue(answered.waitForExistence(timeout: 10))
        let label = ElementRead.snapshot(answered)?.label ?? ""
        XCTAssertTrue(label.contains("Thanks, we'll leave that area out"), label)
    }

    // MARK: - Helpers

    /// The words-only spot check: no photo element, a question that names no outline, each of
    /// the area's three lines rendered on screen with its spoken label, both answers present, and
    /// a clean accessibility audit, which also checks those lines for contrast and clipping.
    @MainActor
    private func checkInWords(_ arguments: [String], name: String, spoken: Lines) throws {
        let app = launch(arguments)
        defer { app.terminate() }
        guard element(app, "spot.area").waitForExistence(timeout: 10) else {
            XCTFail("\(name): spot.area never appeared")
            return
        }
        attach(app, name: name)
        XCTAssertFalse(element(app, "spot.photo").exists, "\(name): no photo is shown without an outline on it")
        XCTAssertEqual(ElementRead.snapshot(element(app, "spot.area.title"))?.label, "Where to look", name)
        let window = app.windows.firstMatch.frame
        for (id, expected) in [("along", spoken.along), ("out", spoken.out), ("up", spoken.up)] {
            let line = element(app, "spot.area.\(id)")
            // At AX5 the card can sit below the fold; the homeowner scrolls to it. Slowly, as
            // ScreenStatesUITests does, so momentum doesn't carry the line past the top.
            for _ in 0..<6 where !line.isHittable { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
            let read = ElementRead.snapshot(line)
            XCTAssertEqual(read?.label, expected, "\(name): spot.area.\(id)")
            let frame = read?.frame ?? .zero
            XCTAssertTrue(!frame.isEmpty && window.contains(frame), "\(name): spot.area.\(id) at \(frame) isn't on screen in \(window)")
        }
        let question = ElementRead.snapshot(element(app, "spot.question"))?.label ?? ""
        XCTAssertTrue(question.contains("Is anything standing in this space?"), "\(name): \(question)")
        XCTAssertTrue(question.contains("take a look yourself"), "\(name): \(question)")
        // Nothing on screen may point at an outline that isn't drawn. Labels only: some elements'
        // values aren't strings.
        let outline = NSPredicate(format: "label CONTAINS[c] 'outline' OR label CONTAINS[c] 'marked area'")
        XCTAssertEqual(app.descendants(matching: .any).matching(outline).count, 0, "\(name): something still mentions the outline")
        XCTAssertTrue(app.buttons["action.spotClear"].exists, "\(name): It's clear is missing")
        XCTAssertTrue(app.buttons["action.spotSomethingThere"].exists, "\(name): Something's there is missing")
        // As ScreenStatesUITests: an issue fails only when a second pass, after a system banner
        // has had time to leave, finds it again.
        let outcome = try AccessibilityAudit.run(app) { _ in Thread.sleep(forTimeInterval: 6) }
        for (_, finding) in outcome.persistent {
            XCTFail("\(name): \(finding.message)")
        }
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-practiceMeter", "NO", "-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "spotConfirm"] + arguments
        app.launch()
        XCTAssertTrue(element(app, "screen.spotConfirm").waitForExistence(timeout: 15), "the spot check never appeared")
        return app
    }

    /// A server answer in Fixtures/results, which the demo reads in debug builds.
    private static func resultFile(_ name: String, file: String = #filePath) -> String {
        URL(fileURLWithPath: file).deletingLastPathComponent().appending(path: "Fixtures/results/\(name).json").path
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
