import CoreGraphics
import Foundation
import HouseScanKit
import ImageIO
import OSLog

/// The spot check's state on the engine (`ScanEngine.spotConfirm`).
struct SpotConfirmState {
    /// Every answer of this scan, with what each was about.
    var confirmations = SpotConfirmations()
    /// The last upload's scene.json, and the sha256 of it and of the answer to it: what a check
    /// asked now is bound to, and the scene the bundle is written again with after "It's clear".
    var lastScene: Data?
    /// The capture packet's inputs from that same upload, with `lastScene` attached: the packet
    /// written again after "It's clear" (`answerSpotCheck`).
    var lastPacket: ScanEngine.PacketInputs?
    var sceneSHA256: String?
    var answerSHA256: String?
    /// The check on screen: its area, the photo shown and the exchange it came from.
    var pending: SpotConfirmation?
    /// The check's entry in the guidance log while it is on screen.
    var request: GuidanceLog.Request?
    /// Checks asked in this scan, for their ids.
    var asked = 0
}

/// The spot check: before an answer's spot is shown as the result, the homeowner is shown the
/// kept photo that best sees the spot and its clearance area (`SpotPhoto.best`) and asked whether
/// anything stands in front of the wall or on the ground there.
///
/// Camera-only coverage and the walked path claim wall, ground and clear space they never saw
/// (HouseScanKit `CoverageMap`, "Bounded exceptions"). "It's clear" backs those claims for this
/// spot and shows the result. "Something's there" and "I can't check this area" withdraw them
/// over the area (`CoverageMap.withdrawClaims`), so the scene reports it unseen, and upload
/// again, as a closed gap does; the new answer's spot is asked about again unless an earlier
/// answer already covers it (`SpotConfirmations.settling`), and then the result says which of
/// the two the homeowner gave. Nothing new goes into scene.json: the answer shows only as the
/// stretch the scene no longer claims, and in the packet's guidance log, where both close the
/// check as skipped.
///
/// The bundled sample is checked like a server's answer, and the screen labels it a sample: the
/// UI tests and the offline demo only ever see the sample, so skipping it would leave the step
/// untested end to end, and "See it on your wall" already draws the sample spot on the real wall
/// with the same label. A refusal still withdraws the real scan's claims; the sample's answer
/// ignores them, and the result says what the homeowner answered.
///
/// The homeowner could instead mark what stands there with the mark flow, but that needs the
/// camera tracking in the scan's world frame, and a bush, woodpile or bin has no mark kind or
/// scene.json object type to describe it. Withdrawing the claim works on every phone and says
/// only what is known: that stretch was not seen clear.
extension ScanEngine {
    /// How long an answer stays on screen before the result or the upload: 1.2 s, as a closed
    /// gap's check mark (`autoAdvanceDelay`), and the autopilot's hold when longer. Not measured.
    private var spotAnsweredHold: Double { options.autopilot ? max(1.2, options.autopilotHold) : 1.2 }

    /// Records the upload's scene and the answer to it, which a check asked about this answer
    /// is bound to. Call it once the answer has decoded.
    func noteExchange(scene: Data, answer: Data, packet: PacketInputs?) {
        spotConfirm.lastScene = scene
        spotConfirm.lastPacket = packet
        spotConfirm.sceneSHA256 = PacketFiles.sha256(scene)
        spotConfirm.answerSHA256 = PacketFiles.sha256(answer)
    }

