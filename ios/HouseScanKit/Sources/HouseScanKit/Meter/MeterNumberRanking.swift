import Foundation

// Finds the meter number among everything Vision read on a close-up. A port of the close-up eval's
// locate.py (experiments/meter-closeup/src/meter_eval/locate.py on t3/meter-closeup at 944cbe1):
// the same tokens, features and hand-set score, which put the number in the top three on 90% of
// the photos whose number Vision read (85% on the held-out half; README, question 5).

/// A box in normalized image coordinates with a top-left origin: Vision's `boundingBox` with y
/// flipped.
public struct MeterBox: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One recognized text line: the top string of a `VNRecognizedTextObservation` and its box.
public struct MeterTextLine: Sendable, Equatable {
    public var text: String
    public var box: MeterBox

    public init(text: String, box: MeterBox) {
        self.text = text
        self.box = box
    }
}

/// One way the recognized text could hold the meter number, with the features the score uses.
public struct MeterTextCandidate: Sendable, Equatable {
    /// The number as compared and shown: uppercase letters and digits, without letters before the
    /// first digit (`MeterNumberRanking.core`).
    public var core: String
    public var box: MeterBox
    /// The core equals a part of a decoded barcode payload.
    public var barcodeConfirmed: Bool
    /// The line starts with a label word such as `No.`, `Nr.`, `#:` or `S/N`.
    public var keyword: Bool
    /// The token is the whole line once the label word is removed.
    public var alone: Bool
    /// The line describes the meter (voltage, rating, `Kh`, `CL200`, `FORM`...) rather than
    /// identifying it.
    public var spec: Bool
    /// The box is taller than wide: rotated text.
    public var vertical: Bool
    public var zeros: Bool
    /// 6 to 14 characters with at least 5 digits.
    public var lengthOK: Bool

    /// locate.py's `score`: the features weighted by hand on the eval's odd-numbered photos, plus
    /// the box height (under 1) to break ties toward larger print.
    public var score: Double {
        8 * weight(barcodeConfirmed) + 3 * weight(keyword) + 2 * weight(alone) + weight(lengthOK)
            - 6 * weight(spec) - 4 * weight(vertical) - 6 * weight(zeros) + box.height
    }

    private func weight(_ flag: Bool) -> Double { flag ? 1 : 0 }
}

public enum MeterNumberRanking {
    /// Every candidate in the recognized lines, in line order and token order within a line.
    ///
    /// A text token whose core equals a barcode payload part is confirmed. One whose core (at
    /// least 6 characters) sits inside a longer payload part is a partial read of it, as when
    /// Vision drops a digit or a prefix printed apart; the candidate then takes that part.
    public static func candidates(lines: [MeterTextLine], barcodePayloads: [String]) -> [MeterTextCandidate] {
        let payloads = payloadParts(barcodePayloads)
        var found: [MeterTextCandidate] = []
        for line in lines {
            let text = line.text
            // locate.py also rules out lines starting with "CAT", which the keyword pattern can
            // never match, so that test is left out.
            let keyword = firstMatch(keywordPattern, in: text) != nil
            let lineCore = core(removingKeyword(from: text))
            let spec = firstMatch(specPattern, in: text) != nil
            for token in tokens(text) {
                var tokenCore = core(token)
                var confirmed = payloads.contains(tokenCore)
                if !confirmed, tokenCore.count >= 6 {
                    // locate.py takes min(longer, key=len) over a set, which leaves ties between
                    // equally long parts to hash order; this breaks them alphabetically.
                    let longer = payloads.filter { $0.contains(tokenCore) }
                        .min { ($0.count, $0) < ($1.count, $1) }
                    if let longer {
                        tokenCore = longer
                        confirmed = true
                    }
                }
                found.append(MeterTextCandidate(
                    core: tokenCore,
                    box: line.box,
                    barcodeConfirmed: confirmed,
                    keyword: keyword,
                    alone: lineCore == tokenCore,
                    spec: spec,
                    vertical: line.box.height > line.box.width,
                    zeros: tokenCore.allSatisfy { $0 == "0" },
                    lengthOK: (6...14).contains(tokenCore.count) && digitCount(tokenCore) >= 5
                ))
            }
        }
        return found
    }

    /// Highest score first; equal scores keep their reading order, as Python's stable sort does.
    public static func ranked(_ candidates: [MeterTextCandidate]) -> [MeterTextCandidate] {
        candidates.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }

