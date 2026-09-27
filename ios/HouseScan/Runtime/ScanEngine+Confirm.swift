import CoreGraphics
import Foundation
import HouseScanKit
import ImageIO
import OSLog

/// The spot check's state on the engine (`ScanEngine.spotConfirm`).
struct SpotConfirmState {
    /// Every answer of this scan, with what each was about.
    var confirmations = SpotConfirmations()
    /// The last upload's scene.json and the answer to it: what a check asked now is bound to, and
    /// the scene the bundle is written again with after an answer that doesn't upload.
    var lastScene: Data?
    var lastAnswer: Data?
    var sceneSHA256: String?
    var answerSHA256: String?
    /// The check on screen: its area, the photo shown and the exchange it came from. Its answer
    /// is filled in when the homeowner gives one.
    var pending: SpotConfirmation?
    /// The photo on screen, raw as stored, with the image decoded from it: judged again, and its
    /// outline's camera corrected again, whenever the wall moves while the question is up
    /// (`refreshSpotPhoto`).
    var shown: (candidate: SpotPhotoCandidate, image: CGImage)?
    /// The unmarked thing the homeowner is marking on the camera, with the check it came from.
    var marking: (check: SpotConfirmation, kind: FeatureKind)?
    /// The entry in the guidance log for the question on screen.
    var request: GuidanceLog.Request?
    /// Checks asked in this scan, for their ids.
    var asked = 0
}

/// The spot check: before an answer's spot is shown as the result, the homeowner is shown the
/// kept photo that best sees the footprint and its front clearance (`SpotArea(result:wall:)`,
/// `SpotPhoto.best`) and asked, on that one photo, at most two questions.
///
/// 1. Is anything in the marked area? "It's clear" backs the camera-only and walked-path claims
///    there (HouseScanKit `CoverageMap`, "Bounded exceptions"). "Something's in the way" withdraws
///    them (`CoverageMap.withdrawClaims`), so the scene reports the area unseen, and uploads again.
///    "A gas meter, AC, window or door" asks which, then opens the camera to mark it with the
///    review's mark flow and uploads again once it is marked; the server checks clearances only
///    from marked objects. When the phone can't mark now (it lost its place, or the camera
///    failed), the area is withdrawn as for "Something's in the way".
/// 2. After "It's clear": what is the ground where the battery would stand? A type goes out as a
///    patch over the footprint and its error margin (`SpotGround`) with an upload; "Not sure"
///    shows the result, and the server reports the surface as not recorded.
///
/// The obstruction question comes first because either of its other answers changes the scan
/// and can move the spot, which would waste a ground answer about this one. Both are about the
/// same outlined place, so they share the photo and the screen.
///
/// An answer counts only about what the homeowner was shown. When no kept photo shows the whole
/// area (`SpotPhotoChoice.showsWholeArea`), or the photo can't be decoded, "It's clear" is not
/// offered: the screen says so and the area is withdrawn (`unconfirmed`), and the scan goes to
/// the server again without those claims. Asking for another view of the area would keep more
/// claims, but it needs a capture step of its own; withdrawing needs none and claims nothing
/// unseen.
///
/// "It's clear" is reused only for the exchange it was given about: the same scene, answer and
/// rules (`SpotConfirmations.settling`). So the upload that sends a ground answer asks the area
/// question once more, about the answer that comes back; the ground answer itself stands for the
/// footprint under the same rules and isn't asked again, and with nothing new to send the result
/// follows. A spot that moved asks both. Answers that left the area out stay. Nothing
/// new goes into scene.json but the ground patch: the answers show as the stretch the scene no
/// longer claims, the marks added, and in the packet's guidance log.
///
/// The bundled sample is checked like a server's answer, and the screen labels it a sample: the
/// UI tests and the offline demo only ever see the sample, so skipping it would leave the step
/// untested end to end.
extension ScanEngine {
    /// How long an answer stays on screen before the result or the upload: 1.2 s, as a closed
    /// gap's check mark (`autoAdvanceDelay`), and the autopilot's hold when longer. Not measured.
    private var spotAnsweredHold: Double { options.autopilot ? max(1.2, options.autopilotHold) : 1.2 }

