import Foundation
import HouseScanKit
import simd

/// What scene.json says about the wall and what was seen, when the 3D map is the coverage model.
struct Map3DExport: Sendable {
    /// The wall scene.json describes: the measured chain, or the walk's tapped wall.
    var wall: WallFrame
    /// The described stretch in s of `wall`; contains 0, the meter.
    var baselineS: ClosedRange<Float>
    /// Measured along `wall` and clipped to `baselineS`.
    var coverage: SceneCoverage
    /// One per `wall.segments` piece, left to right.
    var pieces: [Piece]

    struct Piece: Sendable, Equatable {
        /// How the piece's line was found; nil when it was tapped.
        var source: WallSource?
        /// Position error of the line, meters; nil leaves the server's default for the source.
        var plusMinus: Float?
    }

    var isMeasured: Bool { pieces.contains { $0.source != nil } }
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

    /// The wall, baseline, coverage and wall sources scene.json gets.
    ///
    /// The measured chain is used when `snapshot.measured` exists (`finalSnapshot()` fills it),
    /// its meter piece faces within `WallFrame.minCornerAngle` of the tapped wall (the same rule
    /// that tells a new wall from the same one), and it reaches both ends of the baseline to
    /// within `chainShortfall`. Otherwise the tapped wall is written with source `tap`. Either
    /// way coverage is the one measured along the wall written, so s agrees.
    ///
    /// Every band is clipped to the baseline. The map sees ground in front of the chain only,
    /// and the server reads a ground span past a limit end as covering both sides of the wall's
    /// continued line, so reporting it would claim ground nobody saw.
    ///
    /// `tapWall` and `baselineS` are the walk's (`CoverageMap.wall`, `ScanEngine.exportSpan`).
    static func export(
        _ snapshot: Map3DSnapshot, tapWall: WallFrame, baselineS: ClosedRange<Float>, leftEndMarked: Bool, rightEndMarked: Bool
    ) throws(Map3DCoverageError) -> Map3DExport {
        guard snapshot.wall == tapWall else { throw .wallMismatch }
        if let measured = measuredExport(snapshot, tapWall: tapWall, baselineS: baselineS) {
            return Map3DExport(
                wall: measured.wall, baselineS: measured.baselineS,
                coverage: sceneCoverage(measured.coverage, within: measured.baselineS, leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked),
                pieces: measured.pieces)
        }
        return Map3DExport(
            wall: tapWall, baselineS: baselineS,
            coverage: sceneCoverage(snapshot.coverage, within: baselineS, leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked),
            pieces: tapWall.segments.map { _ in Map3DExport.Piece(source: nil, plusMinus: nil) })
    }

    private static func measuredExport(
        _ snapshot: Map3DSnapshot, tapWall: WallFrame, baselineS: ClosedRange<Float>
    ) -> (wall: WallFrame, baselineS: ClosedRange<Float>, coverage: Map3DCoverage, pieces: [Map3DExport.Piece])? {
        guard let chain = snapshot.chain, let measured = snapshot.measured, chain.meterIndex < chain.walls.count,
              measured.wall.segments.count == chain.walls.count else { return nil }
        let frame = snapshot.frame
        let meterPiece = chain.walls[chain.meterIndex]
        let outward = frame.worldDirection(SIMD3(meterPiece.outward.x, 0, meterPiece.outward.y))
        let flat = simd_normalize(SIMD3(outward.x, 0, outward.z))
        guard simd_dot(flat, tapWall.outward) >= cos(WallFrame.minCornerAngle) else { return nil }

        // The baseline's ends are places on the tapped wall; the same places on the measured one.
        func measuredS(_ s: Float) -> Float { measured.wall.wallPoint(tapWall.world(s: s, height: 0)).s }
        let low = measuredS(baselineS.lowerBound)
        let high = measuredS(baselineS.upperBound)
        guard low < 0, high > 0 else { return nil }

        // The chain's own ends in s, as `MeasuredWallChain.wallFrame` lays it out from the meter.
        let meterMap = frame.map(tapWall.meter)
        let inset = min(0.01, meterPiece.length / 2)
        let meterS = min(max(simd_dot(SIMD2(meterMap.x, meterMap.z) - meterPiece.start, meterPiece.along), inset), meterPiece.length - inset)
        let leftEnd = -meterS - chain.walls.prefix(chain.meterIndex).reduce(0) { $0 + $1.length }
        let rightEnd = meterPiece.length - meterS + chain.walls.suffix(from: chain.meterIndex + 1).reduce(0) { $0 + $1.length }
        guard leftEnd <= low + chainShortfall, rightEnd >= high - chainShortfall else { return nil }

        let pieces = chain.walls.map { Map3DExport.Piece(source: $0.source, plusMinus: plusMinus(of: $0)) }
        return (measured.wall, low...high, measured.coverage, pieces)
    }

    /// The line's position error, meters: the fit's two standard errors (`MeasuredWall.plusMinus`),
    /// scene.json's `plus_minus_ft` for the wall.
    static func plusMinus(of wall: MeasuredWall) -> Float? {
        wall.plusMinus
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
        return SceneCoverage(
            leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked, wall: coverage.wall.compactMap(clip),
            ground: clip(coverage.ground), facing: clip(coverage.facing), overhead: clip(coverage.overhead))
    }

    /// The cells of `map` the 3D map saw, for `CoverageMap`'s covered state under the 3D map: a
    /// wall cell whose whole s range lies in a seen wall stretch, and a ground cell whose whole
    /// range lies in a ground stretch seen out to at least the ground band's depth. `coverage`
    /// must be read along `map.wall`.
    static func coveredCells(_ coverage: Map3DCoverage, in map: CoverageMap) -> [SurfaceBand: Set<Int>] {
        // Spans are built from the same cell edges, so this only absorbs Float rounding.
        let tolerance = map.config.cellWidth * 1e-3
        func cells(within spans: [ClosedRange<Float>]) -> Set<Int> {
            var result: Set<Int> = []
            for span in spans {
                for index in map.indices(overlapping: span) {
                    let cell = map.cellRange(index)
                    if cell.lowerBound >= span.lowerBound - tolerance, cell.upperBound <= span.upperBound + tolerance { result.insert(index) }
                }
            }
            return result
        }
        let deepGround = coverage.ground.filter { $0.out + 1e-4 >= map.config.groundBandDepth }.map(\.span)
        return [.wall: cells(within: coverage.wall), .ground: cells(within: deepGround)]
    }
}
