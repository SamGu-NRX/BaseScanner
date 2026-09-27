import XCTest

/// Every screen state, including ones a replay never reaches (camera denied, offline upload,
/// tracking coaching, a refused mark), rendered by the scripted demo engine (`-uiDemo`, see
/// UI/Preview/UIDemo.swift) and held still with `-uiDemoFreeze`.
///
/// Each state must pass `performAccessibilityAudit()` at the default text size, and the screens
/// with the most text again at the largest accessibility size (AX5). A screenshot of each state
/// is attached to the result bundle.
final class ScreenStatesUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// Name, extra launch arguments, and the screen identifier that must appear.
    private static let states: [(name: String, arguments: [String], screen: String)] = [
        ("onboarding", [], "onboarding"),
        ("findMeter", ["-uiDemoPhase", "findMeter"], "findMeter"),
        ("meterCloseUp-cantGetClearShot", ["-uiDemoPhase", "meterCloseUp", "-uiDemoCloseUpFailed"], "meterCloseUp"),
        ("meterCloseUp-chooseNumber", ["-uiDemoPhase", "meterCloseUp", "-uiDemoMeterChoose"], "meterCloseUp"),
        ("wallWalk", ["-uiDemoPhase", "wallWalk"], "wallWalk"),
        ("wallWalk-slowDown", ["-uiDemoPhase", "wallWalk", "-uiDemoCoaching", "slowDown"], "wallWalk"),
        ("wallWalk-needsTexture", ["-uiDemoPhase", "wallWalk", "-uiDemoCoaching", "needsTexture"], "wallWalk"),
        ("wallWalk-relocalizing", ["-uiDemoPhase", "wallWalk", "-uiDemoCoaching", "relocalizing"], "wallWalk"),
        ("wallWalk-markingRefused", ["-uiDemoPhase", "wallWalk", "-uiDemoMarking", "window", "-uiDemoRefusal"], "wallWalk"),
        ("wallWalk-endQuestion", ["-uiDemoPhase", "wallWalk", "-uiDemoEndQuestion"], "wallWalk"),
        ("wallWalk-endPreview", ["-uiDemoPhase", "wallWalk", "-uiDemoEndPreview"], "wallWalk"),
        ("wallWalk-pastWallEnd", ["-uiDemoPhase", "wallWalk", "-uiDemoCoaching", "pastWallEnd"], "wallWalk"),
        ("wallWalk-nextWall", ["-uiDemoPhase", "wallWalk", "-uiDemoNextWall"], "wallWalk"),
        ("wallWalk-nextWallRefused", ["-uiDemoPhase", "wallWalk", "-uiDemoNextWall", "-uiDemoRefusal"], "wallWalk"),
        ("wallWalk-tiltUp", ["-uiDemoPhase", "wallWalk", "-uiDemoTiltUp"], "wallWalk"),
        ("wallWalk-overheadQuestion", ["-uiDemoPhase", "wallWalk", "-uiDemoOverheadQuestion"], "wallWalk"),
        ("wallWalk-hidden", ["-uiDemoPhase", "wallWalk", "-uiDemoHidden"], "wallWalk"),
        ("wallWalk-seeBehind", ["-uiDemoPhase", "wallWalk", "-uiDemoSeeBehind"], "wallWalk"),
        ("markFeatures", ["-uiDemoPhase", "markFeatures"], "markFeatures"),
        ("markFeatures-marking", ["-uiDemoPhase", "markFeatures", "-uiDemoMarking", "door"], "markFeatures"),
        ("markFeatures-lostPlace", ["-uiDemoPhase", "markFeatures", "-uiDemoCoaching", "relocalizing"], "markFeatures"),
        ("markFeatures-groundQuestion", ["-uiDemoGroundQuestion"], "markFeatures"),
        ("markFeatures-groundAnswered", ["-uiDemoGroundAnswer", "mulch"], "markFeatures"),
        ("gapRequest", ["-uiDemoPhase", "gapRequest"], "gapRequest"),
        ("gapRequest-groundOut", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "groundOut"], "gapRequest"),
        ("gapRequest-walkOut", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "walkOut"], "gapRequest"),
        ("gapRequest-overhead", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "overhead"], "gapRequest"),
        ("gapRequest-overheadQuestion", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "overhead", "-uiDemoOverheadQuestion"], "gapRequest"),
        ("gapRequest-followUp", ["-uiDemoPhase", "gapRequest", "-uiDemoFollowUp"], "gapRequest"),
        ("uploading", ["-uiDemoPhase", "uploading"], "uploading"),
        ("uploading-offline", ["-uiDemoPhase", "uploading", "-uiDemoOffline"], "uploading"),
        ("uploading-sample", ["-uiDemoPhase", "uploading", "-uiDemoSample"], "uploading"),
        ("uploading-rejected", ["-uiDemoPhase", "uploading", "-uiDemoRejected"], "uploading"),
        ("uploading-followUp", ["-uiDemoPhase", "uploading", "-uiDemoFollowUp"], "uploading"),
        ("result-review", ["-uiDemoPhase", "result"], "result"),
        ("result-pass", ["-uiDemoPhase", "result", "-uiDemoPass"], "result"),
        ("result-corner", ["-uiDemoPhase", "result", "-uiDemoCorner"], "result"),
        ("result-overlap", ["-uiDemoPhase", "result", "-uiDemoOverlap"], "result"),
        ("resultAR", ["-uiDemoPhase", "resultAR"], "resultAR"),
        ("cameraDenied", ["-uiDemoFailure", "cameraDenied"], "unsupported"),
        ("arUnsupported", ["-uiDemoFailure", "arUnsupported"], "unsupported"),
        ("sessionFailed", ["-uiDemoFailure", "sessionFailed"], "unsupported"),
        ("replayUnreadable", ["-uiDemoFailure", "replayUnreadable"], "unsupported"),
    ]

    /// The screens with the most text, also checked at AX5.
    private static let largestTextStates: Set<String> = [
        "onboarding", "wallWalk", "wallWalk-endQuestion", "wallWalk-endPreview", "wallWalk-nextWallRefused", "wallWalk-overheadQuestion", "gapRequest-walkOut", "gapRequest-overheadQuestion", "meterCloseUp-cantGetClearShot", "meterCloseUp-chooseNumber",
        "markFeatures", "gapRequest", "uploading-offline", "uploading-rejected", "result-review", "cameraDenied",
        "wallWalk-hidden", "wallWalk-seeBehind", "gapRequest-followUp", "uploading-followUp",
        "markFeatures-groundQuestion", "markFeatures-groundAnswered", "markFeatures-lostPlace",
    ]

    /// Words a state must show: in the named element's label or value, or with no identifier,
    /// in any text on screen.
    private static let expectations: [String: (identifier: String?, text: String)] = [
        "wallWalk-hidden": ("wallTape", "2 sections hidden behind something"),
        "wallWalk-seeBehind": ("instruction", "Something is in front of the wall here"),
        "gapRequest-followUp": ("instruction", "One more view to finish"),
        "uploading-followUp": (nil, "One more view to finish"),
        "markFeatures-groundQuestion": (nil, "What's on the ground along this wall?"),
        "markFeatures-groundAnswered": ("ground.answered", "Mulch"),
        "markFeatures-lostPlace": ("review.lostPlace", "Your phone lost its place"),
        // #40: an overlap reads as one, not as clearance.
        "result-overlap": ("check.meter_working_space", "Overlaps by 1 foot. The rule is no overlap"),
        // #83: the unexplored end nearer the meter than the spot, named by where the scan stopped.
        "result-review": ("result.unseenSide", "The scan stopped 1 ft 4 in left of your meter. A closer spot may be past there."),
    ]

    /// Controls a state must offer, by identifier.
    private static let controls: [String: [String]] = [
        // #39: "Show my result" on every request the check sent back, with one view left too.
        "gapRequest-followUp": ["action.skipGap", "action.showResult"],
    ]

    /// States where the scan is packaged, so "Share scan" must show.
    private static let shareStates: Set<String> = ["uploading-offline", "uploading-rejected", "result-review", "result-pass"]

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testEveryStatePassesTheAccessibilityAudit() throws {
        for state in Self.states {
            try check(state.name, arguments: state.arguments, screen: state.screen)
            if Self.largestTextStates.contains(state.name) {
                try check("\(state.name)-AX5", arguments: state.arguments + Self.largestText, screen: state.screen)
            }
        }
    }

    /// The homeowner's path through the real buttons and camera taps, not the autopilot.
    @MainActor
    func testWholeFlowThroughTheButtons() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo"]
        app.launch()
        XCTAssertTrue(element(app, "screen.onboarding").waitForExistence(timeout: 15))
        tap(app, "action.onboardingNext")
        tap(app, "action.onboardingNext")
        tap(app, "action.finishOnboarding")
        XCTAssertTrue(element(app, "screen.findMeter").waitForExistence(timeout: 10))
        // A tap on the camera marks the meter, like the button.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(element(app, "screen.meterCloseUp").waitForExistence(timeout: 10))
        // Nothing is filled in: the homeowner picks the reading that matches the meter.
        tap(app, "meter.candidate.0", timeout: 15)
        XCTAssertTrue(element(app, "screen.wallWalk").waitForExistence(timeout: 15))
        // A window takes two taps on the camera: bottom-left corner, then top-right.
        tap(app, "action.markSomething")
        tap(app, "feature.window")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)).tap()
        // The right end turns a corner: mark the next wall, walk on along it, and end it there.
        tap(app, "action.markEnd", timeout: 30)
        tap(app, "action.endCorner")
        tap(app, "action.markNextWall")
        tap(app, "action.markEnd", timeout: 30)
        tap(app, "action.endBlocked")
        tap(app, "action.markEnd", timeout: 30)
        tap(app, "action.endBlocked")
        // Both ends answered: the walk asks to tilt up, then what is overhead.
        tap(app, "action.overheadClear", timeout: 15)
        tap(app, "action.finishWalk")
        XCTAssertTrue(element(app, "screen.markFeatures").waitForExistence(timeout: 10))
        tap(app, "ground.answer.gravel")
        tap(app, "window.opens.no")
        tap(app, "action.confirmFeatures")
        XCTAssertTrue(element(app, "screen.gapRequest").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "screen.uploading").waitForExistence(timeout: 20))
        // The answer lists a view the camera can take: the scan goes back to the camera for it
        // on its own, and the result follows that view.
        let followUp = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'instruction' AND label CONTAINS 'One more view to finish'")).firstMatch
        XCTAssertTrue(followUp.waitForExistence(timeout: 20), "the answer's view must be asked for on the camera")
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "result.sampleBadge").exists, "a sample result must say so")
        XCTAssertTrue(element(app, "result.rulesNotFinal").exists, "placeholder rules must be disclosed")
        // B-14: a limit says whether it is a minimum or a maximum. The unit is left off: VoiceOver
        // text spells lengths out ("3 feet") once B-16 lands, the screen text says "3 ft".
        let window = element(app, "check.window")
        XCTAssertTrue(window.exists, "missing check.window")
        XCTAssertTrue((window.value as? String)?.contains("The rule is at least 3") == true,
                      "the window rule must read as a minimum, got \(String(describing: window.value))")
        // The result reveal slides its content in; a tap while it moves can miss (one failure in
        // three local runs), so wait until the button takes taps.
        let showAR = element(app, "action.showAR")
        XCTAssertTrue(showAR.waitForExistence(timeout: 20), "missing action.showAR")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: showAR)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed, "action.showAR never took taps")
        showAR.tap()
        XCTAssertTrue(element(app, "screen.resultAR").waitForExistence(timeout: 10))
        tap(app, "action.closeAR")
        let startOver = element(app, "action.startOver")
        XCTAssertTrue(startOver.waitForExistence(timeout: 10))
        app.swipeUp()
        app.swipeUp()
        startOver.tap()
        XCTAssertTrue(element(app, "screen.onboarding").waitForExistence(timeout: 10))
    }

    /// B-09: "Add something" on the review opens the camera with the marking prompt, and the
    /// review comes back with the new item once it is marked, or unchanged after Cancel.
    @MainActor
    func testAddSomethingFromTheReviewMarksOnTheCamera() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoPhase", "markFeatures"]
        app.launch()
        XCTAssertTrue(element(app, "screen.markFeatures").waitForExistence(timeout: 15))
        let rowsBefore = app.buttons.matching(identifier: "action.deleteFeature").count
        tap(app, "feature.ac")
        XCTAssertTrue(element(app, "action.markPoint").waitForExistence(timeout: 5), "the marking view must appear")
        XCTAssertTrue(element(app, "screen.markFeatures").exists, "marking from the review stays in the review phase")
        tap(app, "action.cancelMarking")
        XCTAssertTrue(element(app, "action.confirmFeatures").waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "action.deleteFeature").count, rowsBefore)
        tap(app, "feature.ac")
        tap(app, "action.markPoint", timeout: 5)
        XCTAssertTrue(element(app, "action.confirmFeatures").waitForExistence(timeout: 5), "the review must come back after the mark")
        XCTAssertEqual(app.buttons.matching(identifier: "action.deleteFeature").count, rowsBefore + 1)
    }

    /// While the phone has lost its place the review can't start a mark, which taps into the
    /// scene: the chips give way to a line saying so, and "Looks complete" still sends the scan.
    @MainActor
    func testReviewWhileLostOffersFinishingNotMarking() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "markFeatures", "-uiDemoCoaching", "relocalizing"]
        app.launch()
        XCTAssertTrue(element(app, "screen.markFeatures").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "review.lostPlace").exists, "the review must say the phone lost its place")
        for kind in ["gas_meter", "door", "window", "ac", "drive", "fence"] {
            XCTAssertFalse(element(app, "feature.\(kind)").exists, "feature.\(kind) must not be offered while the phone is lost")
        }
        XCTAssertTrue(element(app, "action.confirmFeatures").isHittable, "Looks complete must stay available")
    }

    /// The ground question asks until it is answered, then folds into one row with the answer;
    /// Change opens the answers again with the current one selected, and a new pick folds it back.
    @MainActor
    func testGroundQuestionFoldsIntoARowAndChangeReopensIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoFreeze", "-uiDemoGroundQuestion"]
        app.launch()
        XCTAssertTrue(element(app, "screen.markFeatures").waitForExistence(timeout: 15))
        for id in ["lawn", "mulch", "gravel", "concrete", "drive", "deck", "notSure"] {
            XCTAssertTrue(element(app, "ground.answer.\(id)").exists, "missing ground.answer.\(id)")
        }
        XCTAssertFalse(element(app, "ground.change").exists, "an unanswered question must not show Change")

        tap(app, "ground.answer.gravel")
        XCTAssertTrue(element(app, "ground.change").waitForExistence(timeout: 5), "the answer must fold into a row")
        XCTAssertTrue(element(app, "ground.answer.lawn").waitForNonExistence(timeout: 5), "the answers must go once answered")
        XCTAssertTrue(element(app, "ground.answered").label.contains("Gravel"), "the row must show the answer")

        tap(app, "ground.change")
        let gravel = element(app, "ground.answer.gravel")
        XCTAssertTrue(gravel.waitForExistence(timeout: 5), "Change must bring the answers back")
        XCTAssertTrue(gravel.isSelected, "the current answer must show as selected")
        XCTAssertFalse(element(app, "ground.change").exists)

        tap(app, "ground.answer.notSure")
        XCTAssertTrue(element(app, "ground.change").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "ground.answered").label.contains("Not sure"))
    }

    /// A refused upload offers the review, not "Try again"; from the review the scan is sent
    /// again and reaches the result.
    @MainActor
    func testRejectedUploadGoesBackToReview() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoPhase", "gapRequest", "-uiDemoRejected"]
        app.launch()
        XCTAssertTrue(element(app, "action.backToReview").waitForExistence(timeout: 30))
        XCTAssertFalse(element(app, "action.retryUpload").exists, "a refused scan must not offer Try again")
        XCTAssertTrue(element(app, "action.startOver").exists)
        tap(app, "action.backToReview")
        XCTAssertTrue(element(app, "screen.markFeatures").waitForExistence(timeout: 10))
        tap(app, "action.confirmFeatures")
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 40))
    }

    /// "Share scan" opens the system share sheet with the scan file.
    @MainActor
    func testShareScanOpensTheShareSheet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "uploading", "-uiDemoRejected"]
        app.launch()
        tap(app, "action.shareScan")
        let sheet = app.otherElements["ActivityListView"]
        let found = sheet.waitForExistence(timeout: 10)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "shareSheet"
        shot.lifetime = .keepAlways
        add(shot)
        if !found {
            add(XCTAttachment(string: app.debugDescription))
        }
        XCTAssertTrue(found, "the share sheet never appeared")
    }

    @MainActor
    private func check(_ name: String, arguments: [String], screen: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoFreeze"] + arguments
        app.launch()
        defer { app.terminate() }
        guard element(app, "screen.\(screen)").waitForExistence(timeout: 15) else {
            XCTFail("\(name): screen.\(screen) never appeared")
            return
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if Self.shareStates.contains(where: { name == $0 || name == "\($0)-AX5" }) {
            XCTAssertTrue(element(app, "action.shareScan").exists, "\(name): Share scan is missing")
        }
        if let expected = Self.expectations[name.hasSuffix("-AX5") ? String(name.dropLast(4)) : name] {
            let found: Bool
            if let identifier = expected.identifier {
                let target = element(app, identifier)
                found = target.label.contains(expected.text) || (target.value as? String)?.contains(expected.text) == true
            } else {
                found = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected.text)).firstMatch.exists
            }
            XCTAssertTrue(found, "\(name): \"\(expected.text)\" is missing")
        }
        for identifier in Self.controls[name.hasSuffix("-AX5") ? String(name.dropLast(4)) : name] ?? [] {
            XCTAssertTrue(element(app, identifier).exists, "\(name): \(identifier) is missing")
        }
        // A system banner can slide over the app mid-audit (CI's Simulator showed "Ready for Apple
        // Intelligence" over the photo count), so an issue fails the test only when a second
        // audit, after the banner's few seconds on screen, finds it again.
        let first = try audit(app)
        guard !first.isEmpty else { return }
        Thread.sleep(forTimeInterval: 6)
        revealCutOff(first.values.compactMap(\.frame), in: app)
        let second = try audit(app)
        for key in AuditIssueKey.repeated(first, second) {
            XCTFail("\(name): \(second[key]?.message ?? key)")
        }
    }

    private struct Issue {
        var message: String
        var frame: CGRect?
    }

    /// Issues keyed by `AuditIssueKey`. A failed snapshot (the tree changed while the
    /// audit read it) is retried once; a second failure throws.
    @MainActor
    private func audit(_ app: XCUIApplication) throws -> [String: Issue] {
        func run() throws -> [String: Issue] {
            var found: [String: Issue] = [:]
            try app.performAccessibilityAudit { issue in
                let element = issue.element.map { "id '\($0.identifier)' label '\($0.label)'" } ?? "no element"
                let key = AuditIssueKey.key(auditType: issue.auditType.rawValue, identifier: issue.element?.identifier, label: issue.element?.label)
                found[key] = Issue(message: "\(issue.compactDescription) (\(element))", frame: issue.element?.frame)
                return true
            }
            return found
        }
        do {
            return try run()
        } catch {
            Thread.sleep(forTimeInterval: 1)
            return try run()
        }
    }

    /// At the largest text sizes a camera screen scrolls, and a control cut off by the bottom edge
    /// is audited on the sliver that shows, which fails contrast however it is drawn (a few
    /// points of a button's top edge over the camera). A homeowner would scroll to it, so before
    /// the second audit the screen scrolls until every flagged element that crosses the bottom
    /// edge is in full view; one that still fails there fails the test.
    @MainActor
    private func revealCutOff(_ frames: [CGRect], in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        guard let lowest = frames.filter({ $0.minY < screen.maxY && $0.maxY > screen.maxY }).map(\.maxY).max() else { return }
        let distance = min(lowest - screen.maxY + 60, screen.height * 0.5)
        // A slow drag from mid-screen: it scrolls by about the distance dragged, without the
        // momentum a swipe adds.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)), withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 20) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing \(identifier)")
        target.tap()
    }
}
