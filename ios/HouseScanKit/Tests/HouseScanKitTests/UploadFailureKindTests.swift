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

    @Test func anythingElseIsAnUnreadableAnswer() {
        #expect(UploadFailureKind.classify(httpStatus: 302) == .unreadableAnswer)
        #expect(UploadFailureKind.classify(httpStatus: 600) == .unreadableAnswer)
        struct DecodeFailure: Error {}
        #expect(UploadFailureKind.classify(DecodeFailure()) == .unreadableAnswer)
        #expect(!UploadFailureKind.unreadableAnswer.retryable)
    }
}
