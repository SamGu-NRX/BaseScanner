import Foundation
import HouseScanKit
import simd

/// What scene.json says about the wall and what was seen, when the 3D map is the coverage model.
struct Map3DExport: Sendable {
    /// The wall scene.json describes: the measured chain, or the walk's tapped wall. It and its
    /// corners carry their pieces' sources (`WallFrame.source`, `WallCorner.source`).
    var wall: WallFrame
    /// The described stretch in s of `wall`; contains 0, the meter.
    var baselineS: ClosedRange<Float>
    /// Measured along `wall` and clipped to `baselineS`, the wall band with the height each
    /// stretch was seen to.
    var coverage: SceneCoverage
    /// Position error of each piece's line, meters, per `wall.segments` piece
    /// (`SceneInput.wallPlusMinus`); empty for the tapped wall, which takes the server's default.
    var plusMinus: [Float?]
    /// Why the tapped wall was written instead of the measured chain; nil when the chain was.
    var tappedBecause: String?
}

enum Map3DCoverageError: Error, CustomStringConvertible {
    /// The snapshot was read along another wall than the one being exported, so its s would not
    /// match the scene's.
    case wallMismatch

    var description: String {
        switch self {
        case .wallMismatch: "The 3D map's snapshot was read along a different wall than the one being exported."
        }
    }
}

/// Turns a `Map3DSnapshot` into what the export and the walk read.
enum Map3DCoverageSource {
    /// How far the measured chain may stop short of each end of the walk's baseline and still
    /// describe it, meters: two 10 cm voxels. A measured piece ends within half a voxel of its
    /// last column of wall evidence, and a marked end is a tap. A guess, not measured.
    static let chainShortfall: Float = 0.2
    /// How far the tapped meter may lie from the line of the measured meter piece, meters. A
    /// parallel surface near the meter (a fence, a hedge face, the meter box's own front) faces
    /// the same way as the wall and passes the direction check; this keeps it from standing in
    /// for the wall. The meter box stands roughly 0.1 to 0.2 m proud of the wall. A guess, not
    /// measured.
    static let meterLineDistance: Float = 0.3
    /// How far a measured corner within the baseline may lie from the tapped chain, meters. The
    /// homeowner's taps say where the walk's wall runs; a measured corner far from it belongs to
    /// something else. A guess, not measured: larger than tap error, smaller than a step.
    static let cornerDistance: Float = 0.5

