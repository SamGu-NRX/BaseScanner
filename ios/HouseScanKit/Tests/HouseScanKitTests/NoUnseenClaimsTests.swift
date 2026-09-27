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

/// The server finds each corner's s from the walls as written, which can differ from the phone's
/// by the rounding of the baseline points. No ground entry may cross a corner by the server's
/// arithmetic, ported here from server/scene.py `parse_scene` (t3/server 930e8e5).
@Suite struct GroundEntriesStopAtTheServersCornersTests {
    typealias Value = JSONSchemaValidator.Value

    /// The corners' s as the server computes it: walls end to end from the chain's left end, each
    /// as long as its written baseline, shifted so the meter's projection onto its wall is 0.
    static func serverCorners(_ scene: Value) throws -> [Double] {
        let walls = try #require(scene["walls"]?.array)
        var s = 0.0
        var pieces: [(id: String, a: SIMD2<Double>, along: SIMD2<Double>, s0: Double, s1: Double)] = []
        for wall in walls {
            let points = (wall["baseline"]?.array ?? []).compactMap(\.numbers)
            try #require(points.count == 2)
            let a = SIMD2(points[0][0], points[0][1]), b = SIMD2(points[1][0], points[1][1])
            let length = simd_length(b - a)
            let id = try #require(wall["id"]?.string)
            pieces.append((id, a, (b - a) / length, s, s + length))
            s += length
        }
        let pos = try #require(scene["meter"]?["pos"]?.numbers)
        let meterID = try #require(scene["meter"]?["wall_id"]?.string)
        let m = SIMD2(pos[0], pos[2])
        let placed = pieces.filter { $0.id == meterID }.map { p -> (Double, Double) in
            let local = min(max(p.s0 + simd_dot(m - p.a, p.along), p.s0), p.s1)
            return (simd_length(m - (p.a + p.along * (local - p.s0))), local)
        }
        let shift = try #require(placed.min { $0.0 < $1.0 }).1
        return pieces.dropLast().map { $0.s1 - shift }
    }

    /// Exports ground seen over `span` on a wall through the origin turned `degrees` from +x,
    /// with one corner at `corner` (convex or concave), and returns the ground entries with the
    /// server's corners.
    static func export(degrees: Float, corner: Float, convex: Bool, span: ClosedRange<Float>) throws -> (ground: [[Double]], corners: [Double]) {
        let a = degrees * .pi / 180
        let along = SIMD3<Float>(cos(a), 0, sin(a))
        let outward = SIMD3<Float>(-along.z, 0, along.x)
        // Convex: the next piece faces the old along; concave: the old along reversed.
        let next = corner > 0 ? (convex ? along : -along) : (convex ? -along : along)
        let wall = SceneWall(
            meter: SIMD3(0, 1.2, 0), outward: outward, groundY: 0,
            leftCorners: corner < 0 ? [WallCorner(s: corner, outward: next)] : [],
            rightCorners: corner > 0 ? [WallCorner(s: corner, outward: next)] : [])
        let input = SceneInput(
            wall: wall, baselineS: -3...3,
            coverage: SceneCoverage(leftEndMarked: false, rightEndMarked: false, wall: [], ground: [ObservedSpan(span: span, out: 1)]))
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let value = try Value.parse(data)
        let ground = (value["coverage"]?["observed"]?.array ?? []).filter { $0["band"]?.string == "ground" }.compactMap { $0["span_ft"]?.numbers }
        return (ground, try serverCorners(value))
    }

