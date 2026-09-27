import Testing
@testable import MeasureGeometry

struct LengthTests {
    @Test func `feet and inches to meters`() {
        #expect(isClose(Length.meters(feet: 1, inches: 0), 0.3048))
        #expect(isClose(Length.meters(feet: 6, inches: 3.5), 1.9177))
        #expect(isClose(Length.inches(meters: 1), 39.37007874015748))
    }

    @Test func `splitting meters into feet and inches`() {
        #expect(Length.feetAndInches(meters: 1.9177) == FeetAndInches(negative: false, feet: 6, inches: 3.5))
        // 35.99 in rounds to 36 in at 1/8 in steps and carries into the feet.
        #expect(Length.feetAndInches(meters: 35.99 * 0.0254) == FeetAndInches(negative: false, feet: 3, inches: 0))
        #expect(Length.feetAndInches(meters: -0.0254) == FeetAndInches(negative: true, feet: 0, inches: 1))
        // Rounds to zero, so no minus sign.
        #expect(Length.feetAndInches(meters: -0.0001) == FeetAndInches(negative: false, feet: 0, inches: 0))
    }

    @Test(arguments: [
        ("6", "3.5", 75.5),
        ("6", "3 1/2", 75.5),
        ("", "1/4", 0.25),
        ("0", "30", 30.0),
        ("2.5", "", 30.0),
        (" 1 ", " 7/8 ", 12.875),
        ("0", "0", 0.0),
        ("", "0", 0.0),
    ])
    func `typed tape readings`(feet: String, inches: String, totalInches: Double) throws {
        let reading = try TapeReading(feetText: feet, inchesText: inches)
        #expect(isClose(reading.meters, totalInches * 0.0254))
    }

    @Test(arguments: [
        ("x", "", TapeEntryError.unreadable(field: .feet, text: "x")),
        ("1", "3/0", .unreadable(field: .inches, text: "3/0")),
        ("1", "1/4 3", .unreadable(field: .inches, text: "1/4 3")),
        ("1", "3 4", .unreadable(field: .inches, text: "3 4")),
        ("1", "1/2/3", .unreadable(field: .inches, text: "1/2/3")),
        ("", "", .empty),
        (" ", "  ", .empty),
        ("-1", "", .negativeOrNotFinite),
        ("inf", "", .negativeOrNotFinite),
    ])
    func `unusable tape readings are refused`(feet: String, inches: String, expected: TapeEntryError) {
        #expect(throws: expected) {
            try TapeReading(feetText: feet, inchesText: inches)
        }
    }
}
