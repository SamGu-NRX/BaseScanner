import Foundation
import HouseScanKit
import Testing

@Suite struct UploadFailureKindTests {
    @Test func noConnectionIsOfflineAndRetryable() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff] {
            let kind = UploadFailureKind.classify(URLError(code))
            #expect(kind == .offline)
            #expect(kind.retryable)
        }
    }

    @Test func otherNetworkErrorsAreUnreachableAndRetryable() {
        for code in [URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .secureConnectionFailed] {
            let kind = UploadFailureKind.classify(URLError(code))
            #expect(kind == .unreachable)
            #expect(kind.retryable)
        }
    }

    @Test func serverErrorsAreRetryableAndRefusalsAreNot() {
        #expect(UploadFailureKind.classify(httpStatus: 500) == .serverError)
        // A server that timed out or is rate-limiting may take the same scene later.
        #expect(UploadFailureKind.classify(httpStatus: 408) == .busy(retryAfter: nil))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "30") == .busy(retryAfter: 30))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: " 5 ") == .busy(retryAfter: 5))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT") == .busy(retryAfter: nil))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "-3") == .busy(retryAfter: nil))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "+30") == .busy(retryAfter: nil))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "") == .busy(retryAfter: nil))
        // Huge values stop at a day instead of overflowing: Int.max, and more digits than Int holds.
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "86400") == .busy(retryAfter: 86_400))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "86401") == .busy(retryAfter: 86_400))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "\(Int.max)") == .busy(retryAfter: 86_400))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "99999999999999999999999") == .busy(retryAfter: 86_400))
        #expect(UploadFailureKind.classify(httpStatus: 429, retryAfter: "0000030") == .busy(retryAfter: 30))
        #expect(UploadFailureKind.classify(httpStatus: 408).retryable && UploadFailureKind.classify(httpStatus: 429).retryable)
        #expect(!UploadFailureKind.classify(httpStatus: 400).retryable && !UploadFailureKind.classify(httpStatus: 422).retryable)
        #expect(UploadFailureKind.classify(httpStatus: 503).retryable)
        #expect(UploadFailureKind.classify(httpStatus: 599) == .serverError)
        #expect(UploadFailureKind.classify(httpStatus: 400) == .refused)
        #expect(UploadFailureKind.classify(httpStatus: 413) == .refused)
        #expect(UploadFailureKind.classify(httpStatus: 422) == .refused)
        #expect(UploadFailureKind.classify(httpStatus: 499) == .refused)
        #expect(!UploadFailureKind.classify(httpStatus: 422).retryable)
    }

    /// An answer House Scan couldn't use is the answer's problem, not the scan's: the homeowner may
    /// ask again, unlike a refusal.
    @Test func anythingElseIsAnUnreadableAnswerThatMayBeTriedAgain() {
        #expect(UploadFailureKind.classify(httpStatus: 302) == .unreadableAnswer)
        #expect(UploadFailureKind.classify(httpStatus: 600) == .unreadableAnswer)
        struct DecodeFailure: Error {}
        #expect(UploadFailureKind.classify(DecodeFailure()) == .unreadableAnswer)
        #expect(UploadFailureKind.unreadableAnswer.retryable)
        #expect(!UploadFailureKind.refused.retryable)
    }

    /// The placement client's errors: a status is classified as that status, and a response that
    /// wasn't HTTP means no server answered.
    @Test func placementClientErrors() {
        #expect(UploadFailureKind.classify(PlacementHTTPError.server(status: 422, body: "")) == .refused)
        #expect(UploadFailureKind.classify(PlacementHTTPError.server(status: 503, body: "")) == .serverError)
        #expect(UploadFailureKind.classify(PlacementHTTPError.server(status: 429, body: "", retryAfter: "30")) == .busy(retryAfter: 30))
        #expect(UploadFailureKind.classify(PlacementHTTPError.server(status: 302, body: "")) == .unreadableAnswer)
        #expect(UploadFailureKind.classify(PlacementHTTPError.notHTTP) == .unreachable)
    }
}