    /// What the homeowner is asked to pick from: barcode-confirmed candidates first (the README's
    /// "For the app"), each in score order, each number once, at most `limit`.
    public static func choices(_ candidates: [MeterTextCandidate], limit: Int = 3) -> [MeterTextCandidate] {
        let order = ranked(candidates)
        var seen = Set<String>()
        return (order.filter(\.barcodeConfirmed) + order.filter { !$0.barcodeConfirmed })
            .filter { seen.insert($0.core).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Digit-bearing tokens of one line, with a leading label word removed.
    ///
    /// Runs of purely numeric groups merge (`12 345 678` is one token); other groups stand alone
    /// (`123ABC456789`). The whole remaining line is also a token when it has two to four groups,
    /// so a number printed as `1 ABC00 1234 5678` survives. Tokens with fewer than 4 digits drop.
    public static func tokens(_ text: String) -> [String] {
        let rest = removingKeyword(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [String] = []
        var run: [String] = []
        for group in groups {
            if isDigitGroup(group) {
                run.append(group)
                continue
            }
            if !run.isEmpty {
                found.append(run.joined(separator: " "))
                run = []
            }
            found.append(group)
        }
        if !run.isEmpty { found.append(run.joined(separator: " ")) }
        if (2...4).contains(groups.count) { found.append(rest) }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted && digitCount($0) >= 4 }
    }

    /// Uppercase letters and digits only, without a leading run of letters before a digit, so a
    /// label word or utility prefix printed apart from the number does not decide a match:
    /// `NO. 12345678` becomes `12345678`. match.py's `core`.
    public static func core(_ text: String) -> String {
        let normalized = String(text.uppercased().unicodeScalars.filter { isASCIILetter($0) || isASCIIDigit($0) }.map(Character.init))
        guard let firstNonLetter = normalized.unicodeScalars.firstIndex(where: { !isASCIILetter($0) }) else {
            return normalized
        }
        return String(normalized.unicodeScalars[firstNonLetter...])
    }

    /// Cores of the digit-bearing parts of every decoded payload, split on whitespace and `;*,{}`.
    static func payloadParts(_ payloads: [String]) -> Set<String> {
        var parts = Set<String>()
        for payload in payloads {
            for part in payload.split(whereSeparator: { $0.isWhitespace || ";*,{}".contains($0) }) where digitCount(part) >= 4 {
                parts.insert(core(String(part)))
            }
        }
        return parts
    }

    // A label word in front of the number: No., Nr., N°, №, #:, S/N, Serial. "#:" is how Vision
    // renders the Taiwanese label 電號: in front of the number. locate.py's KEYWORD.
    private static let keywordPattern = regex(#"^\s*(?:N[O0R]\.?|N°|№|#\s*:|S/?N|SERIAL\s*#?)\s*[.:#]?\s*"#)
    // Lines that describe the meter rather than identify it: ratings, voltages, constants, forms.
    // locate.py's SPEC.
    private static let specPattern = regex(
        #"\d\s*\(\s*\d+\s*\)|\d\s*V\b|HZ|\bKH\b|KH\s*\d|\bKT\b|\bTA\s*=?\s*\d|\bCL\s*\d|\d\s*CL\b|"#
            + #"\bFM\s*\d|FORM|TYPE|IMP|KWH|REV|U/|°C|AMP|VOLT|\bPHASE|\bWIRE|\d+/\d+|\bCA\s*\d"#
    )

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("MeterNumberRanking: bad pattern \(pattern): \(error)")
        }
    }

    private static func firstMatch(_ pattern: NSRegularExpression, in text: String) -> NSRange? {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
    }

    private static func removingKeyword(from text: String) -> String {
        guard let range = firstMatch(keywordPattern, in: text), let swiftRange = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: swiftRange, with: "")
    }

    /// Python's `str.isdigit` count: characters whose Unicode numeric type is decimal or digit.
    static func digitCount<S: StringProtocol>(_ text: S) -> Int {
        text.unicodeScalars.count { $0.properties.numericType == .decimal || $0.properties.numericType == .digit }
    }

    /// Only decimal digits (Python's `\d`), dots, commas and hyphens: locate.py's DIGIT_GROUP.
    private static func isDigitGroup(_ group: String) -> Bool {
        !group.isEmpty && group.unicodeScalars.allSatisfy { $0.properties.numericType == .decimal || ".,-".unicodeScalars.contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool { ("A"..."Z").contains(scalar) }
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
}
