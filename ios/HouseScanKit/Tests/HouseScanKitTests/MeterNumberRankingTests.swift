import HouseScanKit
import Testing

// Cases from the close-up eval's tests/test_locate.py (t3/meter-closeup at 944cbe1), plus scores
// worked out by hand from locate.py's weights.

private func line(_ text: String, _ box: MeterBox = MeterBox(x: 0.4, y: 0.5, width: 0.2, height: 0.03)) -> MeterTextLine {
    MeterTextLine(text: text, box: box)
}

@Suite struct MeterNumberRankingTests {
    @Test func coreDropsLettersBeforeTheFirstDigit() {
        #expect(MeterNumberRanking.core("NO. 12345678") == "12345678")
        #expect(MeterNumberRanking.core("ABC 123456") == "123456")
        #expect(MeterNumberRanking.core("1 ABC00 1234 5678") == "1ABC0012345678")
        #expect(MeterNumberRanking.core("#:00-01-2345-67") == "0001234567")
        // No digit follows the letters, so nothing is dropped.
        #expect(MeterNumberRanking.core("ab-c") == "ABC")
    }

    @Test func tokensMergeDigitGroupsAndKeepMixedGroups() {
        #expect(MeterNumberRanking.tokens("12 345 678") == ["12 345 678"])
        #expect(MeterNumberRanking.tokens("NO. 12345678") == ["12345678"])
        // A line of two to four groups is also offered whole.
        #expect(MeterNumberRanking.tokens("Type: SCS1321") == ["SCS1321", "Type: SCS1321"])
        // "1" and "ABC00" have fewer than 4 digits; the digit run and the whole line remain.
        #expect(MeterNumberRanking.tokens("1 ABC00 1234 5678") == ["1234 5678", "1 ABC00 1234 5678"])
    }

    @Test func tokensSkipShortNumbers() {
        #expect(MeterNumberRanking.tokens("CL 200") == [])
    }

    @Test func barcodeEqualToATextTokenConfirmsIt() throws {
        let found = MeterNumberRanking.candidates(lines: [line("123ABC456789")], barcodePayloads: ["123ABC456789"])
        let only = try #require(found.count == 1 ? found[0] : nil)
        #expect(only.barcodeConfirmed && only.core == "123ABC456789")
    }

    @Test func partialTextReadTakesTheBarcodesFullString() throws {
        // Vision dropped the leading 1; the QR payload has the whole number.
        let found = MeterNumberRanking.candidates(lines: [line("2345678")], barcodePayloads: ["X0YZ01234567;12345678"])
        let only = try #require(found.count == 1 ? found[0] : nil)
        #expect(only.core == "12345678" && only.barcodeConfirmed)
    }

    @Test func shortTokenInsideAPayloadIsNotConfirmed() throws {
        let found = MeterNumberRanking.candidates(lines: [line("12345")], barcodePayloads: ["9912345000"])
        let only = try #require(found.count == 1 ? found[0] : nil)
        #expect(!only.barcodeConfirmed && only.core == "12345")
    }

    @Test func specLineRanksBelowABareNumber() {
        let found = MeterNumberRanking.candidates(
            lines: [
                line("220V 30(200)A 60Hz", MeterBox(x: 0.3, y: 0.5, width: 0.3, height: 0.05)),
                line("12345678", MeterBox(x: 0.4, y: 0.7, width: 0.2, height: 0.03)),
            ],
            barcodePayloads: []
        )
        #expect(MeterNumberRanking.ranked(found).first?.core == "12345678")
        // "30(200)A": spec -6, 6 characters with 5 digits +1, height 0.05. The whole line
        // "220V30200A60HZ": spec -6, alone +2, 14 characters +1, height 0.05. The bare number:
        // alone +2, length +1, height 0.03.
        #expect(found.map(\.core) == ["30200A", "220V30200A60HZ", "12345678"])
        let expected = [-4.95, -2.95, 3.03]
        for (candidate, score) in zip(found, expected) {
            #expect(abs(candidate.score - score) < 1e-12)
        }
    }

    @Test func labelWordFeatures() throws {
        let found = MeterNumberRanking.candidates(lines: [line("NO. 12345678")], barcodePayloads: [])
        let only = try #require(found.count == 1 ? found[0] : nil)
        #expect(only.keyword && only.alone && only.lengthOK && !only.spec && !only.vertical && !only.zeros)
        // keyword +3, alone +2, length +1, height 0.03.
        #expect(abs(only.score - 6.03) < 1e-12)
    }

    @Test func rotatedAndAllZeroLinesArePenalized() throws {
        let found = MeterNumberRanking.candidates(
            lines: [line("00000000", MeterBox(x: 0.1, y: 0.1, width: 0.02, height: 0.2))],
            barcodePayloads: []
        )
        let only = try #require(found.count == 1 ? found[0] : nil)
        #expect(only.vertical && only.zeros)
        // alone +2, length: 8 characters and 8 digits +1, rotated -4, all zeros -6, height 0.2.
        #expect(abs(only.score - -6.8) < 1e-12)
    }

    @Test func choicesPutBarcodeConfirmedFirstButTheSizeCheckUsesTheTopScore() throws {
        // "99887766" on a spec line: confirmed +8, length +1, spec -6, height 0.03 = 3.03.
        // Whole line "220V99887766": alone +2, length +1, spec -6 = -2.97. "NO. 12345678": 6.03.
        let found = MeterNumberRanking.candidates(
            lines: [line("220V 99887766"), line("NO. 12345678")],
            barcodePayloads: ["99887766"]
        )
        #expect(MeterNumberRanking.ranked(found).map(\.core) == ["12345678", "99887766", "220V99887766"])
        #expect(MeterNumberRanking.choices(found).map(\.core) == ["99887766", "12345678", "220V99887766"])
    }

    @Test func choicesShowEachNumberOnceAndAtMostThree() {
        let found = MeterNumberRanking.candidates(
            lines: ["12345678", "12345678", "23456789", "34567890", "45678901"].map { line($0) },
            barcodePayloads: []
        )
        #expect(MeterNumberRanking.choices(found).map(\.core) == ["12345678", "23456789", "34567890"])
    }
}
