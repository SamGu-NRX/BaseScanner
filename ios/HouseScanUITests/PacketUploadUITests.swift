import XCTest

/// Sending the capture packet: the result's offer, the consent screen and the progress card, in
/// demo mode (`-uiDemo`, which fakes the transfer and sends nothing), and one end-to-end run
/// through the Debug-only test intake when HOUSESCAN_PACKET_STUB_URL names a running stub.
///
/// Environment (as TEST_RUNNER_<NAME> to xcodebuild):
/// - HOUSESCAN_PACKET_STUB_URL: a running `ios/Tools/packet-intake-test-stub.py`, for
///   `testSendsToTheStubAndResumesAfterRelaunch`. Never a real bucket or server.
/// - HOUSESCAN_SHOTS_DIR: also write the consent and progress screenshots there as PNG.
final class PacketUploadUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    /// A demo endpoint: the demo engine never connects to it.
    private static let demoEndpoint = ["-packetUploadURL", "http://127.0.0.1:9"]
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        continueAfterFailure = false
    }

    /// With no endpoint configured the result offers nothing, however far it scrolls.
    @MainActor
    func testNoEndpointOffersNothing() throws {
        let app = launch(["-uiDemoPhase", "result"])
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 15))
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertTrue(element(app, "action.startOver").exists, "the result never scrolled to its end")
        XCTAssertFalse(element(app, "packet.card").exists, "a packet card showed with no endpoint")
        XCTAssertFalse(element(app, "action.packetReview").exists)
        XCTAssertFalse(element(app, "screen.packetConsent").exists)
    }

    /// The consent screen opens from the result with the toggle off and Send disabled; Send
    /// works once the toggle is on, and the result then shows the progress. Each step passes
    /// the accessibility audit.
    @MainActor
    func testConsentStartsOffAndSendShowsProgress() throws {
        let app = launch(["-uiDemoPhase", "result"] + Self.demoEndpoint)
        let consent = try openConsent(app)
        let toggle = consent.switches.firstMatch
        XCTAssertTrue(toggle.exists, "no consent toggle")
        XCTAssertEqual(toggle.value as? String, "0", "the consent toggle must start off")
        let send = element(app, "action.packetSend")
        XCTAssertFalse(send.isEnabled, "Send must be disabled until the toggle is on")
        XCTAssertTrue(element(app, "action.packetSkip").isEnabled)
        try snapshot(app, "23-packet-consent")
        try audit(app, "consent")

        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(send.isEnabled, "Send stays disabled with the toggle on")
        try snapshot(app, "24-packet-consent-on")
        try audit(app, "consent-on")

        send.tap()
        XCTAssertTrue(consent.waitForNonExistence(timeout: 5), "the consent screen stayed up after Send")
        let progress = element(app, "packet.progress")
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "no progress after Send")
        XCTAssertTrue(progress.label.contains("files sent"), progress.label)
        reveal(element(app, "packet.card"), in: app)
        try snapshot(app, "25-packet-sending")
        try audit(app, "sending")
    }

    @MainActor
    func testConsentPassesTheAuditAtTheLargestTextSize() throws {
        let app = launch(["-uiDemoPhase", "result"] + Self.demoEndpoint + Self.largestText)
        let consent = try openConsent(app)
        try snapshot(app, "packet-consent-AX5", export: false)
        try audit(app, "consent-AX5")
        // Every control is reachable by scrolling, and the toggle still starts off.
        let toggle = consent.switches.firstMatch
        XCTAssertEqual(toggle.value as? String, "0")
        reveal(element(app, "action.packetSkip"), in: app)
        XCTAssertTrue(element(app, "action.packetSkip").isHittable)
        try audit(app, "consent-AX5-end")
    }

    /// Skip sends nothing and leaves a way back to the consent screen.
    @MainActor
    func testSkipKeepsTheOfferOpen() throws {
        let app = launch(["-uiDemoPhase", "result"] + Self.demoEndpoint)
        _ = try openConsent(app)
        element(app, "action.packetSkip").tap()
        XCTAssertTrue(element(app, "screen.packetConsent").waitForNonExistence(timeout: 5))
        XCTAssertFalse(element(app, "packet.progress").exists, "Skip started a transfer")
        XCTAssertTrue(element(app, "action.packetReview").exists, "no way back after Skip")
    }

    /// Every state of the card on the result, at the default size and at AX5.
    @MainActor
    func testCardStatesPassTheAudit() throws {
        for state in ["offered", "sending", "waiting", "sent", "failed", "skipped"] {
            for large in [false, true] {
                let name = "card-\(state)\(large ? "-AX5" : "")"
                let app = launch(["-uiDemoPhase", "result", "-uiDemoPacket", state] + Self.demoEndpoint + (large ? Self.largestText : []))
                XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 15), name)
                let card = element(app, "packet.card")
                reveal(card, in: app)
                XCTAssertTrue(card.exists, "\(name): no card")
                if state == "failed" { XCTAssertTrue(element(app, "action.packetRetry").exists, "\(name): no Try again") }
                try snapshot(app, name, export: false)
                try audit(app, name)
                app.terminate()
            }
        }
    }

    // MARK: End to end, against the local stub

    /// A replay scan, opt in, then the app is killed partway through the upload and launched
    /// again: the relaunch begins the session again and sends only what the stub doesn't have,
    /// and the stub takes the whole packet.
    @MainActor
    func testSendsToTheStubAndResumesAfterRelaunch() throws {
        guard let stub = Self.environment["HOUSESCAN_PACKET_STUB_URL"], !stub.isEmpty else {
            throw XCTSkip("Set HOUSESCAN_PACKET_STUB_URL to a running ios/Tools/packet-intake-test-stub.py to run this test.")
        }
        try stubCall(stub, "POST", "/_reset")
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gate) }

        let app = XCUIApplication()
        app.launchArguments = ["-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "0.6", "-autopilotGate", gate.path,
                               "-sampleResult", "-packetUploadURL", stub, "-packetIntake", "localTest"]
        app.launch()
        // Let the autopilot through every screen up to the result, and hold it there.
        for phase in FullFlowUITests.flow.prefix(while: { $0 != "result" }) {
            XCTAssertTrue(element(app, "screen.\(phase)").waitForExistence(timeout: phase == "markFeatures" ? 150 : 60), "screen.\(phase)")
            try Data().write(to: gate.appending(path: phase))
        }
        XCTAssertTrue(element(app, "screen.result").waitForExistence(timeout: 150))
        let consent = try openConsent(app)
        consent.switches.firstMatch.switches.firstMatch.tap()
        element(app, "action.packetSend").tap()

        // Kill the app once some files are stored and some aren't.
        var log = try stubLog(stub)
        let deadline = Date().addingTimeInterval(60)
        while (log["stored"] as? [String] ?? []).count < 3, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            log = try stubLog(stub)
        }
        let files = log["files"] as? Int ?? 0
        let storedAtKill = (log["stored"] as? [String] ?? []).count
        XCTAssertGreaterThan(files, storedAtKill, "the upload finished before the app could be killed")
        app.terminate()

        // Launched again with the same endpoint and no autopilot: it resumes on its own.
        let again = XCUIApplication()
        again.launchArguments = ["-packetUploadURL", stub, "-packetIntake", "localTest", "-sampleResult"]
        again.launch()
        let finished = Date().addingTimeInterval(180)
        repeat {
            Thread.sleep(forTimeInterval: 0.5)
            log = try stubLog(stub)
        } while (log["completed"] as? Bool) != true && Date() < finished
        let report = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        report.name = "stub-log"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertEqual(log["completed"] as? Bool, true, "the stub never took the whole packet")
        let begins = log["begins"] as? [[String: Any]] ?? []
        XCTAssertGreaterThanOrEqual(begins.count, 2, "no begin after the relaunch")
        XCTAssertEqual(begins.last?["resuming"] as? String, "test-session", "the relaunch didn't resume the saved session")
        // Uploads to the relaunch's targets send only files the stub didn't have when it began.
        for session in begins.dropFirst() {
            let generation = session["generation"] as? Int ?? 0
            let storedThen = Set(session["stored"] as? [String] ?? [])
            let sent = (log["puts"] as? [[String: Any]] ?? []).filter { $0["generation"] as? Int == generation }.compactMap { $0["path"] as? String }
            XCTAssertTrue(storedThen.isDisjoint(with: sent), "re-sent stored files: \(storedThen.intersection(sent))")
        }
        XCTAssertEqual((log["stored"] as? [String] ?? []).count, files)
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiDemo", "-uiDemoFreeze"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func openConsent(_ app: XCUIApplication) throws -> XCUIElement {
        let review = element(app, "action.packetReview")
        XCTAssertTrue(review.waitForExistence(timeout: 20), "no packet offer on the result")
        reveal(review, in: app)
        review.tap()
        let consent = element(app, "screen.packetConsent")
        XCTAssertTrue(consent.waitForExistence(timeout: 5), "the consent screen never opened")
        // The sheet's rise, before screenshots and audits.
        Thread.sleep(forTimeInterval: 0.8)
        return consent
    }

    /// Scrolls until `target` is fully on screen.
    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        var tries = 0
        while target.exists, tries < 8, !(target.isHittable && screen.contains(target.frame)) {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -screen.height * 0.35)), withVelocity: .slow, thenHoldForDuration: 0.3)
            tries += 1
        }
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String, export: Bool = true) throws {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if export, let dir = Self.environment["HOUSESCAN_SHOTS_DIR"], !dir.isEmpty {
            try shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }

    /// Fails on accessibility issues found twice, a few seconds apart: a system banner can slide
    /// over the app for one audit (see ScreenStatesUITests).
    @MainActor
    private func audit(_ app: XCUIApplication, _ name: String) throws {
        func run() throws -> [String: String] {
            var found: [String: String] = [:]
            try app.performAccessibilityAudit { issue in
                let key = "\(issue.auditType.rawValue)|\(issue.element?.identifier ?? "")|\(issue.element?.label ?? "")"
                let element = issue.element.map { "type \($0.elementType.rawValue) id '\($0.identifier)' label '\($0.label)' frame \($0.frame)" } ?? "no element"
                found[key] = "\(issue.compactDescription) (\(element))"
                return true
            }
            return found
        }
        let first = try run()
        guard !first.isEmpty else { return }
        Thread.sleep(forTimeInterval: 6)
        let second = try run()
        for key in first.keys.sorted() where second[key] != nil {
            XCTFail("\(name): \(second[key] ?? key)")
        }
    }

    private func stubLog(_ stub: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: stubCall(stub, "GET", "/_log")) as? [String: Any])
    }

    @discardableResult
    private func stubCall(_ stub: String, _ method: String, _ path: String) throws -> Data {
        final class Box: @unchecked Sendable { var result: Result<Data, any Error> = .failure(URLError(.timedOut)) }
        var request = URLRequest(url: try XCTUnwrap(URL(string: stub + path)))
        request.httpMethod = method
        request.timeoutInterval = 10
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            box.result = error.map { .failure($0) } ?? .success(data ?? Data())
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return try box.result.get()
    }
}
