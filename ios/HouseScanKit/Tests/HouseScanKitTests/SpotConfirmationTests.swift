import Foundation
import HouseScanKit
import simd
import Testing

// The spot check on the standard wall (face z = 0, s = x, out = z, ground y = 0). The area is a
// spot 0.9 to 1.7 m right of the meter, 0.3 m deep, inside a clearance zone running to 2.6 m.
@Suite struct SpotConfirmationTests {
    static let spot: ClosedRange<Float> = 0.9...1.7
    static let spotOut: ClosedRange<Float> = 0...0.3
    static let area = SpotArea(spot: spot, spotOut: spotOut, zones: [(0.9...2.6, 0.3), (-0.3...1.5, 0.3), (3...4, 0.3)])

    /// A portrait camera `out` m from the wall at chest height, looking at the middle of the area.
    static func camera(s: Float, out: Float, height: Float = 1.4) -> CameraFrame {
        portraitCamera(at: SIMD3(s, height, out), lookingAt: SIMD3(1.75, 0, 0.15))
    }

    // MARK: Area

    /// Only a zone that holds the whole footprint widens the area: the one overlapping it from
    /// the left is another run of the sweep, and the one past it doesn't touch it.
    @Test func areaIsTheSpotAndTheZonesHoldingIt() {
        #expect(Self.area.span == 0.9...2.6)
        #expect(Self.area.depth == 0.3)
        let alone = SpotArea(spot: Self.spot, spotOut: 0.05...0.45, zones: [])
        #expect(alone.span == Self.spot)
        #expect(alone.depth == 0.45)
    }

    // MARK: Photo choice

    /// Straight on from 2.6 m the whole area is in view. The same view with limited tracking, one
    /// from 70 degrees to the side, one from behind the wall, and one that shows only the stretch
    /// left of the spot don't qualify, however much they show.
    @Test func choosesTheFrontViewWithNormalTrackingThatShowsTheArea() throws {
        let front = Self.camera(s: 1.75, out: 2.6)
        let candidates = [
            SpotPhotoCandidate(id: "limited", camera: front, trackingNormal: false),
            SpotPhotoCandidate(id: "side", camera: Self.camera(s: 1.75 + 2.6 * tan(70 * .pi / 180), out: 2.6), trackingNormal: true),
            SpotPhotoCandidate(id: "behind", camera: portraitCamera(at: SIMD3(1.75, 1.4, -2.6), lookingAt: SIMD3(1.75, 0, 0.15)), trackingNormal: true),
            SpotPhotoCandidate(id: "elsewhere", camera: portraitCamera(at: SIMD3(-3, 1.4, 2.6), lookingAt: SIMD3(-3, 0, 0)), trackingNormal: true),
            SpotPhotoCandidate(id: "front", camera: front, trackingNormal: true),
        ]
        let choice = try #require(SpotPhoto.best(candidates, area: Self.area, wall: standardWall()))
        #expect(choice.id == "front")
        #expect(choice.footprintInView == 1)
        #expect(choice.areaInView == 1)
        #expect(choice.angleFromFront < 0.01)
        #expect(SpotPhoto.best(Array(candidates.dropLast()), area: Self.area, wall: standardWall()) == nil)
    }

    /// From 1.2 m the view is too narrow for the whole area: the view from 2.6 m, which shows
    /// all of it, wins over the nearer one whichever comes first.
    @Test func prefersTheViewShowingMoreOfTheArea() throws {
        let near = SpotPhotoCandidate(id: "near", camera: Self.camera(s: 1.75, out: 1.2), trackingNormal: true)
        let far = SpotPhotoCandidate(id: "far", camera: Self.camera(s: 1.75, out: 2.6), trackingNormal: true)
        let nearOnly = try #require(SpotPhoto.best([near], area: Self.area, wall: standardWall()))
        #expect(nearOnly.areaInView < 1)
        #expect(SpotPhoto.best([near, far], area: Self.area, wall: standardWall())?.id == "far")
        #expect(SpotPhoto.best([far, near], area: Self.area, wall: standardWall())?.id == "far")
    }

