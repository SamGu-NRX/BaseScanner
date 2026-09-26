import Foundation
import HouseScanKit
import simd
import Testing

/// The contract's promise, end to end on the phone's side: supplying exactly what a request in
/// `missing_evidence` names settles it (server/README.md, "What settles each check", on
/// origin/t3/server at e0ee8d3). For each server-style request this plans the capture, supplies
/// it through the coverage map with synthetic cameras, exports the scene, and checks the scene
/// the way the server reads it: a wall request needs the observed wall spans to cover its span;
/// a ground, facing or overhead request needs its band seen at least `out_ft` over all of its span.
@Suite struct ServerRequestSettlementTests {
    static let requests = """
    [{"kind":"band","band":"wall","span_ft":[-2.0,3.0],"message":"wall"},
     {"kind":"band","band":"ground","span_ft":[-1.0,2.0],"out_ft":6.0,"message":"ground"},
     {"kind":"band","band":"facing","span_ft":[0.0,2.58],"out_ft":4.9,"message":"facing"},
     {"kind":"band","band":"overhead","span_ft":[0.0,2.58],"out_ft":7.0,"message":"overhead"}]
    """

    typealias Entry = (band: String, low: Double, high: Double, out: Double?)

    /// Port of the server's `Scene.seen_to` (server/scene.py at e0ee8d3): at each s the deepest
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

    /// Port of the server's `Scene.missing` for a 1D band: the parts of [low, high] no entry covers.
    static func uncovered(_ entries: [Entry], _ low: Double, _ high: Double) -> Double {
        let eps = 1e-9
        var cursor = low
        var missing = 0.0
        var merged: [(Double, Double)] = []
        for (a, b) in entries.map({ ($0.low, $0.high) }).sorted(by: { $0 < $1 }) {
            if let last = merged.last, a <= last.1 + eps { merged[merged.count - 1].1 = max(last.1, b) } else { merged.append((a, b)) }
        }
        for (a, b) in merged {
            if b <= cursor + eps { continue }
            if a >= high - eps { break }
            if a > cursor + eps { missing += min(a, high) - cursor }
            cursor = max(cursor, b)
        }
        if cursor < high - eps { missing += high - cursor }
        return missing
    }

    static func settles(_ item: PlacementMissingEvidence, _ scene: Data) throws -> Bool {
        let value = try JSONSchemaValidator.Value.parse(scene)
        let span = try #require(item.spanFt)
        let band = try #require(item.band).rawValue
        let entries: [Entry] = (value["coverage"]?["observed"]?.array ?? []).compactMap { entry in
            guard entry["band"]?.string == band, let s = entry["span_ft"]?.numbers, s.count == 2 else { return nil }
            return (band, min(s[0], s[1]), max(s[0], s[1]), entry["out_ft"]?.number)
        }
        if let out = item.outFt { return seenTo(entries, span.x, span.y) >= out }
        return uncovered(entries, span.x, span.y) == 0
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
        let walked = try Self.export(map)
        #expect(try scene.validate(walked) == [])
        #expect(planner.isSatisfied(plans[0], map))
        #expect(planner.isSatisfied(plans[2], map))
        #expect(try Self.settles(items[0], walked))
        #expect(try Self.settles(items[2], walked))
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

    /// The ports behave like the server's functions on hand-made entries.
    @Test func seenToAndUncoveredMatchTheServer() {
        let entries: [Entry] = [("ground", 0, 1, 5), ("ground", 1, 2, 7), ("ground", 0.5, 1.5, nil)]
        #expect(Self.seenTo(entries, 0, 2) == 5)
        #expect(Self.seenTo(entries, 0.5, 1.5) == .infinity)
        #expect(Self.seenTo(entries, 0, 3) == 0)
        #expect(Self.uncovered(entries, -1, 2) == 1)
        #expect(Self.uncovered([("wall", 0, 1, nil), ("wall", 1.0001, 2, nil)], 0, 2) > 0)
    }
}
