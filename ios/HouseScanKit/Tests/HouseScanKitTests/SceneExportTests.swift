import Foundation
import HouseScanKit
import Testing
import simd

@Suite struct SceneExportTests {
    typealias Value = JSONSchemaValidator.Value

    /// Wall facing (0.6, 0, 0.8): not axis aligned, so any swapped x/z or sign error shows.
    static let wall = SceneWall(meter: SIMD3(1.0, 1.2, -2.0), outward: SIMD3(0.6, 0, 0.8), groundY: -0.3)

    /// Camera turned 30 degrees about +y, standing at (1, 1.5, 2) m.
    static let pose: simd_float4x4 = {
        var m = simd_float4x4(simd_quatf(angle: .pi / 6, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(1, 1.5, 2, 1)
        return m
    }()

    static func input() -> SceneInput {
        let w = wall
        return SceneInput(
            wall: w, wallID: "side", baselineS: -3...5, wallHeight: 2.7, meterExtraError: 0.1,
            features: [
                .opening(kind: .door, span: 0.5...1.4, bottom: 0, top: 2.0, operable: nil),
                .opening(kind: .window, span: -2.0 ... -1.0, bottom: 0.9, top: 2.1, operable: true),
                .wallObject(kind: .gasMeter, span: -2.65 ... -2.35, bottom: 0.3, top: 1.0),
                .groundObject(kind: .ac, front: [w.world(s: 3.4, height: 0, out: 0.8), w.world(s: 2.6, height: 0, out: 0.9)]),
                .fence(foot: [w.world(s: -1, height: 0, out: 2.0), w.world(s: 2, height: 0, out: 2.4)]),
                .driveway(edge: [w.world(s: 4, height: 0, out: 1), w.world(s: 5, height: 0, out: 1)]),
            ],
            coverage: SceneCoverage(leftEndMarked: true, rightEndMarked: false, wall: [ObservedSpan(span: -3...5, out: 2.286)], ground: [ObservedSpan(span: -3...4, out: 3)]),
            keyframes: [
                SceneKeyframe(id: "k1", cameraToWorld: pose, intrinsics: SIMD4(1450, 1450, 960, 720), w: 1920, h: 1440, img: "k1.jpg"),
                SceneKeyframe(id: "k2", cameraToWorld: matrix_identity_float4x4, intrinsics: SIMD4(1450, 1450, 960, 720), w: 1920, h: 1440, img: "k2.jpg"),
            ],
            stills: ["meter_close": "meter_close.jpg"])
    }

    static func exported() throws -> (data: Data, value: Value) {
        let data = try SceneExport.jsonData(input())
        return (data, try Value.parse(data))
    }

    private func expectClose(_ actual: [Double]?, _ expected: [Double], tolerance: Double = 2e-4,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actual, actual.count == expected.count else {
            Issue.record("expected \(expected), got \(String(describing: actual))", sourceLocation: sourceLocation)
            return
        }
        for (a, e) in zip(actual, expected) where abs(a - e) > tolerance {
            Issue.record("expected \(expected), got \(actual)", sourceLocation: sourceLocation)
            return
        }
    }

    @Test func outwardIsBaselineTurnedClockwiseFromAbove() {
        // Scene schema: outward = baseline direction turned 90 degrees clockwise viewed from +y,
        // which in plan [x, z] is (-along.z, along.x).
        let axis = SceneWall(meter: .zero, outward: SIMD3(0, 0, 1), groundY: 0)
        #expect(axis.along == SIMD3(1, 0, 0))
        for w in [axis, Self.wall] {
            let along = w.along
            #expect(simd_distance(SIMD2(-along.z, along.x), SIMD2(w.outward.x, w.outward.z)) < 1e-6)
        }
    }

    @Test func wallCoordinatesRoundTrip() {
        let w = Self.wall
        let p = w.world(s: 1.25, height: 0.7, out: -0.4)
        let c = w.wallCoordinates(of: p)
        #expect(abs(c.s - 1.25) < 1e-5 && abs(c.height - 0.7) < 1e-5 && abs(c.out + 0.4) < 1e-5)
        // Plan feet back to wall meters: the baseline's right end is s = 5 m on the wall line.
        let plan = w.wallCoordinates(ofPlanPointFeet: SIMD2(16.4042, -16.4042))
        #expect(abs(plan.s - 5) < 1e-4 && abs(plan.out) < 1e-4)
    }

    @Test func exportValidatesAgainstSceneSchema() throws {
        let (data, _) = try Self.exported()
        #expect(try SceneSchemas.scene().validate(data) == [])
    }

    @Test func exportIsDeterministicAndHasNoNulls() throws {
        let first = try SceneExport.jsonData(Self.input())
        #expect(first == (try SceneExport.jsonData(Self.input())))
        let text = String(decoding: first, as: UTF8.self)
        #expect(!text.contains("null"))
        // The only error the input gave is the meter's.
        #expect(text.components(separatedBy: "plus_minus_ft").count == 2)
    }

    /// An estimated ground (the engine's chest-height guess) adds its error to every object's:
    /// the server's default at the object's span (0.3 ft plus 0.16 per foot of its far end from
    /// the meter) plus 0.3 m. The result still matches the schema.
    @Test func objectErrorGoesOnEveryObject() throws {
        var input = Self.input()
        input.objectExtraError = 0.3
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let objects = try #require(try Value.parse(data)["objects"]?.array)
        #expect(objects.count == 4)
        // Door far end 1.4 m, window 2.0, gas meter 2.65, AC 3.4: 0.09144 + 0.16 d + 0.3 m.
        let expected = [0.61544, 0.71144, 0.81544, 0.93544].map { $0 / 0.3048 }
        for (object, error) in zip(objects, expected) {
            expectClose(object["plus_minus_ft"].map { [$0.number ?? .nan] }, [error])
        }
    }

    /// A window 10 ft from the meter with the ground a guess: the server's own error there is
    /// 0.3 + 0.16 x 10 = 1.9 ft, and the guess adds 0.98 ft. Sent as 0.98 ft alone, the explicit
    /// value replaced the server's and understated it by 1.9 ft.
    @Test func aGuessedGroundAddsToTheServersErrorTenFeetOut() throws {
        var input = Self.input()
        input.features = [.opening(kind: .window, span: 2.8...3.048, bottom: 1, top: 2, operable: nil)]
        input.objectExtraError = 0.3
        let window = try #require(try Value.parse(try SceneExport.jsonData(input))["objects"]?.array?.first)
        let error = try #require(window["plus_minus_ft"]?.number)
        expectClose([error], [1.9 + 0.3 / 0.3048])
        #expect(error > 1.9)
        // Without an extra nothing is sent, and the server applies its own 1.9 ft.
        input.objectExtraError = nil
        let plain = try #require(try Value.parse(try SceneExport.jsonData(input))["objects"]?.array?.first)
        #expect(plain["plus_minus_ft"] == nil)
    }

    @Test func meterAndBaselineInFeet() throws {
        let (_, v) = try Self.exported()
        #expect(v["schema_version"] == .string("1.0"))
        expectClose(v["meter"]?["pos"]?.numbers, [3.2808, 3.9370, -6.5617])
        #expect(v["meter"]?["wall_id"] == .string("side"))
        // The server's 0.3 ft and the 0.1 m (0.3281 ft) given on top.
        expectClose(v["meter"]?["plus_minus_ft"].map { [$0.number ?? .nan] }, [0.6281])
        let wall = try #require(v["walls"]?[0])
        // s = -3 m: (1, -2) + (0.8, -0.6) * -3 = (-1.4, -0.2) m. s = 5 m: (5, -5) m.
        expectClose(wall["baseline"]?[0]?.numbers, [-4.5932, -0.6562])
        expectClose(wall["baseline"]?[1]?.numbers, [16.4042, -16.4042])
        expectClose(wall["height_ft"].map { [$0.number ?? .nan] }, [8.8583])
    }

    @Test func objectsInFeet() throws {
        let (_, v) = try Self.exported()
        let objects = try #require(v["objects"]?.array)
        #expect(objects.map { $0["type"]?.string } == ["door", "window", "gas_meter", "ac"])
        let door = objects[0]
        expectClose(door["span_ft"]?.numbers, [1.6404, 4.5932])
        expectClose([door["bottom_ft"]?.number ?? .nan, door["top_ft"]?.number ?? .nan], [0, 6.5617])
        #expect(door["attrs"] == nil)
        #expect(door["source"] == .string("tap"))
        #expect(objects[1]["attrs"] == .object(["operable": .bool(true)]))

        // The gas meter's corners on the wall: its span and heights, and no footprint, since
        // nothing measured how far it stands out.
        let gas = objects[2]
        expectClose(gas["span_ft"]?.numbers, [-8.6942, -7.7100])
        expectClose([gas["bottom_ft"]?.number ?? .nan, gas["top_ft"]?.number ?? .nan], [0.9843, 3.2808])
        #expect(gas["footprint"] == nil)

        // The AC's front corners on the ground, s 2.6 m 0.9 m out and s 3.4 m 0.8 m out: its
        // span, and a footprint from the wall line to that front edge. Heights aren't measured.
        let ac = objects[3]
        expectClose(ac["span_ft"]?.numbers, [8.5302, 11.1549])
        #expect(ac["bottom_ft"] == nil && ac["top_ft"] == nil)
        let footprint = (ac["footprint"]?.array ?? []).compactMap(\.numbers)
        try #require(footprint.count == 4)
        // plan(s, out) = (1, -2) + (0.8, -0.6) s + (0.6, 0.8) out, in meters.
        expectClose(footprint[0], [3.08 / 0.3048, -3.56 / 0.3048])
        expectClose(footprint[1], [3.72 / 0.3048, -4.04 / 0.3048])
        expectClose(footprint[2], [4.2 / 0.3048, -3.4 / 0.3048])
        expectClose(footprint[3], [3.62 / 0.3048, -2.84 / 0.3048])
    }

    @Test func facingGroundCoverageKeyframes() throws {
        let (_, v) = try Self.exported()
        let facing = try #require(v["facing"]?[0])
        expectClose(facing["span_ft"]?.numbers, [-3.2808, 6.5617])
        // Taps 2.0 and 2.4 m out: the facing depth is the nearer, 2.0 m = 6.5617 ft, not the mean.
        expectClose(facing["depth_ft"].map { [$0.number ?? .nan] }, [6.5617])

        let drive = try #require(v["ground"]?[0])
        #expect(drive["type"] == .string("drive"))
        let polygon = (drive["polygon"]?.array ?? []).compactMap(\.numbers)
        try #require(polygon.count == 4)
        // The strip's far side is 0.5 ft further out along the wall's outward (0.6, 0.8).
        expectClose([polygon[3][0] - polygon[0][0], polygon[3][1] - polygon[0][1]], [0.3, 0.4])

        let coverage = try #require(v["coverage"])
        #expect(coverage["ends"]?["left"]?["kind"] == .string("limit"))
        #expect(coverage["ends"]?["right"]?["kind"] == .string("unexplored"))
        let observed = try #require(coverage["observed"]?.array)
        #expect(observed.map { $0["band"]?.string } == ["wall", "ground"])
        // Every wall entry says how high it was seen: 2.286 m is 7.5 ft.
        #expect(observed[0]["out_ft"]?.number == 7.5)
        expectClose(observed[1]["out_ft"].map { [$0.number ?? .nan] }, [9.8425])

        let k1 = try #require(v["keyframes"]?[0])
        let pose = try #require(k1["pose"]?.numbers)
        #expect(pose.count == 16)
        let m = Self.pose
        let rotation = (0..<3).flatMap { c in (0..<4).map { r in Double(m[c][r]) } }
        expectClose(Array(pose[0..<12]), rotation)
        expectClose(Array(pose[12..<16]), [3.2808, 4.9213, 6.5617, 1])
        #expect(k1["w"] == .number(1920) && k1["h"] == .number(1440) && k1["img"] == .string("k1.jpg"))
        #expect(v["stills"] == .object(["meter_close": .string("meter_close.jpg")]))
    }

    @Test func validatorCatchesOutOfSchemaScene() throws {
        let (_, v) = try Self.exported()
        guard case .object(var document) = v else { Issue.record("scene is not an object"); return }
        document["walls"] = .array([])
        let errors = try SceneSchemas.scene().validate(.object(document))
        #expect(errors == ["$.walls: 0 items, fewer than minItems 1"])
    }

    /// A meter tapped on an estimated plane exports a wider error: 0.15 m on top of the server's
    /// 0.3 ft default and of any extra given.
    @Test func estimatedPlaneWidensTheMeterError() throws {
        func meterError(_ plusMinus: Float?, _ plane: MeterPlaneSource) throws -> Double? {
            var input = Self.input()
            input.meterExtraError = plusMinus
            input.meterPlane = plane
            let data = try SceneExport.jsonData(input)
            #expect(try SceneSchemas.scene().validate(data) == [])
            return try Value.parse(data)["meter"]?["plus_minus_ft"]?.number
        }
        #expect(try meterError(nil, .detectedPlane) == nil)
        expectClose([try meterError(0.1, .detectedPlane) ?? .nan], [0.6281])  // 0.3 ft + 0.1 m
        expectClose([try meterError(0.1, .estimatedPlane) ?? .nan], [1.1202])  // 0.3 ft + 0.25 m
        expectClose([try meterError(nil, .estimatedPlane) ?? .nan], [0.7921])  // 0.3 ft + 0.15 m
    }

    /// The schema closes `attrs` to operable and well: an exported window passes, another key fails.
    @Test func attrsAcceptOnlyKnownKeys() throws {
        let (_, v) = try Self.exported()
        guard case .object(var document) = v, case .array(var objects)? = document["objects"],
              case .object(var window) = objects[1] else { Issue.record("no window object"); return }
        #expect(try SceneSchemas.scene().validate(v) == [])
        window["attrs"] = .object(["operable": .bool(true), "locked": .bool(false)])
        objects[1] = .object(window)
        document["objects"] = .array(objects)
        #expect(try !SceneSchemas.scene().validate(.object(document)).isEmpty)
    }

    @Test func invalidInputThrows() {
        var input = Self.input()
        input.features = [.fence(foot: [.zero])]
        #expect(throws: SceneExportError.wrongPointCount(feature: "features[0] fence", expected: 2, actual: 1)) {
            try SceneExport.jsonData(input)
        }

        input = Self.input()
        input.baselineS = 1...5
        #expect(throws: SceneExportError.meterOutsideBaseline(lower: 1, upper: 5)) { try SceneExport.jsonData(input) }

        input = Self.input()
        input.wall.outward = SIMD3(0, 0, 2)
        #expect(throws: SceneExportError.outwardNotUnitHorizontal(SIMD3(0, 0, 2))) { try SceneExport.jsonData(input) }

        input = Self.input()
        input.keyframes[0].intrinsics.x = .nan
        #expect(throws: SceneExportError.self) { try SceneExport.jsonData(input) }
    }

    /// scene.schema.json allows 500 observed entries. Too many spans are joined with their
    /// neighbours, keeping the smaller reach, and spans with a gap between them are never joined.
    @Test func tooManySpansAreJoinedConservativelyToFitTheSchema() throws {
        // 600 touching 1 cm spans alternating 1.0 and 1.2 m, then two separated by a gap.
        var facing = (0..<600).map { i in
            ObservedSpan(span: (Float(i) * 0.01)...(Float(i + 1) * 0.01), out: i.isMultiple(of: 2) ? 1.0 : 1.2)
        }
        facing += [ObservedSpan(span: 7...7.5, out: 2), ObservedSpan(span: 8...8.5, out: 2)]
        var input = Self.input()
        input.coverage = SceneCoverage(leftEndMarked: false, rightEndMarked: false, wall: [ObservedSpan(span: -3...5, out: 2.286)], ground: [], facing: facing)
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let entries = (try Value.parse(data)["coverage"]?["observed"]?.array ?? []).filter { $0["band"]?.string == "facing" }
        #expect(entries.count <= 499)
        // No entry reaches farther than the least of the spans it covers.
        for entry in entries {
            let span = try #require(entry["span_ft"]?.numbers)
            let covered = facing.filter {
                Double($0.span.upperBound) * SceneUnits.feetPerMeter > span[0] + 1e-3
                    && Double($0.span.lowerBound) * SceneUnits.feetPerMeter < span[1] - 1e-3
            }
            let least = try #require(covered.map(\.out).min())
            #expect(try #require(entry["out_ft"]?.number) <= Double(least) * SceneUnits.feetPerMeter + 1e-6)
        }
        // The two separated spans stay two.
        #expect(entries.filter { ($0["span_ft"]?.numbers?.first ?? 0) > 22 }.count == 2)
    }

    /// Every wall entry carries the height seen, rounded down, never absent (absent reads as seen
    /// to headroom height). Many heights are joined like the other bands, each join keeping the
    /// lower, so the band stays within its share of the schema's 500 entries.
    @Test func wallEntriesAlwaysSayHowHighAndFitTheirShare() throws {
        let wall = (0..<600).map { i in
            ObservedSpan(span: (Float(i) * 0.01)...(Float(i + 1) * 0.01), out: i.isMultiple(of: 3) ? 2.0 : 2.1336)
        }
        var input = Self.input()
        input.coverage = SceneCoverage(leftEndMarked: false, rightEndMarked: false, wall: wall, ground: [])
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let entries = (try Value.parse(data)["coverage"]?["observed"]?.array ?? []).filter { $0["band"]?.string == "wall" }
        #expect(entries.count <= 125 && !entries.isEmpty)
        for entry in entries {
            let out = try #require(entry["out_ft"]?.number)
            let span = try #require(entry["span_ft"]?.numbers)
            let covered = wall.filter {
                Double($0.span.upperBound) * SceneUnits.feetPerMeter > span[0] + 1e-3
                    && Double($0.span.lowerBound) * SceneUnits.feetPerMeter < span[1] - 1e-3
            }
            #expect(out <= Double(try #require(covered.map(\.out).min())) * SceneUnits.feetPerMeter + 1e-6)
        }
        // 2.1336 m is 7 ft exactly; Float noise must not round it below.
        input.coverage.wall = [ObservedSpan(span: 0...1, out: 2.1336)]
        let one = try #require(try Value.parse(try SceneExport.jsonData(input))["coverage"]?["observed"]?.array?.first)
        #expect(one["out_ft"]?.number == 7)
    }

    /// Mesh measurements become `facing` and `overheads` entries without `plus_minus_ft` (the
    /// server's mesh default), rounded down to 4 decimals of a foot. The fence feature's entry
    /// stays first. 1.9812 m is 6.5 ft and 2.4994 m 8.2 ft (8.20013 down to 8.2001).
    @Test func meshMeasurementsBecomeFacingAndOverheads() throws {
        var input = Self.input()
        input.meshFacing = [ObservedSpan(span: -0.5...0.5, out: 1.9812)]
        input.meshOverheads = [ObservedSpan(span: 0...1, out: 2.4994)]
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let v = try Value.parse(data)
        let facing = try #require(v["facing"]?.array)
        #expect(facing.count == 2)
        #expect(facing[1]["wall_id"] == .string("side"))
        expectClose(facing[1]["span_ft"]?.numbers, [-1.6404, 1.6404])
        #expect(facing[1]["depth_ft"]?.number == 6.5)
        #expect(facing[1]["plus_minus_ft"] == nil)
        let overheads = try #require(v["overheads"]?.array)
        #expect(overheads.count == 1)
        expectClose(overheads[0]["span_ft"]?.numbers, [0, 3.2808])
        #expect(overheads[0]["clearance_ft"]?.number == 8.2001)
        #expect(overheads[0]["plus_minus_ft"] == nil)
    }

    /// Without mesh measurements there is no `overheads` key, as before.
    @Test func noMeshMeansNoOverheads() throws {
        #expect(try Self.exported().value["overheads"] == nil)
    }

    /// A measured span over a corner is split there, each part naming its own wall.
    @Test func meshSpansSplitAtCorners() throws {
        var input = Self.input()
        input.wall.rightCorners = [WallCorner(s: 0.2, outward: SIMD3(0.8, 0, -0.6))]
        // The AC's corners, placed on the straight wall, fall on one point of the cornered one.
        input.features.removeAll { if case .groundObject = $0 { true } else { false } }
        input.meshOverheads = [ObservedSpan(span: -0.5...0.5, out: 2)]
        let data = try SceneExport.jsonData(input)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let overheads = try #require(try Value.parse(data)["overheads"]?.array)
        #expect(overheads.map { $0["wall_id"]?.string } == ["side", "side-right-1"])
        expectClose(overheads[0]["span_ft"]?.numbers, [-1.6404, 0.6562])
        expectClose(overheads[1]["span_ft"]?.numbers, [0.6562, 1.6404])
    }

    @Test func negativeMeshMeasurementIsRefused() {
        var input = Self.input()
        input.meshFacing = [ObservedSpan(span: 0...1, out: -0.1)]
        #expect(throws: SceneExportError.negativeValue(field: "meshFacing[0].out", value: -0.1)) { try SceneExport.jsonData(input) }
    }
}
