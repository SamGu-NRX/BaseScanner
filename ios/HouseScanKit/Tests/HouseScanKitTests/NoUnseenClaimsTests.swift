import Foundation
@testable import HouseScanKit
import simd
import Testing

// Paths by which the export could claim coverage, a ground patch or a wall no camera saw
// (the Astra review of 35ac3f2), one suite each.

/// The server fills the sector outside a corner that one ground entry crosses; no sample lies
/// there, so no ground entry may cross a corner.
@Suite struct GroundEntriesStopAtCornersTests {
    typealias Value = JSONSchemaValidator.Value

    @Test func noGroundEntryCrossesACorner() throws {
        // Ground seen over -4 ... 6 m with corners at -2 m (inside) and 3 m (outside).
        let data = try SceneExport.jsonData(ChainExportTests.input())
        #expect(try SceneSchemas.scene().validate(data) == [])
        let observed = try #require(try Value.parse(data)["coverage"]?["observed"]?.array)
        let ground = observed.filter { $0["band"]?.string == "ground" }.compactMap { $0["span_ft"]?.numbers }
        let corners = [-2.0, 3.0].map { $0 * SceneUnits.feetPerMeter }
        #expect(ground.count == 3)
        for span in ground {
            #expect(!corners.contains { span[0] + 1e-3 < $0 && $0 < span[1] - 1e-3 }, "\(span) crosses a corner")
        }
        // The pieces meet within the server's 0.01 ft tolerance, so the stretch reads as seen.
        let sorted = ground.sorted { $0[0] < $1[0] }
        for (a, b) in zip(sorted, sorted.dropFirst()) { #expect(b[0] - a[1] < 0.01 && b[0] >= a[1]) }
    }

    /// Facing and overhead entries are read as stretches of s only, so they are not split.
    @Test func facingIsNotSplit() throws {
        var input = ChainExportTests.input()
        input.coverage.facing = [ObservedSpan(span: 1...4, out: 1.5)]
        let observed = try #require(try Value.parse(try SceneExport.jsonData(input))["coverage"]?["observed"]?.array)
        #expect(observed.filter { $0["band"]?.string == "facing" }.count == 1)
    }
}

/// Once a depth frame found a row hidden behind something nearer, a view without depth can't
/// see past it either, so it adds nothing to that row.
@Suite struct HiddenRowsStayHiddenTests {
    /// The bin of `CoverageDepthTests.groundBehindABinIsHiddenUntilSeenFromAClearAngle`: the front
    /// views with depth find the ground behind it hidden, the ground depth stopping at row 1.
    static func binMap() -> CoverageMap {
        let scene = standardScene(boxes: [(SIMD3(-0.3, 0, 1.5), SIMD3(0.3, 0.75, 1.9))])
        var map = CoverageMap(wall: standardWall())
        for x: Float in [0, 0.3] { CoverageDepthTests.observe(&map, CoverageMapTests.frontCamera(x: x), scene: scene) }
        return map
    }

    @Test func viewsWithoutDepthDontCoverAHiddenRow() {
        var map = Self.binMap()
        #expect(map.level(.ground, 0) == .hidden)
        let reach = map.groundDepth(at: 0)
        // Two more positions, without depth, looking through the bin.
        for x: Float in [-0.15, 0.15] { map.observe(CoverageMapTests.frontCamera(x: x), trackingNormal: true) }
        #expect(map.level(.ground, 0) == .hidden)
        #expect(map.groundDepth(at: 0) == reach)
    }

    /// The rebuild after a wall change replays the same order, so the same holds.
    @Test func theRebuildKeepsThem() {
        var map = Self.binMap()
        for x: Float in [-0.15, 0.15] { map.observe(CoverageMapTests.frontCamera(x: x), trackingNormal: true) }
        var moved = map.wall
        moved.meter.x += 0.05
        map.updateWall(moved)
        #expect((map.groundDepth(at: 0) ?? 0) < 0.3)
    }

    /// Without any depth frame first, nothing is hidden and projection alone covers it (the
    /// accepted limit without LiDAR, `CoverageMap`'s type comment).
    @Test func withoutAnyDepthProjectionCovers() {
        var map = CoverageMap(wall: standardWall())
        for x: Float in [0, 0.3] { map.observe(CoverageMapTests.frontCamera(x: x), trackingNormal: true) }
        #expect(map.level(.ground, 0) == .covered)
    }
}

/// The close-up view counts only for the photo on disk, once it passed the reader's image checks.
@Suite struct CloseUpCreditTests {
    static func view(_ s: Float) -> CloseUpView { CloseUpView(camera: wallCamera(s: s), depth: nil) }

