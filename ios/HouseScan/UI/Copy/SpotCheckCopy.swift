import Foundation

/// The spot check's words (`SpotConfirmScreen`, and the guidance log's record of the question).
extension ScanCopy {
    /// One question about the wall and the ground, with the reason for asking, when the area is
    /// outlined on a photo.
    static let spotQuestion = Instruction(
        title: "Is anything standing in the marked area?",
        detail: "Check the wall and the ground inside the blue outline. Photos can miss a low bush, a bin or a step."
    )

    /// The same question when no outline is drawn: no kept photo shows the area, or there is no
    /// wall to draw it with. The area is then given in words (`spotSpace`), so nothing points
    /// at an outline that isn't on screen.
    static let spotQuestionInPerson = Instruction(
        title: "Is anything standing in this space?",
        detail: "We couldn't mark this space on a photo, so take a look yourself. Check the wall and the ground for a low bush, a bin, a step or anything else."
    )
    static let spotSpaceTitle = "Where to look"

    /// The question as shown (`SpotCheck.outline(on:)`), on screen and in the guidance log.
    static func spotQuestionShown(outlined: Bool) -> Instruction {
        outlined ? spotQuestion : spotQuestionInPerson
    }
    static let spotClear = "It's clear"
    static let spotSomethingThere = "Something's there"
    /// For a homeowner who can't see or reach the area, so they needn't guess between the other
    /// two. It says nothing about what is there.
    static let spotCannotCheck = "I can't check this area"
    static let spotClearHint = "Shows your result."
    static let spotSomethingThereHint = "Leaves this area out of your scan and checks your wall again. An installer would need to look at it."
    static let spotCannotCheckHint = "Leaves this area out of your scan as not checked, and checks your wall again. Someone would need to check it in person."

    static func spotAnswered(_ answer: SpotCheckAnswer) -> Instruction {
        switch answer {
        case .clear: Instruction(title: "Thanks, it's clear", detail: "Showing your result.")
        case .somethingThere: Instruction(title: "Thanks, we'll leave that area out", detail: "Checking your wall again. An installer would need to look at what's there.")
        case .cannotCheck: Instruction(title: "Thanks, we'll mark that area not checked", detail: "Checking your wall again. Someone would need to check that area in person.")
        }
    }

    /// Said on the result when the homeowner said something stands where its spot is.
    static let spotRefused = "You said something stands where this spot is. Your scan leaves that area out, and an installer would need to check it."
    /// Said on the result when the homeowner couldn't check the spot's area. It says the area
    /// went unchecked, never that something was seen there or that anyone has been asked to look.
    static let spotNotChecked = "You couldn't check the area around this spot, so your scan leaves it out as not checked. Someone would need to check it in person."
    /// Said on the result when an area the homeowner couldn't check is not this result's spot: the
    /// answer after it names no spot, or a spot elsewhere. That area still counts as unseen.
    /// Beside a notice about this spot it speaks of another area.
    static func scanNotChecked(besideSpotNotice: Bool) -> String {
        let which = besideSpotNotice ? "You also couldn't check another area along this wall" : "You couldn't check an area along this wall"
        return "\(which), so your scan leaves it out as not checked. Someone would need to check it in person."
    }

    /// "From 3 ft to 8 ft 6 in right of your meter": where the area runs along the wall, nearer
    /// end first. An end less than half an inch from the meter rounds to 0 in and is read as the
    /// meter itself, so -0.3...24 in reads "From your meter to 2 ft right of it", not "From 0 in
    /// left to 2 ft right". `spoken` spells the units out for VoiceOver.
    static func spotArea(_ span: ClosedRange<Float>, spoken: Bool = false) -> String {
        let length = { (meters: Float) in spoken ? Distance.spoken(meters) : Distance.feetAndInches(meters) }
        let side = { (s: Float) in s < 0 ? "left" : "right" }
        let atMeter = { (s: Float) in Int((abs(s) / Distance.metersPerInch).rounded()) == 0 }
        let low = span.lowerBound, high = span.upperBound
        switch (atMeter(low), atMeter(high)) {
        case (true, true): return "At your meter"
        case (true, false): return "From your meter to \(length(high)) \(side(high)) of it"
        case (false, true): return "From your meter to \(length(low)) \(side(low)) of it"
        case (false, false): break
        }
        if low >= 0 { return "From \(length(low)) to \(length(high)) right of your meter" }
        if high <= 0 { return "From \(length(high)) to \(length(low)) left of your meter" }
        return "From \(length(low)) left to \(length(high)) right of your meter"
    }

    /// The asked-about area's three extents, each readable on its own: along the wall from the
    /// meter (`SpotCheck.area`), out from the wall over the ground (`SpotCheck.areaDepth`), and up
    /// the wall face to the battery's height (`SpotCheck.spotHeight`). These are the edges
    /// `SpotOutline` draws on a photo, and no more: the words describe the area the question is
    /// about, not every clearance the server checks.
    static func spotSpace(_ check: SpotCheck, spoken: Bool = false) -> (along: String, out: String, up: String) {
        let length = { (meters: Float) in spoken ? Distance.spoken(meters) : Distance.feetAndInches(meters) }
        return (
            along: spotArea(check.area, spoken: spoken),
            out: "From the wall out to \(length(check.areaDepth))",
            up: "From the ground up to \(length(check.spotHeight))"
        )
    }

    /// `spotSpace` as one spoken sentence, for VoiceOver.
    static func spotSpaceSpoken(_ check: SpotCheck) -> String {
        let space = spotSpace(check, spoken: true)
        return "\(space.along), \(space.out.lowercasedFirst), and \(space.up.lowercasedFirst)."
    }

    /// What VoiceOver reads for the outlined photo: what the outline marks, and where, since a
    /// VoiceOver user can't see the outline's edges.
    static func spotPhotoDescription(_ check: SpotCheck) -> String {
        "A blue outline marks where the battery would stand and the space around it. \(spotSpaceSpoken(check))"
    }
}
