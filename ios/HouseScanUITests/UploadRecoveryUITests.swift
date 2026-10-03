import CryptoKit
import Foundation
import Synchronization
import XCTest

/// An answer House Scan can't use (it names another scene, or doesn't decode) is never shown, the
/// scan is kept, and only the homeowner's "Try again" asks again. A refused scan stays separate:
/// it goes back to the review (`ScreenStatesUITests.testRejectedUploadGoesBackToReview`).
final class UploadRecoveryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The real engine and its HTTP client, with the test as the placement server
    /// (`-answersFromGate`). The first answer names another scene. The second names the scene sent
    /// but has a result schema House Scan doesn't read. Every later one is the bundled sample
    /// naming the scene sent. The synthetic wall plays to the upload; neither unusable answer shows
    /// anything of itself, nothing is sent again until "Try again", the second says asking again
    /// might not help, and the third reaches the result.
    @MainActor
    func testUnusableAnswersAreHeldBackUntilTryAgain() throws {
        let sample = String(decoding: try Data(contentsOf: Self.sampleResult), as: UTF8.self)
        let zeros = String(repeating: "0", count: 64)
        let schema = "\"schema_version\": \"1.0\""
        XCTAssertTrue(sample.contains("\"input_sha256\": \"\(zeros)\""))
        XCTAssertTrue(sample.contains(schema))

        let files = FileManager.default
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: gate, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: gate) }
        // Every screen up to the result is let through; the result's gate stays shut, so the
        // autopilot stops there.
        for phase in ["onboarding", "findMeter", "meterCloseUp", "wallWalk", "markFeatures", "gapRequest", "uploading", "spotConfirm"] {
            try Data().write(to: gate.appending(path: phase))
        }
        let server = GateServer(gate: gate) { body, index in
            var answer = sample.replacingOccurrences(of: zeros, with: index == 0 ? Self.sha256(Data("another scene".utf8)) : Self.sha256(body))
            if index == 1 { answer = answer.replacingOccurrences(of: schema, with: "\"schema_version\": \"9.0\"") }
            return Data(answer.utf8)
        }
        defer { server.stop() }

        let app = XCUIApplication()
        app.launchArguments = [
            "-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "1.5", "-autopilotGate", gate.path,
            "-practiceMeter", "NO", "-serverURL", "http://placement.invalid", "-answersFromGate",
        ]
        app.launch()
        let any = app.descendants(matching: .any)
        let note = any["upload.answerNote"]
        let first = any.matching(NSPredicate(format: "label == %@", "We couldn't use the server's answer")).firstMatch
        let second = any.matching(NSPredicate(format: "label == %@", "The answer still couldn't be used")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 300), "the unbound answer never showed as an answer House Scan couldn't use")
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?.target, "POST /v1/placements")
        holdsWithoutAsking(app, requests: 1, server: server, shot: "uploading-unusableAnswer-engine-1")

        tap(app, "action.retryUpload")
        XCTAssertTrue(second.waitForExistence(timeout: 60), "the undecodable answer never showed as a second unusable answer")
        XCTAssertTrue(note.exists)
        XCTAssertEqual(server.requests.count, 2)
        holdsWithoutAsking(app, requests: 2, server: server, shot: "uploading-unusableAnswer-engine-2")

        tap(app, "action.retryUpload")
        XCTAssertTrue(any["screen.result"].waitForExistence(timeout: 240), "the answer after Try again never reached the result")
        XCTAssertGreaterThanOrEqual(server.requests.count, 3)
        XCTAssertTrue(server.requests.allSatisfy { $0.target == "POST /v1/placements" })
    }

    /// On an unusable answer: no "Back to review", a way to start over, and for six seconds no
    /// request beyond `requests` and nothing of the answer on a later screen.
    @MainActor
    private func holdsWithoutAsking(_ app: XCUIApplication, requests: Int, server: GateServer, shot name: String) {
        let any = app.descendants(matching: .any)
        XCTAssertFalse(any["action.backToReview"].exists, "an unusable answer must not send the homeowner back to their marks")
        XCTAssertTrue(any["action.startOver"].exists)
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(server.requests.count, requests, "the app asked again without a tap")
        XCTAssertTrue(any["upload.answerNote"].exists)
        XCTAssertFalse(any["screen.spotConfirm"].exists)
        XCTAssertFalse(any["screen.result"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The first unusable answer leads with "Try again"; the second says asking again might not
    /// help and points to sharing the scan. Both pass the accessibility audit, and neither offers
    /// the review.
    @MainActor
    func testRepeatedUnusableAnswersPointToAWayOut() throws {
        for attempts in [1, 2] {
            let app = XCUIApplication()
            app.launchArguments = ["-practiceMeter", "NO", "-uiDemo", "-uiDemoFreeze", "-uiDemoPhase", "uploading", "-uiDemoUnusableAnswer", "\(attempts)"]
            app.launch()
            let any = app.descendants(matching: .any)
            let note = any["upload.answerNote"]
            XCTAssertTrue(note.waitForExistence(timeout: 15))
            let title = attempts == 1 ? "We couldn't use the server's answer" : "The answer still couldn't be used"
            XCTAssertTrue(any.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists, "attempt \(attempts): title")
            XCTAssertEqual(note.label.contains("Share scan saves a copy"), attempts > 1, "attempt \(attempts): note reads \(note.label)")
            XCTAssertTrue(any["action.retryUpload"].exists)
            XCTAssertTrue(any["action.startOver"].exists)
            XCTAssertFalse(any["action.backToReview"].exists)

            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "uploading-unusableAnswer-\(attempts)"
            shot.lifetime = .keepAlways
            add(shot)
            let outcome = try AccessibilityAudit.run(app) { _ in Thread.sleep(forTimeInterval: 2) }
            XCTAssertTrue(outcome.persistent.isEmpty, "attempt \(attempts): \(outcome.persistent.map(\.finding.message))")

            tap(app, "action.retryUpload")
            XCTAssertTrue(note.waitForNonExistence(timeout: 10), "Try again left the failure up")
            app.terminate()
        }
    }

    /// The demo's answer after an unusable one is the result: "Try again" is the whole way on.
    @MainActor
    func testTryAgainAfterAnUnusableAnswerReachesTheResult() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-practiceMeter", "NO", "-uiDemo", "-uiDemoPhase", "uploading", "-uiDemoUnusableAnswer", "-uiDemoPass"]
        app.launch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["upload.answerNote"].waitForExistence(timeout: 30))
        tap(app, "action.retryUpload")
        let spotClear = app.buttons["action.spotClear"]
        let result = any["screen.result"]
        let deadline = Date().addingTimeInterval(30)
        while !result.exists, Date() < deadline {
            if spotClear.exists, spotClear.isHittable { spotClear.tap() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(result.exists, "Try again never reached the result")
    }

    static let sampleResult = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "HouseScan/Runtime/SampleResult.json")

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND isHittable == true"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 20), .completed, "\(identifier) never became tappable")
        button.tap()
    }
}

