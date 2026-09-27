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
        // All three legend entries under the map at once (end preview, hidden, depth): they
        // overlapped in one row on CI's LiDAR walk (run 36307476187).
        ("wallWalk-fullLegend", ["-uiDemoPhase", "wallWalk", "-uiDemoEndPreview", "-uiDemoHidden"], "wallWalk"),
        ("markFeatures", ["-uiDemoPhase", "markFeatures"], "markFeatures"),
        ("markFeatures-marking", ["-uiDemoPhase", "markFeatures", "-uiDemoMarking", "door"], "markFeatures"),
        ("markFeatures-lostPlace", ["-uiDemoPhase", "markFeatures", "-uiDemoCoaching", "relocalizing"], "markFeatures"),
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
        ("spotConfirm", ["-uiDemoPhase", "spotConfirm"], "spotConfirm"),
        ("spotConfirm-which", ["-uiDemoPhase", "spotConfirm", "-uiDemoSpotStep", "which"], "spotConfirm"),
        ("spotConfirm-ground", ["-uiDemoPhase", "spotConfirm", "-uiDemoSpotStep", "ground"], "spotConfirm"),
        ("spotConfirm-answered", ["-uiDemoPhase", "spotConfirm", "-uiDemoSpotStep", "ground", "-uiDemoSpotAnswered", "clear"], "spotConfirm"),
        ("spotConfirm-cantMark", ["-uiDemoPhase", "spotConfirm", "-uiDemoSpotStep", "which", "-uiDemoSpotAnswered", "cantMark"], "spotConfirm"),
        ("spotConfirm-unconfirmable", ["-uiDemoPhase", "spotConfirm", "-uiDemoSpotUnconfirmable"], "spotConfirm"),
        ("result-review", ["-uiDemoPhase", "result"], "result"),
        ("result-pass", ["-uiDemoPhase", "result", "-uiDemoPass"], "result"),
        ("result-corner", ["-uiDemoPhase", "result", "-uiDemoCorner"], "result"),
        ("result-overlap", ["-uiDemoPhase", "result", "-uiDemoOverlap"], "result"),
        ("result-reject", ["-uiDemoPhase", "result", "-uiDemoResultFile", resultFile("reject-nearest")], "result"),
        ("resultAR", ["-uiDemoPhase", "resultAR"], "resultAR"),
        ("cameraDenied", ["-uiDemoFailure", "cameraDenied"], "unsupported"),
        ("arUnsupported", ["-uiDemoFailure", "arUnsupported"], "unsupported"),
        ("sessionFailed", ["-uiDemoFailure", "sessionFailed"], "unsupported"),
        ("replayUnreadable", ["-uiDemoFailure", "replayUnreadable"], "unsupported"),
    ]

    /// A server answer in Fixtures/results, which the demo reads in debug builds.
    private static func resultFile(_ name: String, file: String = #filePath) -> String {
        URL(fileURLWithPath: file).deletingLastPathComponent().appending(path: "Fixtures/results/\(name).json").path
    }

    /// The screens with the most text, also checked at AX5.
    private static let largestTextStates: Set<String> = [
        "onboarding", "wallWalk", "wallWalk-endQuestion", "wallWalk-endPreview", "wallWalk-nextWallRefused", "wallWalk-overheadQuestion", "gapRequest-walkOut", "gapRequest-overheadQuestion", "meterCloseUp-cantGetClearShot", "meterCloseUp-chooseNumber",
        "markFeatures", "gapRequest", "uploading-offline", "uploading-rejected", "result-review", "cameraDenied",
        "wallWalk-hidden", "wallWalk-seeBehind", "wallWalk-fullLegend", "gapRequest-followUp", "uploading-followUp",
        "markFeatures-lostPlace",
        "spotConfirm", "spotConfirm-which", "spotConfirm-ground", "spotConfirm-answered", "spotConfirm-cantMark", "spotConfirm-unconfirmable",
    ]

    /// Words a state must show: in the named element's label or value, or with no identifier,
    /// in any text on screen.
    private static let expectations: [String: (identifier: String?, text: String)] = [
        "wallWalk-hidden": ("wallTape", "2 sections hidden behind something"),
        "wallWalk-fullLegend": ("wallTape", "2 sections hidden behind something"),
        "wallWalk-seeBehind": ("instruction", "Something is in front of the wall here"),
        "gapRequest-followUp": ("instruction", "One more view to finish"),
        "uploading-followUp": (nil, "One more view to finish"),
        "markFeatures-lostPlace": ("review.lostPlace", "Your phone lost its place"),
        // The spot check asks one question over a photo VoiceOver describes, then says the answer.
        "spotConfirm": ("spot.question", "Is anything in the marked area?"),
        "spotConfirm-which": ("spot.question", "Which one isn't marked?"),
        "spotConfirm-ground": ("spot.question", "What's the ground where the battery would stand?"),
        "spotConfirm-answered": ("spot.answered", "Thanks, it's mulch"),
        "spotConfirm-cantMark": ("spot.answered", "can't be marked now"),
        "spotConfirm-unconfirmable": ("spot.question", "Your photos don't show all of this area"),
        // #40: an overlap reads as one, not as clearance.
        "result-overlap": ("check.meter_working_space", "Overlaps by 1 foot. The rule is no overlap"),
        // The answer comes from the checks: an unsure ground check a view settles.
        "result-review": ("result.headline", "One more look"),
        // A reject names the closest spot and the check it fails.
        "result-reject": ("result.nearest", "The closest spot"),
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

    /// The brand read on the close-up is only offered: "Not <brand>" removes it and leaves the
    /// number candidates to answer.
    @MainActor
    func testRejectingTheMeterBrandKeepsTheNumbers() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "meterCloseUp", "-uiDemoMeterChoose"]
        app.launch()
        XCTAssertTrue(element(app, "meter.brand").waitForExistence(timeout: 15))
        tap(app, "action.rejectMeterBrand")
        XCTAssertTrue(element(app, "meter.brand").waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "meter.candidate.0").exists)
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
        // The demo's close-up shows the picker 4.5 s after it opens. 30 s, not 15: on CI run
        // 36307476187 the Simulator's push daemon spun in a reconnect loop and the app's main
        // thread got no time for 14.6 s (09:42:19.6 to 09:42:34.2 in its log), so the picker
        // would have come at about 17.3 s, just after the old limit.
        tap(app, "meter.candidate.0", timeout: 30)
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
        tap(app, "window.opens.no")
        tap(app, "action.confirmFeatures")
        XCTAssertTrue(element(app, "screen.gapRequest").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "screen.uploading").waitForExistence(timeout: 20))
        // The answer lists a view the camera can take: the scan goes back to the camera for it
        // on its own, and the result follows that view.
        let followUp = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'instruction' AND label CONTAINS 'One more view to finish'")).firstMatch
        XCTAssertTrue(followUp.waitForExistence(timeout: 20), "the answer's view must be asked for on the camera")
        // Before the result, the spot is checked on a photo.
        XCTAssertTrue(element(app, "screen.spotConfirm").waitForExistence(timeout: 30))
        XCTAssertEqual(element(app, "spot.photo").label, "Photo of your wall")
        tap(app, "action.spotClear")
        // Then the ground where the battery would stand; a type goes to the server once more.
        tap(app, "ground.answer.gravel")
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 40))
        XCTAssertTrue(element(app, "result.sampleBadge").exists, "a sample result must say so")
        XCTAssertTrue(element(app, "result.rulesNotFinal").exists, "placeholder rules must be disclosed")
        // B-14: a limit says whether it is a minimum or a maximum. The unit is left off: VoiceOver
        // text spells lengths out ("3 feet") once B-16 lands, the screen text says "3 ft".
        // One read (`ElementRead`): the result's content is still settling in.
        let window = ElementRead.snapshot(element(app, "check.window"))?.value as? String
        XCTAssertTrue(window?.contains("The rule is at least 3") == true,
                      "the window rule must read as a minimum, got \(String(describing: window))")
        // The result reveal slides its content in; a tap while it moves can miss (one failure in
        // three local runs), so wait until the button takes taps.
        let showAR = element(app, "action.showAR")
        XCTAssertTrue(showAR.waitForExistence(timeout: 20), "missing action.showAR")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: showAR)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 10), .completed, "action.showAR never took taps")
        showAR.tap()
        XCTAssertTrue(element(app, "screen.resultAR").waitForExistence(timeout: 10))
        tap(app, "action.closeAR")
        // Start over sits under Details, last.
        tap(app, "result.details", timeout: 10)
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

    /// The review no longer asks about the ground. The spot check does, once the homeowner says
    /// the area is clear: the seven answers replace the first question's three, "A gas meter, AC,
    /// window or door" asks which and Back returns, and an answer ends the check.
    @MainActor
    func testSpotCheckAsksTheGroundOnceTheAreaIsClear() throws {
        continueAfterFailure = false
        let review = XCUIApplication()
        review.launchArguments = ["-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "markFeatures"]
        review.launch()
        XCTAssertTrue(element(review, "screen.markFeatures").waitForExistence(timeout: 15))
        XCTAssertFalse(element(review, "ground.answer.mulch").exists, "the review must not ask about the ground")
        review.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "spotConfirm"]
        app.launch()
        XCTAssertTrue(element(app, "screen.spotConfirm").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "ground.answer.mulch").exists, "the ground waits for the area")
        tap(app, "action.spotUnmarked")
        for kind in ["gas_meter", "ac", "window", "door"] {
            XCTAssertTrue(element(app, "spot.unmarked.\(kind)").waitForExistence(timeout: 5), "missing spot.unmarked.\(kind)")
        }
        tap(app, "action.spotBack")
        tap(app, "action.spotClear", timeout: 5)
        for id in ["lawn", "mulch", "gravel", "concrete", "drive", "deck", "notSure"] {
            XCTAssertTrue(element(app, "ground.answer.\(id)").waitForExistence(timeout: 5), "missing ground.answer.\(id)")
        }
        XCTAssertFalse(element(app, "action.spotClear").exists)
        tap(app, "ground.answer.gravel")
        let answered = element(app, "spot.answered")
        XCTAssertTrue(answered.waitForExistence(timeout: 5))
        XCTAssertTrue(ElementRead.snapshot(answered)?.label.contains("Thanks, it's gravel") == true)
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
        tap(app, "action.spotClear", timeout: 40)
        tap(app, "ground.answer.notSure")
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 20))
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
            // The result keeps Share scan under Details.
            if screen == "result" { tap(app, "result.details") }
            XCTAssertTrue(element(app, "action.shareScan").waitForExistence(timeout: 5), "\(name): Share scan is missing")
        }
        if let expected = Self.expectations[name.hasSuffix("-AX5") ? String(name.dropLast(4)) : name] {
            let found: Bool
            if let identifier = expected.identifier {
                let target = ElementRead.snapshot(element(app, identifier))
                found = target.map { $0.label.contains(expected.text) || ($0.value as? String)?.contains(expected.text) == true } ?? false
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
        let outcome = try AccessibilityAudit.run(app) { first in
            Thread.sleep(forTimeInterval: 6)
            revealCutOff(first.findings.values.compactMap(\.frame), in: app)
        }
        if !outcome.unread.isEmpty {
            let note = XCTAttachment(string: outcome.unread.joined(separator: "\n"))
            note.name = "\(name)-element-gone"
            note.lifetime = .keepAlways
            add(note)
        }
        for (_, finding) in outcome.persistent {
            XCTFail("\(name): \(finding.message)")
        }
        // After the audit, so its scrolling can't change what the audit saw: a control that
        // exists can still sit past the bottom edge, out of the homeowner's reach. At the default
        // size it must be tappable where it is; at AX5 the screen scrolls, so after scrolling to it
        // (#39: "Show my result" sits below the tape there).
        for identifier in Self.controls[name.hasSuffix("-AX5") ? String(name.dropLast(4)) : name] ?? [] {
            let target = element(app, identifier)
            guard target.exists else { continue }
            let reached = name.hasSuffix("-AX5") ? scrollUntilHittable(target, in: app) : target.isHittable
            XCTAssertTrue(reached, "\(name): \(identifier) can't be tapped")
        }
    }

    /// Drags the screen up, at most four times, until the control can be tapped. The same slow
    /// drag as `revealCutOff`, so it scrolls without momentum.
    @MainActor
    private func scrollUntilHittable(_ target: XCUIElement, in app: XCUIApplication) -> Bool {
        let step = app.windows.firstMatch.frame.height * 0.4
        for _ in 0..<4 {
            if target.isHittable { return true }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -step)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        return target.isHittable
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

    /// Taps once the element exists, after giving it a moment to become hittable. A control that
    /// has just appeared can still be moving into place (the walk's controls settle after the
    /// close-up), and a tap there misses without an error (the button flow at 577acc4 never
    /// opened the mark tray). An element below the fold of a scroll view never becomes hittable
    /// on its own, and `tap()` scrolls it into view, so after the short wait it is tapped anyway.
    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 20) {
        let target = element(app, identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing \(identifier)")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: target)
        _ = XCTWaiter().wait(for: [hittable], timeout: 3)
        target.tap()
    }
}