    @Test func aBlurryPhotoIsNotCredited() {
        var credit = CloseUpCredit()
        credit.shotStarted()
        credit.photoChecked(Self.view(0), passed: false)
        #expect(credit.take() == nil)
    }

    @Test func aPassedPhotoIsCreditedOnce() {
        var credit = CloseUpCredit()
        credit.shotStarted()
        credit.photoChecked(Self.view(0.2), passed: true)
        #expect(credit.take()?.camera.position == Self.view(0.2).camera.position)
        #expect(credit.take() == nil)
    }

    /// A skip while a retake's photo saves (or is read) credits nothing: the passed photo it
    /// replaces is being overwritten.
    @Test func aRetakeInFlightCreditsNothing() {
        var credit = CloseUpCredit()
        credit.shotStarted()
        credit.photoChecked(Self.view(0), passed: true)
        credit.shotStarted()
        #expect(credit.take() == nil)
    }

    @Test func theRetakesPhotoIsTheOneCredited() {
        var credit = CloseUpCredit()
        credit.shotStarted()
        credit.photoChecked(Self.view(0), passed: true)
        credit.shotStarted()
        credit.photoChecked(Self.view(0.4), passed: true)
        #expect(credit.take()?.camera.position == Self.view(0.4).camera.position)
    }

    /// A shot whose tracking wasn't normal has no view to credit, whatever the reader says.
    @Test func noViewNoCredit() {
        var credit = CloseUpCredit()
        credit.shotStarted()
        credit.photoChecked(nil, passed: true)
        #expect(credit.take() == nil)
    }
}

/// The walked clearance gives up the server's error for the wall piece it is measured from.
@Suite struct WalkedClearanceBySourceTests {
    static func walked(_ wall: WallFrame) -> CoverageMap {
        var map = CoverageMap(wall: wall)
        FacingTests.walk(&map, out: 2.0, from: -2, to: 5)
        return map
    }

    @Test func aDetectedPlaneWallGivesUpItsLargerError() throws {
        var plane = standardWall()
        plane.source = .plane
        let tap = Self.walked(standardWall())
        let fromPlane = Self.walked(plane)
        // Cell 0 is [0, 0.1524]: 2.0 less 0.3 ft or 0.75 ft, plus 0.16 x 0.1524.
        #expect(nearlyEqual(try #require(tap.walkedClearance(at: 0)), 2.0 - 0.09144 - 0.024384))
        #expect(nearlyEqual(try #require(fromPlane.walkedClearance(at: 0)), 2.0 - 0.2286 - 0.024384))
        #expect(nearlyEqual(ServerErrorDefaults.wall(.mesh), 0.1524))
    }

    /// A walk 2 m out along a piece past a corner whose line came from a detected plane: the
    /// clearance there gives up the plane's 0.75 ft, not the tap's 0.3 ft.
    @Test func aCornerPiecesPlaneErrorComesOffItsClearance() throws {
        var wall = standardWall()
        wall.turn(.right, at: WallCorner(s: 1, outward: SIMD3(1, 0, 0), source: .plane))
        var map = CoverageMap(wall: wall)
        for (step, s) in stride(from: Float(1.5), through: 4, by: 0.5).enumerated() {
            let position = wall.world(s: s, height: 1.4, out: 2)
            map.observe(portraitCamera(at: position, lookingAt: wall.world(s: s, height: 1, out: 0)), trackingNormal: true, time: Double(step))
        }
        // Cell 13 is [1.9812, 2.1336]: 2.0 less 0.75 ft and 0.16 x 2.1336.
        #expect(nearlyEqual(try #require(map.walkedClearance(at: 13)), 2.0 - 0.2286 - 0.16 * 2.1336))
    }

