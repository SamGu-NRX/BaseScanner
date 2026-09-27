import Foundation
import HouseScanKit
import simd
import Testing

// The spot check on the standard wall (face z = 0, s = x, out = z, ground y = 0). Most tests use
// a spot 0.9 to 1.7 m right of the meter, 0.3 m deep, in an area running to 2.6 m.
@Suite struct SpotConfirmationTests {
    static let spot: ClosedRange<Float> = 0.9...1.7
    static let spotOut: ClosedRange<Float> = 0...0.3
    static let area = SpotArea(spot: spot, spotOut: spotOut, span: 0.9...2.6, depth: 0.3)

    /// A portrait camera `out` m from the wall at chest height, looking at the middle of the area.
    static func camera(s: Float, out: Float, height: Float = 1.4) -> CameraFrame {
        portraitCamera(at: SIMD3(s, height, out), lookingAt: SIMD3(1.75, 0, 0.15))
    }

    static let wholeView = SpotPhotoChoice(id: "k00012", footprintInView: 1, areaInView: 1, angleFromFront: 0)

    static let exchange = SpotExchange(sceneSHA256: "scene", answerSHA256: "answer", rulesSHA256: "rules")

    static func confirmation(
        _ area: SpotArea, _ answer: SpotConfirmationAnswer = .clear(ground: .type(.mulch)), exchange: SpotExchange = exchange,
        photo: SpotPhotoChoice? = wholeView
    ) -> SpotConfirmation {
        SpotConfirmation(area: area, exchange: exchange, photo: photo, answer: answer)
    }

    // MARK: Area from the answer

    /// The hosted server's answer to the synthetic replay's scene, through the result decoder.
    static func serverAnswer(editing edit: (inout [String: Any]) -> Void = { _ in }) throws -> PlacementResult {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Schemas/server-answer-synthetic-wall.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        edit(&json)
        return try PlacementResult.decode(try JSONSerialization.data(withJSONObject: json))
    }

    static func setCheck(_ id: String, outcome: String, in json: inout [String: Any]) {
        var checks = json["checks"] as? [[String: Any]] ?? []
        for index in checks.indices where checks[index]["id"] as? String == id {
            checks[index]["outcome"] = outcome
            checks[index]["unsure_cause"] = nil
        }
        json["checks"] = checks
    }

    /// The answer's facing check passes with r = 3 ft from the battery's front: the outline must
    /// reach D + 3 ft out, 1.833 + 3 = 4.833 ft, where the sweep-run zones the result screen draws
    /// stop at the battery's depth. Its other passing checks (the wall behind, equipment above
    /// with r = 0, headroom, the cable) add nothing past the footprint along the wall.
    @Test func theAreaReachesWhatThePassingFacingCheckNeeds() throws {
        let result = try Self.serverAnswer()
        let area = try #require(SpotArea(result: result, wall: standardWall()))
        let feet = { (meters: Float) in Double(meters) / 0.3048 }
        #expect(abs(feet(area.depth) - (1.833333 + 3)) < 1e-3, "depth \(feet(area.depth)) ft")
        #expect(abs(feet(area.spot.lowerBound) - 0.208333) < 1e-3 && abs(feet(area.spot.upperBound) - 2.791667) < 1e-3)
        #expect(area.span == area.spot)
        #expect(abs(feet(area.height) - 3.29) < 0.05)
    }

    /// The other clearances stay out of the area (the #10 freeze decision): a passing gas
    /// clearance (r = 3 ft) changes nothing. An unsure front check adds nothing either: the area
    /// is then the footprint alone.
    @Test func onlyThePassingFrontClearanceGrowsTheArea() throws {
        let asGiven = try #require(SpotArea(result: try Self.serverAnswer(), wall: standardWall()))
        let gasPassing = try #require(SpotArea(result: try Self.serverAnswer { Self.setCheck("gas_clearance", outcome: "pass", in: &$0) }, wall: standardWall()))
        #expect(gasPassing == asGiven)
        let frontUnsure = try #require(SpotArea(result: try Self.serverAnswer { Self.setCheck("facing_gap", outcome: "unsure", in: &$0) }, wall: standardWall()))
        #expect(frontUnsure.span == frontUnsure.spot)
        #expect(abs(Double(frontUnsure.depth) / 0.3048 - 1.833333) < 1e-3)
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
        #expect(choice.showsWholeArea)
        #expect(choice.angleFromFront < 0.01)
        #expect(SpotPhoto.best(Array(candidates.dropLast()), area: Self.area, wall: standardWall()) == nil)
    }

