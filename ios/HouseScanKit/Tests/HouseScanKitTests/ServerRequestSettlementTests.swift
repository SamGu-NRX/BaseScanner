import Foundation
import HouseScanKit
import simd
import Testing

/// The contract's promise, end to end on the phone's side: supplying exactly what a request in
/// `missing_evidence` names settles it (server/README.md, "What settles each check", on
/// t3/server at 930e8e5). For each server-style request this plans the capture, supplies it
/// through the coverage map with synthetic cameras, exports the scene, and checks the scene the
/// way the server reads it: a request with `out_ft` (wall, ground, facing, overhead) needs its
/// band seen at least that far over all of its span; one without needs the band's spans to cover
/// its span.
@Suite struct ServerRequestSettlementTests {
    static let requests = """
    [{"kind":"band","band":"wall","span_ft":[-2.0,3.0],"message":"wall"},
     {"kind":"band","band":"ground","span_ft":[-1.0,2.0],"out_ft":6.0,"message":"ground"},
     {"kind":"band","band":"facing","span_ft":[0.0,2.58],"out_ft":4.9,"message":"facing"},
     {"kind":"band","band":"overhead","span_ft":[0.0,2.58],"out_ft":7.0,"message":"overhead"},
     {"kind":"band","band":"wall","span_ft":[-2.0,3.0],"out_ft":6.500001,"message":"wall above"},
     {"kind":"band","band":"wall","span_ft":[-1.0,2.0],"out_ft":1.000001,"message":"wall route"}]
    """

    typealias Entry = (band: String, low: Double, high: Double, out: Double?)

    /// Port of the server's `Scene.seen_to` (server/scene.py at 930e8e5): at each s the deepest
    /// entry covering it, over the stretch the shallowest of those; an entry without out_ft saw
    /// all the way; a stretch nothing covers gives 0.
    static func seenTo(_ entries: [Entry], _ low: Double, _ high: Double) -> Double {
        let eps = 1e-9
        let cuts = Set([low, high] + entries.flatMap { [$0.low, $0.high] }.filter { $0 > low && $0 < high }).sorted()
        var least = Double.infinity
        for (p, q) in zip(cuts, cuts.dropFirst()) where q - p > eps {
            let here = entries.filter { $0.low <= p + eps && q - eps <= $0.high }.map { $0.out ?? .infinity }.max() ?? 0
            least = min(least, here)
        }
        return least
    }

    /// Port of the server's `Scene.missing(band, s_lo, s_hi, up_to)` with `observed_intervals`,
    /// `merge_intervals` and `subtract_intervals` (server/scene.py at 930e8e5): the total length of
    /// the parts of [low, high] no entry covers. With `upTo`, only entries without out_ft or with
    /// out_ft strictly above it count, as each check that reads the wall band calls it with the
    /// height it needs. Gaps narrower than COVERAGE_TOLERANCE_FT (0.01 ft) are rounding, not unseen.
    static func missing(_ entries: [Entry], _ low: Double, _ high: Double, upTo: Double? = nil) -> Double {
        let eps = 1e-9
        let tolerance = 0.01
        var merged: [(Double, Double)] = []
        let counted = entries.filter { entry in
            guard let upTo, let out = entry.out else { return true }
            return out > upTo
        }
        for (a, b) in counted.map({ ($0.low, $0.high) }).sorted(by: { $0 < $1 }) {
            if let last = merged.last, a <= last.1 + eps { merged[merged.count - 1].1 = max(last.1, b) } else { merged.append((a, b)) }
        }
        var gaps: [(Double, Double)] = []
        var cursor = low
        for (a, b) in merged {
            if b <= cursor + eps { continue }
            if a >= high - eps { break }
            if a > cursor + eps { gaps.append((cursor, min(a, high))) }
            cursor = max(cursor, b)
            if cursor >= high - eps { break }
        }
        if cursor < high - eps { gaps.append((cursor, high)) }
        return gaps.filter { $0.1 - $0.0 >= tolerance }.reduce(0) { $0 + $1.1 - $1.0 }
    }

