/// What a change to the wall's geometry does to the placement answer the homeowner has.
///
/// ARKit keeps refining the ground after the scan is sent: a detected plane replaces the
/// chest-height guess, or a better plane replaces an earlier one. The server checked every
/// clearance against the ground the scan sent, so an answer drawn on a moved ground shows a
/// spot nobody checked. A ground change therefore takes the answer down from the spot check,
/// the result, its 3D preview and the camera view, and sends the scan again, built from the
/// wall as it is now. Only the server's answer to that scan comes back on screen.
///
/// An anchor correction is different: it moves the wall, its corners, the kept cameras, the
/// marks and the ground as one body, and the answer is in wall terms (spans along the wall and
/// depths out from it), so it still describes the wall and stays up.
///
/// One resend per withdrawal. A ground that changes again before a new answer is shown means
/// the phone is still settling, and sending again in a loop would only keep the homeowner
/// waiting: the upload screen shows a failure with "Try again" instead.
public struct GroundFreshness: Equatable, Sendable {
    /// What changed the wall.
    public enum Change: Equatable, Sendable, CaseIterable {
        /// The ground under the wall moved or turned from a guess into a measurement.
        case ground
        /// An anchor correction moved everything captured together.
        case anchorCorrection
    }

    /// Where the flow is when the change arrives.
    public enum Screen: Equatable, Sendable, CaseIterable {
        /// Capturing or reviewing: no answer is up, and the next upload is built from the scan
        /// as it is then.
        case noAnswer
        /// The upload screen: the scan is on its way, or its answer is being readied.
        case sending
        /// The spot check, which draws the answer's spot on a kept photo.
        case spotCheck
        /// The result screen and its 3D preview.
        case result
        /// The result on the live camera.
        case resultInCamera
    }

    public enum Action: Equatable, Sendable {
        /// Leave the answer and the upload as they are.
        case keep
        /// Take the answer down everywhere and send the scan again from current state.
        case sendAgain
        /// Take the answer down, stop any upload, and show a failure that offers "Try again".
        case fail
    }

    /// True from the moment a ground change takes an answer down until an answer is shown on
    /// the result screen again (`answerShown()`).
    public private(set) var awaitingNewAnswer = false

    public init() {}

    /// The decision for one change on one screen, recording a withdrawal.
    public mutating func after(_ change: Change, on screen: Screen) -> Action {
        guard change == .ground else { return .keep }
        switch screen {
        case .noAnswer:
            return .keep
        case .sending:
            // A first upload is built from the scan at the moment it is packaged; only an
            // upload that is itself a resend has already used its one try.
            return awaitingNewAnswer ? .fail : .keep
        case .spotCheck, .result, .resultInCamera:
            if awaitingNewAnswer { return .fail }
            awaitingNewAnswer = true
            return .sendAgain
        }
    }

    /// An answer reached the result screen: the next ground change starts a new resend.
    public mutating func answerShown() {
        awaitingNewAnswer = false
    }
}
