/// Conversions between ARKit meters and the feet and inches a tape reads.
public enum Length {
    /// Exact by definition (international inch, 1959).
    public static let metersPerInch = 0.0254
    public static let inchesPerFoot = 12.0

    public static func meters(feet: Double, inches: Double) -> Double {
        (feet * inchesPerFoot + inches) * metersPerInch
    }

    public static func inches(meters: Double) -> Double {
        meters / metersPerInch
    }

    /// Splits a length into whole feet and remaining inches, rounded to `inchStep` (1/8 in by
    /// default). The sign goes on `negative` so both parts stay non-negative.
    public static func feetAndInches(meters: Double, inchStep: Double = 0.125) -> FeetAndInches {
        let totalInches = (abs(inches(meters: meters)) / inchStep).rounded() * inchStep
        let feet = (totalInches / inchesPerFoot).rounded(.down)
        return FeetAndInches(negative: meters < 0 && totalInches > 0, feet: Int(feet), inches: totalInches - feet * inchesPerFoot)
    }
}

public struct FeetAndInches: Sendable, Equatable {
    public let negative: Bool
    public let feet: Int
    public let inches: Double
}

/// A reading typed from a tape: whole or decimal feet plus inches, where inches may be a decimal
/// ("3.25"), a fraction ("1/4"), or both ("3 1/4").
public struct TapeReading: Sendable, Equatable {
    public let feet: Double
    public let inches: Double

    public var meters: Double {
        Length.meters(feet: feet, inches: inches)
    }

    /// Zero is allowed: the return-to-reference check tapes a gap that should be 0.
    public init(feet: Double, inches: Double) throws(TapeEntryError) {
        guard feet.isFinite, inches.isFinite, feet >= 0, inches >= 0 else {
            throw .negativeOrNotFinite
        }
        self.feet = feet
        self.inches = inches
    }

    /// One empty field counts as zero. Throws when both are empty or either does not parse.
    public init(feetText: String, inchesText: String) throws(TapeEntryError) {
        guard !(feetText + inchesText).allSatisfy(\.isWhitespace) else {
            throw .empty
        }
        let feet = try Self.parseNumber(feetText, field: .feet)
        let inches = try Self.parseNumber(inchesText, field: .inches)
        try self.init(feet: feet, inches: inches)
    }

    /// Accepts "", "3", "3.25", "1/4" and "3 1/4". Empty text is zero.
    private static func parseNumber(_ text: String, field: TapeEntryError.Field) throws(TapeEntryError) -> Double {
        let parts = text.split(separator: " ")
        switch parts.count {
        case 0:
            return 0
        case 1:
            if let value = decimal(parts[0]) ?? fraction(parts[0]) { return value }
        case 2:
            if let whole = decimal(parts[0]), let part = fraction(parts[1]) { return whole + part }
        default:
            break
        }
        throw .unreadable(field: field, text: text)
    }

    private static func decimal(_ text: Substring) -> Double? {
        text.contains("/") ? nil : Double(text)
    }

    private static func fraction(_ text: Substring) -> Double? {
        let halves = text.split(separator: "/", omittingEmptySubsequences: false)
        guard
            halves.count == 2,
            let numerator = Double(halves[0]),
            let denominator = Double(halves[1]),
            denominator > 0
        else { return nil }
        return numerator / denominator
    }
}

public enum TapeEntryError: Error, Sendable, Equatable {
    public enum Field: String, Sendable {
        case feet
        case inches
    }

    case unreadable(field: Field, text: String)
    case negativeOrNotFinite
    case empty
}