    /// From 1.2 m the view is too narrow for the whole area: it can be shown, but it doesn't
    /// show the whole area. The view from 2.6 m, which does, wins whichever comes first.
    @Test func prefersTheViewShowingMoreOfTheArea() throws {
        let near = SpotPhotoCandidate(id: "near", camera: Self.camera(s: 1.75, out: 1.2), trackingNormal: true)
        let far = SpotPhotoCandidate(id: "far", camera: Self.camera(s: 1.75, out: 2.6), trackingNormal: true)
        let nearOnly = try #require(SpotPhoto.best([near], area: Self.area, wall: standardWall()))
        #expect(!nearOnly.showsWholeArea)
        #expect(SpotPhoto.best([near, far], area: Self.area, wall: standardWall())?.id == "far")
        #expect(SpotPhoto.best([far, near], area: Self.area, wall: standardWall())?.id == "far")
    }

    /// The wall face counts too: 2.6 m out at chest height shows the ground but not the wall 2 m
    /// up over the whole stretch, so an area reaching that high isn't shown whole.
    @Test func theWallFaceMustBeInViewToo() throws {
        var tall = Self.area
        tall.height = 2.2
        let front = SpotPhotoCandidate(id: "front", camera: Self.camera(s: 1.75, out: 2.6), trackingNormal: true)
        #expect(try #require(SpotPhoto.best([front], area: Self.area, wall: standardWall())).showsWholeArea)
        #expect(try #require(SpotPhoto.best([front], area: tall, wall: standardWall())).areaInView < 1)
    }

    /// "It's clear" counts only with a shown photo of the whole area: no photo, or one showing
    /// part of it, records nothing, and nothing then settles the spot. Answers that withdraw the
    /// area need no photo.
    @Test func noWholeViewMeansNoConfirmationCounts() {
        var checks = SpotConfirmations()
        let partial = SpotPhotoChoice(id: "near", footprintInView: 1, areaInView: 0.8, angleFromFront: 0)
        #expect(throws: SpotConfirmationError.clearWithoutAWholeView) { try checks.record(Self.confirmation(Self.area, photo: nil)) }
        #expect(throws: SpotConfirmationError.clearWithoutAWholeView) { try checks.record(Self.confirmation(Self.area, photo: partial)) }
        #expect(checks.records.isEmpty)
        #expect(checks.settling(Self.area, in: Self.exchange) == nil)
        #expect(throws: Never.self) { try checks.record(Self.confirmation(Self.area, .unconfirmed, photo: partial)) }
        #expect(checks.settling(Self.area, in: Self.exchange)?.answer == .unconfirmed)
    }

    // MARK: Binding

    /// An answer about the spot settles the same spot named again, within the server's 0.01 ft,
    /// and a smaller area around it. A spot that moved, or an area that grew, is asked about again.
    @Test func aMovedSpotNeedsANewConfirmation() throws {
        var checks = SpotConfirmations()
        try checks.record(Self.confirmation(Self.area))
        let settled = { (area: SpotArea) in checks.settling(area, in: Self.exchange) }
        #expect(settled(Self.area) == Self.confirmation(Self.area))

        var same = Self.area
        same.spot = (Self.spot.lowerBound + 0.002)...(Self.spot.upperBound - 0.002)
        #expect(settled(same) != nil)
        var smaller = Self.area
        smaller.span = Self.spot
        #expect(settled(smaller) != nil)

        var moved = Self.area
        moved.spot = 1.2...2.0
        #expect(settled(moved) == nil)
        var outward = Self.area
        outward.spotOut = 0.05...0.35
        #expect(settled(outward) == nil)
        var wider = Self.area
        wider.span = 0.9...3.0
        #expect(settled(wider) == nil)
        var deeper = Self.area
        deeper.depth = 0.6
        #expect(settled(deeper) == nil)
        var taller = Self.area
        taller.height = 1.0
        #expect(settled(taller) == nil)
    }