    /// Records the upload's scene and the answer to it, which a check asked about this answer
    /// is bound to. Call it once the answer has decoded.
    func noteExchange(scene: Data, answer: Data) {
        spotConfirm.lastScene = scene
        spotConfirm.lastAnswer = answer
        spotConfirm.sceneSHA256 = PacketFiles.sha256(scene)
        spotConfirm.answerSHA256 = PacketFiles.sha256(answer)
    }

    /// The ground patches the export sends: the latest ground answer about each footprint.
    var spotGroundPatches: [SceneGroundPatch] {
        guard let wall = coverage?.wall else { return [] }
        return spotConfirm.confirmations.groundPatches(wall: wall, groundGuessError: groundMeasured ? 0 : Self.estimatedGroundError)
    }

    /// Shows the answer once the gap loop is done with it: the spot check first when the answer
    /// names a spot no earlier check settles, otherwise the result.
    func presentAnswer() {
        guard let result = state.result, let placement, let wall = coverage?.wall, let area = SpotArea(result: placement, wall: wall),
              let sceneSHA256 = spotConfirm.sceneSHA256, let answerSHA256 = spotConfirm.answerSHA256 else {
            state.spotCheck = nil
            go(.result)
            return
        }
        let exchange = SpotExchange(sceneSHA256: sceneSHA256, answerSHA256: answerSHA256, rulesSHA256: placement.policy.rulesSHA256)
        spotConfirm.asked += 1
        let id = spotConfirm.asked
        if let settled = spotConfirm.confirmations.settling(area, in: exchange) {
            // Kept for the result, which says when the area was left out.
            var check = Self.spotCheck(id: id, area: area, photo: nil, confirmable: false, isSample: result.isSample)
            check.answer = Self.answer(settled.answer)
            state.spotCheck = check
            RuntimeLog.engine.info("spot check: s=\(area.spot.lowerBound)...\(area.spot.upperBound) was answered before (\(settled.answer.name, privacy: .public)); showing the result")
            go(.result)
            return
        }
        // Raw cameras with their capture times: each is judged, and drawn, corrected into the frame
        // the wall is in now (`SpotPhotoCandidate.camera(correctedBy:)`).
        let candidates = store.keyframes.map {
            SpotPhotoCandidate(id: $0.id, camera: $0.camera, trackingNormal: $0.tracking == .normal, capturedAt: $0.t)
        }
        let choice = SpotPhoto.best(candidates, area: area, wall: wall, corrections: poseCorrections)
        let candidate = choice.flatMap { choice in candidates.first { $0.id == choice.id } }
        let file = choice.flatMap { choice in store.keyframes.first { $0.id == choice.id } }.map { store.directory.appending(path: $0.fileName) }
        RuntimeLog.engine.info("spot check \(id): area s=\(area.span.lowerBound)...\(area.span.upperBound) out to \(area.depth) m; photo \(choice?.id ?? "none", privacy: .public) shows \(Int((choice?.footprintInView ?? 0) * 100))% of the spot and \(Int((choice?.areaInView ?? 0) * 100))% of the area")
        Task {
            let image = await Self.loadPhoto(file)
            guard state.phase == .uploading, spotConfirm.asked == id, state.result == result else { return }
            // The photo and its outline's camera are fixed together here, after the decode: an
            // anchor correction during it moved the wall, so the photo is judged again against
            // the wall as it is now.
            var photo: SpotCheck.Photo?
            var shown: SpotPhotoChoice?
            spotConfirm.shown = nil
            if let image, let candidate, let wall = coverage?.wall {
                shown = SpotPhoto.best([candidate], area: area, wall: wall, corrections: poseCorrections)
                let camera = shown?.camera ?? candidate.camera(correctedBy: poseCorrections)
                photo = SpotCheck.Photo(image: image, projection: Self.projection(camera))
                spotConfirm.shown = (candidate, image)
            } else if choice != nil {
                RuntimeLog.engine.error("spot check \(id): photo \(choice?.id ?? "", privacy: .public) could not be decoded; nothing can be confirmed")
            }
            // Only a photo on screen that shows the whole area can back "It's clear".
            let confirmable = shown?.showsWholeArea == true
            // The answer is filled in when the homeowner gives one.
            spotConfirm.pending = SpotConfirmation(area: area, exchange: exchange, photo: shown, answer: .unconfirmed)
            spotConfirm.request = spotCheckRequest(.spotCheck(id: id), question: confirmable ? ScanCopy.spotQuestion : ScanCopy.spotUnconfirmable,
                                                   span: area.span, binding: binding(id, area: area, photo: shown))
            state.spotCheck = Self.spotCheck(id: id, area: area, photo: photo, confirmable: confirmable, isSample: result.isSample)
            go(.spotConfirm)
        }
    }

