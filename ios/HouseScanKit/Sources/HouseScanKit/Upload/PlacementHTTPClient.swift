import Foundation

/// Sends a scan's scene.json to the placement server and returns the answer only when it is usable:
/// `POST {serverURL}/v1/placements` with the JSON as the body and `Content-Type: application/json`.
/// Only the JSON goes; the server's solver reads no photos for a bare scene.json, so the keyframes
/// stay on the phone.
///
/// The answer is returned only when the reply is HTTP 2xx and names the scene sent: its
/// `stats.input_sha256` must be the hash of these exact bytes (`ResultBinding`). Every other
/// outcome throws, and `UploadFailureKind.classify` says what it means for the homeowner.
public struct PlacementHTTPClient: Sendable {
    public let serverURL: URL
    public let session: URLSession

    public init(serverURL: URL, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.session = session
    }

    public static func request(serverURL: URL) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: "v1/placements"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        return request
    }

    /// The answer's bytes. `progress` runs from 0 to 1 while the scene is sent, and reaches 1 once
    /// the server has the whole body and is working out the spot.
    public func submit(scene: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let delegate = PlacementUploadProgress(progress: progress)
        let (data, response) = try await session.upload(for: Self.request(serverURL: serverURL), from: scene, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw PlacementHTTPError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw PlacementHTTPError.server(
                status: http.statusCode, body: String(decoding: data.prefix(300), as: UTF8.self),
                retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        try ResultBinding.check(answer: data, submittedScene: scene)
        progress(1)
        return data
    }
}

/// How sending the scene failed before there was an answer to read.
public enum PlacementHTTPError: Error, Equatable, CustomStringConvertible {
    /// The response wasn't HTTP, so no server answered.
    case notHTTP
    /// The server answered with a status outside 2xx. `body` is the first 300 bytes, for the log.
    case server(status: Int, body: String, retryAfter: String? = nil)

    public var description: String {
        switch self {
        case .notHTTP: "the response was not HTTP"
        case .server(let status, let body, _): "the server answered \(status): \(body)"
        }
    }
}

/// Reports upload progress. Once the whole body is sent the server is working out the spot in the
/// same request, so it reports 1 and the screen can move on to "Check clearances". Before that it
/// stops at 0.99, so rounding never shows 100%. Holding 0.99 until the answer left the screen on
/// "Sending measurements, 99%" for the whole analysis (field test run 1).
final class PlacementUploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        if totalBytesSent >= totalBytesExpectedToSend {
            progress(1)
        } else {
            progress(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }
}
