import Foundation
import HouseScanKit

/// One instruction: a short line the homeowner acts on, and an optional second line that says
/// how. Every camera screen shows exactly one of these at a time.
struct Instruction: Hashable {
    var title: String
    var detail: String?
}

/// All user-facing words for engine values. The engine sends meanings (contract `GuidanceStep`,
/// `Coaching`, ...); this file is the only place that turns them into copy, so the vocabulary
/// stays consistent: "photos", "the wall", "your meter", feet and inches.
enum ScanCopy {
    // MARK: Guidance

    /// `hint` changes the words of an aim step only (`aim(_:ground:hint:)`).
    static func guidance(_ step: GuidanceStep, hint: GuidanceHint? = nil) -> Instruction {
        switch step {
        case .findMeter:
            Instruction(
                title: "Find your electric meter",
                detail: "A gray box with a round glass dial or a small screen, usually on an outside wall."
            )
        case .aimAtWallForMeter:
            Instruction(title: "Hold on, finding your wall", detail: "Move your phone slowly side to side, then aim at your meter again.")
        case .holdOnMeter:
            Instruction(title: "Hold your meter in the circle", detail: "Your phone takes the photo by itself.")
        case .walk(let side, let remaining):
            Instruction(
                title: "Walk slowly to your \(side.rawValue)",
                detail: remaining.map { "Keep the wall and the ground in view. About \(Distance.remainingWalk($0)) to go." }
                    ?? "Keep the wall and the ground in view."
            )
        case .markEnd(let side):
            Instruction(
                title: "Is this the \(side.rawValue) end of the wall?",
                detail: "Aim where the wall stops or turns a corner, and tap Wall ends here."
            )
        case .aimAtGround(let s):
            // A cell counts once seen from two places at least 0.25 m apart (`coveringBaseline`),
            // so tilting down without moving never clears it.
            aim(
                Instruction(title: "Tilt down to show the ground", detail: "The strip along the wall, \(Distance.fromMeter(s)). Take a small step sideways as you look."),
                ground: true, hint: hint
            )
        case .aimAtWall(let s):
            // "Around at your meter" read wrong once the walk starts at the meter.
            aim(
                Instruction(title: "Tilt up to show more wall", detail: abs(s) < Distance.metersPerInch * 3 ? "At your meter." : "Around \(Distance.fromMeter(s))."),
                ground: false, hint: hint
            )
        case .stepBack:
            Instruction(title: "Take a step back", detail: "Your phone needs to see more of the wall at once.")
        case .tiltUp(let span):
            Instruction(
                title: "Tilt up to show above the area by your meter",
                detail: "Aim at the wall \(Distance.stretchAroundMeter(span)) and whatever is above it."
            )
        case .markNextWall(_, nil):
            Instruction(title: "Walk round the corner, then aim at the next wall", detail: "Put the circle on it and tap Mark next wall.")
        case .markNextWall(_, let refusal?):
            nextWallRefusal(refusal)
        case .walkComplete:
            Instruction(title: "That's the whole wall", detail: "Tap Done when you're ready.")
        case .seeBehind(let s):
            Instruction(
                title: "Something is in front of the wall here",
                // A place to look, not a measurement: "About 5 ft", not "4 ft 11 in".
                detail: "\(Distance.aroundFromMeter(s...s).capitalizedFirst). Look at it from the side or step around it."
            )
        case .gap:
            Instruction(title: "One more view", detail: nil)
        }
    }

    /// The line beside the walk's first aim ring, which fills as its stretch is captured (#81).
    /// A stretch counts only once it is seen from two places a step apart
    /// (`CoverageConfig.coveringBaseline`), so holding still never fills the ring: the line asks
    /// for a step.
    static let aimRingLegend = "Keep the ring in view and take a small step to one side. It fills as your phone captures this spot."

    /// An aim step's card with what the hint adds. The title follows the target: on build 4.1 the
    /// chevron pointed up while the card said "Tilt down" (#81). Seen once from here, the step to
    /// the side is the whole instruction (#77). Too close, "step back" joins the same card
    /// instead of replacing it with another (#77).
    private static func aim(_ base: Instruction, ground: Bool, hint: GuidanceHint?) -> Instruction {
        guard let hint else { return base }
        var copy = base
        if hint.needsSecondPosition {
            copy.title = "Now take one step to the side and look again"
        } else {
            switch hint.aim {
            case .above? where ground:
                copy.title = "Tilt up a little"
            case .below? where !ground:
                copy.title = "Tilt down a little"
            case .onScreen? where ground:
                copy.title = "Put the ring on the strip"
            default:
                break
            }
        }
        if hint.stepBack {
            copy.detail = [copy.detail, "Step back a little."].compactMap { $0 }.joined(separator: " ")
        }
        return copy
    }

