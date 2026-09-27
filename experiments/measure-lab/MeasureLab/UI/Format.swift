import Foundation
import MeasureGeometry

/// Text for lengths and angles. Tapes read feet, inches and eighths, so lengths show both units.
enum Format {
    /// "1.918 m · 6 ft 3 1/2 in"
    static func length(_ meters: Double) -> String {
        "\(meters.formatted(.number.precision(.fractionLength(3)))) m · \(feetAndInches(meters))"
    }

    /// "6 ft 3 1/2 in", to the nearest 1/8 in.
    static func feetAndInches(_ meters: Double) -> String {
        let split = Length.feetAndInches(meters: meters)
        let sign = split.negative ? "−" : ""
        let inches = eighths(split.inches)
        return split.feet == 0 ? "\(sign)\(inches) in" : "\(sign)\(split.feet) ft \(inches) in"
    }

    /// "0.8 in"
    static func inches(_ meters: Double) -> String {
        "\(Length.inches(meters: meters).formatted(.number.precision(.fractionLength(1)))) in"
    }

    /// "+1.3 in" or "−0.4 in"
    static func signedInches(_ meters: Double) -> String {
        let value = Length.inches(meters: meters)
        let rounded = (value * 10).rounded() / 10
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(1)))
        return rounded == 0 ? "0.0 in" : "\(rounded > 0 ? "+" : "−")\(magnitude) in"
    }

    /// "38°"
    static func degrees(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0))))°"
    }

    /// 3.5 → "3 1/2", 0.125 → "1/8", 7 → "7". Expects a multiple of 1/8.
    static func eighths(_ inches: Double) -> String {
        var whole = Int(inches.rounded(.down))
        var numerator = Int(((inches - Double(whole)) * 8).rounded())
        if numerator == 8 {
            whole += 1
            numerator = 0
        }
        guard numerator > 0 else { return "\(whole)" }
        var denominator = 8
        while numerator.isMultiple(of: 2) {
            numerator /= 2
            denominator /= 2
        }
        return whole == 0 ? "\(numerator)/\(denominator)" : "\(whole) \(numerator)/\(denominator)"
    }
}
