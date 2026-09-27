import Foundation
@testable import HouseScanKit
import simd
import Testing

/// When the export may describe the 3D map's measured wall chain instead of the walk's tapped
/// wall (`MeasuredChainAdmission`): each refusal on its own, and the tapped corner the chain
/// doesn't have.
@Suite struct MeasuredChainAdmissionTests {
    /// The walk's wall: the meter at (0, 1.2, 0), facing +z, ground at 0.
    static let tapped = WallFrame(meter: SIMD3(0, 1.2, 0), outward: SIMD3(0, 0, 1), groundY: 0)!
    static let frame = MapFrame(wall: tapped)

    static func piece(_ a: SIMD2<Float>, _ b: SIMD2<Float>, outward: SIMD2<Float> = SIMD2(0, 1)) -> MeasuredWall {
        MeasuredWall(start: a, end: b, outward: outward, source: .mesh, support: 30, plusMinus: 0.03)
    }

    static func admit(_ chain: MeasuredWallChain, tapped: WallFrame = tapped, baseline: ClosedRange<Float> = -2...2) -> Result<ClosedRange<Float>, MeasuredChainAdmission.Refusal> {
        let measured = chain.wallFrame(meter: tapped.meter, groundY: tapped.groundY, frame: frame)!
        return MeasuredChainAdmission.admit(chain, as: measured, frame: frame, tapWall: tapped, baselineS: baseline)
    }

    static func refused(_ result: Result<ClosedRange<Float>, MeasuredChainAdmission.Refusal>, _ words: String) -> Bool {
        if case .failure(let refusal) = result { return refusal.reason.contains(words) }
        return false
    }

    @Test func aChainOnTheTappedWallIsAdmitted() throws {
        let result = Self.admit(MeasuredWallChain(walls: [Self.piece(SIMD2(-3, 0), SIMD2(3, 0))], meterIndex: 0))
        let baseline = try result.get()
        #expect(abs(baseline.lowerBound + 2) < 1e-3 && abs(baseline.upperBound - 2) < 1e-3)
    }

    /// The walk turned a right corner at s = 2 and went 1 m along the side wall; the map found
    /// only the front wall, straight on past x = 2. The side wall's end projects back onto the
    /// front wall at s = 2, but lies 1 m from it.
    @Test func aTappedCornerTheChainLacksKeepsTheTappedWall() {
        var cornered = Self.tapped
        cornered.turn(.right, at: WallCorner(s: 2, outward: SIMD3(1, 0, 0)))
        let chain = MeasuredWallChain(walls: [Self.piece(SIMD2(-3, 0), SIMD2(3.5, 0))], meterIndex: 0)
        #expect(Self.refused(Self.admit(chain, tapped: cornered, baseline: -2...3), "tapped"))
    }

    @Test func aMeterFarFromTheMeasuredLineIsRefused() {
        let chain = MeasuredWallChain(walls: [Self.piece(SIMD2(-3, -0.5), SIMD2(3, -0.5))], meterIndex: 0)
        #expect(Self.refused(Self.admit(chain), "meter is"))
    }

    @Test func aMeterPieceTurnedFromTheTappedWallIsRefused() {
        let turn: Float = 45 * .pi / 180
        let along = SIMD2(cos(turn), -sin(turn))
        let outward = SIMD2(sin(turn), cos(turn))
        let chain = MeasuredWallChain(walls: [Self.piece(-3 * along, 3 * along, outward: outward)], meterIndex: 0)
        #expect(Self.refused(Self.admit(chain), "turns"))
    }

    @Test func aChainShortOfTheBaselineIsRefused() {
        let chain = MeasuredWallChain(walls: [Self.piece(SIMD2(-1, 0), SIMD2(3, 0))], meterIndex: 0)
        #expect(Self.refused(Self.admit(chain), "short of the baseline"))
    }

    @Test func aMeasuredCornerFarFromTheTappedWallIsRefused() {
        // The chain steps 1.5 m out at x = 0.5 (a bump-out the walk never tapped) and runs on
        // there; the tapped wall runs straight on.
        let chain = MeasuredWallChain(
            walls: [
                Self.piece(SIMD2(-3, 0), SIMD2(0.5, 0)), Self.piece(SIMD2(0.5, 0), SIMD2(0.5, 1.5), outward: SIMD2(-1, 0)),
                Self.piece(SIMD2(0.5, 1.5), SIMD2(4, 1.5)),
            ], meterIndex: 0)
        #expect(Self.refused(Self.admit(chain, baseline: -2...3), "measured corner"))
    }
}
