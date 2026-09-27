import HouseScanKit
import Testing

/// The onboarding's permission requests and what they allow later.
@Suite struct CapturePermissionsTests {
    @Test func aReplayAsksForNothing() {
        #expect(CapturePermissions.exit(replay: true, camera: .undecided, motionUndecided: true) == .findMeter)
        #expect(CapturePermissions.exit(replay: true, camera: .refused, motionUndecided: true) == .findMeter)
    }

    /// Without the camera there is no scan, so Motion & Fitness is not asked for.
    @Test func aRefusedCameraShowsTheFailureWithoutAskingForMotion() {
        #expect(CapturePermissions.exit(replay: false, camera: .refused, motionUndecided: true) == .cameraFailure)
        #expect(CapturePermissions.exit(replay: false, camera: .refused, motionUndecided: false) == .cameraFailure)
    }

    @Test func undecidedPermissionsAreAskedForBeforeTheMeterSearch() {
        #expect(CapturePermissions.exit(replay: false, camera: .undecided, motionUndecided: true) == .ask(camera: true, motion: true))
        #expect(CapturePermissions.exit(replay: false, camera: .undecided, motionUndecided: false) == .ask(camera: true, motion: false))
        #expect(CapturePermissions.exit(replay: false, camera: .allowed, motionUndecided: true) == .ask(camera: false, motion: true))
        #expect(CapturePermissions.exit(replay: false, camera: .allowed, motionUndecided: false) == .findMeter)
    }

    /// An unanswered request must not lead to the barometer raising the prompt over the meter
    /// search; once the permission is decided, the barometer starts.
    @Test func anUnansweredMotionRequestHoldsTheBarometerUntilDecided() {
        #expect(!CapturePermissions.barometerMayStart(after: .unanswered, undecided: true))
        #expect(CapturePermissions.barometerMayStart(after: .unanswered, undecided: false))
        #expect(CapturePermissions.barometerMayStart(after: .allowed, undecided: false))
        #expect(CapturePermissions.barometerMayStart(after: .denied, undecided: false))
        #expect(CapturePermissions.barometerMayStart(after: .notNeeded, undecided: false))
        // Never asked (no activity support): the barometer's own prompt is the only one.
        #expect(CapturePermissions.barometerMayStart(after: nil, undecided: true))
    }
}
