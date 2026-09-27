import Foundation
import simd

/// Whether scene.json may describe the 3D map's measured wall chain rather than the walk's
/// tapped wall: only where the two agree.
public enum MeasuredChainAdmission {
    /// How far the measured chain may stop short of each end of the walk's baseline and still
    /// describe it, meters: two 10 cm voxels. A measured piece ends within half a voxel of its
    /// last column of wall evidence, and a marked end is a tap. A guess, not measured.
    public static let chainShortfall: Float = 0.2
    /// How far the tapped meter may lie from the line of the measured meter piece, meters. A
    /// parallel surface near the meter (a fence, a hedge face, the meter box's own front) faces
    /// the same way as the wall and passes the direction check; this keeps it from standing in
    /// for the wall. The meter box stands roughly 0.1 to 0.2 m proud of the wall. A guess, not
    /// measured.
    public static let meterLineDistance: Float = 0.3
    /// How far a measured corner within the baseline may lie from the tapped chain, meters. The
    /// homeowner's taps say where the walk's wall runs; a measured corner far from it belongs to
    /// something else. A guess, not measured: larger than tap error, smaller than a step.
    public static let cornerDistance: Float = 0.5

    /// Why the measured chain was not admitted.
    public struct Refusal: Error, Equatable {
        public var reason: String
    }

    /// The baseline in `measured`'s s when the chain (laid out as `measured`,
    /// `MeasuredWallChain.wallFrame`) may stand for the tapped wall: its meter piece faces within
    /// `WallFrame.minCornerAngle` of the tapped wall, the meter's foot falls on it within
    /// `meterLineDistance` of its line, every measured corner within the baseline lies within
    /// `cornerDistance` of the tapped chain and every tapped corner and baseline end within
    /// `cornerDistance` of the measured chain, and the chain reaches both ends of the baseline to
    /// within `chainShortfall`. `frame` is the map's frame; `baselineS` is in the tapped wall's s.
    public static func admit(
        _ chain: MeasuredWallChain, as measured: WallFrame, frame: MapFrame, tapWall: WallFrame, baselineS: ClosedRange<Float>
    ) -> Result<ClosedRange<Float>, Refusal> {
        guard chain.meterIndex < chain.walls.count, measured.segments.count == chain.walls.count else {
            return .failure(Refusal(reason: "no measured wall passes the meter"))
        }
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
        let low = tapWall.s(baselineS.lowerBound, along: measured)
        let high = tapWall.s(baselineS.upperBound, along: measured)
        guard low < 0, high > 0 else { return .failure(Refusal(reason: "the baseline's ends fall on one side of the meter on the measured wall")) }

        for corner in measured.leftCorners + measured.rightCorners where corner.s > low && corner.s < high {
            let point = measured.world(s: corner.s, height: 0)
            let distance = planDistance(point, tapWall.world(s: tapWall.wallPoint(point).s, height: 0))
            guard distance <= cornerDistance else {
                return .failure(Refusal(reason: "the measured corner at s=\(corner.s) m is \(distance) m from the tapped wall"))
            }
        }

        // And the reverse: every tapped corner within the baseline, and both of the baseline's
        // ends, lie within `cornerDistance` of the measured chain, measured in plan. Projecting
        // onto the measured chain alone ignores how far off it a point lies: a walk that turned a
        // corner the map didn't find would map its side wall onto the front wall's line.
        let tappedPlaces = (tapWall.leftCorners + tapWall.rightCorners).map(\.s).filter { baselineS.contains($0) }
            + [baselineS.lowerBound, baselineS.upperBound]
        for s in tappedPlaces {
            let point = tapWall.world(s: s, height: 0)
            let distance = planDistance(point, measured.world(s: measured.wallPoint(point).s, height: 0))
            guard distance <= cornerDistance else {
                return .failure(Refusal(reason: "the tapped wall at s=\(s) m is \(distance) m from the measured chain"))
            }
        }

        // The chain's own ends in s, as `MeasuredWallChain.wallFrame` lays it out from the meter.
        let leftEnd = -footT - chain.walls.prefix(chain.meterIndex).reduce(0) { $0 + $1.length }
        let rightEnd = meterPiece.length - footT + chain.walls.suffix(from: chain.meterIndex + 1).reduce(0) { $0 + $1.length }
        guard leftEnd <= low + chainShortfall, rightEnd >= high - chainShortfall else {
            return .failure(Refusal(reason: "the measured chain spans s=\(leftEnd)...\(rightEnd) m, short of the baseline \(low)...\(high) m"))
        }
        return .success(low...high)
    }

    static func planDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_distance(SIMD2(a.x, a.z), SIMD2(b.x, b.z))
    }
}