    /// The wall, baseline, coverage and wall sources scene.json gets.
    ///
    /// The measured chain is used when `snapshot.measured` exists (`finalSnapshot()` fills it)
    /// and it agrees with the walk: its meter piece faces within `WallFrame.minCornerAngle` of the
    /// tapped wall (the rule that tells a new wall from the same one), the meter lies within
    /// `meterLineDistance` of that piece's line with its foot on the piece, every measured corner
    /// within the baseline lies within `cornerDistance` of the tapped chain, and the chain reaches
    /// both ends of the baseline to within `chainShortfall`. Otherwise the tapped wall is written with source
    /// `tap`, and `tappedBecause` says which test failed. Coverage is always the one measured along
    /// the wall written, so s agrees.
    ///
    /// `walkedFacing` (`CoverageMap.facingSpans()`: where the phone was carried, less its position
    /// error) and `confirmedOverhead` (`CoverageMap.overheadSpans()`: tilt-up views the homeowner
    /// said are clear) are in the tapped wall's s. Each is merged into the map's band of the same
    /// name, taking the larger reach wherever either has one. When the measured chain is written
    /// they are first restated along it (`ObservedSpan.carried`), on the meter's piece only:
    /// past a corner of either wall one straight stretch of the other can face two ways.
    ///
    /// Every band is clipped to the baseline. The map sees ground in front of the chain only,
    /// and the server reads a ground span past a limit end as covering both sides of the wall's
    /// continued line, so reporting it would claim ground nobody saw.
    ///
    /// `tapWall` and `baselineS` are the walk's (`CoverageMap.wall`, `ScanEngine.exportSpan`).
    static func export(
        _ snapshot: Map3DSnapshot, tapWall: WallFrame, baselineS: ClosedRange<Float>,
        leftEndMarked: Bool, rightEndMarked: Bool, walkedFacing: [ObservedSpan], confirmedOverhead: [ObservedSpan]
    ) throws(Map3DCoverageError) -> Map3DExport {
        guard snapshot.wall == tapWall else { throw .wallMismatch }
        switch measuredExport(snapshot, tapWall: tapWall, baselineS: baselineS) {
        case .success(let measured):
            var coverage = measured.coverage
            coverage.facing = largerReach(coverage.facing, ObservedSpan.carried(walkedFacing, depth: nil, from: tapWall, to: measured.wall))
            // The session's map runs with the default config, whose battery depth the map's own
            // overhead band is judged over.
            let batteryDepth = Map3DConfig().overheadDepth
            coverage.overhead = largerReach(
                coverage.overhead, ObservedSpan.carried(confirmedOverhead, depth: batteryDepth, from: tapWall, to: measured.wall))
            return Map3DExport(
                wall: measured.wall, baselineS: measured.baselineS,
                coverage: sceneCoverage(coverage, within: measured.baselineS, leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked),
                plusMinus: measured.plusMinus, tappedBecause: nil)
        case .failure(let refusal):
            var coverage = snapshot.coverage
            coverage.facing = largerReach(coverage.facing, walkedFacing)
            coverage.overhead = largerReach(coverage.overhead, confirmedOverhead)
            return Map3DExport(
                wall: tapWall, baselineS: baselineS,
                coverage: sceneCoverage(coverage, within: baselineS, leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked),
                plusMinus: [], tappedBecause: refusal.reason)
        }
    }

    /// Why the measured chain was not written.
    struct Refusal: Error {
        var reason: String
    }

    private static func measuredExport(
        _ snapshot: Map3DSnapshot, tapWall: WallFrame, baselineS: ClosedRange<Float>
    ) -> Result<(wall: WallFrame, baselineS: ClosedRange<Float>, coverage: Map3DCoverage, plusMinus: [Float?]), Refusal> {
        guard let chain = snapshot.chain, chain.meterIndex < chain.walls.count else { return .failure(Refusal(reason: "no measured wall passes the meter")) }
        guard let measured = snapshot.measured, measured.wall.segments.count == chain.walls.count else {
            return .failure(Refusal(reason: "the snapshot has no measured wall frame"))
        }
        let frame = snapshot.frame
        let meterPiece = chain.walls[chain.meterIndex]
        let outward = frame.worldDirection(SIMD3(meterPiece.outward.x, 0, meterPiece.outward.y))
        let flat = simd_normalize(SIMD3(outward.x, 0, outward.z))
        guard simd_dot(flat, tapWall.outward) >= cos(WallFrame.minCornerAngle) else {
            return .failure(Refusal(reason: "the measured meter piece turns more than 30 degrees from the tapped wall"))
        }
        let meterMap = frame.map(tapWall.meter)
        let meterPlan = SIMD2(meterMap.x, meterMap.z)
        // The exported wall's origin is the meter's foot on this piece (`wallFrame`), which the
        // server must find again by projecting the meter; a foot off the piece would be clamped.
        let footT = simd_dot(meterPlan - meterPiece.start, meterPiece.along)
        let inset = min(0.01, meterPiece.length / 2)
        guard footT >= inset, footT <= meterPiece.length - inset else {
            return .failure(Refusal(reason: "the meter's foot falls off the measured meter piece"))
        }
        let meterOff = abs(simd_dot(meterPlan - meterPiece.start, meterPiece.outward))
        guard meterOff <= meterLineDistance else {
            return .failure(Refusal(reason: "the meter is \(meterOff) m from the measured meter piece's line"))
        }

        // The baseline's ends are places on the tapped wall; the same places on the measured one.
        func measuredS(_ s: Float) -> Float { measured.wall.wallPoint(tapWall.world(s: s, height: 0)).s }
        let low = measuredS(baselineS.lowerBound)
        let high = measuredS(baselineS.upperBound)
        guard low < 0, high > 0 else { return .failure(Refusal(reason: "the baseline's ends fall on one side of the meter on the measured wall")) }

        for corner in measured.wall.leftCorners + measured.wall.rightCorners where corner.s > low && corner.s < high {
            let point = measured.wall.world(s: corner.s, height: 0)
            let onTapped = tapWall.world(s: tapWall.wallPoint(point).s, height: 0)
            let distance = simd_distance(SIMD2(point.x, point.z), SIMD2(onTapped.x, onTapped.z))
            guard distance <= cornerDistance else {
                return .failure(Refusal(reason: "the measured corner at s=\(corner.s) m is \(distance) m from the tapped wall"))
            }
        }

        // The chain's own ends in s, as `MeasuredWallChain.wallFrame` lays it out from the meter.
        let meterS = footT
        let leftEnd = -meterS - chain.walls.prefix(chain.meterIndex).reduce(0) { $0 + $1.length }
        let rightEnd = meterPiece.length - meterS + chain.walls.suffix(from: chain.meterIndex + 1).reduce(0) { $0 + $1.length }
        guard leftEnd <= low + chainShortfall, rightEnd >= high - chainShortfall else {
            return .failure(Refusal(reason: "the measured chain spans s=\(leftEnd)...\(rightEnd) m, short of the baseline \(low)...\(high) m"))
        }

        return .success((measured.wall, low...high, measured.coverage, chain.walls.map(plusMinus(of:))))
    }

