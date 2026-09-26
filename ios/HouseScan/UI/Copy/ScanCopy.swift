import Foundation

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

    static func guidance(_ step: GuidanceStep) -> Instruction {
        switch step {
        case .findMeter:
            Instruction(
                title: "Find your electric meter",
                detail: "A gray box with a round glass dial or a small screen, usually on an outside wall."
            )
        case .aimAtWallForMeter:
            Instruction(title: "Step a little closer to the wall", detail: "Then aim at your meter again.")
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
            Instruction(title: "Tilt down to show the ground", detail: "The strip along the wall, \(Distance.fromMeter(s)).")
        case .aimAtWall(let s):
            Instruction(title: "Tilt up to show more wall", detail: "Around \(Distance.fromMeter(s)).")
        case .stepBack:
            Instruction(title: "Take a step back", detail: "Your phone needs to see more of the wall at once.")
        case .walkComplete:
            Instruction(title: "That's the whole wall", detail: "Tap Done when you're ready.")
        case .gap:
            Instruction(title: "One more view", detail: nil)
        }
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
            Instruction(title: "It's too dark to see the wall", detail: "Turn on a porch light, or try again in daylight.")
        case .holdSteady:
            Instruction(title: "Hold steady", detail: nil)
        case .relocalizing:
            Instruction(title: "Point at the meter like this.", detail: "Your phone lost its place for a moment.")
        case .trackingLost:
            Instruction(title: "Your phone lost its place", detail: "Aim back at your meter and move slowly.")
        }
    }

    /// Short symbol for a coaching pill.
    static func coachingSymbol(_ coaching: Coaching) -> String {
        switch coaching {
        case .initializing: "iphone.gen3.radiowaves.left.and.right"
        case .slowDown: "tortoise.fill"
        case .needsTexture: "square.grid.3x3.middle.filled"
        case .tooDark: "moon.fill"
        case .holdSteady: "hand.raised.fill"
        case .relocalizing, .trackingLost: "location.slash.fill"
        }
    }

    // MARK: Close-up

    static func closeUpProblem(_ problem: CloseUpProblem) -> String {
        switch problem {
        case .blurry: "Hold still"
        case .tooDark: "Too dark to read. Try your phone's flashlight."
        case .tooBright: "Too much glare. Tilt the phone a little."
        case .meterNotCentered: "Center the meter in the circle"
        case .tooFar: "Move closer to the meter"
        case .tracking: "Move slowly"
        case .numberTooSmall: "Move closer so the numbers are bigger"
        case .noNumber: "We couldn't read the numbers. Try again."
        }
    }

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

    static func markingPrompt(_ marking: MarkingState) -> Instruction {
        let noun = name(marking.kind).lowercased()
        switch (marking.kind, marking.step) {
        case (.door, 0), (.window, 0):
            return Instruction(title: "Tap the \(noun)'s bottom-left corner", detail: "Put the circle on it and tap Mark, or tap it on screen.")
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
            return Instruction(title: "Tap the \(noun)", detail: "Put the circle on it and tap Mark, or tap it on screen.")
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

    // MARK: Gap

    static func gap(_ gap: GapRequest) -> Instruction {
        let place = Distance.aroundFromMeter(gap.span)
        switch gap.reason {
        case .groundNearCandidate:
            return Instruction(title: "Show the ground \(place)", detail: "This might be a spot for the battery, so the ground there needs a clear look from two places.")
        case .wallAboveCandidate:
            return Instruction(title: "Show the wall \(place)", detail: "Tilt up so the wall above this spot is in view.")
        case .server(let detail):
            return Instruction(title: gap.band == .ground ? "Show the ground \(place)" : "Show the wall \(place)", detail: detail)
        }
    }

    // MARK: Upload

    /// The question after "Wall ends here". A corner means the wall goes on out of sight, which
    /// the result must not treat as the end of usable wall.
    static func endQuestion(_ side: WallSide) -> Instruction {
        Instruction(title: "What's at the \(side.rawValue) end?", detail: "This tells the installer whether the wall keeps going.")
    }

    /// With no server connected nothing is sent, and the words must not say it is.
    static func upload(_ upload: UploadState, sample: Bool) -> Instruction {
        if sample {
            switch upload {
            case .idle, .packaging, .uploading, .analyzing:
                return Instruction(title: "Making a sample result", detail: "No server is connected, so your photos stay on this phone. The result you'll see is an example, not a check of your wall.")
            case .failed, .rejected, .done:
                break
            }
        }
        return self.upload(upload)
    }

    static func upload(_ upload: UploadState) -> Instruction {
        switch upload {
        case .idle, .packaging:
            Instruction(title: "Getting your photos ready", detail: nil)
        case .uploading:
            Instruction(title: "Sending your photos", detail: "Keep the app open. It takes about a minute.")
        case .analyzing:
            Instruction(title: "Checking your wall", detail: "Measuring clearances around your meter.")
        case .failed(let message, let offline):
            offline
                ? Instruction(title: "You're offline", detail: "Your scan is saved on this phone. Try again when you have signal.")
                : Instruction(title: "That didn't go through", detail: message)
        case .rejected(let message):
            // Placeholder wording until the UI lane's pass on the rejected state.
            Instruction(title: "The scan couldn't be checked", detail: message)
        case .done:
            Instruction(title: "Done", detail: nil)
        }
    }

    // MARK: Result

    static func headline(_ result: ResultPresentation) -> String {
        switch result.decision {
        case .pass: "There's a spot for your battery"
        case .manualReview: "An installer will take a look"
        case .reject: "This wall doesn't have a spot"
        }
    }

    /// The one line under the headline: where, and how much cable, for a pass.
    static func placement(_ result: ResultPresentation) -> String? {
        guard let spot = result.spot else { return nil }
        let center = (spot.span.lowerBound + spot.span.upperBound) / 2
        var line = Distance.fromMeter(center).prefix(1).uppercased() + Distance.fromMeter(center).dropFirst()
        if let cable = result.cableLength {
            line += ", \(Distance.roughFeet(cable)) of cable"
        }
        return line
    }

    static let rulesNotFinal = "The placement rules aren't final yet, so an installer reviews every result for now."

    static func unsureNote(_ row: CheckRow) -> String {
        row.needsPerson ? "An installer will check this" : "One more photo would settle this"
    }

    /// "Measured 3 ft 2 in. The rule is 3 ft, and the measurement can be off by about 4 in."
    static func measurement(_ row: CheckRow) -> String? {
        guard let measured = row.measured else { return nil }
        var parts = ["Measured \(Distance.feetAndInches(measured))."]
        if let threshold = row.threshold {
            if let plusMinus = row.plusMinus, plusMinus > 0 {
                parts.append("The rule is \(Distance.feetAndInches(threshold)), and the measurement can be off by about \(Distance.feetAndInches(plusMinus)).")
            } else {
                parts.append("The rule is \(Distance.feetAndInches(threshold)).")
            }
        }
        return parts.joined(separator: " ")
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
