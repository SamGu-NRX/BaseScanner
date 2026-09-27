import Foundation

// Names the meter's maker from the lines Vision read on the close-up. A port of the autodetect
// lab's brands.py and its pick rule (experiments/autodetect/meter_brand/ on t3/autodetect-lab at
// 538f60e): on #16's photos it named the maker correctly on 17 of 19 where the name is printed in
// plain letters and 22 of 42 where it is part of a logo, named none on the 9 without a name, and
// once named the wrong one, on a plate printed with two makers' names.

public enum MeterBrand {
    /// A maker, as shown to the homeowner, and its spellings as printed on meters. Each printed
    /// name is its own brand, even where one company later bought another (Elster and Honeywell,
    /// Actaris and Itron), because the phone reports what is printed. A spelling of 4 characters
    /// or fewer must be a whole token; one of 6 letters or more may be one edit away.
    public static let makers: [(name: String, spellings: [String])] = [
        ("Itron", ["ITRON"]),
        ("Actaris", ["ACTARIS"]),
        ("Schlumberger", ["SCHLUMBERGER"]),
        ("Landis+Gyr", ["LANDIS+GYR", "LANDIS GYR", "LANDIS & GYR", "LANDIS&GYR", "L+G", "LANDIS"]),
        ("GE", ["GE", "GENERAL ELECTRIC"]),
        ("Aclara", ["ACLARA"]),
        ("Elster", ["ELSTER"]),
        ("Honeywell", ["HONEYWELL"]),
        ("ABB", ["ABB"]),
        ("Sensus", ["SENSUS"]),
        ("Sangamo", ["SANGAMO"]),
        ("Westinghouse", ["WESTINGHOUSE"]),
        ("Duncan", ["DUNCAN"]),
        ("Siemens", ["SIEMENS"]),
        ("AEG", ["AEG"]),
        ("Iskra", ["ISKRA", "ISKRAEMECO"]),
        ("EMH", ["EMH"]),
        ("DZG", ["DZG"]),
        ("Kamstrup", ["KAMSTRUP"]),
        ("EDMI", ["EDMI"]),
        ("ZIV", ["ZIV"]),
        ("Sagemcom", ["SAGEMCOM", "SAGEM"]),
        ("Hexing", ["HEXING"]),
        ("Holley", ["HOLLEY"]),
        ("Genus", ["GENUS"]),
        ("Secure", ["SECURE METERS"]),
        ("Toshiba", ["TOSHIBA"]),
        ("Mitsubishi", ["MITSUBISHI"]),
        ("Osaki", ["OSAKI"]),
        ("Tatung", ["TATUNG"]),
        ("Chung-Hsin", ["CHUNGHSIN", "CHUNG HSIN", "CHUNG-HSIN"]),
        ("CGE", ["CGE"]),
        ("Enermet", ["ENERMET"]),
        ("Ampy", ["AMPY"]),
        ("Logarex", ["LOGAREX"]),
        ("Echelon", ["ECHELON"]),
    ]

    /// Every spelling with its maker, longest first, so `LANDIS & GYR` is tried before `LANDIS`
    /// and `GENERAL ELECTRIC` before `GE`. Equal lengths keep list order, as Python's stable sort.
    private static let spellings: [(spelling: String, maker: String)] = makers
        .flatMap { maker in maker.spellings.map { (spelling: $0, maker: maker.name) } }
        .enumerated()
        .sorted { $0.element.spelling.count != $1.element.spelling.count ? $0.element.spelling.count > $1.element.spelling.count : $0.offset < $1.offset }
        .map(\.element)

    /// The maker to show for the close-up: the one named on the tallest line that names any, or
    /// nil. Equal heights go to the maker whose name sorts last, as brands.py's `max` over
    /// (height, name) does.
    public static func read(_ lines: [MeterTextLine]) -> String? {
        lines.compactMap { line in match(line.text).map { (height: line.box.height, maker: $0) } }
            .max { ($0.height, $0.maker.uppercased()) < ($1.height, $1.maker.uppercased()) }?
            .maker
    }

    /// The maker one recognized line names, or nil.
    ///
    /// Long spellings match as a substring of the line, or one edit from a token or a pair of
    /// adjacent tokens (Vision drops or swaps a letter, or splits `LANDIS+GYR`). Short spellings
    /// such as `GE` must be a whole token, because they occur inside unrelated words. The edit
    /// needs 6 letters: at 5, `GENUS` is one edit from `GE US`.
    public static func match(_ line: String) -> String? {
        let norm = normalized(line)
        guard !norm.isEmpty else { return nil }
        let tokens = norm.split(separator: " ").map(String.init)
        let pairs = zip(tokens, tokens.dropFirst())
        let windows = tokens + pairs.map { $0 + $1 } + pairs.map { $0 + " " + $1 }
        let squeezed = norm.replacingOccurrences(of: " ", with: "")
        for (spelling, maker) in spellings {
            if spelling.count <= 4 {
                if tokens.contains(spelling) { return maker }
                continue
            }
            let bare = spelling.replacingOccurrences(of: " ", with: "")
            if (" " + norm + " ").contains(" " + spelling + " ") || squeezed.contains(bare) { return maker }
            if bare.count >= 6,
               windows.contains(where: { withinOneEdit(bare, $0.replacingOccurrences(of: " ", with: "")) }) {
                return maker
            }
        }
        return nil
    }

    /// Accents folded to plain letters (`Itrón` reads as ITRON) and other non-ASCII dropped, upper
    /// case, `&` and `+` kept because they are part of names, other characters to spaces, runs of
    /// spaces collapsed.
    static func normalized(_ text: String) -> String {
        let ascii = String(String.UnicodeScalarView(text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)))
        let kept = ascii.uppercased().map { character -> Character in
            character.isASCII && (character.isUppercase || character.isNumber || character == "+" || character == "&") ? character : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        var short = Array(a)
        var long = Array(b)
        guard abs(short.count - long.count) <= 1 else { return false }
        if short.count > long.count { swap(&short, &long) }
        var i = 0
        var j = 0
        var edited = false
        while i < short.count, j < long.count {
            if short[i] == long[j] {
                i += 1
                j += 1
                continue
            }
            if edited { return false }
            edited = true
            if short.count == long.count { i += 1 }
            j += 1
        }
        return true
    }
}
