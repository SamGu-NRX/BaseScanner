import Foundation
import HouseScanKit
import Testing
import simd

/// The assumed AC or gas square near corners that are not right angles, and near several corners
/// in a row. `CornerFootprintTests` covers one right-angle corner. Here the expected geometry is
/// built from the turn angles alone, without the export's `WallSegment.chain`: each piece of wall
/// is a segment in plan, and the expected span is every piece clipped to the square. For every
/// export this suite checks that the footprint is the full square on the tapped piece, centred on
/// the tap and facing out from that piece, that it is simple, and that `span_ft` is the tap's own
/// stretch joined with every stretch of wall inside the square. A 5 mm walk of the chain checks
/// the span a second way, without the clipping.
///
/// With HOUSESCAN_CORNER_SCENES_OUT set (see `CornerFootprintTests`), the named cases are written
/// into that folder and the sweep into its `sweep` subfolder, so the server's `parse_scene` can
/// read them.
@Suite struct CornerChainFootprintTests {
    typealias Value = JSONSchemaValidator.Value
    typealias Base = CornerFootprintTests

    /// A corner: where it is along the chain, meters, and how far the wall turns there, degrees.
    /// A positive turn brings the wall toward the homeowner (an inside corner), a negative one
    /// takes it away (an outside corner).
    struct Turn: Sendable, CustomStringConvertible {
        let s: Double
        let degrees: Double
        var description: String { "\(degrees > 0 ? "in" : "out")\(Int(abs(degrees)))@\(s)" }
    }

    /// The corners on each side of the meter, nearest the meter first.
    struct Chain: Sendable, CustomStringConvertible {
        var left: [Turn] = []
        var right: [Turn] = []
        var description: String {
            let sides = [("L", left), ("R", right)].filter { !$0.1.isEmpty }
            return sides.map { "\($0.0) " + $0.1.map(\.description).joined(separator: " ") }.joined(separator: " ")
        }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let kind: ScenePointObjectKind
        let chain: Chain
        let tapS: Double
        /// The span worked out by hand, meters. The sweep has none and relies on the clipping.
        var span: ClosedRange<Double>?
        var testDescription: String { name }
    }

    /// One straight piece of the expected chain in plan, meters: the meter at the origin, x along
    /// the meter's wall and y toward the homeowner (world x and z).
    struct Piece {
        let span: ClosedRange<Double>
        /// The plan point at s = `anchorS`, the corner nearer the meter (the meter for its piece).
        let anchor: SIMD2<Double>
        let anchorS: Double
        /// Unit direction of +s.
        let along: SIMD2<Double>
        /// Unit direction from the wall toward the homeowner: `along` turned a quarter turn toward
        /// +y, as the export's cross(-outward, up) gives.
        var outward: SIMD2<Double> { SIMD2(-along.y, along.x) }
        func point(_ s: Double) -> SIMD2<Double> { anchor + along * (s - anchorS) }
    }

    /// Where the open ends of the expected chain stop, meters from the meter. The export's end
    /// pieces never stop; this is far past every square here.
    static let reach = 50.0

    /// The pieces left to right and the index of the meter's. Walking right, an inside turn swings
    /// the direction of travel, +s, toward the piece's outward side. Walking left the direction
    /// of travel is -s, so the same turn swings +s the other way.
    static func pieces(_ chain: Chain) -> (pieces: [Piece], meter: Int) {
        let meterPiece = Piece(
            span: (chain.left.first?.s ?? -reach)...(chain.right.first?.s ?? reach), anchor: .zero, anchorS: 0, along: SIMD2(1, 0))
        func walk(_ turns: [Turn], sign: Double, end: Double) -> [Piece] {
            var heading = 0.0
            var previous = meterPiece
            var result: [Piece] = []
            for (index, turn) in turns.enumerated() {
                heading += sign * turn.degrees
                let far = index + 1 < turns.count ? turns[index + 1].s : end
                let piece = Piece(
                    span: min(turn.s, far)...max(turn.s, far), anchor: previous.point(turn.s), anchorS: turn.s,
                    along: SIMD2(cos(heading * .pi / 180), sin(heading * .pi / 180)))
                result.append(piece)
                previous = piece
            }
            return result
        }
        let left = walk(chain.left, sign: -1, end: -reach)
        return (left.reversed() + [meterPiece] + walk(chain.right, sign: 1, end: reach), left.count)
    }

