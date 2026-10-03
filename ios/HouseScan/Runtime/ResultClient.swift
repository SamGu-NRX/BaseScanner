import Foundation
import HouseScanKit

/// Sends a scan's scene.json to the placement server and returns the result JSON (contract C2).
@MainActor
protocol ResultClient: AnyObject {
    /// True when the answer is the bundled sample, not a server's analysis.
    var isSample: Bool { get }
    func submit(scene: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data
}

/// Posts scene.json to the placement server and returns the answer only when it names the scene
/// sent (HouseScanKit's `PlacementHTTPClient`, which the package tests drive over real HTTP). Only
/// the JSON goes: the keyframes stay on the phone, and in the scan folder's `scan.zip`, which
/// leaves only if the homeowner shares it.
@MainActor
final class HTTPResultClient: ResultClient {
    let serverURL: URL
    let isSample = false
    private let client: PlacementHTTPClient

    init(serverURL: URL, session: URLSession = .shared) {
        self.serverURL = serverURL
        client = PlacementHTTPClient(serverURL: serverURL, session: session)
    }

    func submit(scene: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try await client.submit(scene: scene, progress: progress)
    }
}

/// The bundled sample is missing: a build problem, not something the server said.
struct MissingSampleResult: Error, CustomStringConvertible {
    var description: String { "SampleResult.json is missing from the app bundle." }
}

/// What the homeowner reads about a failed upload. Which failures are worth sending again is
/// decided (and tested) in HouseScanKit's `UploadFailureKind`; the technical detail goes to the
/// log, and the screen never shows raw error text.
enum UploadFailure {
    /// A failure while sending or reading the answer (not while packaging the scan).
    /// `unusableAnswers` counts the server's answers House Scan couldn't use since the scan was
    /// sent from the review or a gap; this adds one when `error` is such an answer.
    static func state(for error: any Error, sample: Bool, unusableAnswers: inout Int) -> UploadState {
        // No server was asked: a missing or unreadable bundled sample is the build's problem, and
        // the words must not say a server answered.
        if sample {
            return .rejected(message: "This build's sample result is missing or unreadable. Start over with a build that has a server.")
        }
        let kind = UploadFailureKind.classify(error)
        if kind == .unreadableAnswer { unusableAnswers += 1 }
        return state(for: kind, unusableAnswers: unusableAnswers)
    }

    static func state(for kind: UploadFailureKind, unusableAnswers: Int) -> UploadState {
        switch kind {
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
        // The answer's problem, not the scan's: ask again, never "check your marks".
        case .unreadableAnswer:
            .unusableAnswer(attempts: max(unusableAnswers, 1))
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

/// Answers with the bundled SampleResult.json, for tests and demos without a server. The result
/// is flagged `isSample` so the screen says it is not a real analysis. It answers no particular
/// scene (its `input_sha256` is all zeros), so it is deliberately not checked with
/// `ResultBinding`.
@MainActor
final class SampleResultClient: ResultClient {
    let isSample = true
    /// Seconds the fake upload takes, so each upload state is visible in demos and UI tests.
    let pace: Double
    /// A server answer in a JSON file that replaces the bundled sample while it is set. Only the
    /// engine sets it, from `-sampleResultAfterSpotAnswer` and the scan's spot answers
    /// (`ScanEngine.spotConfirm`), for UI tests.
    var answerFile: URL?

    init(pace: Double) {
        self.pace = pace
    }

    func submit(scene: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        for step in 1...4 {
            try await Task.sleep(for: .seconds(pace / 5))
            progress(Double(step) / 4)
        }
        try await Task.sleep(for: .seconds(pace))
        if let answerFile { return try Data(contentsOf: answerFile) }
        guard let url = Bundle.main.url(forResource: "SampleResult", withExtension: "json") else { throw MissingSampleResult() }
        return try Data(contentsOf: url)
    }
}