    /// Past a corner each piece takes its own source's error.
    @Test func eachPieceTakesItsOwnSource() throws {
        var wall = standardWall()
        wall.turn(.right, at: WallCorner(s: 1, outward: simd_normalize(SIMD3(1, 0, 1)), source: .plane))
        var map = CoverageMap(wall: wall)
        #expect(map.positionError(atS: 0.5) == ServerErrorDefaults.wall(.tap, atS: 0.5))
        #expect(map.positionError(atS: 1.5) == ServerErrorDefaults.wall(.plane, atS: 1.5))
        map.setWallLineSource(.plane)
        #expect(map.positionError(atS: 0.5) == ServerErrorDefaults.wall(.plane, atS: 0.5))
    }
}

/// Walked evidence joins poses only within the stretch they were captured in, in capture order,
/// whenever their photos finish storing.
@Suite struct WalkedPathSegmentTests {
    /// Frame A is captured before a tracking break, B after; A's photo finishes storing after the
    /// break and after B's. They must not join across the break.
    @Test func aLateSaveDoesntJoinAcrossABreak() {
        var map = CoverageMap(wall: standardWall())
        let before = map.pathSegment
        map.breakWalkedPath()
        let after = map.pathSegment
        #expect(before != after)
        map.observe(FacingTests.camera(s: 0.5, out: 2), trackingNormal: true, time: 11, segment: after)
        map.observe(FacingTests.camera(s: 0, out: 2), trackingNormal: true, time: 10, segment: before)
        #expect(map.facingSpans().isEmpty)
    }

    /// Within one segment, poses stored out of order still join in capture order.
    @Test func outOfOrderSavesJoinInCaptureOrder() {
        var map = CoverageMap(wall: standardWall())
        let segment = map.pathSegment
        for (s, t) in [(Float(1.0), 12.0), (0, 10), (0.5, 11)] {
            map.observe(FacingTests.camera(s: s, out: 2), trackingNormal: true, time: t, segment: segment)
        }
        // The steps 0 -> 0.5 -> 1.0 cover cells 0 to 5, [0, 0.9144].
        #expect(map.walkedClearance(at: 0) != nil && map.walkedClearance(at: 5) != nil)
    }
}

/// Every written span ends inward of what was seen, and a patch reaches no farther than the
/// entry as written.
@Suite struct InwardRoundingTests {
    typealias Value = JSONSchemaValidator.Value

    @Test func spansRoundInward() {
        // 0.30481 m is 1.000033 ft and 0.91439 m is 2.999967 ft: nearest would give 1 and 3.
        #expect(SceneExport.spanInward(0.30481...0.91439) == [1.0001, 2.9999])
        // Whole 6 in cell edges stay exact despite Float noise, also far from the meter, where
        // neighbouring entries must still meet.
        #expect(SceneExport.spanInward(0.1524...0.3048) == [0.5, 1.0])
        let far = (Float(36) * 0.1524)...(Float(60) * 0.1524)
        #expect(SceneExport.spanInward(far) == [18, 30])
        #expect(SceneExport.spanInward((-Float(60) * 0.1524)...(-Float(36) * 0.1524)) == [-30, -18])
        #expect(SceneExport.spanInward(0.30481...0.30482) == nil)
    }

    /// 1.8287999 m is 5.99999967 ft: written as 5.9999, and the patch stops there too.
    @Test func thePatchStopsAtTheWrittenReach() throws {
        var input = SceneExportTests.input()
        input.features = []
        input.coverage = SceneCoverage(
            leftEndMarked: false, rightEndMarked: false, wall: [ObservedSpan(span: -3...5, out: 2.286)],
            ground: [ObservedSpan(span: 0.30481...0.91439, out: 1.8287999)])
        input.groundType = .lawn
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let v = try Value.parse(data)
        let entry = try #require(v["coverage"]?["observed"]?.array?.first { $0["band"]?.string == "ground" })
        #expect(entry["out_ft"]?.number == 5.9999)
        #expect(entry["span_ft"]?.numbers == [1.0001, 2.9999])
        let polygon = try #require(GroundPatchExportTests.polygons(data, type: "lawn").first)
        let wall = input.wall
        for point in polygon {
            let c = wall.wallCoordinates(ofPlanPointFeet: SIMD2(point[0], point[1]))
            let s = Double(c.s) * SceneUnits.feetPerMeter, out = Double(c.out) * SceneUnits.feetPerMeter
            #expect(s >= 1.0001 - 1e-5 && s <= 2.9999 + 1e-5, "s \(s)")
            #expect(out <= 5.9999 + 1e-5 && out >= -0.0011, "out \(out)")
        }
    }
}