    static func entries(_ scene: Data, band: String) throws -> [Entry] {
        let value = try JSONSchemaValidator.Value.parse(scene)
        return (value["coverage"]?["observed"]?.array ?? []).compactMap { entry in
            guard entry["band"]?.string == band, let s = entry["span_ft"]?.numbers, s.count == 2 else { return nil }
            return (band, min(s[0], s[1]), max(s[0], s[1]), entry["out_ft"]?.number)
        }
    }

    static func settles(_ item: PlacementMissingEvidence, _ scene: Data) throws -> Bool {
        let span = try #require(item.spanFt)
        let entries = try Self.entries(scene, band: try #require(item.band).rawValue)
        if let out = item.outFt { return seenTo(entries, span.x, span.y) >= out }
        return missing(entries, span.x, span.y) == 0
    }

    static func export(_ map: CoverageMap) throws -> Data {
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        return try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -3...3, coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false)))
    }

    @Test func supplyingExactlyWhatEachRequestNamesSettlesIt() throws {
        let items = try JSONDecoder().decode([PlacementMissingEvidence].self, from: Data(Self.requests.utf8))
        let planner = GapPlanner()
        let plans = try items.map { try #require(planner.plan(for: $0, leftEnd: nil, rightEnd: nil)) }
        var map = CoverageMap(wall: standardWall())
        let scene = try SceneSchemas.scene()

        let empty = try Self.export(map)
        #expect(try scene.validate(empty) == [])
        for item in items { #expect(try !Self.settles(item, empty), "\(item.message) settled before anything was captured") }

        // Wall, and facing with it: a level walk 2 m out, a view every 0.3 m from -1.5 to 1.5.
        // Each wall cell within 0.9 m of two of them is covered; the walk leaves 2 m less the
        // position error clear, 5.78 ft at the facing span's far edge (0.914 m out along the wall).
        for step in 0...10 { map.observe(wallCamera(s: -1.5 + 0.3 * Float(step)), trackingNormal: true, time: Double(step)) }
        // The level views see the wall 0 to 2.40 m up, so every wall row to the top, 7.5 ft.
        let walked = try Self.export(map)
        #expect(try scene.validate(walked) == [])
        for index in [0, 2, 4, 5] {
            #expect(planner.isSatisfied(plans[index], map), "\(items[index].message)")
            #expect(try Self.settles(items[index], walked), "\(items[index].message)")
        }
        #expect(try !Self.settles(items[1], walked), "a level walk sees no ground")

        // Ground out to 6 ft (1.83 m): views straight down from 2 m, 1 m out, see 0 to 2.2 m out.
        #expect(!planner.isSatisfied(plans[1], map))
        for step in 0...8 { map.observe(GroundDepthTests.downCamera(s: -1 + 0.3 * Float(step), out: 1.0), trackingNormal: true) }
        let deep = try Self.export(map)
        #expect(try scene.validate(deep) == [])
        #expect(planner.isSatisfied(plans[1], map))
        #expect(try Self.settles(items[1], deep))

        // Overhead to 7 ft: seen tilted up is not enough until the homeowner says nothing is there.
        #expect(!planner.isSatisfied(plans[3], map))
        #expect(try !Self.settles(items[3], deep))
        map.recordOverhead(OverheadTests.tiltUp(pitch: 30), trackingNormal: true)
        let final = try Self.export(map)
        #expect(try scene.validate(final) == [])
        #expect(planner.isSatisfied(plans[3], map))
        for item in items { #expect(try Self.settles(item, final), "\(item.message) not settled") }
    }

    /// A walk pitched 16 degrees down from 2.6 m sees the wall 1.9812 m up, which is 6.5 ft
    /// exactly: enough for the cable's 1 ft, but the checks above the battery need more than
    /// 6.5 ft, and so does the request the server makes for them (6.500001 ft). Reaching it takes
    /// views that show the wall higher, here level views from 2 m out.
    @Test func aWallRequestIsSettledOnlyAboveItsHeight() throws {
        let items = try JSONDecoder().decode([PlacementMissingEvidence].self, from: Data(Self.requests.utf8))
        let above = items[4], route = items[5]
        let planner = GapPlanner()
        let plan = try #require(planner.plan(for: above, leftEnd: nil, rightEnd: nil))
        #expect(plan.need == .wallUp(Float(6.500001) * 0.3048))
        #expect(plan.requestedOutFt == 6.500001)

        var map = CoverageMap(wall: standardWall())
        for step in 0...10 { map.observe(CoverageMapTests.frontCamera(x: -1.5 + 0.3 * Float(step)), trackingNormal: true) }
        let low = try Self.export(map)
        #expect(try SceneSchemas.scene().validate(low) == [])
        let wall = try Self.entries(low, band: "wall")
        #expect(!wall.isEmpty && wall.allSatisfy { $0.out != nil })
        #expect(Self.seenTo(wall, -2, 3) == 6.5)
        #expect(try Self.settles(route, low))
        #expect(try !Self.settles(above, low))
        #expect(!planner.isSatisfied(plan, map))
        // As the server's checks read it: over 1 ft (the cable), not over 6.5 ft.
        #expect(Self.missing(wall, -2, 3, upTo: 1.0) == 0)
        #expect(Self.missing(wall, -2, 3, upTo: 6.5) == 5)

        for step in 0...10 { map.observe(wallCamera(s: -1.5 + 0.3 * Float(step)), trackingNormal: true) }
        let high = try Self.export(map)
        #expect(planner.isSatisfied(plan, map))
        #expect(try Self.settles(above, high))
        #expect(Self.missing(try Self.entries(high, band: "wall"), -2, 3, upTo: 6.5) == 0)
    }

    /// A wall request above the rows the map samples can't be captured: it goes to review.
    @Test func aWallRequestAboveTheCaptureHeightGoesToReview() throws {
        let planner = GapPlanner()
        let json = #"{"kind":"band","band":"wall","span_ft":[0,2],"out_ft":%@,"message":"m"}"#
        func item(_ out: String) throws -> PlacementMissingEvidence {
            try JSONDecoder().decode(PlacementMissingEvidence.self, from: Data(json.replacingOccurrences(of: "%@", with: out).utf8))
        }
        #expect(!planner.isBeyondCapture(try item("7.5")))
        #expect(planner.plan(for: try item("7.5"), leftEnd: nil, rightEnd: nil) != nil)
        #expect(planner.isBeyondCapture(try item("7.500001")))
        #expect(planner.plan(for: try item("7.500001"), leftEnd: nil, rightEnd: nil) == nil)
    }

    /// The ports behave like the server's functions on hand-made entries.
    @Test func portsMatchTheServer() {
        let entries: [Entry] = [("ground", 0, 1, 5), ("ground", 1, 2, 7), ("ground", 0.5, 1.5, nil)]
        #expect(Self.seenTo(entries, 0, 2) == 5)
        #expect(Self.seenTo(entries, 0.5, 1.5) == .infinity)
        #expect(Self.seenTo(entries, 0, 3) == 0)
        #expect(Self.missing(entries, -1, 2) == 1)
        // Gaps under 0.01 ft are rounding; wider ones are unseen.
        #expect(Self.missing([("wall", 0, 1, nil), ("wall", 1.005, 2, nil)], 0, 2) == 0)
        #expect(abs(Self.missing([("wall", 0, 1, nil), ("wall", 1.02, 2, nil)], 0, 2) - 0.02) < 1e-9)
        // up_to counts an entry only strictly above it; one without out_ft always counts.
        let wall: [Entry] = [("wall", 0, 1, 6.5), ("wall", 1, 2, 6.6), ("wall", 2, 3, nil)]
        #expect(Self.missing(wall, 0, 3, upTo: 6.5) == 1)
        #expect(Self.missing(wall, 0, 3, upTo: 6.4) == 0)
        #expect(Self.missing(wall, 0, 3, upTo: 7) == 2)
        #expect(Self.missing(wall, 0, 3) == 0)
    }
}
