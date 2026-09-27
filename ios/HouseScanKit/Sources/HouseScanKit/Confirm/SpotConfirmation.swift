import Foundation
import simd

// The homeowner's check of the spot a placement answer names.
//
// Camera-only coverage records what was in a photo's view, not what the photo saw: a bush or a
// bin in front of the wall is claimed as wall and ground behind it. The walked path is taken as
// clear space in front of the wall even where something low stands under it (`CoverageMap`,
// "Bounded exceptions"). Before the answer is shown, the app shows the homeowner a kept photo of
// the spot and its front clearance (`SpotArea(result:wall:)`) and asks whether
// anything is there. An answer counts only about what a photo showed whole (`SpotPhotoChoice
// .showsWholeArea`); without such a photo the area is withdrawn (`unconfirmed`). "It's clear" keeps
// the claims; "Something's there" takes them back over that area (`CoverageMap.withdrawClaims`)
// and the scan is checked again. Once the area is clear it asks what the ground is where the
// battery would stand, sent as a patch over the footprint alone (`SpotGround`). This file holds
// the parts with one correct answer: which area is asked about, which photo shows it, when an
// answer already given settles a new answer, and where a ground answer is sent.

/// The area a spot check asks about, meters: the spot's footprint and its front clearance
/// (`init(result:wall:)`), as a stretch of wall, the ground in front of it and the wall face above it.
public struct SpotArea: Sendable, Equatable {
    /// The footprint along the wall (s) and out from it.
    public var spot: ClosedRange<Float>
    public var spotOut: ClosedRange<Float>
    /// The whole area along the wall.
    public var span: ClosedRange<Float>
    /// How far out from the wall the area reaches.
    public var depth: Float
    /// How high up the wall face the area reaches: the battery's height.
    public var height: Float

    public init(spot: ClosedRange<Float>, spotOut: ClosedRange<Float>, span: ClosedRange<Float>, depth: Float, height: Float = 0) {
        self.spot = spot
        self.spotOut = spotOut
        self.span = span
        self.depth = depth
        self.height = height
    }

    /// Two answers' spans that differ by less than this are the same, meters: 0.01 ft, the
    /// server's COVERAGE_TOLERANCE_FT, so a spot the server placed again in the same place counts
    /// as the same spot after its trip through feet and Float meters.
    public static let tolerance: Float = 0.003048

    /// The area an answer's spot rests on, or nil when the answer names no spot.
    ///
    /// The footprint (`span_ft`, and out from the wall from the back edge the server puts on the
    /// wall line to its depth) and the front clearance: when the answer's front-clearance check
    /// (`rule.key` `facing.*`, measured from the battery's front) passes, out to D + r, D the
    /// footprint's depth and r its `threshold_ft`, over the footprint's stretch. That is the space
    /// the walked path claims clear that the result rests on (server/README.md "What settles each
    /// check" on t3/server: the facing band's `out_ft` must exceed D + r). The wall face is asked
    /// about up to the battery's height. Both questions, what stands there and what unmarked
    /// equipment is there, are asked over this one area.
    ///
    /// The other clearances (gas, AC, openings, pool, drive) are left out by the manager's decision
    /// for the #10 freeze: their regions reach r + e either side, wider than a walk photo shows, so
    /// every spot would go unconfirmed. The known tradeoff: an unmarked gas meter just outside the
    /// area goes unasked, and the gas check can pass without it. Asking about it is a follow-up.
    /// An unsure or failing front check adds nothing: the result doesn't rest on that space.
    public init?(result: PlacementResult, wall: WallFrame) {
        guard let placed = result.spot else { return nil }
        let meters = { (feet: Double) in Float(feet * 0.3048) }
        let spot = meters(min(placed.spanFt.x, placed.spanFt.y))...meters(max(placed.spanFt.x, placed.spanFt.y))
        let depth = meters(placed.depthFt)
        // The footprint's back edge: its centre's distance out less half its depth (back-left and
        // back-right corners come first), as the result screen draws it.
        let back = placed.footprint.count >= 2 ? (placed.footprint[0] + placed.footprint[1]) / 2 : placed.center
        let d = placed.center - back
        let centerOut = meters(d.x * placed.outward.x + d.y * placed.outward.y)
        let offset = max(0, centerOut - depth / 2)
        let spotOut = offset...(offset + depth)
        let front = result.checks
            .filter { $0.outcome == .pass && $0.comparison == .atLeast && $0.rule.key.hasPrefix("facing.") }
            .compactMap { $0.thresholdFt.map { meters($0) } }
            .max()
        let out = spotOut.upperBound + (front ?? 0)
        self.init(spot: spot, spotOut: spotOut, span: spot, depth: out, height: meters(placed.heightFt))
    }

