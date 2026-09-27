import Foundation

/// A server request's stretch in whole feet, for the gap card to name by its two ends (issue #75).
///
/// A server request is met only over its whole span: `GapPlanner.isSatisfied` needs progress 1
/// over `GapPlan.requestedSpanFt`. So the stretch the card names must cover all of it. Each end
/// is rounded outward, and nothing is clipped to the wall's marked ends: a ground request can run
/// past a limit end (`GapPlanner.reachesPastEnd`), where ground is still recorded, and naming only
/// the wall's part of it left required ground unnamed.
public enum RequestStretch {
    /// How far an end may lie past a whole foot and still round to it: the server's
    /// COVERAGE_TOLERANCE_FT, under which a gap reads as rounding (`GapPlanner.fraction`). It also
    /// keeps a span given in whole feet from gaining a foot on its way to meters and back.
    public static let toleranceFt: Double = 0.01

    /// `span`, meters along the wall, as whole feet rounded outward: the lower end down, the upper
    /// end up. 2.4...7.4 ft is 2...8 ft, -7.4...-2.4 ft is -8...-2 ft, -2.4...7.4 ft is -3...8 ft.
    public static func wholeFeet(_ span: ClosedRange<Float>) -> ClosedRange<Int> {
        let low = Double(span.lowerBound) * SceneUnits.feetPerMeter
        let high = Double(span.upperBound) * SceneUnits.feetPerMeter
        let first = Int((low + toleranceFt).rounded(.down))
        let last = Int((high - toleranceFt).rounded(.up))
        return first...max(first, last)
    }
}
