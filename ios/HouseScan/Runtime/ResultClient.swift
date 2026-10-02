import Foundation
import HouseScanKit

/// Sends a scan's scene.json to the placement server and returns the result JSON (contract C2).
@MainActor
protocol ResultClient: AnyObject {
    /// True when the answer is the bundled sample, not a server's analysis.
    var isSample: Bool { get }
    func submit(scene: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data
}

/// Posts scene.json to the placement server: `POST {serverURL}/v1/placements` with the JSON as
/// the body and `Content-Type: application/json`. Only the JSON goes: the server's solver reads no
/// photos and skips the image check for a bare scene.json, so the keyframes stay on the phone
/// (and in the scan folder's `scan.zip`, which leaves only if the homeowner shares it). The
/// response body is the result JSON, and it is returned only when it names the scene sent: its
/// `stats.input_sha256` must be present and be the hash of these exact bytes (`ResultBinding`).
/// Any other answer throws, and the upload screen treats it as an answer it couldn't read.
@MainActor
final class HTTPResultClient: ResultClient {
    let serverURL: URL
    let isSample = false

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    nonisolated static func makeRequest(serverURL: URL) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: "v1/placements"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        return request
    }

    func submit(scene: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let request = Self.makeRequest(serverURL: serverURL)
        let delegate = UploadProgressDelegate(progress: progress)
        let (data, response) = try await URLSession.shared.upload(for: request, from: scene, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw UploadError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw UploadError.server(
                status: http.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        try ResultBinding.check(answer: data, submittedScene: scene)
        progress(1)
        return data
    }
}

enum UploadError: Error, CustomStringConvertible {
    case notHTTP
    case server(status: Int, body: String, retryAfter: String? = nil)
    case missingSample

    var description: String {
        switch self {
        case .notHTTP: "The server's answer was not HTTP."
        case .server(let status, let body, _): "The server answered \(status): \(body)"
        case .missingSample: "SampleResult.json is missing from the app bundle."
        }
    }
}

/// What the homeowner reads about a failed upload. Which failures are worth sending again is
/// decided (and tested) in HouseScanKit's `UploadFailureKind`; the technical detail goes to the
/// log, and the screen never shows raw error text.
enum UploadFailure {
    /// A failure while sending or reading the answer (not while packaging the scan).
    static func state(for error: any Error) -> UploadState {
        let kind: UploadFailureKind = if case .server(let status, _, let retryAfter) = error as? UploadError {
            UploadFailureKind.classify(httpStatus: status, retryAfter: retryAfter)
        } else {
            UploadFailureKind.classify(error)
        }
        return switch kind {
        case .offline:
            .failed(message: "Your phone isn't connected to the internet. Your scan is saved on this phone.", offline: true)
        case .unreachable:
            .failed(message: "We couldn't reach the House Scan server. Your scan is saved on this phone, so you can try again.", offline: false)
        case .serverError:
            .failed(message: "The House Scan server had a problem. Your scan is saved on this phone, so you can try again.", offline: false)
        case .busy(let retryAfter):
            .failed(message: busyMessage(retryAfter), offline: false)
        case .refused:
            .rejected(message: "The server couldn't use this scan. Go back to the review to check your marks, or start over.")
        case .unreadableAnswer:
            .rejected(message: "We couldn't read the server's answer. Go back to the review and send it again, or start over.")
        }
    }

    /// A busy server: when it said how long to wait (at most a day, `UploadFailureKind`), the
    /// homeowner hears that, rounded up to a minute past 90 seconds; either way the scan is kept
    /// and "Try again" is offered at once.
    static func busyMessage(_ retryAfter: Int?) -> String {
        let wait: String? = retryAfter.map { raw in
            let seconds = min(max(raw, 1), UploadFailureKind.maxRetryAfterSeconds)
            let minutes = seconds / 60 + (seconds % 60 == 0 ? 0 : 1)
            return seconds <= 90 ? "about \(seconds) seconds" : "about \(minutes) minutes"
        }
        let when = wait.map { "Try again in \($0)." } ?? "Try again in a moment."
        return "The House Scan server is busy. Your scan is saved on this phone. \(when)"
    }

    /// The scan couldn't be turned into scene.json. A driveway or fence that has to be marked
    /// again says which, so the homeowner knows what to fix in the review.
    static func packaging(_ error: any Error) -> UploadState {
        switch error as? ScanEngine.ExportError {
        case .markCollapsed(.driveway)?:
            .rejected(message: "Mark the driveway again: its two points came out on top of each other.")
        case .markCollapsed(.fence)?:
            .rejected(message: "Mark the fence again: its two points came out on top of each other.")
        default:
            .rejected(message: "This scan couldn't be prepared for sending. Go back to the review to check your marks, or start over.")
        }
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    /// Once the whole body is sent the server is working out the spot in the same request, so
    /// report 1 and let the screen move on to "Check clearances". Before that, stop at 0.99 so
    /// rounding never shows 100%. Holding 0.99 until the answer left the screen on "Sending
    /// measurements, 99%" for the whole analysis (field test run 1).
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        if totalBytesSent >= totalBytesExpectedToSend {
            progress(1)
        } else {
            progress(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }
}

/// Answers with the bundled SampleResult.json, for tests and demos without a server. The result
/// is flagged `isSample` so the screen says it is not a real analysis. It answers no particular
/// scene (its `input_sha256` is all zeros), so it is deliberately not checked with
/// `ResultBinding`.
@MainActor
final class SampleResultClient: ResultClient {
    let isSample = true
    /// Seconds the fake upload takes, so each upload state is visible in demos and UI tests.
    let pace: Double

    init(pace: Double) {
        self.pace = pace
    }

    func submit(scene: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        for step in 1...4 {
            try await Task.sleep(for: .seconds(pace / 5))
            progress(Double(step) / 4)
        }
        try await Task.sleep(for: .seconds(pace))
        guard let url = Bundle.main.url(forResource: "SampleResult", withExtension: "json") else { throw UploadError.missingSample }
        return try Data(contentsOf: url)
    }
}
