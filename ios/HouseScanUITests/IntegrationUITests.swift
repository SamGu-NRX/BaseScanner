#if HOUSESCAN_INTEGRATION
import XCTest

/// The integration build's capture gates in the running app, on the synthetic replay: what it
/// asks, when, and what reaches a capture API. The API is ios/Tools/capture-receiver.py on this
/// Mac's loopback, which logs every request per run; start it before the tests. Nothing here
/// talks to a remote server.
///
/// Compiled only into the Integration configurations (`HOUSESCAN_INTEGRATION`), so the client
/// scheme's test run never contains it. A replay is sent only to a receiver on this machine and
/// only with `-captureSendReplayToLocalReceiver`; the device-data switch that governs camera
/// captures is checked in the build settings, not here (the Simulator has no camera session).
final class IntegrationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// One test's endpoint on the receiver, and the requests it logged for it.
    struct Receiver {
        static let environment = ProcessInfo.processInfo.environment
        static let base = environment["HSI_CAPTURE_RECEIVER"] ?? "http://127.0.0.1:8767"
        static let logDir = environment["HSI_CAPTURE_RECEIVER_LOG"] ?? "/Users/Shared/hsi-capture-receiver"
        let run = UUID().uuidString.lowercased()

        var endpoint: URL { URL(string: "\(Self.base)/\(run)/v1")! }

        /// Every logged request of this run, as the receiver wrote them.
        func requests(_ route: String? = nil) -> [[String: Any]] {
            guard let text = try? String(contentsOfFile: "\(Self.logDir)/\(run).jsonl", encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }.filter { route == nil || $0["route"] as? String == route }
        }

        /// Fails the test unless the receiver answers, so "nothing was sent" can't pass because
        /// nothing could have been.
        static func started() throws -> Receiver {
            var request = URLRequest(url: URL(string: "\(base)/health")!)
            request.timeoutInterval = 5
            let answered = XCTestExpectation(description: "receiver health")
            var status = 0
            URLSession.shared.dataTask(with: request) { _, response, _ in
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                answered.fulfill()
            }.resume()
            _ = XCTWaiter().wait(for: [answered], timeout: 6)
            guard status == 200 else {
                // A failure, not a skip: a run whose tests all skipped would still report success.
                XCTFail("Start ios/Tools/capture-receiver.py first: \(base)/health did not answer 200 (got \(status)).")
                throw URLError(.cannotConnectToHost)
            }
            return Receiver()
        }
    }

    /// Screens the autopilot walks through, up to the result.
    static let flow = ["onboarding", "findMeter", "meterCloseUp", "wallWalk", "markFeatures", "gapRequest", "uploading", "result"]

    struct Run {
        let app: XCUIApplication
        let gate: URL

        /// Waits for `phase`, then lets the autopilot leave it.
        func pass(_ phase: String, timeout: TimeInterval = 150) throws {
            XCTAssertTrue(app.descendants(matching: .any)["screen.\(phase)"].waitForExistence(timeout: timeout), "screen.\(phase) never appeared")
            try Data().write(to: gate.appending(path: phase))
        }

        func waitFor(_ phase: String, timeout: TimeInterval = 60) {
            XCTAssertTrue(app.descendants(matching: .any)["screen.\(phase)"].waitForExistence(timeout: timeout), "screen.\(phase) never appeared")
        }

        var send: XCUIElement { app.buttons["captureConsent.send"] }
        var skip: XCUIElement { app.buttons["captureConsent.skip"] }
        var agree: XCUIElement { app.switches["captureConsent.agree"] }
    }

    @MainActor
    private func launch(endpoint: URL?, sendReplay: Bool) throws -> Run {
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: gate) }
        var arguments = ["-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "1.5", "-autopilotGate", gate.path, "-sampleResult"]
        if let endpoint { arguments += ["-captureAPIURL", endpoint.absoluteString] }
        if sendReplay { arguments.append("-captureSendReplayToLocalReceiver") }
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return Run(app: app, gate: gate)
    }

    /// Runs the rest of the scan to the result without answering anything.
    private func finish(_ run: Run, from phase: String) throws {
        for next in Self.flow.drop(while: { $0 != phase }) { try run.pass(next) }
    }

    /// No endpoint in the build or the launch: nothing is asked, nothing shown, nothing sent.
    @MainActor
    func testWithoutAnEndpointNothingIsAskedOrSent() throws {
        let server = try Receiver.started()
        let run = try launch(endpoint: nil, sendReplay: true)
        try run.pass("onboarding")
        run.waitFor("findMeter")
        XCTAssertFalse(run.send.waitForExistence(timeout: 3), "the consent question appeared without an endpoint")
        try finish(run, from: "findMeter")
        XCTAssertFalse(run.app.descendants(matching: .any)["captureSyncLine"].exists)
        XCTAssertTrue(server.requests().isEmpty)
    }

    /// An endpoint, but a capture that may not be sent there (the replay without its switch, as a
    /// camera capture without the device-data switch): recorded on the phone, nothing asked or sent.
    @MainActor
    func testACaptureThatMayNotBeSentStaysOnThePhone() throws {
        let server = try Receiver.started()
        let run = try launch(endpoint: server.endpoint, sendReplay: false)
        try run.pass("onboarding")
        run.waitFor("findMeter")
        XCTAssertFalse(run.send.waitForExistence(timeout: 3), "the consent question appeared for a capture that may not be sent")
        try finish(run, from: "findMeter")
        XCTAssertTrue(server.requests().isEmpty)
    }

    /// `-replay` with no folder after it starts no replay (the engine's own parse), so the replay's
    /// local-receiver exception must not apply: no question, nothing sent. The Simulator has no
    /// camera session, so this run stops at the unsupported screen.
    @MainActor
    func testADanglingReplayFlagGetsNoReplayException() throws {
        let server = try Receiver.started()
        let app = XCUIApplication()
        app.launchArguments = ["-sampleResult", "-captureAPIURL", server.endpoint.absoluteString, "-captureSendReplayToLocalReceiver", "-replay"]
        app.launch()
        XCTAssertFalse(app.buttons["captureConsent.send"].waitForExistence(timeout: 8), "a dangling -replay got the replay's send exception")
        XCTAssertTrue(server.requests().isEmpty)
    }

    /// The question comes before the meter is marked, with the toggle off and Send disabled; Skip
    /// sends nothing for the whole scan.
    @MainActor
    func testTheQuestionStartsOffAndSkipSendsNothing() throws {
        let server = try Receiver.started()
        let run = try launch(endpoint: server.endpoint, sendReplay: true)
        try run.pass("onboarding")
        run.waitFor("findMeter")
        XCTAssertTrue(run.send.waitForExistence(timeout: 20), "no consent question before the meter was marked")
        XCTAssertEqual(run.agree.value as? String, "0", "the toggle started on")
        XCTAssertFalse(run.send.isEnabled, "Send was enabled before the toggle was on")
        attach(run.app, "consent-initial")
        run.skip.tap()
        XCTAssertTrue(run.send.waitForNonExistence(timeout: 10), "Skip left the question up")
        try finish(run, from: "findMeter")
        XCTAssertTrue(server.requests().isEmpty)
    }

    /// A yes before the scan sends its photos during the walk; the next scan asks again.
    @MainActor
    func testAYesSendsDuringTheScanAndANewScanAsksAgain() throws {
        let server = try Receiver.started()
        let run = try launch(endpoint: server.endpoint, sendReplay: true)
        try run.pass("onboarding")
        run.waitFor("findMeter")
        XCTAssertTrue(run.send.waitForExistence(timeout: 20))
        // A SwiftUI toggle row flips from its switch, at the trailing edge.
        run.agree.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(run.agree.value as? String, "1")
        XCTAssertTrue(run.send.isEnabled)
        run.send.tap()
        XCTAssertTrue(run.send.waitForNonExistence(timeout: 10))

        for phase in ["findMeter", "meterCloseUp", "wallWalk"] { try run.pass(phase) }
        // Still scanning: the photos kept so far are already acknowledged by the receiver.
        run.waitFor("markFeatures", timeout: 150)
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.requests("POST captures/files:commit").contains { ($0["commitFiles"] as? Int ?? 0) > 0 }
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [committed], timeout: 60), .completed, "no photo was committed while the scan was under way")
        XCTAssertEqual(server.requests("POST captures").count, 1)
        XCTAssertTrue(server.requests("PUT upload").allSatisfy { $0["authorization"] as? Bool == false && $0["contentMD5"] as? Bool == true })
        attach(run.app, "sending-during-scan")
        try finish(run, from: "markFeatures")

        // A new scan: the question again, off again, and nothing more sent until it is answered.
        let creates = server.requests("POST captures").count
        run.app.buttons["action.startOver"].firstMatch.tap()
        run.waitFor("onboarding")
        // Skip jumps to the last page; the scan starts from its "Allow camera" button.
        run.app.buttons["action.onboardingSkip"].tap()
        XCTAssertTrue(run.app.buttons["action.finishOnboarding"].waitForExistence(timeout: 10))
        run.app.buttons["action.finishOnboarding"].tap()
        run.waitFor("findMeter")
        XCTAssertTrue(run.send.waitForExistence(timeout: 20), "the new scan did not ask again")
        XCTAssertEqual(run.agree.value as? String, "0")
        XCTAssertFalse(run.send.isEnabled)
        XCTAssertEqual(server.requests("POST captures").count, creates)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
#endif
