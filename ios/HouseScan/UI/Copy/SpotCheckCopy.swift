import Foundation

/// The spot check's words (`SpotConfirmScreen`, and the guidance log's record of the questions).
extension ScanCopy {
    // MARK: What's in the area

    static let spotQuestion = Instruction(
        title: "Is anything in the marked area?",
        detail: "Look at the wall and the ground inside the blue outline. Photos can miss a low bush, a bin or a step."
    )
    static let spotClear = "It's clear"
    static let spotSomethingThere = "Something's in the way"
    static let spotUnmarked = "A gas meter, AC, window or door"
    static let spotClearHint = "Asks what the ground is next."
    static let spotSomethingThereHint = "A bush, a bin or a step. Leaves this area out of your scan and checks your wall again. An installer will look at it."
    static let spotUnmarkedHint = "One you didn't mark. You'll mark it on the camera."

    static let spotWhich = Instruction(
        title: "Which one isn't marked?",
        detail: "You'll mark it on the camera, then we'll check your wall again."
    )
    /// The kinds the spot check offers to mark: the equipment the server keeps a clearance from.
    static let spotUnmarkedKinds: [FeatureKind] = [.gasMeter, .acUnit, .window, .door]
    static let spotBack = "Back"

    // MARK: Ground

    /// Asked once the area is clear. The camera can't tell mulch from soil, so without this answer
    /// the server's check of the ground under the battery ends unsure.
    static let spotGroundQuestion = Instruction(
        title: "What's the ground where the battery would stand?",
        detail: "Inside the small outline. The battery can only stand on some kinds of ground."
    )

    // MARK: No photo shows it all

    static let spotUnconfirmable = Instruction(
        title: "Your photos don't show all of this area",
        detail: "So you can't check it here. We'll leave it out and check your wall again, and an installer will look at it."
    )
    static let spotContinue = "Continue"

    // MARK: Answered

    static func spotAnswered(_ answer: SpotCheckAnswer, checksAgain: Bool) -> Instruction {
        switch answer {
        case .clear(.type(let type)):
            Instruction(title: "Thanks, it's \(groundName(type).lowercased())", detail: checksAgain ? "Checking your spot again with it." : "Showing your result.")
        case .clear(.notSure):
            Instruction(title: "Thanks", detail: "Showing your result. An installer will check the ground.")
        case .somethingThere:
            Instruction(title: "Thanks, we'll leave that area out", detail: "Checking your wall again. An installer will look at what's there.")
        case .unmarkedCantMark(let kind):
            Instruction(
                title: "The \(noun(kind)) can't be marked now",
                detail: "Your phone lost its place. We'll leave that area out and check your wall again, and an installer will look at it.")
        case .unconfirmed:
            Instruction(title: "We'll leave that area out", detail: "Checking your wall again.")
        }
    }

    /// Said on the result when the spot's area was left out.
    static func spotLeftOut(_ answer: SpotCheckAnswer) -> String? {
        switch answer {
        case .clear: nil
        case .somethingThere, .unmarkedCantMark:
            "You said something is where this spot is. Your scan leaves that area out, and an installer will check it."
        case .unconfirmed:
            "Your photos didn't show all of this spot's area, so your scan leaves it out and an installer will check it."
        }
    }

    // MARK: Place

    /// "From 3 ft to 8 ft 6 in right of your meter": where the area runs. `spoken` spells the
    /// units out for VoiceOver.
    static func spotArea(_ span: ClosedRange<Float>, spoken: Bool = false) -> String {
        let length = { (meters: Float) in spoken ? Distance.spoken(meters) : Distance.feetAndInches(meters) }
        let low = span.lowerBound, high = span.upperBound
        if low >= 0 { return "From \(length(low)) to \(length(high)) right of your meter" }
        if high <= 0 { return "From \(length(high)) to \(length(low)) left of your meter" }
        return "From \(length(low)) left to \(length(high)) right of your meter"
    }

    /// What VoiceOver reads for the photo.
    static func spotPhotoDescription(_ check: SpotCheck) -> String {
        if check.step == .ground {
            return "A small outline marks where the battery would stand. \(spotArea(check.spot, spoken: true))."
        }
        return "A blue outline marks where the battery would stand and the space around it. \(spotArea(check.area, spoken: true))."
    }
}