    // MARK: Coaching

    static func coaching(_ coaching: Coaching) -> Instruction {
        switch coaching {
        case .initializing:
            Instruction(title: "Move your phone slowly", detail: "It's getting its bearings.")
        case .slowDown:
            Instruction(title: "Slow down", detail: "Walk a little slower so the photos stay sharp.")
        case .needsTexture:
            Instruction(title: "Aim at a corner or somewhere with more texture", detail: "A plain wall or the sky gives your phone nothing to follow.")
        case .tooDark:
            Instruction(title: "It's dark here", detail: "Some photos won't count. Try your phone's flashlight, or come back in daylight.")
        case .tooDarkToMeasure:
            Instruction(title: "It's too dark to measure here", detail: "Try in daylight.")
        case .holdSteady:
            Instruction(title: "Hold steady", detail: nil)
        case .turnSlowly:
            Instruction(title: "Turn more slowly", detail: "Photos taken while turning come out blurred.")
        case .relocalizing:
            Instruction(title: "Point at the meter like this.", detail: "Your phone lost its place for a moment.")
        case .trackingLost:
            Instruction(title: "Your phone lost its place", detail: "Aim back at your meter and move slowly.")
        case .pastWallEnd:
            Instruction(title: "You're past the end of the wall", detail: "Photos here aren't kept. Walk back toward your meter.")
        }
    }

    /// Short symbol for a coaching pill.
    static func coachingSymbol(_ coaching: Coaching) -> String {
        switch coaching {
        case .initializing: "iphone.gen3.radiowaves.left.and.right"
        case .slowDown: "tortoise.fill"
        case .needsTexture: "square.grid.3x3.middle.filled"
        case .tooDark, .tooDarkToMeasure: "moon.fill"
        case .holdSteady: "hand.raised.fill"
        case .turnSlowly: "arrow.clockwise"
        case .relocalizing, .trackingLost: "location.slash.fill"
        case .pastWallEnd: "arrow.uturn.backward"
        }
    }

    /// One short line for coaching that rides along with the task instead of replacing it (the
    /// walk's capture-gate coaching): the task's title and second line stay, and this goes under
    /// them. Only the coaching's title, so the task's own words stay the bigger part of the card.
    static func coachingNote(_ coaching: Coaching) -> String {
        let title = ScanCopy.coaching(coaching).title
        return title.hasSuffix(".") ? title : "\(title)."
    }

    /// Tracking problems and standing past the end replace the task on the card: nothing the task
    /// asks for counts until they clear. The capture gate's coaching and too little texture ride
    /// along with it instead (`withCoaching`). No `default`, so a new case has to pick a side.
    static func coachingReplacesTask(_ coaching: Coaching) -> Bool {
        switch coaching {
        case .initializing, .relocalizing, .trackingLost, .pastWallEnd: true
        case .slowDown, .needsTexture, .tooDark, .tooDarkToMeasure, .holdSteady, .turnSlowly: false
        }
    }

    /// The task with ride-along coaching under it: the task's title and second line both stay (on
    /// an aim step the second line is the only thing that says where to aim), and the coaching adds
    /// its own short line (`coachingNote`). Replacing the whole card hid the task each time the
    /// coaching came up (#80), and the dark coaching can stay up for a whole night walk.
    static func withCoaching(_ task: Instruction, _ coaching: Coaching?) -> Instruction {
        guard let coaching else { return task }
        let detail = [task.detail, coachingNote(coaching)].compactMap { $0 }.joined(separator: "\n")
        return Instruction(title: task.title, detail: detail)
    }

    // MARK: Wall ends

    /// Under the wall map when ending the wall at the dashed line would cut off part of the walk,
    /// only while the walk asks to walk that way or mark the end (`EndPreview.leavesOutWalked`).
    static func endLeavesOut(_ meters: Float) -> String {
        "Ending the wall here leaves out \(Distance.roughFeet(meters)) you walked"
    }

