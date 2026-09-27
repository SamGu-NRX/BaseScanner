import Foundation
import HouseScanKit
import OSLog
import simd

/// Ending the wall during the walk without pointing at the end ("Can't get there", "Wall ends
/// here"), and the preview of where an end would land.
extension ScanEngine {
    /// The side ending the wall applies to now, and whether the end lands at the reticle. The
    /// walk's own side while it asks to walk or to mark the end; during a request about the wall
    /// in front of the homeowner (tilt down, tilt up, step back), the side of the meter the phone
    /// is on (`WalkedEnd.side`). Nil when both ends are marked or the walk is doing something else.
    private var endOnOffer: (side: WallSide, atReticle: Bool)? {
        guard state.phase == .wallWalk, state.marking == nil, state.endQuestion == nil, !state.overheadQuestion,
              nextWallSide == nil, let map = coverage else { return nil }
        switch state.guidance {
        case .walk(let side, _):
            return (side, false)
        case .markEnd(let side):
            return (side, true)
        case .aimAtGround, .aimAtWall, .stepBack:
            guard let side = WalkedEnd.side(phone: phonePosition, wall: map.wall, leftEnd: map.leftEnd, rightEnd: map.rightEnd) else { return nil }
            return (side == .left ? .left : .right, false)
        case .findMeter, .aimAtWallForMeter, .holdOnMeter, .walkComplete, .tiltUp, .markNextWall, .gap, .seeBehind:
            return nil
        }
    }

    /// Where ending the walk on `side` puts the end now (`WalkedEnd`): the phone's place along the
    /// wall on that side with tracking normal, else kept to what was walked on that side (#71).
    /// The phone's place doesn't count while it has lost it.
    func walkedEnd(_ side: WallSide) -> Float? {
        walkedEndChoice(side)?.s
    }

    /// `walkedEnd` with why it landed there, for the preview and the log.
    private func walkedEndChoice(_ side: WallSide) -> WalkedEnd.Choice? {
        guard let map = coverage else { return nil }
        let trackingNormal = currentFrame?.tracking == .normal
        return WalkedEnd.choose(side.walk, phone: phonePosition, trackingNormal: trackingNormal, walked: map.walkedPositions, wall: map.wall)
    }

    /// The strip's seen cells, when the cap decided the end: what an end short of them leaves
    /// out is said (`WalkedEnd.leftOut`), not dropped silently (#71). Nil when the end is where
    /// the phone stands, whose camera sees past it anyway.
    private func seenPastCap(_ choice: WalkedEnd.Choice?, _ map: CoverageMap) -> ClosedRange<Float>? {
        choice?.capped == true ? map.seenExtent : nil
    }

    /// Where the phone is; nil while it has lost its place.
    private var phonePosition: SIMD3<Float>? {
        currentFrame.flatMap { $0.tracking.hasLostItsPlace ? nil : $0.camera.position }
    }

    /// The end preview for this moment (`ScanViewState.endPreview`).
    func currentEndPreview() -> EndPreview? {
        guard let offer = endOnOffer, let map = coverage, let frame = currentFrame else { return nil }
        let side: WallSide
        let s: Float
        var seen: ClosedRange<Float>?
        if offer.atReticle {
            // `markWallEnd` with no point: the middle of the view, which is the sensor image's
            // middle whatever the view's size.
            guard frame.tracking == .normal,
                  let hit = nearbyWallHit(frame.camera.ray(throughPixel: frame.camera.imageSize / 2), camera: frame.camera, wall: map.wall) else { return nil }
            side = hit.s < 0 ? .left : .right
            s = hit.s
        } else {
            guard let choice = walkedEndChoice(offer.side) else { return nil }
            side = offer.side
            s = choice.s
            seen = seenPastCap(choice, map)
        }
        // What this end leaves out of the walk shows only while the walk asks to walk this side
        // or mark its end, and not with the phone far out from the wall (#66). During a tilt or
        // step-back request the dashed line and "Wall ends here" stay; the end question says what
        // pressing it left out (`endWallHere`).
        let onWalkTask: Bool
        switch state.guidance {
        case .walk, .markEnd:
            onWalkTask = true
        default:
            onWalkTask = false
        }
        // The phone's distance from the wall matters only when the end is its place along it.
        let phoneOut: Float? = offer.atReticle ? nil : phonePosition.map { map.wall.wallPoint($0).out }
        let leavesOut = WalkedEnd.leavesOut(
            side: side.walk, s: s, walked: map.walkedPositions, wall: map.wall,
            phoneOut: phoneOut, onWalkTask: onWalkTask, seen: seen
        )
        return EndPreview(side: side, s: s, atReticle: offer.atReticle, leavesOutWalked: leavesOut)
    }