    static func pieceIndex(_ pieces: [Piece], atS s: Double) -> Int {
        pieces.firstIndex { $0.span.contains(s) } ?? 0
    }

    /// The export's wall for `chain`: each corner's outward is the expected piece's.
    static func wall(_ chain: Chain) -> SceneWall {
        let (pieces, meter) = Self.pieces(chain)
        func corner(_ piece: Piece) -> WallCorner {
            WallCorner(s: Float(piece.anchorS), outward: SIMD3(Float(piece.outward.x), 0, Float(piece.outward.y)))
        }
        return SceneWall(
            meter: SIMD3(0, 1.2, 0), outward: SIMD3(0, 0, 1), groundY: 0,
            leftCorners: pieces[..<meter].reversed().map(corner), rightCorners: pieces[(meter + 1)...].map(corner))
    }

    static func export(_ c: Case) throws -> Data {
        let (pieces, _) = Self.pieces(c.chain)
        // Tapped on the wall face; the export keeps only the tap's s.
        return try export(c, tap: pieces[pieceIndex(pieces, atS: c.tapS)].point(c.tapS))
    }

    /// Exports `c` tapped at plan point `t`, meters.
    static func export(_ c: Case, tap t: SIMD2<Double>) throws -> Data {
        let tap = SIMD3(Float(t.x), c.kind == .ac ? 0 : 0.8, Float(t.y))
        return try SceneExport.jsonData(SceneInput(
            wall: wall(c.chain), wallID: "side", baselineS: -4...4, wallHeight: 2.7,
            features: [.pointObject(kind: c.kind, tap: tap, bottom: nil, top: nil)],
            coverage: SceneCoverage(
                leftEndMarked: false, rightEndMarked: false,
                wall: [ObservedSpan(span: -4...4, out: 2.286)], ground: [ObservedSpan(span: -4...4, out: 2)])))
    }

    /// The stretch of s, meters, where `piece` lies inside or on the convex polygon `p`, whose
    /// vertices run counterclockwise in plan. Nil when it misses. A point within 1 µm of an edge
    /// counts as on it, so a piece lying along a side is found.
    static func clip(_ piece: Piece, to p: [SIMD2<Double>]) -> ClosedRange<Double>? {
        var lower = piece.span.lowerBound
        var upper = piece.span.upperBound
        for i in p.indices {
            let a = p[i]
            let edge = simd_normalize(p[(i + 1) % p.count] - a)
            // Signed distance inside the edge at s is f + g (s - lower).
            let start = piece.point(lower) - a
            let f = edge.x * start.y - edge.y * start.x
            let g = edge.x * piece.along.y - edge.y * piece.along.x
            if abs(g) < 1e-12 {
                if f < -1e-6 { return nil }
                continue
            }
            let bound = lower + (-1e-6 - f) / g
            if g > 0 { lower = max(lower, bound) } else { upper = min(upper, bound) }
            if lower > upper { return nil }
        }
        return lower...upper
    }

    static let feet = SceneUnits.feetPerMeter
    static let tolerance = Base.tolerance