    /// Over the walk's own prompt after "Done with this wall" was refused and the ends cleared
    /// (`ScanViewState.wallTooShort`).
    static let wallTooShort = "The ends were too close. Walk along the wall first."

    // MARK: Close-up

    static func closeUpProblem(_ problem: CloseUpProblem) -> String {
        switch problem {
        case .blurry: "Hold still"
        case .tooDark: "Too dark to read. Try your phone's flashlight."
        case .tooBright: "Too much glare. Tilt the phone a little."
        case .meterNotCentered: "Center the meter in the circle"
        case .tooFar: "Move closer to the meter"
        case .tracking: "Move slowly"
        case .numberTooSmall: "Move closer so the number looks bigger"
        case .noNumber: "Couldn't read the number. Hold still for another photo."
        }
    }

    /// The instruction while the meter number is read and confirmed; nil once it's settled or
    /// skipped, when the close-up's own instruction applies.
    static func meterNumber(_ state: MeterNumberState?) -> Instruction? {
        switch state {
        case .reading:
            Instruction(title: "Reading your meter number", detail: "One moment.")
        case .choose:
            Instruction(title: "Which number is on your meter?", detail: "Check it against the meter, then tap it.")
        case .confirmed(let number):
            Instruction(title: "Meter number saved", detail: number)
        case .skipped, nil:
            nil
        }
    }

    static let barcodeMatch = "Matches the barcode"
    /// The maker read on the close-up, above the number candidates.
    static func meterBrand(_ brand: String) -> String { "\(brand) meter" }
    static func notMeterBrand(_ brand: String) -> String { "Not \(brand)" }
    static let noneOfThese = "None of these"

    // MARK: Features

    static func name(_ kind: FeatureKind) -> String {
        switch kind {
        case .gasMeter: "Gas meter"
        case .door: "Door"
        case .window: "Window"
        case .acUnit: "AC unit"
        case .driveway: "Driveway"
        case .fence: "Fence"
        }
    }

    /// The name mid-sentence: "Tap the gas meter", "Mark AC unit". Lowercasing `name` read
    /// "ac unit" (B-16).
    static func noun(_ kind: FeatureKind) -> String {
        switch kind {
        case .acUnit: "AC unit"
        default: name(kind).lowercased()
        }
    }

    static func symbol(_ kind: FeatureKind) -> String {
        switch kind {
        case .gasMeter: "flame.fill"
        case .door: "door.left.hand.closed"
        case .window: "window.vertical.closed"
        case .acUnit: "fan.fill"
        case .driveway: "car.fill"
        case .fence: "square.split.2x1"
        }
    }

    /// Under an AC unit on the review: one tap gives no size, so the scene sends it as a square
    /// of `SceneExport.acAssumedSide` (#72), and the homeowner is told the size is assumed.
    static let acAssumedSize: String = {
        let side = Distance.feetAndInches(SceneExport.acAssumedSide)
        return "Assumed about \(side) \u{00D7} \(side)"
    }()
    /// `acAssumedSize` for VoiceOver, which reads "ft" as letters.
    static let acAssumedSizeSpoken: String = {
        let side = Distance.spoken(SceneExport.acAssumedSide)
        return "Assumed about \(side) by \(side)"
    }()

    /// The window question's way out: sent as unknown, like no answer.
    static let windowNotSure = "Not sure"

    /// Over "Looks complete" after its first tap found a question unanswered (#65).
    static let reviewUnanswered = "A question above has no answer yet. Answer it, or tap Looks complete again to send."

    /// Under a reviewed mark that lies wholly past a marked end (`ScanViewState.featuresPastEnds`).
    static let featurePastEnd = "Past the end of your scan"

    static func markingPrompt(_ marking: MarkingState) -> Instruction {
        let item = noun(marking.kind)
        switch (marking.kind, marking.step) {
        case (.door, 0), (.window, 0):
            return Instruction(title: "Tap the \(item)'s bottom-left corner", detail: "Put the circle on it and tap Mark, or tap it on screen.")
        case (.door, _), (.window, _):
            return Instruction(title: "Now tap its top-right corner", detail: nil)
        case (.driveway, 0):
            return Instruction(title: "Tap one end of the driveway's edge", detail: "Use the edge closest to the wall.")
        case (.driveway, _):
            return Instruction(title: "Now tap the other end of that edge", detail: nil)
        case (.fence, 0):
            return Instruction(title: "Tap the bottom of the fence at one end", detail: "Where it meets the ground.")
        case (.fence, _):
            return Instruction(title: "Now tap the bottom at the other end", detail: nil)
        case (.gasMeter, _), (.acUnit, _):
            return Instruction(title: "Tap the \(item)", detail: "Put the circle on it and tap Mark, or tap it on screen.")
        }
    }