    /// Same footprint, same area: "It's clear" is asked again after a new scene, a new answer or
    /// new rules, each alone. An answer that withdrew the area stays, whatever changed. The ground
    /// answer is kept for the footprint under the same rules, so the upload that sends it doesn't
    /// ask it again.
    @Test func aClearAnswerIsBoundToTheSceneTheAnswerAndTheRules() throws {
        var checks = SpotConfirmations()
        let a = SpotExchange(sceneSHA256: "scene-a", answerSHA256: "answer-a", rulesSHA256: "rules-a")
        try checks.record(Self.confirmation(Self.area, exchange: a))
        #expect(checks.settling(Self.area, in: a) != nil)
        var scene = a
        scene.sceneSHA256 = "scene-b"
        var answer = a
        answer.answerSHA256 = "answer-b"
        var rules = a
        rules.rulesSHA256 = "rules-b"
        for changed in [scene, answer, rules] { #expect(checks.settling(Self.area, in: changed) == nil) }
        #expect(checks.groundAnswer(for: Self.area, rulesSHA256: "rules-a") == .type(.mulch))
        #expect(checks.groundAnswer(for: Self.area, rulesSHA256: "rules-b") == nil)
        var moved = Self.area
        moved.spot = 2.0...2.8
        #expect(checks.groundAnswer(for: moved, rulesSHA256: "rules-a") == nil)

        var withdrawn = SpotConfirmations()
        try withdrawn.record(Self.confirmation(Self.area, .somethingThere, exchange: a))
        let other = SpotExchange(sceneSHA256: "scene-b", answerSHA256: "answer-b", rulesSHA256: "rules-b")
        #expect(withdrawn.settling(Self.area, in: other)?.answer == .somethingThere)
        #expect(withdrawn.groundAnswer(for: Self.area, rulesSHA256: "rules-a") == nil)
    }

    /// A refusal settles the same spot too, and the latest answer about an area wins.
    @Test func theLatestAnswerAboutAnAreaSettlesIt() throws {
        var checks = SpotConfirmations()
        try checks.record(Self.confirmation(Self.area, .somethingThere))
        #expect(checks.settling(Self.area, in: Self.exchange)?.answer == .somethingThere)
        try checks.record(Self.confirmation(Self.area, .clear(ground: .notSure)))
        #expect(checks.settling(Self.area, in: Self.exchange)?.answer == .clear(ground: .notSure))
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

    // MARK: Ground

    /// The patches an export of `map` carries for `checks`, as (s, out) points in meters.
    static func patchPoints(_ map: CoverageMap, _ checks: SpotConfirmations, groundGuessError: Float = 0, ground: [ObservedSpan]? = nil) throws -> [[SIMD2<Double>]] {
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        var coverage = SceneCoverage(map, leftEndMarked: false, rightEndMarked: false)
        if let ground { coverage.ground = ground }
        let data = try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -2...5, coverage: coverage,
            groundPatches: checks.groundPatches(wall: map.wall, groundGuessError: groundGuessError)))
        #expect(try SceneSchemas.scene().validate(data) == [])
        let patches = try JSONSchemaValidator.Value.parse(data)["ground"]?.array ?? []
        return patches.map { patch in
            (patch["polygon"]?.array ?? []).compactMap(\.numbers).map { p in
                let c = wall.wallCoordinates(ofPlanPointFeet: SIMD2(p[0], p[1]))
                return SIMD2(Double(c.s), Double(c.out))
            }
        }
    }

    /// The margin on the standard wall (tapped): 0.3 ft plus 0.16 per unit along the wall at the
    /// footprint's far edge, 1.7 m, so 0.09144 + 0.272 = 0.36344 m; with a guessed ground 0.3 m more.
    @Test func theMarginIsTheServersWallErrorAtTheFarEdge() {
        #expect(nearlyEqual(SpotGround.margin(spot: Self.spot, wall: standardWall(), groundGuessError: 0), 0.36344))
        #expect(nearlyEqual(SpotGround.margin(spot: Self.spot, wall: standardWall(), groundGuessError: 0.3), 0.66344))
        #expect(nearlyEqual(SpotGround.margin(spot: -1.7 ... -0.9, wall: standardWall(), groundGuessError: 0), 0.36344))
    }

