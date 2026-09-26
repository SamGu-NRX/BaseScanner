import Foundation
import HouseScanKit
import simd
import Testing

// On the standard wall s = x and out = z. A walk here is a row of kept frames at height 1.4 m
// looking at the wall; what they see does not matter, only where they were.
@Suite struct FacingTests {
    static func walk(_ map: inout CoverageMap, out: Float, from start: Float, to end: Float, step: Float = 0.5, tracking: Bool = true) {
        var s = start
        while s <= end + 1e-4 {
            map.observe(portraitCamera(at: SIMD3(s, 1.4, out), forward: forwardFacingWall(pitchedDown: 20)), trackingNormal: tracking)
            s += step
        }
    }

    @Test func positionErrorIsTheServerDefault() {
        // 0.3 ft at the meter; 0.3 + 0.16 * 10 = 1.9 ft at 10 ft.
        #expect(nearlyEqual(CoverageMap.positionError(atS: 0), 0.09144))
        #expect(nearlyEqual(CoverageMap.positionError(atS: -3.048), 1.9 * 0.3048))
    }

    @Test func clearanceIsTheWalkedDistanceLessTheErrorAtTheFarEdge() {
        var map = CoverageMap(wall: standardWall())
        Self.walk(&map, out: 2.0, from: -2, to: 2)
        // Cell 0 is [0, 0.1524]: 2.0 - (0.09144 + 0.16 * 0.1524).
        #expect(map.walkedClearance(at: 0).map { nearlyEqual($0, 1.884176) } == true)
        // Cell -1 is [-0.1524, 0], the same distance from the meter.
        #expect(map.walkedClearance(at: -1).map { nearlyEqual($0, 1.884176) } == true)
        // Past the walk's ends nothing was walked past.
        #expect(map.walkedClearance(at: map.cellIndex(forS: 2.1)) == nil)
        #expect(map.walkedClearance(at: map.cellIndex(forS: -2.1)) == nil)
    }

    @Test func aStretchTakesItsNearerEndAndTheFarthestPassCounts() {
        var map = CoverageMap(wall: standardWall())
        // One pass angles in from 2.0 m to 1.4 m out between s = 0 and 0.5 (0.78 m apart).
        map.observe(portraitCamera(at: SIMD3(0, 1.4, 2.0), forward: forwardFacingWall(pitchedDown: 20)), trackingNormal: true)
        map.observe(portraitCamera(at: SIMD3(0.5, 1.4, 1.4), forward: forwardFacingWall(pitchedDown: 20)), trackingNormal: true)
        #expect(map.walkedClearance(at: 1).map { nearlyEqual($0, 1.4 - CoverageMap.positionError(atS: 0.3048)) } == true)
        // A later pass 1.8 m out over the same stretch shows more of it clear.
        map.observe(portraitCamera(at: SIMD3(0, 1.4, 1.8), forward: forwardFacingWall(pitchedDown: 20)), trackingNormal: true)
        map.observe(portraitCamera(at: SIMD3(0.5, 1.4, 1.8), forward: forwardFacingWall(pitchedDown: 20)), trackingNormal: true)
        #expect(map.walkedClearance(at: 1).map { nearlyEqual($0, 1.8 - CoverageMap.positionError(atS: 0.3048)) } == true)
    }

    @Test func jumpsAndLimitedTrackingAreNotWalked() {
        var map = CoverageMap(wall: standardWall())
        // 1.5 m between kept frames is more than `walkStep`: the stretch between is unknown.
        Self.walk(&map, out: 2.0, from: 0, to: 1.5, step: 1.5)
        #expect(map.facingSpans().isEmpty)
        var limited = CoverageMap(wall: standardWall())
        Self.walk(&limited, out: 2.0, from: 0, to: 2, tracking: false)
        #expect(limited.facingSpans().isEmpty)
    }

    /// A walk on the guidance's path settles facing near the meter under the public rules: the
    /// exported clearance exceeds D + r = 4.83 ft over a battery either side of the meter.
    @Test func aWalkAtTheStandOffSettlesFacingNearTheMeter() throws {
        var map = CoverageMap(wall: standardWall())
        Self.walk(&map, out: GuidanceConfig().standOff, from: -3, to: 3)
        let spans = map.facingSpans()
        let battery: Float = 2.58 * 0.3048
        for index in map.indices(overlapping: -battery...battery) {
            let clear = try #require(map.walkedClearance(at: index))
            #expect(clear * Float(SceneUnits.feetPerMeter) > 4.83)
            #expect(spans.contains { $0.span.contains(map.cellRange(index).lowerBound + 0.01) && $0.out * Float(SceneUnits.feetPerMeter) > 4.83 })
        }
        // Merged spans never claim more than any of their cells.
        for item in spans {
            for index in map.indices(overlapping: item.span) {
                #expect(item.out <= (map.walkedClearance(at: index) ?? 0) + 1e-6)
            }
        }
    }

    @Test func exportCarriesFacingEntriesInFeet() throws {
        var map = CoverageMap(wall: standardWall())
        Self.walk(&map, out: 2.0, from: -1, to: 1)
        let wall = SceneWall(meter: map.wall.meter, outward: map.wall.outward, groundY: map.wall.groundY)
        let data = try SceneExport.jsonData(SceneInput(
            wall: wall, baselineS: -2...2, coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false)))
        #expect(try SceneSchemas.scene().validate(data) == [])
        let observed = try #require(JSONSchemaValidator.Value.parse(data)["coverage"]?["observed"]?.array)
        let facing = observed.filter { $0["band"]?.string == "facing" }
        #expect(facing.count == map.facingSpans().count)
        #expect(!facing.isEmpty)
        for (entry, item) in zip(facing, map.facingSpans()) {
            let out = try #require(entry["out_ft"]?.number)
            // Rounded down, bar the export's 1e-7 ft allowance for Float noise.
            #expect(out <= Double(item.out) * SceneUnits.feetPerMeter + 1e-6)
            #expect(out > Double(item.out) * SceneUnits.feetPerMeter - 1e-3)
        }
    }
}
