import Foundation

/// Lengths in the words a homeowner uses: feet and inches, rounded to the nearest inch.
enum Distance {
    static let metersPerInch: Float = 0.0254

    /// "8 in", "3 ft", "3 ft 4 in". Negative input is treated as its magnitude.
    static func feetAndInches(_ meters: Float) -> String {
        let totalInches = Int((abs(meters) / metersPerInch).rounded())
        let feet = totalInches / 12
        let inches = totalInches % 12
        switch (feet, inches) {
        case (0, let inches): return "\(inches) in"
        case (let feet, 0): return "\(feet) ft"
        default: return "\(feet) ft \(inches) in"
        }
    }

    /// Whole feet for rough amounts ("about 12 ft to go"), never below 1 ft.
    /// How far is left to walk, in 5 ft steps above 5 ft. The walk card showed the nearest foot,
    /// so its text changed about every stride; a coarse count reads calmer and changes rarely.
    static func remainingWalk(_ meters: Float) -> String {
        let feet = abs(meters) / (metersPerInch * 12)
        guard feet > 5 else { return roughFeet(meters) }
        return "\(Int((feet / 5).rounded()) * 5) ft"
    }

    static func roughFeet(_ meters: Float) -> String {
        let feet = max(1, Int((abs(meters) / (metersPerInch * 12)).rounded()))
        return "\(feet) ft"
    }

    /// VoiceOver reads "ft" as letters; spell the units out.
    static func spoken(_ meters: Float) -> String {
        let totalInches = Int((abs(meters) / metersPerInch).rounded())
        let feet = totalInches / 12
        let inches = totalInches % 12
        let feetWord = feet == 1 ? "foot" : "feet"
        let inchWord = inches == 1 ? "inch" : "inches"
        switch (feet, inches) {
        case (0, let inches): return "\(inches) \(inchWord)"
        case (let feet, 0): return "\(feet) \(feetWord)"
        default: return "\(feet) \(feetWord) \(inches) \(inchWord)"
        }
    }

    /// "3 ft 4 in right of your meter" for a position s along the wall.
    static func fromMeter(_ s: Float) -> String {
        if abs(s) < metersPerInch * 3 { return "at your meter" }
        return "\(feetAndInches(s)) \(s < 0 ? "left" : "right") of your meter"
    }

    /// "about 5 ft right of your meter" for the middle of a span: a place to walk to, not a
    /// measurement to check.
    static func aroundFromMeter(_ span: ClosedRange<Float>) -> String {
        let center = (span.lowerBound + span.upperBound) / 2
        if span.contains(0) || abs(center) < 0.3 { return "around your meter" }
        return "about \(roughFeet(center)) \(center < 0 ? "left" : "right") of your meter"
    }
}
