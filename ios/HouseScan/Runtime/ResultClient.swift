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
/// (and in the scan folder's `scan.zip` for replay and debugging). The response body is the
/// result JSON.
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
            throw UploadError.server(status: http.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        progress(1)
        return data
    }
}

enum UploadError: Error, CustomStringConvertible {
    case notHTTP
    case server(status: Int, body: String)
    case missingSample

    var description: String {
        switch self {
        case .notHTTP: "The server's answer was not HTTP."
        case .server(let status, let body): "The server answered \(status): \(body)"
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
        let kind: UploadFailureKind = if case .server(let status, _) = error as? UploadError {
            UploadFailureKind.classify(httpStatus: status)
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
        case .refused:
            .rejected(message: "The server couldn't use this scan. Go back to the review to check your marks, or start over.")
        case .unreadableAnswer:
            .rejected(message: "We couldn't read the server's answer. Go back to the review and send it again, or start over.")
        }
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

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// Answers with the bundled SampleResult.json, for tests and demos without a server. The result
/// is flagged `isSample` so the screen says it is not a real analysis.
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