    static func refusal(_ refusal: MarkRefusal) -> String {
        switch refusal {
        case .noSurface: "Nothing to pin there. Aim at the wall or the ground and try again."
        case .wrongSide: "That spot is behind the wall. Tap something on this side."
        case .tooFarFromWall: "That's too far from the wall to matter. Tap something closer."
        case .trackingNotReady: "One moment, your phone is still finding its place."
        }
    }

    /// Asked after the next wall is marked, before the walk follows the corner
    /// (`ScanViewState.nextWallConfirm`, #70): a surface behind the end post passed the checks
    /// on build 4.1. The ring is on the point marked.
    static func nextWallConfirm(_ confirm: NextWallConfirm) -> Instruction {
        Instruction(
            title: "Is this the next wall?",
            detail: "The ring is on the wall you marked. It meets this wall about \(Distance.roughFeet(confirm.fromEnd)) from where you ended it."
        )
    }

    /// A refused mark of the next wall: what went wrong, then what to do.
    static func nextWallRefusal(_ refusal: NextWallRefusal) -> Instruction {
        switch refusal {
        case .noSurface: Instruction(title: "No wall under the circle", detail: "Step closer and aim at the next wall.")
        case .trackingNotReady: Instruction(title: "One moment, your phone is still finding its place", detail: "Then aim at the next wall.")
        case .sameWall: Instruction(title: "That looks like the same wall", detail: "Aim at the wall round the corner.")
        case .notAtCorner: Instruction(title: "That wall doesn't meet this one at the corner", detail: "Aim at the wall right round the corner.")
        }
    }

    // MARK: Ground

    /// Asked on the feature review. The camera can't tell mulch from soil, so without this answer
    /// the server's check of the ground under the battery always ends unsure.
    static let groundQuestion = Instruction(
        title: "What's on the ground along this wall?",
        detail: "The battery can only stand on some kinds of ground."
    )
    /// Names the homeowner would use: "Grass", not the schema's "lawn".
    static func groundName(_ type: GroundType) -> String {
        switch type {
        case .lawn: "Grass"
        case .mulch: "Mulch"
        case .gravel: "Gravel"
        case .concrete: "Concrete"
        case .drive: "Driveway"
        case .deck: "Deck"
        }
    }
    static let groundNotSure = "Not sure"
    static func groundAnswer(_ answer: GroundAnswer) -> String {
        switch answer {
        case .type(let type): groundName(type)
        case .notSure: groundNotSure
        }
    }
    /// The label over the answer once the question has folded into a row.
    static let groundAnsweredLabel = "Ground along the wall"
    static let groundChange = "Change"

    // MARK: Gap

    /// The card for a gap request. A server request can run along much of the wall, so its
    /// stretch is named by its two ends, all of it (issue #75, `Distance.range`); the phone's own
    /// requests are short and named by their middle.
    static func gap(_ gap: GapRequest) -> Instruction {
        let place = Distance.aroundFromMeter(gap.span)
        let stretch = Distance.range(gap.span)
        switch gap.reason {
        case .groundNearCandidate:
            return Instruction(title: "Show the ground \(place)", detail: "This might be a spot for the battery, so the ground there needs a clear look from two places.")
        case .wallAboveCandidate:
            return Instruction(title: "Show the wall \(place)", detail: "Tilt up so the wall above this spot is in view.")
        case .server(let detail):
            return Instruction(title: gap.band == .ground ? "Show the ground \(stretch)" : "Show the wall \(stretch)", detail: detail)
        case .groundOut(let out):
            return Instruction(
                title: "Show the ground out to about \(Distance.feetAtLeast(out)) from the wall",
                detail: "\(stretch.capitalizedFirst). Step back and tilt down until that much ground is in view."
            )
        case .walkOut(let out):
            return Instruction(
                title: "Walk along this stretch about \(Distance.feetAtLeast(out)) out from the wall",
                detail: "\(stretch.capitalizedFirst). Follow the dotted line. Walking there shows nothing stands in front of the wall."
            )
        case .overhead:
            return Instruction(
                title: "Tilt up here",
                detail: "\(place.capitalizedFirst). Show the wall above this spot, up to the roof or the sky."
            )
        }
    }

