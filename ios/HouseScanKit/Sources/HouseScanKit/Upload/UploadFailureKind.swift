import Foundation

/// Why sending the scene failed, which decides whether sending it again can help.
///
/// A network failure or a server error (5xx) may go away, so the homeowner can try again. A
/// refusal (4xx) or an answer that doesn't decode would come back the same for the same scene, so
/// the way on is back to the review or starting over.
public enum UploadFailureKind: Sendable, Equatable {
    /// No connection at all.
    case offline
    /// Connected, but the server couldn't be reached or the connection broke.
    case unreachable
    /// The server answered 5xx.
    case serverError
    /// The server answered 4xx: it refused this scene.
    case refused
    /// The answer wasn't HTTP or didn't decode as a result.
    case unreadableAnswer

    /// Sending the same scene again can succeed.
    public var retryable: Bool {
        switch self {
        case .offline, .unreachable, .serverError: true
        case .refused, .unreadableAnswer: false
        }
    }

    public static func classify(_ error: any Error) -> UploadFailureKind {
        if let urlError = error as? URLError {
            return offlineCodes.contains(urlError.code) ? .offline : .unreachable
        }
        return .unreadableAnswer
    }

    /// The kind for an HTTP status outside 200...299.
    public static func classify(httpStatus status: Int) -> UploadFailureKind {
        switch status {
        case 500..<600: .serverError
        case 400..<500: .refused
        default: .unreadableAnswer
        }
    }

    /// No connection at all, as opposed to a server that can't be reached.
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
    ]
}
