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

    /// Whole feet rounded up, for a distance the homeowner must reach at least: "out to about
    /// 7 ft" must not ask for less than the request.
    static func feetAtLeast(_ meters: Float) -> String {
        "\(max(1, Int((abs(meters) / (metersPerInch * 12) - 0.001).rounded(.up)))) ft"
    }

    /// "5 ft either side of your meter", or "from 3 ft left to 5 ft right of your meter" when the
    /// stretch is lopsided, for the tilt-up step.
    static func stretchAroundMeter(_ span: ClosedRange<Float>) -> String {
        let left = roughFeet(span.lowerBound), right = roughFeet(span.upperBound)
        if span.lowerBound >= 0 { return "from your meter to \(right) right of it" }
        if span.upperBound <= 0 { return "from \(left) left of your meter to your meter" }
        if left == right { return "\(left) either side of your meter" }
        return "from \(left) left to \(right) right of your meter"
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

    /// "from 4 ft to 19 ft right of your meter", or "from 3 ft left to 2 ft right of your meter":
    /// a stretch by its two ends in whole feet, nearer end first, for a request that can run
    /// along much of the wall (issue #75). It is clipped to the wall's marked ends, so a request
    /// running past one names only the wall there is; one lying wholly past an end is named as
    /// it is. Ends that round to the same foot read "about 5 ft right of your meter".
    static func range(_ span: ClosedRange<Float>, clippedTo ends: (left: Float?, right: Float?) = (nil, nil)) -> String {
        var low = max(span.lowerBound, ends.left ?? -.infinity)
        var high = min(span.upperBound, ends.right ?? .infinity)
        if low > high {
            low = span.lowerBound
            high = span.upperBound
        }
        let foot = metersPerInch * 12
        let lowFeet = Int((low / foot).rounded()), highFeet = Int((high / foot).rounded())
        switch (lowFeet, highFeet) {
        case (0, 0):
            return "around your meter"
        case let (a, b) where a == b:
            return "about \(abs(a)) ft \(a < 0 ? "left" : "right") of your meter"
        case (0, let b) where b > 0:
            return "from your meter to \(b) ft right of it"
        case (let a, 0) where a < 0:
            return "from your meter to \(-a) ft left of it"
        case let (a, b) where a > 0:
            return "from \(a) ft to \(b) ft right of your meter"
        case let (a, b) where b < 0:
            return "from \(-b) ft to \(-a) ft left of your meter"
        case let (a, b):
            return "from \(-a) ft left to \(b) ft right of your meter"
        }
    }

    /// "about 5 ft right of your meter" for the middle of a span: a place to walk to, not a
    /// measurement to check.
    static func aroundFromMeter(_ span: ClosedRange<Float>) -> String {
        let center = (span.lowerBound + span.upperBound) / 2
        if span.contains(0) || abs(center) < 0.3 { return "around your meter" }
        return "about \(roughFeet(center)) \(center < 0 ? "left" : "right") of your meter"
    }
}

extension String {
    /// "about 5 ft right of your meter" as the start of a sentence.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