    /// Whether this area holds `other`: the same footprint, and an area at least as large. An
    /// answer about this area is an answer about `other`.
    public func holds(_ other: SpotArea) -> Bool {
        let t = Self.tolerance
        func same(_ a: ClosedRange<Float>, _ b: ClosedRange<Float>) -> Bool {
            abs(a.lowerBound - b.lowerBound) <= t && abs(a.upperBound - b.upperBound) <= t
        }
        return same(spot, other.spot) && same(spotOut, other.spotOut)
            && span.lowerBound <= other.span.lowerBound + t && span.upperBound >= other.span.upperBound - t
            && depth >= other.depth - t && height >= other.height - t
    }
}

// MARK: - Photo choice

/// A kept photo the spot check may show.
public struct SpotPhotoCandidate: Sendable, Equatable {
    public var id: String
    /// The camera as ARKit reported it when the photo was taken (`StoredKeyframe.rawPose`).
    public var camera: CameraFrame
    public var trackingNormal: Bool
    /// When it was taken, on the frame clock; nil when no anchor correction can apply to it.
    public var capturedAt: Double?

    public init(id: String, camera: CameraFrame, trackingNormal: Bool, capturedAt: Double? = nil) {
        self.id = id
        self.camera = camera
        self.trackingNormal = trackingNormal
        self.capturedAt = capturedAt
    }

    /// The camera in the frame the wall agrees with now: the raw camera moved by every anchor
    /// correction applied after the photo was taken (`MeterAnchorTracking`). The wall has moved
    /// with those corrections, so the raw camera against it would put the outline off the spot
    /// by as much as the corrections moved it.
    public func camera(correctedBy corrections: PoseCorrections) -> CameraFrame {
        guard let capturedAt else { return camera }
        return CameraFrame(
            cameraToWorld: corrections.pose(camera.cameraToWorld, capturedAt: capturedAt), intrinsics: camera.intrinsics,
            imageSize: camera.imageSize)
    }
}

/// The photo chosen for a spot check and how much of the area it shows.
public struct SpotPhotoChoice: Sendable, Equatable {
    public var id: String
    /// Fractions of the footprint's ground samples, and of the whole area's ground and wall face
    /// samples, inside the image.
    public var footprintInView: Float
    public var areaInView: Float
    /// Angle between the view from the area's middle to the camera and the wall's outward, in
    /// plan, radians.
    public var angleFromFront: Float
    /// The camera the fractions were worked out with, corrected (`SpotPhotoCandidate
    /// .camera(correctedBy:)`): the one to draw the outline through. Nil when made by hand.
    public var camera: CameraFrame?

    public init(id: String, footprintInView: Float, areaInView: Float, angleFromFront: Float, camera: CameraFrame? = nil) {
        self.id = id
        self.footprintInView = footprintInView
        self.areaInView = areaInView
        self.angleFromFront = angleFromFront
        self.camera = camera
    }

    /// Every sample of the footprint and the whole area is in the photo: the homeowner can see all
    /// of what the answer is about. Only such a photo lets "It's clear" count
    /// (`SpotConfirmations.record`).
    public var showsWholeArea: Bool { footprintInView >= 1 && areaInView >= 1 }
}