    /// The reply on the see-behind step: the homeowner can't get a view past the obstruction.
    static let cannotSeeBehind = "Can't see past it"

    // MARK: Card replies

    /// The walk card's reply (`ScanActions.cannotAccessArea`) and its VoiceOver hint, worded for
    /// what it does on `step`; nil on a step that offers none. On an aim or tilt step the
    /// homeowner is already at the spot and it's the view that can't be had, so "Can't get
    /// there" read as the wrong answer and testers kept tilting (#63). It stays on the steps
    /// that ask to go somewhere. The wall's end (`markEnd`) has "Wall ends here" instead.
    static func reply(for step: GuidanceStep) -> (title: String, hint: String)? {
        switch step {
        case .aimAtGround, .aimAtWall:
            (title: "Skip this spot", hint: "An installer will look at it instead.")
        case .tiltUp:
            (title: "Skip this", hint: "Skips the view above this part of the wall. An installer will look at it instead.")
        case .walk:
            (title: "Can't get there", hint: "Ends the wall at the dashed line on the map. An installer will look at what's past it.")
        case .markNextWall:
            (title: "Can't get there", hint: "Skips this part of the wall. An installer will look at it instead.")
        case .seeBehind:
            (title: cannotSeeBehind, hint: "Skips the part behind it. An installer will look at it instead.")
        case .findMeter, .aimAtWallForMeter, .holdOnMeter, .markEnd, .stepBack, .walkComplete, .gap:
            nil
        }
    }

    // MARK: Follow-up view

    /// The check came back asking for views the camera can take now; the scan goes straight
    /// back to the camera for them before the result. Said on the upload screen as it hands
    /// over and on the camera card that follows, so the two read as one step.
    static func followUp(remaining: Int) -> String {
        remaining <= 1 ? "One more view to finish" : "\(remaining) more views to finish"
    }

    /// A sample result checked nothing, so it must not say the wall was checked.
    static func followUpDetail(sample: Bool) -> String {
        sample
            ? "The example result asks for another view, so the camera opens again. Nothing leaves this phone."
            : "The check needs a view the camera can take now. Your result comes right after."
    }

    // MARK: Upload

    /// The question after the tilt-up view. The camera can't tell open sky from an eave.
    static let overheadQuestion = Instruction(
        title: "What's above that part of the wall?",
        detail: "The battery needs clear space above it."
    )
    static let overheadClear = "Open sky or nothing overhead"
    static let overheadCovered = "A roof edge, porch or stairs"

    /// The question after "Wall ends here". A corner means the wall goes on out of sight, which
    /// the result must not treat as the end of usable wall. `leavesOut` is how much of the walk
    /// the end just made leaves out (`ScanViewState.endQuestionLeavesOut`), said here since the
    /// strip says it only while the walk asks to walk that way (#66).
    static func endQuestion(_ side: WallSide, leavesOut: Float? = nil) -> Instruction {
        let why = "This tells the installer whether the wall keeps going."
        let detail = leavesOut.map { "This leaves out \(Distance.roughFeet($0)) you walked. \(why)" } ?? why
        return Instruction(title: "What's at the \(side.rawValue) end?", detail: detail)
    }

    /// With no server connected nothing is sent, and the words must not say it is.
    /// `followUps` is how many views the finished check still wants from the camera.
    static func upload(_ upload: UploadState, sample: Bool, followUps: Int = 0) -> Instruction {
        if upload == .done, followUps > 0 {
            return Instruction(title: followUp(remaining: followUps), detail: followUpDetail(sample: sample))
        }
        if sample {
            switch upload {
            case .idle, .packaging, .uploading, .analyzing:
                return Instruction(title: "Making a sample result", detail: "No server is connected, so nothing leaves this phone. The result you'll see is an example, not a check of your wall.")
            case .failed, .rejected, .done:
                break
            }
        }
        return self.upload(upload)
    }

