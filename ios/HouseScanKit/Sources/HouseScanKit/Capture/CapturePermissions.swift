import Foundation

/// The order of the camera and Motion & Fitness prompts, kept apart from AVFoundation and Core
/// Motion so it can be tested without the system alerts. Both are asked for while the onboarding
/// that explains them is on screen; left to the AR session and the barometer, they would come up
/// over "Find your electric meter".
public enum CapturePermissions {
    /// The camera's authorization. Restricted counts as refused: the homeowner can't allow it.
    public enum Camera: Sendable, Equatable {
        case undecided, allowed, refused
    }

    /// The answer to the onboarding's Motion & Fitness request.
    public enum Motion: Sendable, Equatable {
        case allowed, denied
        /// Core Motion called back with the permission still undecided (an error, or before the
        /// alert was answered). Nothing says the alert was dealt with.
        case unanswered
        /// Nothing to ask: already decided, or this phone has no barometer.
        case notNeeded
    }

    /// What "Allow camera" on the onboarding does.
    public enum Exit: Sendable, Equatable {
        case findMeter
        /// Without the camera there is no scan: the camera failure screen, and no motion prompt.
        case cameraFailure
        /// Ask first, still on the onboarding: the camera if `camera`, then Motion & Fitness if
        /// `motion`. A camera refusal then ends at `cameraFailure`; any motion answer goes on.
        case ask(camera: Bool, motion: Bool)
    }

    /// A replay asks for nothing. Otherwise an undecided permission is asked for before the meter
    /// search, and a refused camera stops there.
    public static func exit(replay: Bool, camera: Camera, motionUndecided: Bool) -> Exit {
        if replay { return .findMeter }
        switch camera {
        case .refused: return .cameraFailure
        case .undecided: return .ask(camera: true, motion: motionUndecided)
        case .allowed: return motionUndecided ? .ask(camera: false, motion: true) : .findMeter
        }
    }

    /// Whether the scan may start the barometer, which raises the Motion & Fitness prompt itself
    /// while the permission is undecided. After an onboarding request that came back unanswered
    /// it stays off, so the prompt can't come up over the meter search; once the permission is
    /// decided it starts (denied, it records nothing). With no onboarding request (`nil`, as on a
    /// phone without activity support) nothing is held.
    public static func barometerMayStart(after answer: Motion?, undecided: Bool) -> Bool {
        !(undecided && answer == .unanswered)
    }
}