    /// Everything wrong with the exported object for `c`, and its span in feet. The square is
    /// expected on piece `onPiece`, by default the one holding the tap's s.
    static func check(_ c: Case, _ data: Data, onPiece: Int? = nil) throws -> (problems: [String], span: [Double]) {
        var problems: [String] = []
        let object = try #require(try Value.parse(data)["objects"]?[0])
        let points = (object["footprint"]?.array ?? []).compactMap(\.numbers)
        let span = try #require(object["span_ft"]?.numbers)
        guard points.count == 4, points.allSatisfy({ $0.count == 2 }), span.count == 2 else {
            return (["footprint \(points) or span \(span) is not four points and a pair"], span)
        }
        let exported = points.map { SIMD2($0[0], $0[1]) }

        // The full square on the tapped piece, centred on the tap and facing out from the piece:
        // back edge along +s, front edge one depth out.
        let (pieces, meter) = Self.pieces(c.chain)
        let k = onPiece ?? pieceIndex(pieces, atS: c.tapS)
        let piece = pieces[k]
        let (width, depth) = Base.size(c.kind)
        let t = piece.point(c.tapS)
        let back = [t - piece.along * (width / 2), t + piece.along * (width / 2)]
        let square = back + [back[1] + piece.outward * depth, back[0] + piece.outward * depth]
        for (index, (got, want)) in zip(exported, square.map { $0 * feet }).enumerated() where simd_distance(got, want) > tolerance {
            problems.append("vertex \(index) at \(got) ft, expected \(want) ft")
        }
        if !Base.isSimple(exported) { problems.append("footprint \(exported) is not simple") }
        if abs(Base.area(exported) - width * depth * feet * feet) > 1e-3 { problems.append("area \(Base.area(exported)) ft²") }

        let wallID = k == meter ? "side" : "side-\(k < meter ? "left" : "right")-\(abs(k - meter))"
        if object["wall_id"] != .string(wallID) { problems.append("wall_id \(String(describing: object["wall_id"])), expected \(wallID)") }

        // The span: the tap's own stretch joined with every other piece clipped to the square.
        var expected = (c.tapS - width / 2)...(c.tapS + width / 2)
        for (index, other) in pieces.enumerated() where index != k {
            guard let inside = clip(other, to: square) else { continue }
            expected = min(expected.lowerBound, inside.lowerBound)...max(expected.upperBound, inside.upperBound)
        }
        if abs(span[0] - expected.lowerBound * feet) > tolerance || abs(span[1] - expected.upperBound * feet) > tolerance {
            problems.append("span \(span) ft, expected \([expected.lowerBound * feet, expected.upperBound * feet]) ft")
        }

        // Walking every piece every 5 mm, and at each corner: wall inside the exported square lies
        // within the exported span. A piece can meet the square only inside the circle round it,
        // so each piece is walked across that circle, wherever along the chain it lies.
        let centre = (square[0] + square[2]) / 2
        let radius = simd_distance(square[0], square[2]) / 2 + 0.01
        var walk = pieces.dropFirst().map { (s: $0.span.lowerBound, piece: $0) }
        for piece in pieces {
            let foot = piece.anchorS + simd_dot(centre - piece.anchor, piece.along)
            let offLine = simd_distance(piece.point(foot), centre)
            guard offLine < radius else { continue }
            let half = (radius * radius - offLine * offLine).squareRoot()
            let from = max(foot - half, piece.span.lowerBound)
            let to = min(foot + half, piece.span.upperBound)
            guard from <= to else { continue }
            walk += (stride(from: from, to: to, by: 0.005).map { $0 } + [to]).map { (s: $0, piece: piece) }
        }
        for (s, piece) in walk {
            let wallPoint = piece.point(s) * feet
            guard Base.distance(wallPoint, toConvex: exported) < 1e-4 else { continue }
            if !(span[0] - tolerance...span[1] + tolerance).contains(s * feet) {
                problems.append("wall at s = \(s) m is inside the footprint but outside span \(span)")
                break
            }
        }
        return (problems, span)
    }