/// Thresholds of the photo choice. Hypotheses, not measured with homeowners.
public struct SpotPhotoConfig: Sendable, Equatable {
    /// A photo more than 60 degrees to the side shows the area's ground foreshortened and the
    /// wall face edge on, where something in front of the wall is hard to make out. Tighter than
    /// coverage's 65 degrees (`CoverageConfig.maxAngleFromNormal`) because a person reads this
    /// photo, not a measurement.
    public var maxAngleFromFront: Float = 60 * .pi / 180
    /// Farther than coverage's limit a phone photo shows a battery-sized area too small to judge.
    public var maxDistance: Float = CoverageConfig().maxDistance
    /// Samples this close to the image's edge don't count, as in coverage.
    public var imageMargin: Float = CoverageConfig().imageMargin
    /// A photo shown must show at least half the footprint: with less, the homeowner can't see
    /// where the battery would stand. Showing it is not confirming it: only a photo that shows the
    /// whole area lets "It's clear" count (`SpotPhotoChoice.showsWholeArea`).
    public var minFootprintInView: Float = 0.5
    /// Ground samples every this many meters along the wall and out from it.
    public var sampleSpacing: Float = 0.15

    public init() {}
}

public enum SpotPhoto {
    /// The kept photo that best shows the area, or nil when none shows enough of it.
    ///
    /// A photo qualifies when it was taken with normal tracking, from in front of the area's
    /// piece of wall, within `maxAngleFromFront` of straight on, and shows at least
    /// `minFootprintInView` of the footprint. Among those the photo with the most of the area in
    /// view wins: the footprint's fraction and the whole area's, weighted equally. Ties go to the
    /// photo nearer straight on, then to the earlier candidate. A sample counts when it lies in
    /// front of the camera, inside the image margin and within `maxDistance`; the ground is
    /// sampled every `sampleSpacing` along the wall and out from it, edges included, and the whole
    /// area's wall face as far up as `SpotArea.height`, on the same spacing.
    ///
    /// Each candidate is judged with its camera corrected by `corrections` into the frame `wall`
    /// is in (`SpotPhotoCandidate.camera(correctedBy:)`), and the choice carries that camera for
    /// the outline. After another correction, judging the same candidate again against the moved
    /// wall gives the same fractions and a camera that draws the outline in the same place.
    public static func best(
        _ candidates: [SpotPhotoCandidate], area: SpotArea, wall: WallFrame, corrections: PoseCorrections = .none,
        config: SpotPhotoConfig = SpotPhotoConfig()
    ) -> SpotPhotoChoice? {
        let footprint = samples(wall, along: area.spot, out: area.spotOut, spacing: config.sampleSpacing)
        let whole = samples(wall, along: area.span, out: 0...area.depth, spacing: config.sampleSpacing)
            + faceSamples(wall, along: area.span, up: 0...area.height, spacing: config.sampleSpacing)
        let middle = (area.span.lowerBound + area.span.upperBound) / 2
        let piece = wall.segment(atS: middle)
        let centre = wall.world(s: middle, height: 0, out: area.depth / 2)
        var best: (choice: SpotPhotoChoice, score: Float)?
        for candidate in candidates where candidate.trackingNormal {
            let camera = candidate.camera(correctedBy: corrections)
            guard wall.out(of: camera.position, pieceAtS: middle) > 0 else { continue }
            let toCamera = SIMD2(camera.position.x - centre.x, camera.position.z - centre.z)
            guard simd_length(toCamera) > 0 else { continue }
            let cosine = simd_dot(simd_normalize(toCamera), simd_normalize(SIMD2(piece.outward.x, piece.outward.z)))
            let angle = acos(min(max(cosine, -1), 1))
            guard angle <= config.maxAngleFromFront else { continue }
            func fraction(_ points: [SIMD3<Float>]) -> Float {
                let inView = points.filter { point in
                    guard simd_distance(point, camera.position) <= config.maxDistance, let pixel = camera.pixel(of: point) else { return false }
                    return camera.contains(pixel: pixel, margin: config.imageMargin)
                }
                return Float(inView.count) / Float(max(1, points.count))
            }
            let footprintInView = fraction(footprint)
            guard footprintInView >= config.minFootprintInView else { continue }
            let choice = SpotPhotoChoice(
                id: candidate.id, footprintInView: footprintInView, areaInView: fraction(whole), angleFromFront: angle, camera: camera)
            let score = (footprintInView + choice.areaInView) / 2
            if let current = best, score < current.score || (score == current.score && angle >= current.choice.angleFromFront) { continue }
            best = (choice, score)
        }
        return best?.choice
    }

