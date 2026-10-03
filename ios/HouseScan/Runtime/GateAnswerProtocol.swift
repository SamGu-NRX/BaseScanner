import Foundation
import Synchronization

/// The placement server's side of an upload under `-answersFromGate`, played by a UI test through
/// the `-autopilotGate` folder. The app's real `PlacementHTTPClient` sends through `session`, so
/// the request, the answer's status check and `ResultBinding` all run as they do against a server;
/// only the socket is replaced.
///
/// For the n-th request (from 0, in the order the app sends them) it writes `request-n.target`
/// ("POST /v1/placements"), then the exact body as `request-n.json`, then waits up to 60 seconds
/// for the test's `answer-n.json` and answers HTTP 200 with its bytes. With no answer by then the
/// request fails as timed out.
///
/// The UI test used to run a server on 127.0.0.1 inside its runner. That server answered
/// URLSession on a Mac, but on the hosted Simulator the app's requests to it failed as offline
/// (Actions run 37107233020); the runner is a background app while the app under test is open.
/// HouseScanKit's `PlacementHTTPClientTests` still drive the client over a real loopback socket.
final class GateAnswerProtocol: URLProtocol, @unchecked Sendable {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GateAnswerProtocol.self]
        return URLSession(configuration: configuration)
    }()

    static let answerWait: TimeInterval = 60

    /// Requests started in this process, which numbers the files.
    private static let started = Mutex(0)

    /// Set and read only on the loading thread: `startLoading`, the timer and `stopLoading` all
    /// run on the run loop URLSession called `startLoading` on.
    private var poll: Timer?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let gate = LaunchOptions().autopilotGate, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        do {
            body = try Self.body(of: request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        // Numbered only once the body is read. A write that fails after this leaves a gap in the
        // numbers, which the test's server skips over.
        let index = Self.started.withLock { count in
            defer { count += 1 }
            return count
        }
        do {
            let target = "\(request.httpMethod ?? "GET") \(url.path())"
            try Data(target.utf8).write(to: gate.appending(path: "request-\(index).target"), options: .atomic)
            try body.write(to: gate.appending(path: "request-\(index).json"), options: .atomic)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let answer = gate.appending(path: "answer-\(index).json")
        let deadline = Date().addingTimeInterval(Self.answerWait)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [self] timer in
            if let body = try? Data(contentsOf: answer) {
                timer.invalidate()
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } else if Date() >= deadline {
                timer.invalidate()
                RuntimeLog.engine.error("answers from gate: no \(answer.lastPathComponent, privacy: .public) within \(Self.answerWait, privacy: .public) s")
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
        }
        RunLoop.current.add(timer, forMode: RunLoop.current.currentMode ?? .default)
        poll = timer
    }

    override func stopLoading() {
        poll?.invalidate()
        poll = nil
    }

    /// An upload task hands its body over as a stream, not `httpBody`. A stream that fails to read
    /// throws: a cut-short body would reach the test as an answer naming the wrong scene.
    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
