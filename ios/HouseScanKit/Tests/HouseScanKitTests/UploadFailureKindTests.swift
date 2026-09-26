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