    static func upload(_ upload: UploadState) -> Instruction {
        switch upload {
        // The upload carries the wall's measurements; the photos stay on the phone.
        case .idle, .packaging:
            Instruction(title: "Getting your measurements ready", detail: nil)
        case .uploading:
            Instruction(title: "Sending your measurements", detail: "Keep the app open until this finishes.")
        case .analyzing:
            Instruction(title: "Checking your wall", detail: "Measuring clearances around your meter.")
        case .failed(let message, let offline):
            offline
                ? Instruction(title: "You're offline", detail: "Your scan is saved on this phone. Try again when you have signal.")
                : Instruction(title: "That didn't go through", detail: message)
        // The engine's message is already in the homeowner's words and says why.
        case .rejected(let message):
            Instruction(title: "We couldn't check this scan", detail: message)
        case .done:
            Instruction(title: "Done", detail: nil)
        }
    }

    // MARK: Result

    /// The answer in the homeowner's words (`ResultPresentation.answer`).
    static func headline(_ answer: ResultReading.Answer) -> String {
        switch answer {
        case .fits: "A battery fits here"
        case .oneMoreLook: "One more look"
        case .installer: "An installer will confirm"
        case .notHere: "Not on this wall"
        }
    }

    /// The one line under the headline: where, and how much cable, for a pass.
    static func placement(_ result: ResultPresentation) -> String? {
        guard let spot = result.spot else { return nil }
        let center = (spot.span.lowerBound + spot.span.upperBound) / 2
        var line = Distance.fromMeter(center).capitalizedFirst
        if let cable = result.cableLength {
            line += ", \(Distance.roughFeet(cable)) of cable"
        }
        return line
    }

    /// Why the closest spot doesn't work, for a result without a spot: "The closest spot, 4 ft
    /// left of your meter, fails this check: distance from gas equipment. Measured 2 ft 4 in. The
    /// rule is at least 3 ft." The check's title follows a colon because the server's titles name
    /// what a passing spot has ("No box or vent above the battery"), so a sentence that used one
    /// as the failure would say the opposite for some of them.
    static func nearest(_ result: ResultPresentation, spoken: Bool = false) -> String? {
        guard let spot = result.nearestSpot, let id = result.nearestFailingCheck,
              let row = result.checks.first(where: { $0.id == id }) else { return nil }
        let center = (spot.span.lowerBound + spot.span.upperBound) / 2
        let place = spoken && abs(center) >= Distance.metersPerInch * 3
            ? "\(Distance.spoken(center)) \(center < 0 ? "left" : "right") of your meter"
            : Distance.fromMeter(center)
        var line = "The closest spot, \(place), fails this check: \(row.title.lowercasedFirst)."
        if let measurement = measurement(row, spoken: spoken) {
            line += " \(measurement)"
        }
        return line
    }

    /// The sentence under a failed or unsure line on the result card: the measurement against the
    /// rule, or without a measurement, the server's reason (fail) or who settles it (unsure).
    static func cardLine(_ row: CheckRow, spoken: Bool = false) -> String? {
        switch row.outcome {
        case .pass: nil
        case .fail: measurement(row, spoken: spoken) ?? row.reason
        case .unsure: measurement(row, spoken: spoken) ?? unsureNote(row)
        }
    }

    /// "Settles: distance from the gas meter, clear space in front": the checks a requested view
    /// would settle, by their titles. A check a person has to judge (a borderline measurement, an
    /// unknown attribute) stays off the list: another view doesn't settle it. Nil when none is left.
    static func settles(_ item: MissingEvidence, checks: [CheckRow]) -> String? {
        let titles = item.checkIDs.compactMap { id in
            checks.first { $0.id == id && !$0.needsPerson }?.title.lowercasedFirst
        }
        guard !titles.isEmpty else { return nil }
        return "Settles: \(titles.joined(separator: ", "))"
    }

    static let seeOnWall = "See it on your wall"
    /// For a spot an installer still has to confirm against the meter's working space.
    static let seeClosest = "See the closest spot"
    static let showMe = "Show me"
    static let scanAnotherWall = "Scan another wall"
    static let details = "Details"

    static let installerConfirms = "An installer confirms this on site."
    static let rulesNotFinal = "The placement rules aren't final yet, so an installer reviews every result for now."
    // The server's result covers where the battery goes, not the panel itself.
    static let panelReview = "Your electrical panel still needs an electrician's review. This scan only covers where the battery can go."

