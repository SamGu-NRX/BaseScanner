import Foundation

/// Why sending the scene failed, which decides whether sending it again can help.
///
/// A network failure, a server error (5xx) or a server that is busy or timed out (408, 429) may
/// go away, so the homeowner can try again. Any other refusal (4xx) or an answer that doesn't
/// decode would come back the same for the same scene, so the way on is back to the review or
/// starting over.
public enum UploadFailureKind: Sendable, Equatable {
    /// No connection at all.
    case offline
    /// Connected, but the server couldn't be reached or the connection broke.
    case unreachable
    /// The server answered 5xx.
    case serverError
    /// The server answered 408 (it timed out waiting for the request) or 429 (too many requests):
    /// the same scene can succeed later. `retryAfter` is the server's Retry-After in seconds, when
    /// it sent one as a number.
    case busy(retryAfter: Int?)
    /// The server answered 4xx: it refused this scene.
    case refused
    /// The answer wasn't HTTP or didn't decode as a result.
    case unreadableAnswer

    /// Sending the same scene again can succeed.
    public var retryable: Bool {
        switch self {
        case .offline, .unreachable, .serverError, .busy: true
        case .refused, .unreadableAnswer: false
        }
    }

    public static func classify(_ error: any Error) -> UploadFailureKind {
        if let urlError = error as? URLError {
            return offlineCodes.contains(urlError.code) ? .offline : .unreachable
        }
        return .unreadableAnswer
    }

    /// The kind for an HTTP status outside 200...299. `retryAfter` is the answer's Retry-After
    /// header. Only its delay-seconds form is read, as advice for the message: an HTTP date is
    /// ignored, nothing waits on it, and the homeowner can try again at any time.
    public static func classify(httpStatus status: Int, retryAfter: String? = nil) -> UploadFailureKind {
        switch status {
        case 408, 429: .busy(retryAfter: retryAfter.flatMap(retryAfterSeconds))
        case 500..<600: .serverError
        case 400..<500: .refused
        default: .unreadableAnswer
        }
    }

    /// The longest wait read from Retry-After, a day. Anything longer is treated as a day, so a
    /// huge value can't overflow the arithmetic that phrases the wait.
    public static let maxRetryAfterSeconds = 86_400

    /// Retry-After's delay-seconds form (digits only, surrounding spaces allowed), capped at
    /// `maxRetryAfterSeconds`; nil for anything else.
    static func retryAfterSeconds(_ header: String) -> Int? {
        let digits = header.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        // More digits than a day could need: the cap, without parsing a number that overflows.
        if digits.drop(while: { $0 == "0" }).count > 5 { return maxRetryAfterSeconds }
        return min(Int(digits) ?? maxRetryAfterSeconds, maxRetryAfterSeconds)
    }

    /// No connection at all, as opposed to a server that can't be reached.
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
    ]
}