    /// Two views showing all of the area: the one nearer straight on wins; an exact tie goes to
    /// the earlier photo.
    @Test func tiesGoToTheStraighterThenTheEarlierView() {
        let straight = SpotPhotoCandidate(id: "straight", camera: Self.camera(s: 1.75, out: 2.6), trackingNormal: true)
        let angled = SpotPhotoCandidate(id: "angled", camera: Self.camera(s: 2.4, out: 2.6), trackingNormal: true)
        #expect(SpotPhoto.best([angled, straight], area: Self.area, wall: standardWall())?.id == "straight")
        let again = SpotPhotoCandidate(id: "again", camera: straight.camera, trackingNormal: true)
        #expect(SpotPhoto.best([straight, again], area: Self.area, wall: standardWall())?.id == "straight")
    }

    // MARK: Binding

    static func confirmation(_ area: SpotArea, _ answer: SpotConfirmationAnswer = .clear) -> SpotConfirmation {
        SpotConfirmation(area: area, answerSHA256: "answer", sceneSHA256: "scene", photoID: "k00012", answer: answer)
    }

    /// An answer about the spot settles the same spot named again, within the server's 0.01 ft,
    /// and a smaller area around it. A spot that moved, or an area that grew, is asked about again.
    @Test func aMovedSpotNeedsANewConfirmation() {
        var checks = SpotConfirmations()
        checks.record(Self.confirmation(Self.area))
        #expect(checks.settling(Self.area) == Self.confirmation(Self.area))

        var same = Self.area
        same.spot = (Self.spot.lowerBound + 0.002)...(Self.spot.upperBound - 0.002)
        #expect(checks.settling(same) != nil)
        var smaller = Self.area
        smaller.span = Self.spot
        #expect(checks.settling(smaller) != nil)

        var moved = Self.area
        moved.spot = 1.2...2.0
        #expect(checks.settling(moved) == nil)
        var outward = Self.area
        outward.spotOut = 0.05...0.35
        #expect(checks.settling(outward) == nil)
        var wider = Self.area
        wider.span = 0.9...3.0
        #expect(checks.settling(wider) == nil)
        var deeper = Self.area
        deeper.depth = 0.6
        #expect(checks.settling(deeper) == nil)
    }

    /// A refusal settles the same spot too: the homeowner already said something stands there,
    /// and the latest answer about an area wins.
    @Test func theLatestAnswerAboutAnAreaSettlesIt() {
        var checks = SpotConfirmations()
        checks.record(Self.confirmation(Self.area, .somethingThere))
        #expect(checks.settling(Self.area)?.answer == .somethingThere)
        checks.record(Self.confirmation(Self.area, .clear))
        #expect(checks.settling(Self.area)?.answer == .clear)
        #expect(checks.records.count == 2)
    }

    // MARK: Something's there

    /// A walk 2.6 m out from 1 m left of the meter to 3.5 m right, a kept frame every 0.5 m and
    /// every second.
    static func walkedMap() -> CoverageMap {
        var map = CoverageMap(wall: standardWall())
        FacingTests.walk(&map, out: 2.6, from: -1, to: 3.5)
        return map
    }

