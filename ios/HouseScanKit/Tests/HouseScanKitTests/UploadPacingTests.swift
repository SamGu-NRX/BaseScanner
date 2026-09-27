import Foundation
import HouseScanKit
import Testing

/// Issue #31: the upload screen holds "Check clearances" for a minimum time however fast the
/// answer comes.
@Suite struct UploadPacingTests {
    private let start = ContinuousClock.now

    @Test func anAnswerThatCameAtOnceWaitsTheWholeMinimum() {
        #expect(UploadPacing.remaining(since: start, minimum: .milliseconds(600), now: start) == .milliseconds(600))
    }

    @Test func anAnswerPartWayThroughWaitsTheRest() {
        let now = start + .milliseconds(250)
        #expect(UploadPacing.remaining(since: start, minimum: .milliseconds(600), now: now) == .milliseconds(350))
    }

    @Test func aSlowAnswerDoesNotWait() {
        #expect(UploadPacing.remaining(since: start, minimum: .milliseconds(600), now: start + .milliseconds(600)) == .zero)
        #expect(UploadPacing.remaining(since: start, minimum: .milliseconds(600), now: start + .seconds(3)) == .zero)
    }

    @Test func aStepThatNeverStartedWaitsTheWholeMinimum() {
        #expect(UploadPacing.remaining(since: nil, minimum: .milliseconds(800), now: start) == .milliseconds(800))
    }
}