    /// Mulch at the spot is sent over the footprint plus the margin and nowhere else: along the
    /// wall 0.9 - m to 1.7 + m, out to 0.3 + m, where the walk saw the ground farther out than that.
    @Test func theGroundPatchCoversTheFootprintPlusTheMargin() throws {
        let map = Self.walkedMap()
        let m: Double = 0.36344
        let inside = map.indices(overlapping: (0.9 - Float(m))...(1.7 + Float(m)))
        #expect(inside.allSatisfy { (map.groundDepth(at: $0) ?? 0) > 0.3 + Float(m) }, "the walk sees past the patch")
        var checks = SpotConfirmations()
        try checks.record(Self.confirmation(Self.area, .clear(ground: .type(.mulch))))
        let patches = try Self.patchPoints(map, checks)
        #expect(patches.count == 1)
        let points = try #require(patches.first)
        // 0.0005 m is a few of the export's 0.0001 ft rounding steps and its 0.0001 ft inset.
        let s = points.map(\.x), out = points.map(\.y)
        #expect(abs((s.min() ?? .nan) - (0.9 - m)) < 5e-4 && abs((s.max() ?? .nan) - (1.7 + m)) < 5e-4, "s \(s)")
        #expect(abs((out.max() ?? .nan) - (0.3 + m)) < 5e-4 && (out.min() ?? .nan) < 0, "out \(out)")
    }

    /// Where the ground was seen less far than the margin, or not along part of the stretch, the
    /// patch stops at what was seen: here ground seen from 1.0 to 1.5 m, out to 0.4 m.
    @Test func theGroundPatchStaysInsideSeenGround() throws {
        var checks = SpotConfirmations()
        try checks.record(Self.confirmation(Self.area, .clear(ground: .type(.gravel))))
        let points = try #require(try Self.patchPoints(Self.walkedMap(), checks, ground: [ObservedSpan(span: 1.0...1.5, out: 0.4)]).first)
        #expect(points.allSatisfy { $0.x >= 1.0 - 1e-4 && $0.x <= 1.5 + 1e-4 && $0.y <= 0.4 + 1e-4 }, "\(points)")
        #expect(abs((points.map(\.y).max() ?? 0) - 0.4) < 5e-4)
    }

    /// No spot answered yet (the first upload), "Not sure", and a later "Something's there" about
    /// the same footprint all send no patch.
    @Test func noPatchBeforeASpotOrWithNotSure() throws {
        let map = Self.walkedMap()
        #expect(try Self.patchPoints(map, SpotConfirmations()).isEmpty)
        var notSure = SpotConfirmations()
        try notSure.record(Self.confirmation(Self.area, .clear(ground: .notSure)))
        #expect(try Self.patchPoints(map, notSure).isEmpty)
        var withdrawn = SpotConfirmations()
        try withdrawn.record(Self.confirmation(Self.area, .clear(ground: .type(.mulch))))
        try withdrawn.record(Self.confirmation(Self.area, .somethingThere))
        #expect(try Self.patchPoints(map, withdrawn).isEmpty)
    }

    /// A spot that moved asks the ground question again; until then only the old footprint has a
    /// patch. Answering about the new footprint adds its own; the old one, still true, stays.
    @Test func aMovedSpotAsksTheGroundAgain() throws {
        var checks = SpotConfirmations()
        try checks.record(Self.confirmation(Self.area, .clear(ground: .type(.mulch))))
        var moved = Self.area
        moved.spot = 2.0...2.8
        #expect(checks.settling(moved, in: Self.exchange) == nil)
        #expect(checks.groundPatches(wall: standardWall(), groundGuessError: 0).count == 1)
        try checks.record(Self.confirmation(moved, .clear(ground: .type(.lawn))))
        #expect(checks.groundPatches(wall: standardWall(), groundGuessError: 0).map(\.type) == [.mulch, .lawn])
        // Answered again about the first footprint: the latest answer is the one sent.
        try checks.record(Self.confirmation(Self.area, .clear(ground: .type(.gravel))))
        #expect(checks.groundPatches(wall: standardWall(), groundGuessError: 0).map(\.type) == [.lawn, .gravel])
    }

    /// A mark added for unmarked equipment doesn't settle the spot: the homeowner is asked again
    /// once the scan comes back with it. Equipment that couldn't be marked settles it, as
    /// "Something's there" does.
    @Test func equipmentMarkedNowAsksAgain() throws {
        var checks = SpotConfirmations()
        try checks.record(Self.confirmation(Self.area, .unmarked(.gasMeter, markedNow: true)))
        #expect(checks.settling(Self.area, in: Self.exchange) == nil)
        try checks.record(Self.confirmation(Self.area, .unmarked(.door, markedNow: false)))
        #expect(checks.settling(Self.area, in: Self.exchange)?.answer == .unmarked(.door, markedNow: false))
        #expect(checks.groundPatches(wall: standardWall(), groundGuessError: 0).isEmpty)
    }
}
