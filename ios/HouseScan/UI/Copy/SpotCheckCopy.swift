import Foundation

/// The spot check's words (`SpotConfirmScreen`, and the guidance log's record of the question).
extension ScanCopy {
    /// One question about the wall and the ground, with the reason for asking.
    static let spotQuestion = Instruction(
        title: "Is anything standing in the marked area?",
        detail: "Check the wall and the ground inside the blue outline. Photos can miss a low bush, a bin or a step."
    )
    static let spotClear = "It's clear"
    static let spotSomethingThere = "Something's there"
    static let spotClearHint = "Shows your result."
    static let spotSomethingThereHint = "Leaves this area out of your scan and checks your wall again. An installer will look at it."

    static func spotAnswered(_ answer: SpotCheckAnswer) -> Instruction {
        switch answer {
        case .clear: Instruction(title: "Thanks, it's clear", detail: "Showing your result.")
        case .somethingThere: Instruction(title: "Thanks, we'll leave that area out", detail: "Checking your wall again. An installer will look at what's there.")
        }
    }

    /// Said on the result when the homeowner said something stands where its spot is.
    static let spotRefused = "You said something stands where this spot is. Your scan leaves that area out, and an installer will check it."

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
        let place = spotArea(check.area, spoken: true)
        return "A blue outline marks where the battery would stand and the space around it. \(place)."
    }
}
