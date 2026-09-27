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
    /// The wall, baseline, coverage and wall sources scene.json gets.
    ///
    /// The measured chain is used when `snapshot.measured` exists (`finalSnapshot()` fills it)
    /// and it agrees with the walk (`MeasuredChainAdmission`). Otherwise the tapped wall is
    /// written with source `tap`, and `tappedBecause` says which test failed. Coverage is always
    /// the one measured along
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
        guard let chain = snapshot.chain else { return .failure(Refusal(reason: "no measured wall passes the meter")) }
        guard let measured = snapshot.measured else { return .failure(Refusal(reason: "the snapshot has no measured wall frame")) }
        switch MeasuredChainAdmission.admit(chain, as: measured.wall, frame: snapshot.frame, tapWall: tapWall, baselineS: baselineS) {
        case .success(let baseline):
            return .success((measured.wall, baseline, measured.coverage, chain.walls.map(plusMinus(of:))))
        case .failure(let refusal):
            return .failure(Refusal(reason: refusal.reason))
        }
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