    /// The wall moved while the question is up (an anchor correction, a new ground): the photo's
    /// outline is drawn through its camera corrected again, and the photo is judged again. One that
    /// no longer shows the whole area can't back "It's clear": the question gives way to leaving
    /// the area out. `publishWall` calls it.
    func refreshSpotPhoto() {
        guard state.phase == .spotConfirm, var check = state.spotCheck, check.answer == nil, let shown = spotConfirm.shown,
              var pending = spotConfirm.pending, let wall = coverage?.wall else { return }
        let view = SpotPhoto.best([shown.candidate], area: pending.area, wall: wall, corrections: poseCorrections)
        let camera = view?.camera ?? shown.candidate.camera(correctedBy: poseCorrections)
        check.photo = SpotCheck.Photo(image: shown.image, projection: Self.projection(camera))
        pending.photo = view
        spotConfirm.pending = pending
        let confirmable = view?.showsWholeArea == true
        if confirmable != check.confirmable {
            RuntimeLog.engine.info("spot check \(check.id): the wall moved and photo \(shown.candidate.id, privacy: .public) \(confirmable ? "now shows" : "no longer shows", privacy: .public) the whole area")
            check.confirmable = confirmable
            check.step = .area
        }
        state.spotCheck = check
    }

    private static func projection(_ camera: CameraFrame) -> CameraProjection {
        CameraProjection(cameraToWorld: camera.cameraToWorld, intrinsics: camera.intrinsics, imageSize: camera.imageSize)
    }

    // MARK: Answers

    /// The first question: is anything in the marked area?
    func answerSpotArea(_ answer: SpotAreaAnswer) {
        guard state.phase == .spotConfirm, var check = state.spotCheck, check.confirmable, check.step == .area, check.answer == nil else { return }
        switch answer {
        case .clear:
            guard let pending = spotConfirm.pending, let wall = coverage?.wall else { return }
            if let known = spotConfirm.confirmations.groundAnswer(for: pending.area, rulesSHA256: pending.exchange.rulesSHA256) {
                // Asked again after the upload that sent the ground answer: it still stands.
                finish(.clear(ground: known), shown: .clear(Self.groundAnswer(known)), withdraw: false)
                return
            }
            // The ground question, about the footprint, is logged as its own request.
            resolveGuidance(.met)
            let spot = pending.area.spot
            let margin = SpotGround.margin(spot: spot, wall: wall, groundGuessError: groundMeasured ? 0 : Self.estimatedGroundError)
            spotConfirm.request = spotCheckRequest(.spotGround(id: check.id), question: ScanCopy.spotGroundQuestion,
                                                   span: (spot.lowerBound - margin)...(spot.upperBound + margin),
                                                   binding: binding(check.id, area: pending.area, photo: pending.photo))
            check.step = .ground
            state.spotCheck = check
            noteGuidance()
        case .somethingThere:
            finish(.somethingThere, shown: .somethingThere, withdraw: true)
        case .unmarked:
            check.step = .which
            state.spotCheck = check
        }
    }

    /// Which unmarked thing is in the area: mark it on the camera, or leave the area out when the
    /// phone can't mark now. Nil goes back to the first question.
    func chooseUnmarked(_ kind: FeatureKind?) {
        guard state.phase == .spotConfirm, var check = state.spotCheck, check.step == .which, check.answer == nil else { return }
        guard let kind, let equipment = Self.equipment(kind) else {
            check.step = .area
            state.spotCheck = check
            return
        }
        guard !state.tracking.hasLostItsPlace, currentFrame != nil, let pending = spotConfirm.pending else {
            RuntimeLog.engine.info("spot check \(check.id): an unmarked \(kind.rawValue, privacy: .public) can't be marked now (tracking \(Self.name(self.state.tracking), privacy: .public)); leaving the area out")
            finish(.unmarked(equipment, markedNow: false), shown: .unmarkedCantMark(kind), withdraw: true)
            return
        }
        // The review's mark flow, on the camera. Placing the mark uploads (`spotMarkPlaced`);
        // cancelling comes back here (`spotMarkCancelled`).
        spotConfirm.marking = (pending, kind)
        RuntimeLog.engine.info("spot check \(check.id): marking an unmarked \(kind.rawValue, privacy: .public)")
        go(.markFeatures)
        beginMarking(kind)
    }