    /// Ground points over a rectangle in wall coordinates, `spacing` apart or closer, edges included.
    static func samples(_ wall: WallFrame, along: ClosedRange<Float>, out: ClosedRange<Float>, spacing: Float) -> [SIMD3<Float>] {
        return steps(along, spacing).flatMap { s in steps(out, spacing).map { o in wall.world(s: s, height: 0, out: o) } }
    }

    /// Points on the wall face over a rectangle, as `samples`; none when `up` has no height.
    static func faceSamples(_ wall: WallFrame, along: ClosedRange<Float>, up: ClosedRange<Float>, spacing: Float) -> [SIMD3<Float>] {
        guard up.upperBound > up.lowerBound else { return [] }
        return steps(along, spacing).flatMap { s in steps(up, spacing).map { h in wall.world(s: s, height: h) } }
    }

    static func steps(_ range: ClosedRange<Float>, _ spacing: Float) -> [Float] {
        let count = max(1, Int(((range.upperBound - range.lowerBound) / spacing).rounded(.up)))
        return (0...count).map { range.lowerBound + (range.upperBound - range.lowerBound) * Float($0) / Float(count) }
    }
}

// MARK: - Binding

/// What the homeowner said the ground is where the battery would stand.
public enum SpotGroundAnswer: Sendable, Equatable {
    case type(SceneGroundType)
    /// No patch is sent; the server reports the surface as not recorded.
    case notSure
}

/// Equipment whose clearance the server checks only when it is marked: the scene has to list it.
public enum SpotEquipment: String, Sendable, Equatable, CaseIterable {
    case gasMeter = "gas_meter"
    case ac
    case window
    case door
}

/// The homeowner's answer to a spot check.
public enum SpotConfirmationAnswer: Sendable, Equatable {
    /// Nothing is in the area: the photo's claims over it stand, backed by this answer, and the
    /// ground under the footprint is `ground`.
    case clear(ground: SpotGroundAnswer)
    /// Something stands there: the claims over the area are withdrawn and the scan is checked
    /// again.
    case somethingThere
    /// Equipment the scan didn't mark is in the area. `markedNow` when the homeowner marked it
    /// and the scan went to the server again with it; otherwise the phone couldn't mark it, and
    /// the claims over the area were withdrawn as for `somethingThere`.
    case unmarked(SpotEquipment, markedNow: Bool)
    /// No kept photo showed the whole area, so nothing could be confirmed: the claims over the
    /// area were withdrawn.
    case unconfirmed

    /// Whether the answer confirms the area: only this answer needs a photo of the whole area,
    /// and only it is bound to the exchange it was given about (`SpotExchange`).
    public var confirms: Bool {
        if case .clear = self { return true }
        return false
    }

    /// Whether this answer settles the area for a later answer naming the same spot. A mark added
    /// since doesn't: the homeowner hasn't yet said the area is otherwise clear, nor what the
    /// ground is.
    public var settles: Bool {
        if case .unmarked(_, markedNow: true) = self { return false }
        return true
    }

