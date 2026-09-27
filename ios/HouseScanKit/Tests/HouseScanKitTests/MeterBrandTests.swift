import Testing
@testable import HouseScanKit

@Suite struct MeterBrandTests {
    private func line(_ text: String, height: Double) -> MeterTextLine {
        MeterTextLine(text: text, box: MeterBox(x: 0.1, y: 0.1, width: 0.5, height: height))
    }

    @Test(arguments: [
        ("Landis+Gyr", "Landis+Gyr"),
        ("LANDIS + GYR", "Landis+Gyr"),
        ("Landis & Gyr AG", "Landis+Gyr"),
        ("L+G", "Landis+Gyr"),
        ("ITRON", "Itron"),
        ("Itrón", "Itron"), // accent folded
        ("TATUNG CO.", "Tatung"),
        ("Tatunq", "Tatung"), // one edit
        ("Iskraemeco", "Iskra"),
        ("GE", "GE"),
        ("GE (US)", "GE"), // the token GE, not GENUS one edit from "GEUS"
        ("CANADIAN GENERAL ELECTRIC", "GE"),
        ("Elster", "Elster"),
        ("ABB Alpha", "ABB"),
        ("Aclaro", "Aclara"), // one edit at 6 letters
        ("CHUNG HSIN ELECTRIC", "Chung-Hsin"),
    ])
    func namesTheMaker(text: String, maker: String) {
        #expect(MeterBrand.match(text) == maker)
    }

    @Test(arguments: [
        "ltron", // ITRON has 5 letters, so no edit is allowed
        "AGE 5", // GE inside a word is not GE
        "GENERAL",
        "KILOWATTHOURS",
        "CL200 240V 3W",
        "",
        "大同",
    ])
    func namesNothing(text: String) {
        #expect(MeterBrand.match(text) == nil)
    }

    @Test func readsTheMakerOnTheTallestLineThatNamesOne() {
        let lines = [
            line("KILOWATTHOURS", height: 0.09),
            line("Aclara", height: 0.02),
            line("LANDIS & GYR", height: 0.03),
        ]
        #expect(MeterBrand.read(lines) == "Landis+Gyr")
    }

    @Test func readsNothingWhenNoLineNamesAMaker() {
        #expect(MeterBrand.read([line("CL200", height: 0.05), line("240V", height: 0.04)]) == nil)
        #expect(MeterBrand.read([]) == nil)
    }

    @Test func oneEditMeansOneInsertionDeletionOrSubstitution() {
        #expect(MeterBrand.withinOneEdit("TATUNG", "TATUNG"))
        #expect(MeterBrand.withinOneEdit("TATUNG", "TATUNQ"))
        #expect(MeterBrand.withinOneEdit("TATUNG", "TATNG"))
        #expect(MeterBrand.withinOneEdit("TATUNG", "TATUNGS"))
        #expect(!MeterBrand.withinOneEdit("TATUNG", "TATNQ"))
        #expect(!MeterBrand.withinOneEdit("TATUNG", "TA"))
    }

    @Test func normalizesLikeTheEval() {
        #expect(MeterBrand.normalized("  Landis+Gyr,  Inc. ") == "LANDIS+GYR INC")
        #expect(MeterBrand.normalized("Itrón") == "ITRON")
        #expect(MeterBrand.normalized("中興 Chung-Hsin") == "CHUNG HSIN")
    }
}