    /// Republishes the end preview; called with every guidance update, since the phone moves.
    func publishEndPreview() {
        let preview = currentEndPreview()
        if preview != state.endPreview { state.endPreview = preview }
    }

    func endWallHere() {
        guard let preview = currentEndPreview(), !preview.atReticle, let map = coverage else { return }
        // Whatever the walk was asking, the end question says how much of the walk this end
        // leaves out, now that the homeowner chose to end the wall here (#66).
        let seen = seenPastCap(walkedEndChoice(preview.side), map)
        let leavesOut = WalkedEnd.leftOut(preview.side.walk, s: preview.s, walked: map.walkedPositions, wall: map.wall, seen: seen)
        // The walk toward that side is met: the homeowner got to its end.
        if case .walk(let side, _) = state.guidance, side == preview.side { resolveGuidance(.met) }
        logEnd("wall ends here", side: preview.side, at: preview.s)
        // Unexplored until the homeowner says something blocks the wall there, as for a marked end.
        state.endQuestion = preview.side
        state.endQuestionLeavesOut = leavesOut
        setEnd(preview.side, at: preview.s, kind: .unexplored)
    }

    /// "Can't get there" while the walk asks to walk `side` or to mark its end: the end goes where
    /// the preview showed, as an unexplored end.
    func endWalkCannotGoOn(_ side: WallSide) {
        guard let s = walkedEnd(side) else { return }
        logEnd("can't get there", side: side, at: s)
        setEnd(side, at: s, kind: .unexplored)
    }

    /// Where the end went, and why (#71): the phone's place, the kept-photo cap, whether the cap
    /// decided it, tracking, how many meters of cells the strip showed past the end, and what the
    /// old rule, the unbroken covered reach, would have said.
    private func logEnd(_ action: String, side: WallSide, at s: Float) {
        guard let map = coverage else { return }
        let phone = currentFrame.map { map.wall.wallPoint($0.camera.position).s } ?? .nan
        let tracking = currentFrame.map { String(describing: $0.tracking) } ?? "none"
        let choice = walkedEndChoice(side)
        let cap = choice?.cap ?? .nan
        let capped = choice?.capped == true ? "cap" : "phone"
        let shown = WalkedEnd.shownPast(side.walk, s: s, seen: map.seenExtent, minimum: 0) ?? 0
        let covered = GuidancePlanner().reach(side.walk, coverage: map)
        RuntimeLog.engine.info("\(action, privacy: .public) on the \(side.rawValue, privacy: .public): end at s=\(s), chose \(capped, privacy: .public) (phone at s=\(phone), cap s=\(cap), tracking \(tracking, privacy: .public)); strip showed \(shown) m past it; covered reach \(covered) m")
    }

    /// `ScanViewState.featuresPastEnds`, refreshed when the ends move (`publishWall`), the spans
    /// follow the wall (`reprojectFeatures`) and a mark is added.
    func publishFeaturesPastEnds() {
        let left = coverage?.leftEnd
        let right = coverage?.rightEnd
        let past = Set(state.features.filter { WalkedEnd.liesPastAnEnd($0.span, leftEnd: left, rightEnd: right) }.map(\.id))
        if past != state.featuresPastEnds { state.featuresPastEnds = past }
    }
}

extension WallSide {
    var walk: WalkSide { self == .left ? .left : .right }
}
