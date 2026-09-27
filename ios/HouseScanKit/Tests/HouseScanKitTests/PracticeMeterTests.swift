import Foundation
import simd
import Testing
@testable import HouseScanKit

@Suite struct PracticeMeterTests {
    // MARK: Who may turn it on

    /// Only development and TestFlight installs offer the switch; an App Store install, or one
    /// StoreKit couldn't place, never does.
    @Test(arguments: PracticeMeter.InstallEnvironment.allCases)
    func onlyDevelopmentAndTestFlightOfferTheSwitch(environment: PracticeMeter.InstallEnvironment) {
        let offered: Set<PracticeMeter.InstallEnvironment> = [.development, .testFlight]
        #expect(PracticeMeter.isAvailable(in: environment) == offered.contains(environment))
    }

    /// A switch left on by a TestFlight build does nothing once the install comes from the App
    /// Store, and nothing while the environment is still unknown.
    @Test func aStoredSwitchIsIgnoredOutsideDevelopmentAndTestFlight() {
        #expect(!PracticeMeter.isOn(requested: true, in: .appStore))
        #expect(!PracticeMeter.isOn(requested: true, in: .unknown))
        #expect(PracticeMeter.isOn(requested: true, in: .testFlight))
        #expect(PracticeMeter.isOn(requested: true, in: .development))
        #expect(!PracticeMeter.isOn(requested: false, in: .development))
    }

    // MARK: The drawn meter

    /// Centered on the tap, upright, the size of a meter box, and just in front of the wall.
    @Test func theSampleStandsUprightOnTheWallAtTheTap() throws {
        let meter = SIMD3<Float>(1, 1.5, -2)
        // A wall facing +x: someone facing it looks along -x, and their right is -z.
        let outward = SIMD3<Float>(1, 0, 0)
        let along = simd_normalize(simd_cross(-outward, SIMD3(0, 1, 0)))
        #expect(simd_distance(along, SIMD3(0, 0, -1)) < 1e-6)
        let corners = PracticeMeter.plateCorners(meter: meter, along: along, outward: outward)
        try #require(corners.count == 4)
        let (topLeft, topRight, bottomRight, bottomLeft) = (corners[0], corners[1], corners[2], corners[3])
        let center = corners.reduce(SIMD3<Float>.zero, +) / 4
        #expect(simd_distance(center, meter + outward * PracticeMeter.plateStandOff) < 1e-6)
        // Top above bottom by the plate's height; right is +along from left by its width.
        #expect(abs((topLeft.y - bottomLeft.y) - PracticeMeter.plateSize.y) < 1e-6)
        #expect(simd_distance(topRight - topLeft, along * PracticeMeter.plateSize.x) < 1e-6)
        #expect(simd_distance(bottomRight - bottomLeft, along * PracticeMeter.plateSize.x) < 1e-6)
        // Every corner sits the stand-off in front of the wall's plane through the tap.
        for corner in corners {
            #expect(abs(simd_dot(corner - meter, outward) - PracticeMeter.plateStandOff) < 1e-6)
        }
    }

    // MARK: What the reader makes of it

    /// The sample's printed lines as Vision would return them, top to bottom, with the number on
    /// its own label: the ranking offers the sample's number first, the size check passes it on a
    /// replay-sized photo (640 px tall upright), and no real maker is named.
    @Test func theReaderOffersTheSampleNumberFirstAndNamesNoMaker() throws {
        let heights: [Double] = [0.045, 0.025, 0.035, 0.022, 0.070]
        try #require(heights.count == PracticeMeter.printedLines.count)
        var y = 0.15
        let lines = zip(PracticeMeter.printedLines, heights).map { text, height -> MeterTextLine in
            defer { y += height + 0.04 }
            return MeterTextLine(text: text, box: MeterBox(x: 0.25, y: y, width: 0.5, height: height))
        }
        let found = MeterNumberRanking.candidates(lines: lines, barcodePayloads: [])
        let choices = try #require(MeterPhotoChecks.choices(from: found, photoHeight: 640))
        #expect(choices.candidates.first?.core == PracticeMeter.number)
        #expect(!choices.numberTooSmall)
        #expect(MeterBrand.read(lines) == nil)
        #expect(MeterBrand.match(PracticeMeter.brand) == nil)
    }

    // MARK: Drawing it in perspective

    @Test func theHomographySendsTheRectangleCornersToTheQuad() throws {
        let quad: [SIMD2<Double>] = [SIMD2(120, 80), SIMD2(310, 110), SIMD2(290, 420), SIMD2(100, 380)]
        let m = try #require(QuadHomography.mapping(width: 400, height: 600, to: quad))
        let rectangle: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(400, 0), SIMD2(400, 600), SIMD2(0, 600)]
        for (corner, target) in zip(rectangle, quad) {
            let mapped = try #require(QuadHomography.apply(m, to: corner))
            #expect(simd_distance(mapped, target) < 1e-9, "\(corner) went to \(mapped), not \(target)")
        }
        // A perspective map sends the rectangle's center to where the quad's diagonals cross.
        let center = try #require(QuadHomography.apply(m, to: SIMD2(200, 300)))
        let crossing = try #require(Self.intersection(quad[0], quad[2], quad[1], quad[3]))
        #expect(simd_distance(center, crossing) < 1e-9)
    }

    @Test func aParallelogramNeedsNoPerspective() throws {
        let quad: [SIMD2<Double>] = [SIMD2(10, 10), SIMD2(110, 30), SIMD2(130, 230), SIMD2(30, 210)]
        let m = try #require(QuadHomography.mapping(width: 100, height: 200, to: quad))
        #expect(abs(m.columns.2.x) < 1e-12 && abs(m.columns.2.y) < 1e-12 && m.columns.2.z == 1)
        #expect(try simd_distance(#require(QuadHomography.apply(m, to: SIMD2(100, 200))), quad[2]) < 1e-9)
    }

    @Test func aFlattenedQuadHasNoMapping() {
        let line: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2), SIMD2(3, 3)]
        #expect(QuadHomography.mapping(width: 1, height: 1, to: line) == nil)
        #expect(QuadHomography.mapping(width: 0, height: 1, to: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]) == nil)
    }

    // MARK: The stamp

    /// A practice scan says so in its stamp, and every stamp has the field.
    @Test func theStampSaysWhetherTheScanWasPractice() throws {
        let app = ScanStamp.App(version: "0.1.0", build: "1", commit: "abc123def456")
        let practice = try JSONSchemaValidator.Value.parse(ScanStamp(app: app, server: .init(url: nil), practice: true).jsonData())
        #expect(practice["practice"] == .bool(true))
        let real = try JSONSchemaValidator.Value.parse(ScanStamp(app: app, server: .init(url: nil)).jsonData())
        #expect(real["practice"] == .bool(false))
    }

    private static func intersection(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> SIMD2<Double>? {
        let r = b - a
        let s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let t = ((c - a).x * s.y - (c - a).y * s.x) / denominator
        return a + r * t
    }
}