    /// The line's position error, meters: the fit's two standard errors (`MeasuredWall.plusMinus`),
    /// scene.json's `plus_minus_ft` for the wall.
    static func plusMinus(of wall: MeasuredWall) -> Float? {
        wall.plusMinus
    }

    /// The larger of two reaches at every s either has one, as spans in s order, neighbours
    /// with the same reach joined. Where only one list has a span, its reach stands.
    static func largerReach(_ a: [ObservedSpan], _ b: [ObservedSpan]) -> [ObservedSpan] {
        let all = a + b
        let edges = Set(all.flatMap { [$0.span.lowerBound, $0.span.upperBound] }).sorted()
        var result: [ObservedSpan] = []
        for (low, high) in zip(edges, edges.dropFirst()) where low < high {
            let middle = (low + high) / 2
            guard let reach = all.filter({ $0.span.contains(middle) }).map(\.out).max() else { continue }
            if let last = result.last, last.out == reach, last.span.upperBound == low {
                result[result.count - 1].span = last.span.lowerBound...high
            } else {
                result.append(ObservedSpan(span: low...high, out: reach))
            }
        }
        return result
    }

    static func sceneCoverage(_ coverage: Map3DCoverage, within baseline: ClosedRange<Float>, leftEndMarked: Bool, rightEndMarked: Bool) -> SceneCoverage {
        func clip(_ span: ClosedRange<Float>) -> ClosedRange<Float>? {
            let low = max(span.lowerBound, baseline.lowerBound)
            let high = min(span.upperBound, baseline.upperBound)
            return low < high ? low...high : nil
        }
        func clip(_ spans: [ObservedSpan]) -> [ObservedSpan] {
            spans.compactMap { item in clip(item.span).map { ObservedSpan(span: $0, out: item.out) } }
        }
        // Each stretch of face with the height it was seen to (`Map3DCoverage.wallHeight`), not
        // only the stretches seen to headroom (`Map3DCoverage.wall`): the server credits each
        // entry against the height its check needs.
        return SceneCoverage(
            leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked, wall: clip(coverage.wallHeight),
            ground: clip(coverage.ground), facing: clip(coverage.facing), overhead: clip(coverage.overhead))
    }
}