    /// Spans of one band of the exported scene, in feet.
    static func observed(_ map: CoverageMap, band: String) throws -> [[Double]] {
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        let data = try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -2...5, coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false)))
        #expect(try SceneSchemas.scene().validate(data) == [])
        let entries = try #require(JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array)
        return entries.filter { $0["band"]?.string == band }.compactMap { $0["span_ft"]?.numbers }
    }

    static func feet(_ meters: Float) -> Double { Double(meters) * SceneUnits.feetPerMeter }

    /// "Something's there" takes back the wall, ground and walked-path claims over exactly the
    /// cells the area overlaps: they read skipped, report nothing, and the exported scene lists
    /// no wall, ground or facing entry over them, while the cells either side keep theirs.
    @Test func somethingThereMarksExactlyTheAreaUnobservedAndTheExportShowsItUnseen() throws {
        var map = Self.walkedMap()
        let before = map
        let inside = map.indices(overlapping: Self.area.span)
        let neighbours = [inside.lowerBound - 1, inside.upperBound + 1]
        for index in inside {
            #expect(map.level(.wall, index) == .covered && map.level(.ground, index) == .covered, "cell \(index) before")
            #expect(map.walkedClearance(at: index) != nil, "cell \(index) walked")
        }
        #expect(!map.hasWithdrawnClaims(overlapping: Self.area.span))

        map.withdrawClaims(over: Self.area.span)

        #expect(map.withdrawnCells == Set(inside))
        #expect(map.hasWithdrawnClaims(overlapping: Self.area.span))
        // Cell 5 (0.762 to 0.914 m) holds the area's left edge; cell 4 ends at 0.762.
        #expect(!map.hasWithdrawnClaims(overlapping: -1...0.75))
        for index in inside {
            #expect(map.level(.wall, index) == .skipped && map.level(.ground, index) == .skipped, "cell \(index)")
            #expect(map.wallSeenHeight(at: index) == nil && map.groundDepth(at: index) == nil && map.walkedClearance(at: index) == nil)
        }
        for index in neighbours {
            #expect(map.level(.wall, index) == before.level(.wall, index) && map.level(.ground, index) == before.level(.ground, index))
            #expect(map.wallSeenHeight(at: index) == before.wallSeenHeight(at: index))
            #expect(map.groundDepth(at: index) == before.groundDepth(at: index))
            #expect(map.walkedClearance(at: index) == before.walkedClearance(at: index))
        }
        let stretch = map.cellRange(inside.lowerBound).lowerBound...map.cellRange(inside.upperBound).upperBound
        for band in SurfaceBand.allCases {
            #expect(map.coveredIntervals(band).allSatisfy { $0.upperBound <= stretch.lowerBound + 1e-4 || $0.lowerBound >= stretch.upperBound - 1e-4 })
        }

        // The withdrawn stretch in feet: whole cells, so it reaches past the area on either side.
        let low = Self.feet(stretch.lowerBound)
        let high = Self.feet(stretch.upperBound)
        for band in ["wall", "ground", "facing"] {
            let spans = try Self.observed(map, band: band)
            #expect(!spans.isEmpty, "\(band): nothing left")
            for span in spans {
                #expect(span[1] <= low + 1e-3 || span[0] >= high - 1e-3, "\(band) \(span) reaches into \(low)...\(high)")
            }
            // Both sides are still reported, up to the withdrawn stretch.
            #expect(spans.contains { abs($0[1] - low) < 1e-3 }, "\(band): nothing ends at \(low)")
            #expect(spans.contains { abs($0[0] - high) < 1e-3 }, "\(band): nothing starts at \(high)")
            // Before, the same band reported the stretch.
            #expect(try Self.observed(before, band: band).contains { $0[0] < high - 1e-3 && $0[1] > low + 1e-3 }, "\(band) was not reported there before")
        }
    }

    /// The withdrawal lasts: a later view over the area adds nothing, a rebuild keeps it, and a
    /// meter moved one cell along the wall moves it with the cells.
    @Test func withdrawnClaimsLastThroughNewViewsAndRebuilds() {
        var map = Self.walkedMap()
        map.withdrawClaims(over: Self.area.span)
        let inside = map.indices(overlapping: Self.area.span)
        map.observe(FacingTests.camera(s: 1.75, out: 2.0), trackingNormal: true, time: 30)
        map.observe(FacingTests.camera(s: 2.1, out: 2.0), trackingNormal: true, time: 31)
        #expect(inside.allSatisfy { map.level(.wall, $0) == .skipped && map.wallSeenHeight(at: $0) == nil })

        map.heightError = 0.3
        #expect(map.withdrawnCells == Set(inside))

        let width = map.config.cellWidth
        map.updateWall(WallFrame(meter: SIMD3(width, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)!)
        #expect(map.withdrawnCells == Set(inside.map { $0 - 1 }))
        let moved = map.cellRange(inside.lowerBound - 1).lowerBound...map.cellRange(inside.upperBound - 1).upperBound
        #expect(map.wallSeenSpans().allSatisfy { $0.span.upperBound <= moved.lowerBound + 1e-4 || $0.span.lowerBound >= moved.upperBound - 1e-4 })
    }
}