    /// Which rules answered, for a reviewer: "Rules 2f52ec35".
    static func rulesHash(_ hash: String) -> String {
        "Rules \(hash)"
    }

    static func unseenSide(_ side: WallSide) -> String {
        "A closer spot may exist on the \(side.rawValue) of your meter. The scan didn't reach that side."
    }

    /// The note on an unexplored end nearer the meter than the spot (issue #83): where the scan
    /// stopped, so the homeowner knows which end is meant. Without a spot, any spot past it.
    static func unseenEnd(_ end: UnseenEnd, hasSpot: Bool) -> String {
        "The scan stopped \(Distance.fromMeter(end.s)). \(hasSpot ? "A closer spot" : "A spot") may be past there."
    }

    static let shareScan = "Share scan"
    static let shareScanContents = "Your photos and measurements, for the House Scan team"

    static func unsureNote(_ row: CheckRow) -> String {
        row.needsPerson ? "An installer will check this" : "One more photo would settle this"
    }

    /// "Measured 3 ft 2 in. The rule is at least 3 ft, and the measurement can be off by about 4 in."
    /// The limit says whether it is a minimum or a maximum: without it, the 20 ft cable limit read
    /// like a minimum under "Measured 3 ft".
    /// `spoken` spells out feet and inches for VoiceOver, which reads "ft" and "in" as letters.
    static func measurement(_ row: CheckRow, spoken: Bool = false) -> String? {
        guard let measured = row.measured else { return nil }
        let length = spoken ? Distance.spoken : Distance.feetAndInches
        var parts = [measuredLine(measured, length: length)]
        if let threshold = row.threshold {
            let limit = ruleLimit(threshold, row.comparison, length: length)
            if let plusMinus = row.plusMinus, plusMinus > 0 {
                parts.append("The rule is \(limit), and the measurement can be off by about \(length(plusMinus)).")
            } else {
                parts.append("The rule is \(limit).")
            }
        }
        return parts.joined(separator: " ")
    }

    /// "Measured 3 ft 2 in.", or "Overlaps by 1 ft 3 in." below zero. A clearance the server
    /// measures to an area (the meter's working space, a box on the wall above) goes negative
    /// once the battery is inside it, and the bare magnitude read as clearance (#40). Less than
    /// half an inch of overlap stays "Measured 0 in.", not "Overlaps by 0 in.".
    static func measuredLine(_ measured: Float, length: (Float) -> String = Distance.feetAndInches) -> String {
        if measured <= -Distance.metersPerInch / 2 {
            return "Overlaps by \(length(measured))."
        }
        return "Measured \(length(measured))."
    }

    /// "at least 3 ft", "at most 20 ft", or the bare distance when the server didn't say which.
    /// A minimum of 0 reads "no overlap": "at least 0 in" says the same thing less plainly.
    static func ruleLimit(_ threshold: Float, _ comparison: RuleComparison?, length: (Float) -> String = Distance.feetAndInches) -> String {
        let distance = length(threshold)
        guard let comparison else { return distance }
        switch comparison {
        case .atLeast: return threshold < Distance.metersPerInch / 2 ? "no overlap" : "at least \(distance)"
        case .atMost: return "at most \(distance)"
        }
    }

    static func outcomeWord(_ outcome: CheckOutcome) -> String {
        switch outcome {
        case .pass: "Looks good"
        case .unsure: "Not sure yet"
        case .fail: "Doesn't work"
        }
    }

    // MARK: Failure

    static func failure(_ failure: ScanFailure) -> Instruction {
        switch failure {
        case .cameraDenied:
            Instruction(title: "House Scan needs your camera", detail: "It uses the camera to measure the wall around your meter. Turn on Camera for House Scan in Settings.")
        case .arUnsupported:
            Instruction(title: "This phone can't measure walls", detail: "House Scan needs an iPhone that supports motion tracking with the camera. Try another iPhone from the last few years.")
        // The engine's messages for these two are system error text (ARKit's, or the replay
        // loader's), not the homeowner's words, so they aren't shown.
        case .sessionFailed:
            Instruction(title: "The camera stopped", detail: "Something interrupted the camera partway through. Start over to try again.")
        case .replayUnreadable:
            Instruction(title: "This recording can't be opened", detail: "Some of its files are missing or damaged, so it can't be played back.")
        }
    }
}