    /// Shows the answer once the gap loop is done with it: the spot check first when the answer
    /// names a spot no earlier check settles, otherwise the result.
    func presentAnswer() {
        guard let result = state.result, let spot = result.spot, let wall = coverage?.wall,
              let sceneSHA256 = spotConfirm.sceneSHA256, let answerSHA256 = spotConfirm.answerSHA256 else {
            state.spotCheck = nil
            go(.result)
            return
        }
        let area = SpotArea(
            spot: spot.span, spotOut: spot.offsetFromWall...(spot.offsetFromWall + spot.depth),
            zones: result.clearances.map { (span: $0.span, depth: $0.depth) })
        spotConfirm.asked += 1
        let id = spotConfirm.asked
        if let settled = spotConfirm.confirmations.settling(area) {
            // Kept for the result, which says when the homeowner said something stands there or
            // couldn't check the area.
            state.spotCheck = Self.spotCheck(id: id, area: area, spot: spot, photo: nil, answer: Self.answer(settled.answer), isSample: result.isSample)
            RuntimeLog.engine.info("spot check: s=\(area.spot.lowerBound)...\(area.spot.upperBound) was answered before (\(settled.answer.rawValue, privacy: .public)); showing the result")
            go(.result)
            return
        }
        let candidates = store.keyframes.map { SpotPhotoCandidate(id: $0.id, camera: $0.camera, trackingNormal: $0.tracking == .normal) }
        let choice = SpotPhoto.best(candidates, area: area, wall: wall)
        let stored = choice.flatMap { choice in store.keyframes.first { $0.id == choice.id } }
        let file = stored.map { store.directory.appending(path: $0.fileName) }
        if let choice {
            RuntimeLog.engine.info("spot check: photo \(choice.id, privacy: .public) shows \(Int(choice.footprintInView * 100))% of the spot and \(Int(choice.areaInView * 100))% of s=\(area.span.lowerBound)...\(area.span.upperBound)")
        } else {
            RuntimeLog.engine.info("spot check: no kept photo shows s=\(area.span.lowerBound)...\(area.span.upperBound) from the front; asking without one")
        }
        Task {
            let image = await Self.loadPhoto(file)
            guard state.phase == .uploading, spotConfirm.asked == id, state.result == result else { return }
            var photo: SpotCheck.Photo?
            if let image, let camera = stored?.camera {
                photo = SpotCheck.Photo(image: image, projection: CameraProjection(
                    cameraToWorld: camera.cameraToWorld, intrinsics: camera.intrinsics, imageSize: camera.imageSize))
            } else if let stored {
                RuntimeLog.engine.error("spot check: keyframe \(stored.id, privacy: .public) didn't load; asking without a photo")
            }
            let check = Self.spotCheck(id: id, area: area, spot: spot, photo: photo, answer: nil, isSample: result.isSample)
            // Recorded once the photo has loaded, from what the screen shows: the photo only when
            // it is outlined on screen, and the question asked with or without the outline.
            let outlined = check.outline(on: state.wall) != nil
            let shownID = outlined ? stored?.id : nil
            // `answer` is replaced by the homeowner's (`answerSpotCheck`) before it is recorded.
            spotConfirm.pending = SpotConfirmation(area: area, answerSHA256: answerSHA256, sceneSHA256: sceneSHA256, photoID: shownID, answer: .clear)
            spotConfirm.request = spotCheckRequest(
                area: area, question: ScanCopy.spotQuestionShown(outlined: outlined), photoID: shownID,
                answerSHA256: answerSHA256, sceneSHA256: sceneSHA256, id: id)
            state.spotCheck = check
            go(.spotConfirm)
        }
    }

    /// The homeowner's answer to the spot check on screen.
    func answerSpotCheck(_ answer: SpotCheckAnswer) {
        guard state.phase == .spotConfirm, var check = state.spotCheck, check.answer == nil, var confirmation = spotConfirm.pending else { return }
        confirmation.answer = Self.confirmationAnswer(answer)
        spotConfirm.confirmations.record(confirmation)
        spotConfirm.pending = nil
        check.answer = answer
        state.spotCheck = check
        // An answer other than "It's clear" sends the area to review without the claims, like an
        // overhead answer.
        resolveGuidance(confirmation.answer.guidanceOutcome)
        let area = confirmation.area
        let keepsClaims = confirmation.answer.keepsClaims
        if !keepsClaims { updateCoverage { $0.withdrawClaims(over: area.span) } }
        let said = switch confirmation.answer {
        case .clear: "clear"
        case .somethingThere: "something there, claims withdrawn"
        case .cannotCheck: "can't check, claims withdrawn"
        }
        RuntimeLog.engine.info("spot check \(check.id): \(said, privacy: .public) over s=\(area.span.lowerBound)...\(area.span.upperBound), photo \(confirmation.photoID ?? "none", privacy: .public), answer \(confirmation.answerSHA256.prefix(12), privacy: .public), scene \(confirmation.sceneSHA256.prefix(12), privacy: .public)")
        let id = check.id
        Task {
            try? await Task.sleep(for: .seconds(spotAnsweredHold))
            guard state.phase == .spotConfirm, state.spotCheck?.id == id else { return }
            guard keepsClaims else {
                // UI tests: the answer to this upload comes from a file (`-sampleResultAfterSpotAnswer`).
                if let file = options.sampleResultAfterSpotAnswer, let sample = resultClient as? SampleResultClient {
                    sample.answerFile = file
                }
                // The scan without those claims goes to the server again.
                startUpload()
                return
            }
            // The bundle was written at the upload, before this answer: write it again so its
            // guidance log holds the answer. The upload's captured packet is reused, with only
            // the guidance log read again and placed in that packet's frame, so the packet keeps
            // the submitted scene's geometry, mesh and photos rather than mixing in a later wall.
            if let packet = spotConfirm.lastPacket { saveBundle(withCurrentGuidance(packet)) }
            go(.result)
        }
    }

