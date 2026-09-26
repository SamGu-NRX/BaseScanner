import Foundation

/// Sends a scan bundle to the placement server and returns the result JSON (contract C2).
@MainActor
protocol ResultClient: AnyObject {
    /// True when the answer is the bundled sample, not a server's analysis.
    var isSample: Bool { get }
    func submit(bundle: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Data
}

/// Posts the zip to the placement server: `POST {serverURL}/v1/placements` with the raw bundle
/// as `application/zip` (server/api.py on origin/t3/server, which also takes a bare scene.json or
/// a multipart form). The response body is the result JSON.
@MainActor
final class HTTPResultClient: ResultClient {
    let serverURL: URL
    let isSample = false

    init(serverURL: URL) {
        self.serverURL = serverURL
    }

    nonisolated static func makeRequest(serverURL: URL, zip: URL) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: "v1/placements"))
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120
        return request
    }

    func submit(bundle: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let request = Self.makeRequest(serverURL: serverURL, zip: bundle)
        let delegate = UploadProgressDelegate(progress: progress)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bundle, delegate: delegate)
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

    func submit(bundle: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        for step in 1...4 {
            try await Task.sleep(for: .seconds(pace / 5))
            progress(Double(step) / 4)
        }
        try await Task.sleep(for: .seconds(pace))
        guard let url = Bundle.main.url(forResource: "SampleResult", withExtension: "json") else { throw UploadError.missingSample }
        return try Data(contentsOf: url)
    }
}