    /// The reviewer's case: at 45 degrees the corner at 0.9144 m (3 ft) is written as
    /// [2.1213, 2.1213] ft, which the server places 2.999971 ft from the meter.
    @Test func theReviewersCase() throws {
        let (ground, corners) = try Self.export(degrees: 45, corner: 0.9144, convex: true, span: 0...2)
        #expect(abs(corners[0] - 2.999971) < 1e-6)
        for span in ground { #expect(!(span[0] < corners[0] - 1e-9 && span[1] > corners[0] + 1e-9), "\(span) crosses \(corners[0])") }
    }

    /// Rotations, corner positions and both kinds of corner on either side of the meter.
    @Test func noRotationCrossesTheServersCorner() throws {
        for degrees in stride(from: Float(3), to: 90, by: 7) {
            for corner: Float in [0.9144, 1.2345, -0.8765, -1.7] {
                for convex in [true, false] {
                    let span: ClosedRange<Float> = corner > 0 ? 0...2.5 : -2.5...0
                    let (ground, corners) = try Self.export(degrees: degrees, corner: corner, convex: convex, span: span)
                    let c = try #require(corners.first)
                    #expect(ground.count == 2, "\(degrees) \(corner) \(convex): \(ground)")
                    for entry in ground {
                        #expect(!(entry[0] < c - 1e-9 && entry[1] > c + 1e-9), "\(degrees) \(corner) \(convex): \(entry) crosses \(c)")
                    }
                    // The two sides meet across under the server's 0.01 ft tolerance.
                    let sorted = ground.sorted { $0[0] < $1[0] }
                    if sorted.count == 2 { #expect(sorted[1][0] - sorted[0][1] < 0.01) }
                }
            }
        }
    }
}

/// A sighting depth didn't confirm is dropped once depth shows the row hidden; the rebuild after
/// a wall change replays the frames in the order they were captured.
@Suite struct UnverifiedSightingsTests {
    static let scene = CoverageDepthTests.boxScene
    static let target = SIMD3<Float>(0.08, 1.0, 0)

    /// A view without depth credits cell 0's rows, then a depth view finds the box in front of
    /// them. One clear view with depth later must not make two positions with the first.
    @Test func anUnverifiedSightingGoesOnceDepthShowsTheRowHidden() {
        var map = CoverageMap(wall: standardWall())
        map.observe(wallCamera(s: 0), trackingNormal: true)
        CoverageDepthTests.observe(&map, wallCamera(s: 0.3), scene: Self.scene)
        #expect(map.level(.wall, 0) == .hidden)
        CoverageDepthTests.observe(&map, portraitCamera(at: SIMD3(2.2, 1.2, 2.0), lookingAt: Self.target), scene: Self.scene)
        #expect(map.level(.wall, 0) == .hidden)
        #expect(map.wallSeenHeight(at: 0) == nil)
    }

    /// The same five frames, their photos stored in another order: after a rebuild both maps
    /// agree, as the frames were captured. Captured: a clear view with depth, two views without
    /// depth, a depth view showing the box, another clear view with depth.
    @Test func theRebuildReplaysInCaptureOrder() {
        enum Shot { case clear(Float), plain(Float), blocked }
        let shots: [(Shot, Double)] = [(.clear(2.2), 1), (.plain(0), 2), (.plain(0.3), 3), (.blocked, 4), (.clear(2.5), 5)]
        func observe(_ order: [Int]) -> CoverageMap {
            var map = CoverageMap(wall: standardWall())
            for index in order {
                let (shot, time) = shots[index]
                switch shot {
                case .clear(let x):
                    let camera = portraitCamera(at: SIMD3(x, 1.2, 2.0), lookingAt: Self.target)
                    map.observe(camera, trackingNormal: true, time: time, depth: renderDepth(Self.scene, from: camera))
                case .plain(let s):
                    map.observe(wallCamera(s: s), trackingNormal: true, time: time)
                case .blocked:
                    map.observe(wallCamera(s: 0.3), trackingNormal: true, time: time, depth: renderDepth(Self.scene, from: wallCamera(s: 0.3)))
                }
            }
            var moved = map.wall
            moved.meter.y += 0.05
            map.updateWall(moved)
            return map
        }
        let captured = observe([0, 1, 2, 3, 4])
        let stored = observe([1, 2, 0, 3, 4])
        #expect(captured.level(.wall, 0) == .covered)
        #expect(stored.level(.wall, 0) == captured.level(.wall, 0))
        #expect(stored.wallSeenHeight(at: 0) == captured.wallSeenHeight(at: 0))
    }
}

/// While the ground is a guess, a seen height needs the wall from the guess less its error: a
/// ground guessed too high would otherwise leave the real foot of the wall unseen.
@Suite struct GuessedGroundFootTests {
    /// The ground guessed 0.3 m above the real one at y = 0. `highWallCamera` shows the wall only
    /// from y = 0.2968 up, so the foot below that, which the guess hides, is never seen.
    @Test func aGuessTooHighLeavesTheFootToBeSeen() {
        var guessed = standardWall()
        guessed.groundY = 0.3
        var map = CoverageMap(wall: guessed)
        map.heightError = 0.3
        map.observe(CoverageMapTests.highWallCamera(s: 0), trackingNormal: true)
        map.observe(CoverageMapTests.highWallCamera(s: 0.3), trackingNormal: true)
        // The band from the guessed ground up is covered, so the walk moves on; no height is sent.
        #expect(map.level(.wall, 0) == .covered)
        #expect(map.wallSeenHeight(at: 0) == nil)
        // Level views from 1.2 m show the wall from y = -0.003: the foot rows down to the guess
        // less 0.3 m (y = 0) are seen now, and the band above them already was, to its top row.
        // The height is reported less the error.
        map.observe(wallCamera(s: -0.3), trackingNormal: true)
        map.observe(wallCamera(s: 0.6), trackingNormal: true)
        #expect(nearlyEqual(map.wallSeenHeight(at: 0) ?? .nan, 2.286 - 0.3))
    }

    @Test func aMeasuredGroundHasNoFootRows() {
        var map = CoverageMap(wall: standardWall())
        #expect(map.wallRows.first == 0)
        map.heightError = 0.3
        #expect(map.wallRows.prefix(3).map { $0 } == [-0.3, -0.1524, 0])
        map.heightError = 0
        #expect(map.wallRows.first == 0)
    }
}
