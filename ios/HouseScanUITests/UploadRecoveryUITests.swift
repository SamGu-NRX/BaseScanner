import CryptoKit
import Foundation
import Network
import Synchronization
import XCTest

/// An answer House Scan can't use (it names another scene, or doesn't decode) is never shown, the
/// scan is kept, and only the homeowner's "Try again" asks again. A refused scan stays separate:
/// it goes back to the review (`ScreenStatesUITests.testRejectedUploadGoesBackToReview`).
final class UploadRecoveryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The real engine against a placement server on 127.0.0.1. The first answer names another
    /// scene. The second names the scene sent but has a result schema House Scan doesn't read.
    /// Every later one is the bundled sample naming the scene sent. The synthetic wall plays to
    /// the upload; neither unusable answer shows anything of itself, nothing is sent again until
    /// "Try again", the second says asking again might not help, and the third reaches the result.
    @MainActor
    func testUnusableAnswersAreHeldBackUntilTryAgain() throws {
        let sample = String(decoding: try Data(contentsOf: Self.sampleResult), as: UTF8.self)
        let zeros = String(repeating: "0", count: 64)
        let schema = "\"schema_version\": \"1.0\""
        XCTAssertTrue(sample.contains("\"input_sha256\": \"\(zeros)\""))
        XCTAssertTrue(sample.contains(schema))
        let server = try PlacementStub { request, index in
            var answer = sample.replacingOccurrences(of: zeros, with: index == 0 ? Self.sha256(Data("another scene".utf8)) : Self.sha256(request.body))
            if index == 1 { answer = answer.replacingOccurrences(of: schema, with: "\"schema_version\": \"9.0\"") }
            return Data(answer.utf8)
        }
        defer { server.stop() }

        let files = FileManager.default
        let gate = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "housescan-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try files.createDirectory(at: gate, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: gate) }
        // Every screen up to the result is let through; the result's gate stays shut, so the
        // autopilot stops there.
        for phase in ["onboarding", "findMeter", "meterCloseUp", "wallWalk", "markFeatures", "gapRequest", "uploading", "spotConfirm"] {
            try Data().write(to: gate.appending(path: phase))
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-replay", FullFlowUITests.fixture, "-autopilot", "-autopilotHold", "1.5", "-autopilotGate", gate.path,
            "-practiceMeter", "NO", "-serverURL", server.base.absoluteString,
        ]
        app.launch()
        let any = app.descendants(matching: .any)
        let note = any["upload.answerNote"]
        let first = any.matching(NSPredicate(format: "label == %@", "We couldn't use the server's answer")).firstMatch
        let second = any.matching(NSPredicate(format: "label == %@", "The answer still couldn't be used")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 300), "the unbound answer never showed as an answer House Scan couldn't use")
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests.first?.path, "/v1/placements")
        holdsWithoutAsking(app, requests: 1, server: server, shot: "uploading-unusableAnswer-engine-1")

        tap(app, "action.retryUpload")
        XCTAssertTrue(second.waitForExistence(timeout: 60), "the undecodable answer never showed as a second unusable answer")
        XCTAssertTrue(note.exists)
        XCTAssertEqual(server.requests.count, 2)
        holdsWithoutAsking(app, requests: 2, server: server, shot: "uploading-unusableAnswer-engine-2")

        tap(app, "action.retryUpload")
        XCTAssertTrue(any["screen.result"].waitForExistence(timeout: 240), "the answer after Try again never reached the result")
        XCTAssertGreaterThanOrEqual(server.requests.count, 3)
        XCTAssertTrue(server.requests.allSatisfy { $0.method == "POST" && $0.path == "/v1/placements" })
    }

    /// On an unusable answer: no "Back to review", a way to start over, and for six seconds no
    /// request beyond `requests` and nothing of the answer on a later screen.
    @MainActor
    private func holdsWithoutAsking(_ app: XCUIApplication, requests: Int, server: PlacementStub, shot name: String) {
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

/// A placement server on 127.0.0.1 that the app in the Simulator reaches like any other: every
/// request is answered 200 with the body `answer` builds from it and its index, and kept for the
/// test. It speaks only what the app sends: one request per connection with a `Content-Length`
/// body, and it closes the connection after replying. `stop()` closes the listener; the
/// listener's handlers hold the stub weakly, so dropping it closes the listener too.
final class PlacementStub: Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var body: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "placement-stub")
    private let answer: @Sendable (Request, Int) -> Data
    private let log = Mutex<[Request]>([])

    var requests: [Request] { log.withLock { $0 } }
    var base: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")! }

    init(answer: @escaping @Sendable (Request, Int) -> Data) throws {
        self.answer = answer
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self, queue] connection in
            guard self != nil else { return connection.cancel() }
            connection.start(queue: queue)
            Self.receive(connection, buffer: Data()) { [weak self] request in
                guard let self else { return connection.cancel() }
                self.reply(to: request, on: connection)
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }

    private func reply(to request: Request, on connection: NWConnection) {
        let index = log.withLock { log in
            log.append(request)
            return log.count - 1
        }
        let body = answer(request, index)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func receive(_ connection: NWConnection, buffer: Data, handler: @escaping @Sendable (Request) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parse(buffer) { return handler(request) }
            if done || error != nil { return connection.cancel() }
            receive(connection, buffer: buffer, handler: handler)
        }
    }

    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let line = head[0].split(separator: " ")
        guard line.count >= 2 else { return nil }
        var length = 0
        for field in head.dropFirst() {
            guard let colon = field.firstIndex(of: ":"), field[..<colon].lowercased() == "content-length" else { continue }
            length = Int(field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(line[0]), path: String(line[1]), body: Data(body.prefix(length)))
    }
}