    /// Whether a capture can settle a gap request: not over a stretch whose claims the homeowner
    /// withdrew, where a new view would claim the same thing past the same obstruction, or past
    /// whatever kept the homeowner from checking it. Overhead requests are not about that
    /// stretch's wall or ground.
    func captureCanSettle(_ plan: GapPlan) -> Bool {
        if case .overhead = plan.need { return true }
        return !(coverage?.hasWithdrawnClaims(overlapping: plan.span) ?? false)
    }

    /// Forgets the scan's checks: they name spans along a wall that no longer exists.
    func resetSpotChecks() {
        spotConfirm = SpotConfirmState()
        state.spotCheck = nil
    }

    /// The check's guidance-log entry while it is on screen (`guidanceRequest`).
    var spotCheckGuidance: GuidanceLog.Request? { spotConfirm.request }

    /// A gap_band request on the ground over the area. scene.json and the packet have no field
    /// for the check, so the message carries what binds it: the question and photo shown and the
    /// sha256 of the answer and scene it was about.
    private func spotCheckRequest(area: SpotArea, question: Instruction, photoID: String?, answerSHA256: String, sceneSHA256: String, id: Int) -> GuidanceLog.Request {
        let format = { (value: Float) in String(format: "%.2f", value) }
        let binding = "Spot check \(id): keyframe \(photoID ?? "none") shown; spot s \(format(area.spot.lowerBound)) to \(format(area.spot.upperBound)) m, "
            + "area s \(format(area.span.lowerBound)) to \(format(area.span.upperBound)) m out to \(format(area.depth)) m; "
            + "answer sha256 \(answerSHA256), scene sha256 \(sceneSHA256)."
        return GuidanceLog.Request(
            topic: .spotCheck(id: id), kind: .gapBand, origin: .phone, message: Self.text(question) + " " + binding,
            band: .ground, span: area.span)
    }

    private static func spotCheck(id: Int, area: SpotArea, spot: BatterySpot, photo: SpotCheck.Photo?, answer: SpotCheckAnswer?, isSample: Bool) -> SpotCheck {
        SpotCheck(
            id: id, spot: area.spot, spotOut: area.spotOut, spotHeight: spot.height, area: area.span, areaDepth: area.depth,
            photo: photo, answer: answer, isSample: isSample)
    }

    /// The photo at `url` as a landscape image no wider than 2048 px, decoded off the main actor.
    private static func loadPhoto(_ url: URL?) async -> CGImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    private static func answer(_ answer: SpotConfirmationAnswer) -> SpotCheckAnswer {
        switch answer {
        case .clear: .clear
        case .somethingThere: .somethingThere
        case .cannotCheck: .cannotCheck
        }
    }

    private static func confirmationAnswer(_ answer: SpotCheckAnswer) -> SpotConfirmationAnswer {
        switch answer {
        case .clear: .clear
        case .somethingThere: .somethingThere
        case .cannotCheck: .cannotCheck
        }
    }
}