    /// For logs: "clear, mulch", "something there", "unmarked gas_meter, marked".
    public var name: String {
        switch self {
        case .clear(.type(let type)): "clear, \(type.rawValue)"
        case .clear(.notSure): "clear, ground not sure"
        case .somethingThere: "something there"
        case .unmarked(let kind, let marked): "unmarked \(kind.rawValue), \(marked ? "marked" : "can't be marked")"
        case .unconfirmed: "unconfirmed, no photo shows the whole area"
        }
    }
}

/// The exchange a check was asked about: the scene uploaded and the answer to it, each by the
/// sha256 of its bytes, and the rules the answer applied (`policy.rules_sha256`).
public struct SpotExchange: Sendable, Equatable {
    public var sceneSHA256: String
    public var answerSHA256: String
    public var rulesSHA256: String

    public init(sceneSHA256: String, answerSHA256: String, rulesSHA256: String) {
        self.sceneSHA256 = sceneSHA256
        self.answerSHA256 = answerSHA256
        self.rulesSHA256 = rulesSHA256
    }
}

/// One spot check and its answer, tied to what it was about: the area, the exchange, and the photo
/// shown.
public struct SpotConfirmation: Sendable, Equatable {
    public var area: SpotArea
    public var exchange: SpotExchange
    /// The photo shown and how much of the area it showed; nil when no kept photo was shown.
    public var photo: SpotPhotoChoice?
    public var answer: SpotConfirmationAnswer

    public init(area: SpotArea, exchange: SpotExchange, photo: SpotPhotoChoice?, answer: SpotConfirmationAnswer) {
        self.area = area
        self.exchange = exchange
        self.photo = photo
        self.answer = answer
    }

    public var photoID: String? { photo?.id }
}

public enum SpotConfirmationError: Error, Equatable {
    /// "It's clear" about an area no shown photo showed whole: the homeowner can only confirm
    /// what they were shown.
    case clearWithoutAWholeView
}

/// Every spot check of a scan, oldest first.
///
/// A later answer that names a spot is settled by the latest check whose area holds the new one
/// (`SpotArea.holds`: the same footprint, and an area at least as large), when that check's
/// answer settles (`SpotConfirmationAnswer.settles`). A spot that moved, or an area that grew, is
/// asked about again. "It's clear" settles it only for the very exchange it was given about: the
/// same scene, the same answer and the same rules (`SpotExchange`). Any new upload, the one that
/// sends the ground answer included, asks the area question again; the ground answer itself is
/// kept for the footprint under the same rules (`groundAnswer(for:rulesSHA256:)`), so it isn't
/// asked twice. Answers that withdrew the area stay whatever changed: they only ever make the scan
/// claim less.
public struct SpotConfirmations: Sendable, Equatable {
    public private(set) var records: [SpotConfirmation] = []

    public init() {}

    /// Records an answer. "It's clear" counts only with a shown photo of the whole area
    /// (`SpotPhotoChoice.showsWholeArea`); otherwise nothing is recorded and it throws.
    public mutating func record(_ confirmation: SpotConfirmation) throws(SpotConfirmationError) {
        if confirmation.answer.confirms, confirmation.photo?.showsWholeArea != true { throw .clearWithoutAWholeView }
        records.append(confirmation)
    }

    /// The latest check that settles `area` in `exchange`, or nil when the homeowner has to be
    /// asked.
    public func settling(_ area: SpotArea, in exchange: SpotExchange) -> SpotConfirmation? {
        guard let latest = records.last(where: { $0.area.holds(area) }), latest.answer.settles else { return nil }
        if latest.answer.confirms, latest.exchange != exchange { return nil }
        return latest
    }