/// The placement server for `-answersFromGate`, answering through the gate folder
/// (`GateAnswerProtocol` in the app). For each `request-n.json` the app leaves there it writes
/// `answer-n.json`, built by `answer` from the request's body and n, and keeps the request for the
/// test. A background thread polls every 0.1 s until `stop()`.
final class GateServer: Sendable {
    struct Request: Sendable {
        var target: String
        var body: Data
    }

    private let log = Mutex<[Request]>([])
    private let stopped = Mutex(false)

    var requests: [Request] { log.withLock { $0 } }

    init(gate: URL, answer: @escaping @Sendable (Data, Int) -> Data) {
        Thread.detachNewThread { [self] in
            while !stopped.withLock({ $0 }) {
                let index = log.withLock { $0.count }
                let body = gate.appending(path: "request-\(index).json")
                if let data = try? Data(contentsOf: body) {
                    let target = (try? String(contentsOf: gate.appending(path: "request-\(index).target"), encoding: .utf8)) ?? ""
                    log.withLock { $0.append(Request(target: target, body: data)) }
                    do {
                        try answer(data, index).write(to: gate.appending(path: "answer-\(index).json"), options: .atomic)
                    } catch {
                        XCTFail("couldn't write answer-\(index).json: \(error)")
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
    }

    func stop() { stopped.withLock { $0 = true } }
}