    /// Writes the scene to HOUSESCAN_CORNER_SCENES_OUT, or its `subfolder`, when it is set.
    static func keep(_ data: Data, as name: String, in subfolder: String? = nil) throws {
        guard let path = ProcessInfo.processInfo.environment["HOUSESCAN_CORNER_SCENES_OUT"], !path.isEmpty else { return }
        var folder = URL(fileURLWithPath: path)
        if let subfolder { folder.appendPathComponent(subfolder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name).json"))
    }

    // MARK: Named cases

    /// Each span is worked by hand from the chain's geometry. Spans past an outside corner stay
    /// the tap's own: the wall turns away behind the square.
    static let named: [Case] = [
        // The next wall leaves the corner at 45° and runs out of the square's right side, 0.1572 m
        // past the corner in x.
        Case(
            name: "ac-1.7-inside-45-right", kind: .ac, chain: Chain(right: [Turn(s: 2, degrees: 45)]), tapS: 1.7,
            span: 1.2428...(2 + 0.1572 * 2.0.squareRoot())),
        // A 135° inside turn runs the next wall back over the square, out of its left side at
        // x = -1.2428 m, 0.7572 m from the corner in x.
        Case(
            name: "ac-1.7-inside-135-left", kind: .ac, chain: Chain(left: [Turn(s: -2, degrees: 135)]), tapS: -1.7,
            span: -(2 + 0.7572 * 2.0.squareRoot()) ... -1.2428),
        Case(
            name: "ac-1.7-outside-60-right", kind: .ac, chain: Chain(right: [Turn(s: 2, degrees: -60)]), tapS: 1.7,
            span: 1.2428...2.1572),
        Case(
            name: "gas-1.9-outside-120-left", kind: .gasMeter, chain: Chain(left: [Turn(s: -2, degrees: -120)]), tapS: -1.9,
            span: -2.05 ... -1.75),
        // Tapped 0.3 m up a wall that turned 60° toward the homeowner. The square's back edge runs
        // 0.1572 m back past the corner, and its left side crosses the meter's wall
        // 0.1572 / cos 60° m short of the corner.
        Case(
            name: "ac-2.3-inside-60-right-far-piece", kind: .ac, chain: Chain(right: [Turn(s: 2, degrees: 60)]), tapS: 2.3,
            span: (2 - 0.1572 / 0.5)...2.7572),
        // The wall steps 0.5 m toward the homeowner and carries on parallel. The square holds the
        // whole step and the first 0.1572 m of the wall past it.
        Case(
            name: "ac-1.7-step-out-right", kind: .ac,
            chain: Chain(right: [Turn(s: 2, degrees: 90), Turn(s: 2.5, degrees: -90)]), tapS: 1.7, span: 1.2428...2.6572),
        // Tapped on the step itself, the square stands on it facing the meter's side and crosses
        // the meter's wall out to its front edge, 0.9144 m from the step. The wall past the step
        // turns away and meets the square only at the corner.
        Case(
            name: "ac-2.25-step-out-middle-piece", kind: .ac,
            chain: Chain(right: [Turn(s: 2, degrees: 90), Turn(s: 2.5, degrees: -90)]), tapS: 2.25, span: 1.0856...2.7072),
        // The wall steps 0.6 m back and carries on. Tapped on the recessed wall, the square holds
        // the whole step and reaches back over the end of the meter's wall.
        Case(
            name: "ac-2.9-step-back-far-piece", kind: .ac,
            chain: Chain(right: [Turn(s: 2, degrees: -90), Turn(s: 2.6, degrees: 90)]), tapS: 2.9, span: 1.8428...3.3572),
        // A bay: a 0.2 m wall at 45°, then a wall parallel to the meter's, 0.1414 m out. The square
        // holds the angled wall and the bay front up to x = 1.7572 m.
        Case(
            name: "ac-1.3-bay-right", kind: .ac,
            chain: Chain(right: [Turn(s: 1.5, degrees: 45), Turn(s: 1.7, degrees: -45)]), tapS: 1.3,
            span: 0.8428...(1.7 + 1.7572 - 1.5 - 0.2 / 2.0.squareRoot())),
        // A 0.6 m wide slot: two inside corners leave the far wall facing the meter's. Tapped on
        // the short wall between them, the square crosses both.
        Case(
            name: "ac-2.3-slot-middle-piece", kind: .ac,
            chain: Chain(right: [Turn(s: 2, degrees: 90), Turn(s: 2.6, degrees: 90)]), tapS: 2.3, span: 1.0856...3.5144),
        // The meter in a recess 0.85 m wide, narrower than the assumed AC square, which crosses
        // both side walls.
        Case(
            name: "ac-0.02-recess-both-sides", kind: .ac,
            chain: Chain(left: [Turn(s: -0.4, degrees: 90)], right: [Turn(s: 0.45, degrees: 90)]), tapS: 0.02,
            span: -1.3144...1.3644),
        // Left mirrors of two right-angle cases in `CornerFootprintTests`: a gas meter just round
        // a corner near the meter, standing across the meter's wall, and one whose side lies
        // exactly along the meter's wall.
        Case(
            name: "gas-0.25-inside-left-far-piece", kind: .gasMeter, chain: Chain(left: [Turn(s: -0.2, degrees: 90)]), tapS: -0.25,
            span: -0.4...0.1),
        Case(
            name: "gas-0.36-inside-left-flush", kind: .gasMeter, chain: Chain(left: [Turn(s: -0.21, degrees: 90)]), tapS: -0.36,
            span: -0.51...0.09),
    ]

    @Test(arguments: named)
    func namedCase(_ c: Case) throws {
        let data = try Self.export(c)
        try Self.keep(data, as: c.name)
        #expect(try SceneSchemas.scene().validate(data) == [])
        let result = try Self.check(c, data)
        #expect(result.problems.isEmpty, "\(result.problems)")
        let span = try #require(c.span)
        #expect(
            abs(result.span[0] - span.lowerBound * Self.feet) < Self.tolerance && abs(result.span[1] - span.upperBound * Self.feet) < Self.tolerance,
            "span \(result.span) ft, worked by hand \(span) m")
    }