    /// What the homeowner last said the ground is under this footprint, under the same rules, or
    /// nil when it has to be asked: the footprint moved, the rules changed, or the latest answer
    /// about the footprint withdrew the area. It is bound to the footprint, not the scene: the
    /// scene that carries it differs from the one it was given about by the answer itself.
    public func groundAnswer(for area: SpotArea, rulesSHA256: String) -> SpotGroundAnswer? {
        let footprint = { (a: SpotArea) in SpotArea(spot: a.spot, spotOut: a.spotOut, span: a.spot, depth: a.spotOut.upperBound) }
        guard let latest = records.last(where: { footprint($0.area).holds(footprint(area)) && footprint(area).holds(footprint($0.area)) }),
              latest.exchange.rulesSHA256 == rulesSHA256, case .clear(let ground) = latest.answer else { return nil }
        return ground
    }

    /// The ground patches to send: for each footprint answered about, the latest answer about it,
    /// when that says the area is clear and names a type. Before any spot, after "Not sure", or
    /// once the latest answer about a footprint says something is there, none for it.
    /// `groundGuessError` is the ground's error while it is a guess, 0 once measured
    /// (`SpotGround.margin`).
    public func groundPatches(wall: WallFrame, groundGuessError: Float) -> [SceneGroundPatch] {
        var answered: [SpotArea] = []
        var patches: [SceneGroundPatch] = []
        for record in records.reversed() {
            let footprint = SpotArea(spot: record.area.spot, spotOut: record.area.spotOut, span: record.area.spot, depth: record.area.spotOut.upperBound)
            guard !answered.contains(where: { $0.holds(footprint) && footprint.holds($0) }) else { continue }
            answered.append(footprint)
            guard case .clear(.type(let type)) = record.answer else { continue }
            patches.append(SpotGround.patch(type, under: record.area, wall: wall, groundGuessError: groundGuessError))
        }
        return patches.reversed()
    }
}

// MARK: - Ground

/// Where a ground answer is sent: the spot's footprint grown by the server's position error for
/// it, so the server finds the patch under the footprint wherever within its error the battery
/// really stands (server/solver.py `check_ground` at t3/server: the footprint is checked against
/// the patches with the wall's error at its far edge, `piece.plus_minus`).
public enum SpotGround {
    /// The margin around the footprint, meters: the server's error for the wall line of the
    /// footprint's piece at the footprint's edge farther from the meter along the chain
    /// (`ServerErrorDefaults.wall(_:atS:)`: its source's default plus 0.16 per meter walked), plus
    /// `groundGuessError` while the ground is a guess (`ScanEngine.estimatedGroundError`, 0.3 m,
    /// else 0). A guessed ground moves heights, not plan positions; it is added because the export
    /// widens every position it sends (the meter, the objects) by it while the ground is a guess,
    /// and the patch is treated the same way. Neither value was measured on a phone: both are the
    /// server's rules and the export's guess.
    ///
    /// With the margin alone the server reports the footprint within error of a surface boundary
    /// (`ground_surface` UNSURE, cause `margin`) rather than PASS: it wants no unrecorded ground
    /// within the patch's own error plus the wall's (`near_unknown`), and the answer is about
    /// where the battery stands, not the ground beyond the margin.
    public static func margin(spot: ClosedRange<Float>, wall: WallFrame, groundGuessError: Float) -> Float {
        let middle = (spot.lowerBound + spot.upperBound) / 2
        let far = max(abs(spot.lowerBound), abs(spot.upperBound))
        return ServerErrorDefaults.wall(wall.segment(atS: middle).source, atS: far) + groundGuessError
    }

    /// The patch for `type` under the spot of `area`: the footprint plus `margin` along the wall
    /// and out from it. The export sends only the part the ground coverage saw
    /// (`SceneGroundPatch.seen`).
    public static func patch(_ type: SceneGroundType, under area: SpotArea, wall: WallFrame, groundGuessError: Float) -> SceneGroundPatch {
        let m = margin(spot: area.spot, wall: wall, groundGuessError: groundGuessError)
        return SceneGroundPatch(type: type, span: (area.spot.lowerBound - m)...(area.spot.upperBound + m), out: area.spotOut.upperBound + m)
    }
}