    /// The ground question.
    func answerSpotGround(_ answer: GroundAnswer) {
        guard state.phase == .spotConfirm, let check = state.spotCheck, check.step == .ground, check.answer == nil else { return }
        let ground: SpotGroundAnswer = switch answer {
        case .type(let type): .type(Self.sceneGroundType(type))
        case .notSure: .notSure
        }
        finish(.clear(ground: ground), shown: .clear(answer), withdraw: false)
    }

    /// No photo shows the whole area: leave it out and check the wall again.
    func continueUnconfirmed() {
        guard state.phase == .spotConfirm, let check = state.spotCheck, !check.confirmable, check.answer == nil else { return }
        finish(.unconfirmed, shown: .unconfirmed, withdraw: true)
    }

    /// Records the answer, shows it for a moment, then uploads again, or shows the result when
    /// nothing changed ("It's clear", ground not sure).
    private func finish(_ answer: SpotConfirmationAnswer, shown: SpotCheckAnswer, withdraw: Bool) {
        guard var check = state.spotCheck, var confirmation = spotConfirm.pending else { return }
        confirmation.answer = answer
        let patchesBefore = spotGroundPatches
        do {
            try spotConfirm.confirmations.record(confirmation)
        } catch {
            RuntimeLog.engine.error("spot check \(check.id): \(answer.name, privacy: .public) not recorded without a photo of the whole area")
            return
        }
        spotConfirm.pending = nil
        // The scan changes when the answer withdraws the area or sends a ground patch not yet sent.
        let uploads = withdraw || spotGroundPatches != patchesBefore
        check.answer = shown
        check.checksAgain = uploads
        state.spotCheck = check
        // An answer that withdraws the area sends it to review without the claims.
        resolveGuidance(withdraw ? .skipped : .met)
        let area = confirmation.area
        if withdraw { updateCoverage { $0.withdrawClaims(over: area.span) } }
        RuntimeLog.engine.info("spot check \(check.id): \(answer.name, privacy: .public)\(withdraw ? ", claims withdrawn" : "", privacy: .public) over s=\(area.span.lowerBound)...\(area.span.upperBound), photo \(confirmation.photoID ?? "none", privacy: .public), scene \(confirmation.exchange.sceneSHA256.prefix(12), privacy: .public), answer \(confirmation.exchange.answerSHA256.prefix(12), privacy: .public), rules \(confirmation.exchange.rulesSHA256.prefix(12), privacy: .public)")
        let id = check.id
        Task {
            try? await Task.sleep(for: .seconds(spotAnsweredHold))
            guard state.phase == .spotConfirm, state.spotCheck?.id == id else { return }
            if uploads {
                // The scan with the change (claims withdrawn, or the ground patch) goes again.
                startUpload()
                return
            }
            // The bundle was written at the upload, before this answer: write it again so its
            // guidance log holds the answer.
            if let scene = spotConfirm.lastScene, let snapshot = lastUploadSnapshot { saveBundle(scene: scene, snapshot: snapshot) }
            go(.result)
        }
    }

    // MARK: Marking unmarked equipment

    /// The mark for the spot check's unmarked equipment is placed: record it and upload.
    func spotMarkPlaced() {
        guard let marking = spotConfirm.marking else { return }
        spotConfirm.marking = nil
        guard let equipment = Self.equipment(marking.kind) else { return }
        var confirmation = marking.check
        confirmation.answer = .unmarked(equipment, markedNow: true)
        try? spotConfirm.confirmations.record(confirmation)
        spotConfirm.pending = nil
        RuntimeLog.engine.info("spot check: the unmarked \(marking.kind.rawValue, privacy: .public) is marked; checking the wall again")
        startUpload()
    }

    /// The spot check's unmarked equipment is being marked on the camera.
    var spotConfirmIsMarking: Bool { spotConfirm.marking != nil }

    /// The mark was cancelled: back to the spot check's first question.
    func spotMarkCancelled() {
        guard let marking = spotConfirm.marking else { return }
        spotConfirm.marking = nil
        spotConfirm.pending = marking.check
        state.spotCheck?.step = .area
        go(.spotConfirm)
    }

