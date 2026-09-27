import HouseScanKit
import Testing

/// #110: the result card offers only what the camera can still do.
@Suite struct ResultCardActionsTests {
    private typealias Primary = ResultCardActions.Primary

    private static func primary(_ answer: ResultReading.Answer, hasSpot: Bool = true, spotIsClean: Bool = true,
                                hasViewToTake: Bool = false, sourceAvailable: Bool = true) -> Primary? {
        ResultCardActions.primary(answer: answer, hasSpot: hasSpot, spotIsClean: spotIsClean,
                                  hasViewToTake: hasViewToTake, sourceAvailable: sourceAvailable)
    }

    @Test func withTheCameraUpEachAnswerKeepsItsButton() {
        #expect(Self.primary(.fits) == .showAR(clean: true))
        #expect(Self.primary(.oneMoreLook, hasViewToTake: true) == .takeView)
        #expect(Self.primary(.installer, spotIsClean: false) == .showAR(clean: false))
        #expect(Self.primary(.installer) == .showAR(clean: true))
        #expect(Self.primary(.notHere, hasSpot: false) == .startOver)
    }

    /// No spot, nothing to show in AR; no view to take, no "Show me".
    @Test func nothingToShowMeansNoButton() {
        #expect(Self.primary(.fits, hasSpot: false) == nil)
        #expect(Self.primary(.installer, hasSpot: false) == nil)
        #expect(Self.primary(.oneMoreLook, hasViewToTake: false) == nil)
    }

    /// The camera failed after upload: a manual-review result with a capturable unsure check
    /// showed a filled "Show me" that opened a capture with no frames. Now it is gone, as the AR
    /// button already was. Starting over starts a new camera, so it stays.
    @Test func aFailedCameraOffersNothingThatNeedsIt() {
        #expect(Self.primary(.oneMoreLook, hasViewToTake: true, sourceAvailable: false) == nil)
        #expect(Self.primary(.fits, sourceAvailable: false) == nil)
        #expect(Self.primary(.installer, spotIsClean: false, sourceAvailable: false) == nil)
        #expect(Self.primary(.notHere, hasSpot: false, sourceAvailable: false) == .startOver)
    }

    /// The check lines' "Show me" and Details' "Capture it now" follow the same rule.
    @Test func aViewIsOfferedOnlyWhileTheCameraCanTakeIt() {
        #expect(ResultCardActions.offersView(capturable: true, sourceAvailable: true))
        #expect(!ResultCardActions.offersView(capturable: true, sourceAvailable: false))
        #expect(!ResultCardActions.offersView(capturable: false, sourceAvailable: true))
        #expect(!ResultCardActions.offersView(capturable: false, sourceAvailable: false))
    }
}
