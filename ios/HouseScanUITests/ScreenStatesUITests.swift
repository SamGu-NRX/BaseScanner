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
        ("wallWalk-nextWall", ["-uiDemoPhase", "wallWalk", "-uiDemoNextWall"], "wallWalk"),
        ("wallWalk-nextWallRefused", ["-uiDemoPhase", "wallWalk", "-uiDemoNextWall", "-uiDemoRefusal"], "wallWalk"),
        ("wallWalk-tiltUp", ["-uiDemoPhase", "wallWalk", "-uiDemoTiltUp"], "wallWalk"),
        ("wallWalk-overheadQuestion", ["-uiDemoPhase", "wallWalk", "-uiDemoOverheadQuestion"], "wallWalk"),
        ("markFeatures", ["-uiDemoPhase", "markFeatures"], "markFeatures"),
        ("markFeatures-marking", ["-uiDemoPhase", "markFeatures", "-uiDemoMarking", "door"], "markFeatures"),
        ("gapRequest", ["-uiDemoPhase", "gapRequest"], "gapRequest"),
        ("gapRequest-groundOut", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "groundOut"], "gapRequest"),
        ("gapRequest-walkOut", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "walkOut"], "gapRequest"),
        ("gapRequest-overhead", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "overhead"], "gapRequest"),
        ("gapRequest-overheadQuestion", ["-uiDemoPhase", "gapRequest", "-uiDemoGap", "overhead", "-uiDemoOverheadQuestion"], "gapRequest"),
        ("uploading", ["-uiDemoPhase", "uploading"], "uploading"),
        ("uploading-offline", ["-uiDemoPhase", "uploading", "-uiDemoOffline"], "uploading"),
        ("uploading-sample", ["-uiDemoPhase", "uploading", "-uiDemoSample"], "uploading"),
        ("uploading-rejected", ["-uiDemoPhase", "uploading", "-uiDemoRejected"], "uploading"),
        ("result-review", ["-uiDemoPhase", "result"], "result"),
        ("result-pass", ["-uiDemoPhase", "result", "-uiDemoPass"], "result"),
        ("resultAR", ["-uiDemoPhase", "resultAR"], "resultAR"),
        ("cameraDenied", ["-uiDemoFailure", "cameraDenied"], "unsupported"),
        ("arUnsupported", ["-uiDemoFailure", "arUnsupported"], "unsupported"),
        ("sessionFailed", ["-uiDemoFailure", "sessionFailed"], "unsupported"),
        ("replayUnreadable", ["-uiDemoFailure", "replayUnreadable"], "unsupported"),
    ]

    /// The screens with the most text, also checked at AX5.
    private static let largestTextStates: Set<String> = [
        "onboarding", "wallWalk", "wallWalk-endQuestion", "wallWalk-nextWallRefused", "wallWalk-overheadQuestion", "gapRequest-walkOut", "gapRequest-overheadQuestion", "meterCloseUp-cantGetClearShot", "meterCloseUp-chooseNumber",
        "markFeatures", "gapRequest", "uploading-offline", "uploading-rejected", "result-review", "cameraDenied",
    ]

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
        tap(app, "window.opens.no")
        tap(app, "action.confirmFeatures")
        XCTAssertTrue(element(app, "screen.gapRequest").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "screen.uploading").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "result.sampleBadge").exists, "a sample result must say so")
        XCTAssertTrue(element(app, "result.rulesNotFinal").exists, "placeholder rules must be disclosed")
        tap(app, "action.showAR")
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
        // A system banner can slide over the app mid-audit (CI's Simulator showed "Ready for Apple
        // Intelligence" over the photo count), so an issue fails the test only when a second
        // audit, after the banner's few seconds on screen, finds it again.
        let first = try audit(app)
        guard !first.isEmpty else { return }
        Thread.sleep(forTimeInterval: 6)
        let second = try audit(app)
        for key in first.keys.sorted() where second[key] != nil {
            XCTFail("\(name): \(second[key] ?? key)")
        }
    }

    /// Issues keyed by type, identifier and label. A failed snapshot (the tree changed while the
    /// audit read it) is retried once; a second failure throws.
    @MainActor
    private func audit(_ app: XCUIApplication) throws -> [String: String] {
        func run() throws -> [String: String] {
            var found: [String: String] = [:]
            try app.performAccessibilityAudit { issue in
                let element = issue.element.map { "id '\($0.identifier)' label '\($0.label)'" } ?? "no element"
                let key = "\(issue.auditType.rawValue)|\(issue.element?.identifier ?? "")|\(issue.element?.label ?? "")"
                found[key] = "\(issue.compactDescription) (\(element))"
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