    // MARK: A tap at a corner's exact s

    /// A tap whose s is exactly a corner's, on a right corner at 2 m and its mirror on the left.
    /// An AC tapped on the ground diagonally off an outside corner stands in front of neither
    /// wall, so `wallCoordinates` clamps its s to the corner. A tap on the corner itself lands
    /// there too.
    struct CornerTap: Sendable, CustomTestStringConvertible {
        let name: String
        let kind: ScenePointObjectKind
        let degrees: Double
        /// The tap's plan offset from the right-hand corner, meters; the left tap mirrors it.
        let offset: SIMD2<Double>
        var testDescription: String { name }
    }

    static let cornerTaps: [CornerTap] = [
        CornerTap(name: "ac-ground-off-outside-corner", kind: .ac, degrees: -90, offset: SIMD2(0.5, 0.5)),
        CornerTap(name: "gas-at-outside-corner", kind: .gasMeter, degrees: -90, offset: .zero),
        CornerTap(name: "ac-at-inside-corner", kind: .ac, degrees: 90, offset: .zero),
    ]

    /// Both exports are full squares on one of the two pieces meeting at the corner, centred on
    /// it, with a span covering the wall inside them. That much holds on either side.
    ///
    /// The left house is the right one reflected in x = 0, so its export should be the right
    /// export reflected. It is not: the square stands on the piece left of the corner
    /// (`WallSegment.index(in:atS:)`), which is the meter's wall for a right corner and the far
    /// wall for a left one. The review of #184 (beta-qa `caretakers/sept30-review-184.md`,
    /// finding 1) found this; which shape an exact-corner tap should get is Sam's decision, so the
    /// mirror assertions stay strict and are marked as a known issue. When the export changes,
    /// the known issue stops occurring and this test fails, so the marking must be removed.
    @Test(arguments: cornerTaps)
    func tapAtACornersExactS(_ t: CornerTap) throws {
        var exported: [(footprint: [SIMD2<Double>], span: [Double])] = []
        for side in [1.0, -1.0] {
            let turn = Turn(s: 2 * side, degrees: t.degrees)
            let c = Case(
                name: "\(t.name)-\(side > 0 ? "right" : "left")", kind: t.kind,
                chain: side > 0 ? Chain(right: [turn]) : Chain(left: [turn]), tapS: turn.s)
            let data = try Self.export(c, tap: SIMD2(turn.s + t.offset.x * side, t.offset.y))
            try Self.keep(data, as: c.name, in: "corner-exact")
            #expect(try SceneSchemas.scene().validate(data) == [])
            let (pieces, _) = Self.pieces(c.chain)
            let adjacent = pieces.indices.filter { pieces[$0].span.lowerBound == turn.s || pieces[$0].span.upperBound == turn.s }
            let results = try adjacent.map { try Self.check(c, data, onPiece: $0) }
            #expect(results.contains { $0.problems.isEmpty }, "\(c.name): \(results.map(\.problems))")
            let object = try #require(try Value.parse(data)["objects"]?[0])
            let points = (object["footprint"]?.array ?? []).compactMap(\.numbers).map { SIMD2($0[0], $0[1]) }
            exported.append((points, results[0].span))
        }
        let (right, left) = (exported[0], exported[1])
        withKnownIssue("An exact-corner tap's square stands on the piece left of the corner, so mirror images differ") {
            let reflected = right.footprint.map { SIMD2(-$0.x, $0.y) }
            let matched = reflected.allSatisfy { r in left.footprint.contains { simd_distance($0, r) < Self.tolerance } }
            #expect(matched, "right footprint reflected \(reflected) ft, left footprint \(left.footprint) ft")
            #expect(
                abs(left.span[0] + right.span[1]) < Self.tolerance && abs(left.span[1] + right.span[0]) < Self.tolerance,
                "right span \(right.span) ft, left span \(left.span) ft")
        }
    }

    // MARK: Sweep

    /// Chains for the sweep. One corner at 2 m turning 30° to 150° either way; two corners 0.2 or
    /// 0.5 m apart turning 45°, 90° or 135° either way; and a corner each side of a 1.2 m meter
    /// wall. Each is mirrored to the other side. Chains whose pieces cross each other are left
    /// out: the walk cannot follow a wall through another wall.
    static let chains: [Chain] = {
        let single: [Double] = [30, 45, 60, 90, 120, 135, 150].flatMap { [$0, -$0] }
        let turns: [Double] = [45, 90, 135].flatMap { [$0, -$0] }
        var right: [[Turn]] = single.map { [Turn(s: 2, degrees: $0)] }
        for a in turns {
            for b in turns {
                for length in [0.2, 0.5] { right.append([Turn(s: 2, degrees: a), Turn(s: 2 + length, degrees: b)]) }
            }
        }
        let mirrored = { (turns: [Turn]) in turns.map { Turn(s: -$0.s, degrees: $0.degrees) } }
        var chains = right.flatMap { [Chain(right: $0), Chain(left: mirrored($0))] }
        for a in turns {
            for b in turns { chains.append(Chain(left: [Turn(s: -0.6, degrees: a)], right: [Turn(s: 0.6, degrees: b)])) }
        }
        return chains.filter { !crossesItself($0) }
    }()

    /// Taps before, between and past the corners, none on a corner.
    static func taps(_ chain: Chain) -> [Double] {
        if !chain.left.isEmpty, !chain.right.isEmpty { return [-0.9, -0.55, -0.3, 0, 0.3, 0.55, 0.9] }
        let sign: Double = chain.right.isEmpty ? -1 : 1
        let corners = (chain.right.isEmpty ? chain.left : chain.right).map { abs($0.s) }
        var taps = [-1.0, -0.5, -0.2, -0.05].map { corners[0] + $0 } + [0.05, 0.2, 0.5, 1.0].map { corners.last! + $0 }
        if corners.count == 2 { taps += [corners[0] + 0.05, (corners[0] + corners[1]) / 2, corners[1] - 0.05] }
        return taps.map { sign * $0 }
    }

    static let sweep: [Case] = chains.flatMap { chain in
        taps(chain).flatMap { tap in
            [ScenePointObjectKind.ac, .gasMeter].map { kind in
                Case(name: "\(kind.rawValue) \(tap) \(chain)", kind: kind, chain: chain, tapS: tap)
            }
        }
    }

    /// Whether two pieces that are not neighbours meet in plan.
    static func crossesItself(_ chain: Chain) -> Bool {
        let (pieces, _) = Self.pieces(chain)
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let segments = pieces.map { ($0.point($0.span.lowerBound), $0.point($0.span.upperBound)) }
        for i in segments.indices {
            for j in segments.indices where j > i + 1 {
                let (a, b) = segments[i], (c, d) = segments[j]
                let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
                if d1 * d2 <= 0, d3 * d4 <= 0, max(abs(d1), abs(d2), abs(d3), abs(d4)) > 0 { return true }
            }
        }
        return false
    }

    @Test func sweepOfChainsAndTaps() throws {
        #expect(Self.chains.count > 100, "\(Self.chains.count) chains")
        var failed = 0
        for c in Self.sweep {
            let data = try Self.export(c)
            try Self.keep(data, as: c.name.replacingOccurrences(of: " ", with: "_"), in: "sweep")
            let problems = try Self.check(c, data).problems
            guard !problems.isEmpty else { continue }
            failed += 1
            if failed <= 20 { Issue.record("\(c.name): \(problems.joined(separator: "; "))") }
        }
        #expect(failed == 0, "\(failed) of \(Self.sweep.count) cases failed; the first 20 are listed")
    }

    /// Every check here compares against the chain built from the turn angles, so that chain must
    /// be the one the export walks: the same point at each s, and the same outward. Samples are
    /// Float, as the export takes them. At a corner both pieces hold the same wall point but face
    /// different ways, so there only the wall point is compared.
    @Test func expectedChainIsTheExportsChain() {
        for chain in Self.chains {
            let wall = Self.wall(chain)
            let (pieces, _) = Self.pieces(chain)
            let corners = pieces.dropFirst().map(\.span.lowerBound)
            for step in -80...80 {
                let s = Double(Float(step) * 0.05)
                let piece = pieces[Self.pieceIndex(pieces, atS: s)]
                let atCorner = corners.contains { abs($0 - s) < 1e-3 }
                for out in atCorner ? [0.0] : [0.0, 1.0] {
                    let want = piece.point(s) + piece.outward * out
                    let got = wall.world(s: Float(s), height: 0, out: Float(out))
                    #expect(simd_distance(SIMD2(Double(got.x), Double(got.z)), want) < 1e-5, "\(chain) at s = \(s), out = \(out)")
                }
            }
        }
    }

    /// The turn signs mean what `Turn` says. Past an inside corner the wall comes toward the
    /// homeowner (+z), past an outside corner it goes away, on either side of the meter. The
    /// chain-equivalence test cannot see this, because the export's corners come from the same
    /// model.
    @Test func insideTurnsComeTowardTheHomeowner() {
        for chain in Self.chains where chain.left.count + chain.right.count == 1 {
            let turn = (chain.left + chain.right)[0]
            let past = Self.wall(chain).world(s: Float(turn.s + (turn.s > 0 ? 0.5 : -0.5)), height: 0, out: 0)
            #expect(turn.degrees > 0 ? past.z > 0.1 : past.z < -0.1, "\(chain): 0.5 m past the corner z = \(past.z)")
        }
    }

    /// The clipping itself, on a unit square and lines worked by hand.
    @Test func clipFindsTheStretchInsideASquare() throws {
        let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let diagonal = Piece(span: -5...5, anchor: SIMD2(0, 0), anchorS: 0, along: simd_normalize(SIMD2(1, 1)))
        let inside = try #require(Self.clip(diagonal, to: square))
        #expect(abs(inside.lowerBound) < 1e-5 && abs(inside.upperBound - 2.0.squareRoot()) < 1e-5)
        let alongSide = Piece(span: -5...0.5, anchor: SIMD2(0, 1), anchorS: 0, along: SIMD2(1, 0))
        let side = try #require(Self.clip(alongSide, to: square))
        #expect(abs(side.lowerBound) < 1e-5 && abs(side.upperBound - 0.5) < 1e-12)
        #expect(Self.clip(Piece(span: -5...5, anchor: SIMD2(0, 1.5), anchorS: 0, along: SIMD2(1, 0)), to: square) == nil)
    }
}