    // MARK: Support

    /// Whether a capture can settle a gap request: not over a stretch whose claims the homeowner
    /// withdrew, where a new view would claim the same thing past the same obstruction. Overhead
    /// requests are not about that stretch's wall or ground.
    func captureCanSettle(_ plan: GapPlan) -> Bool {
        if case .overhead = plan.need { return true }
        return !(coverage?.hasWithdrawnClaims(overlapping: plan.span) ?? false)
    }

    /// Forgets the scan's checks: they name spans along a wall that no longer exists.
    func resetSpotChecks() {
        spotConfirm = SpotConfirmState()
        state.spotCheck = nil
    }

    /// The question's guidance-log entry while it is on screen (`guidanceRequest`).
    var spotCheckGuidance: GuidanceLog.Request? { spotConfirm.request }

    /// What binds a check, for the guidance log: scene.json and the packet have no field for it.
    private func binding(_ id: Int, area: SpotArea, photo: SpotPhotoChoice?) -> String {
        let format = { (value: Float) in String(format: "%.2f", value) }
        guard let pending = spotConfirm.pending else { return "Spot check \(id)." }
        let shown = photo.map { "keyframe \($0.id) shown, \(Int($0.areaInView * 100))% of the area in view" } ?? "no keyframe shown"
        return "Spot check \(id): \(shown); spot s \(format(area.spot.lowerBound)) to \(format(area.spot.upperBound)) m, "
            + "area s \(format(area.span.lowerBound)) to \(format(area.span.upperBound)) m out to \(format(area.depth)) m; "
            + "scene sha256 \(pending.exchange.sceneSHA256), answer sha256 \(pending.exchange.answerSHA256), rules sha256 \(pending.exchange.rulesSHA256)."
    }

    /// A gap_band request on the ground over `span`, its message the question and the binding.
    private func spotCheckRequest(_ topic: GuidanceLog.Topic, question: Instruction, span: ClosedRange<Float>, binding: String) -> GuidanceLog.Request {
        GuidanceLog.Request(topic: topic, kind: .gapBand, origin: .phone, message: Self.text(question) + " " + binding, band: .ground, span: span)
    }

    private static func spotCheck(id: Int, area: SpotArea, photo: SpotCheck.Photo?, confirmable: Bool, isSample: Bool) -> SpotCheck {
        SpotCheck(
            id: id, spot: area.spot, spotOut: area.spotOut, spotHeight: area.height, area: area.span, areaDepth: area.depth,
            photo: photo, confirmable: confirmable, answer: nil, isSample: isSample)
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

    private static func groundAnswer(_ answer: SpotGroundAnswer) -> GroundAnswer {
        switch answer {
        case .type(let type): .type(groundType(type))
        case .notSure: .notSure
        }
    }

    private static func answer(_ answer: SpotConfirmationAnswer) -> SpotCheckAnswer {
        switch answer {
        case .clear(let ground): .clear(groundAnswer(ground))
        case .somethingThere: .somethingThere
        case .unmarked(let equipment, _): .unmarkedCantMark(featureKind(equipment))
        case .unconfirmed: .unconfirmed
        }
    }

    static func equipment(_ kind: FeatureKind) -> SpotEquipment? {
        switch kind {
        case .gasMeter: .gasMeter
        case .acUnit: .ac
        case .window: .window
        case .door: .door
        // Only equipment the spot check asks about (`ScanCopy.spotUnmarkedKinds`).
        case .battery, .elecBox, .driveway, .fence: nil
        }
    }

    private static func featureKind(_ equipment: SpotEquipment) -> FeatureKind {
        switch equipment {
        case .gasMeter: .gasMeter
        case .ac: .acUnit
        case .window: .window
        case .door: .door
        }
    }

    static func sceneGroundType(_ type: GroundType) -> SceneGroundType {
        switch type {
        case .lawn: .lawn
        case .mulch: .mulch
        case .gravel: .gravel
        case .concrete: .concrete
        case .drive: .drive
        case .deck: .deck
        }
    }

    private static func groundType(_ type: SceneGroundType) -> GroundType {
        switch type {
        case .lawn: .lawn
        case .mulch: .mulch
        case .gravel: .gravel
        case .concrete: .concrete
        case .drive: .drive
        case .deck: .deck
        }
    }
}
