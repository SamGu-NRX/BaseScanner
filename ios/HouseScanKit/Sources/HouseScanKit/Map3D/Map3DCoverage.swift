import Foundation
import simd

/// What the 3D map saw along a wall chain, in the form scene.json's `coverage.observed` takes
/// (server/README.md "What settles each check", on t3/server). s and out are meters along and
/// out from the chain the spans were measured against.
public struct Map3DCoverage: Sendable, Equatable {
    /// Stretches where the wall face was seen from the ground to headroom.
    public var wall: [ClosedRange<Float>]
    /// Stretches of wall face, each with how high above the ground it was seen without a break:
    /// scene.json's wall `out_ft`, which each server check credits against its own height.
    public var wallHeight: [ObservedSpan]
    /// Stretches of ground, each with how far out from the wall it was seen without a break.
    public var ground: [ObservedSpan]
    /// Stretches with the space in front of the wall seen clear, each with how far out.
    public var facing: [ObservedSpan]
    /// Stretches with the space over the battery's depth seen clear, each with how high.
    public var overhead: [ObservedSpan]
}

extension SceneCoverage {
    /// The 3D map's coverage, with the ends' kinds from the homeowner's answers.
    public init(_ coverage: Map3DCoverage, leftEndMarked: Bool, rightEndMarked: Bool) {
        self.init(
            leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked, wall: coverage.wallHeight,
            ground: coverage.ground, facing: coverage.facing, overhead: coverage.overhead)
    }
}

/// Coverage is read from the voxels, so a place counts as seen only where a ray reached it:
/// behind a bush stays unseen however many frames pointed at it. Each cell is judged at sample
/// points half a voxel apart, and every sample must pass.
extension Map3D {
    /// Cells along the chain within `alongExtent` of the meter either way.
    public var cellIndices: ClosedRange<Int> {
        Int((-config.alongExtent / config.cellWidth).rounded(.down))...Int((config.alongExtent / config.cellWidth).rounded(.up)) - 1
    }

    /// A cell's s range. Edges come from the index alone, like `CoverageMap.cellRange`, so
    /// neighbouring cells share bit-identical edges.
    public func cellRange(_ index: Int) -> ClosedRange<Float> {
        (Float(index) * config.cellWidth)...(Float(index + 1) * config.cellWidth)
    }

    public func coverage(along wall: WallFrame) -> Map3DCoverage {
        var seenWall: [ClosedRange<Float>] = []
        var wallHeight: [ObservedSpan] = []
        var ground: [ObservedSpan] = []
        var facing: [ObservedSpan] = []
        var overhead: [ObservedSpan] = []
        let facades = facadeOffsets(along: wall)
        for index in cellIndices {
            let range = cellRange(index)
            let height = seenHeight(cell: index, along: wall, facade: facades[index])
            if let height { wallHeight.append(ObservedSpan(span: range, out: height)) }
            let wallSeen = (height ?? 0) >= config.headroom
            if wallSeen {
                if let last = seenWall.last, last.upperBound == range.lowerBound {
                    seenWall[seenWall.count - 1] = last.lowerBound...range.upperBound
                } else {
                    seenWall.append(range)
                }
            }
            let facade = facades[index] ?? 0
            if let out = groundReach(cell: index, along: wall, facade: facade) { ground.append(ObservedSpan(span: range, out: out)) }
            guard wallSeen else { continue }
            if let out = clearReach(cell: index, along: wall, facade: facade) { facing.append(ObservedSpan(span: range, out: out)) }
            if let height = clearHeight(cell: index, along: wall, facade: facades[index]) { overhead.append(ObservedSpan(span: range, out: height)) }
        }
        let touching = config.cellWidth * 0.01
        return Map3DCoverage(
            wall: seenWall, wallHeight: ObservedSpan.merge(wallHeight, touching: touching), ground: ObservedSpan.merge(ground, touching: touching),
            facing: ObservedSpan.merge(facing, touching: touching), overhead: ObservedSpan.merge(overhead, touching: touching))
    }

    // MARK: Per cell

    /// Whether the facade over a cell was seen from `voxelSize` up to headroom (`wallHeight`
    /// reaches it). At every sample
    /// some well-seen surface (`VoxelGrid.isWellSeenSurface`) must lie on the facade face, from
    /// `recessDepth` behind the facade to `faceTolerance` in front of it, or on attached relief
    /// (`attachedRelief`) up to `reliefDepth` in front. The facade is where the wall's surface
    /// was measured near the cell (`facadeOffset`), so a chain line placed a few centimeters
    /// off still finds it. Anything else standing in front of the wall, a box or a shrub, hides
    /// it. The layer at the ground belongs to the ground band.
    public func isWallSeen(cell index: Int, along wall: WallFrame) -> Bool {
        isWallSeen(cell: index, along: wall, facade: facadeOffset(cell: index, along: wall))
    }

    private func isWallSeen(cell index: Int, along wall: WallFrame, facade: Float?) -> Bool {
        (seenHeight(cell: index, along: wall, facade: facade) ?? 0) >= config.headroom
    }

    /// How high above the ground the facade over a cell was seen without a break, meters: the
    /// least over the cell's samples of `seenHeight(_:s:facade:)`. Nil where not even the
    /// lowest row was.
    public func wallHeight(cell index: Int, along wall: WallFrame) -> Float? {
        seenHeight(cell: index, along: wall, facade: facadeOffset(cell: index, along: wall))
    }

    private func seenHeight(cell index: Int, along wall: WallFrame, facade: Float?) -> Float? {
        guard let facade else { return nil }
        let heights = bandHeights()
        var least: Float = .infinity
        for s in samples(in: cellRange(index)) {
            guard let top = seenHeight(wall, s: s, heights: heights, facade: facade) else { return nil }
            least = min(least, top)
        }
        return least.isFinite ? least : nil
    }

    /// The highest row at s up to which every row, from the lowest, shows the facade: its face,
    /// or attached relief (`attachedRelief`). Relief counts only where it runs on to that height;
    /// where the face shows above relief (a box on the wall, a shrub), the height stops below it.
    private func seenHeight(_ wall: WallFrame, s: Float, heights: [Float], facade: Float) -> Float? {
        let rows = heights.map { faceSample(wall, s: s, height: $0, facade: facade) }
        var top = (rows.firstIndex { !$0.face && $0.relief == nil } ?? rows.count) - 1
        if let firstRelief = rows.firstIndex(where: { !$0.face }), firstRelief <= top {
            let relief = Array(rows[firstRelief...top])
            if relief.contains(where: \.face) || !attachedRelief(wall, s: s, rows: relief, facade: facade) { top = firstRelief - 1 }
        }
        return top >= 0 ? rows[top].height : nil
    }

    /// Heights the wall band is judged at: every half voxel from one voxel up to the top of the
    /// map, and headroom itself, which the facing and overhead bands need seen.
    private func bandHeights() -> [Float] {
        (Array(stride(from: config.voxelSize, to: config.top, by: config.voxelSize / 2)) + [config.headroom]).sorted()
    }

    /// Front of the facade face, meters past the facade: a voxel's center lies at most 7.1 cm
    /// from a vertical plane through it (half a voxel's diagonal), so 7.5 cm keeps every voxel
    /// the face runs through and turns away the next layer out. Something standing closer to
    /// the wall than about that is part of the facade.
    private var faceTolerance: Float { config.voxelSize * 0.75 }

    /// Where the facade runs near a cell, meters out from the chain's line: the mode (2 cm bins)
    /// of the offsets of well-seen, outward-facing surface voxels within `faceBehind` of the
    /// line, over the cells within about a meter either side. Nil where none was seen.
    func facadeOffset(cell index: Int, along wall: WallFrame) -> Float? {
        facadeHistogram(cells: (index - 6)...(index + 6), along: wall).mode
    }

    private func facadeOffsets(along wall: WallFrame) -> [Int: Float] {
        var result: [Int: Float] = [:]
        let perCell = Dictionary(uniqueKeysWithValues: cellIndices.map { ($0, facadeHistogram(cells: $0...$0, along: wall)) })
        for index in cellIndices {
            var sum = Histogram()
            for neighbour in (index - 6)...(index + 6) { if let h = perCell[neighbour] { sum.add(h) } }
            result[index] = sum.mode
        }
        return result
    }

    struct Histogram {
        /// Count per 2 cm bin of offset.
        var bins: [Int: Int] = [:]
        static let bin: Float = 0.02

        mutating func add(_ offset: Float) { bins[Int((offset / Self.bin).rounded()), default: 0] += 1 }
        mutating func add(_ other: Histogram) { for (k, v) in other.bins { bins[k, default: 0] += v } }

        /// The most common offset, ties toward the line.
        var mode: Float? {
            bins.max { a, b in a.value != b.value ? a.value < b.value : abs(a.key) > abs(b.key) }.map { Float($0.key) * Self.bin }
        }
    }

    private func facadeHistogram(cells: ClosedRange<Int>, along wall: WallFrame) -> Histogram {
        var histogram = Histogram()
        for index in cells {
            for s in samples(in: cellRange(index)) {
                let outward = frame.mapDirection(wall.segment(atS: s).outward)
                var seen = Set<Int>()
                for height in stride(from: config.voxelSize * 2, to: config.headroom, by: config.voxelSize * 2) {
                    for out in stride(from: -config.faceBehind, through: config.faceBehind, by: config.voxelSize / 2) {
                        guard let g = coordinate(wall, s: s, height: height, out: out), let i = grid.index(g), seen.insert(i).inserted else { continue }
                        let voxel = grid.pool[i]
                        guard grid.isWellSeenSurface(i, config: config), simd_dot(voxel.normal ?? .zero, outward) >= cos(Float.pi / 6) else { continue }
                        histogram.add(wall.out(of: frame.world(grid.center(of: g)), pieceAtS: s))
                    }
                }
            }
        }
        return histogram
    }


    struct FaceSample {
        var height: Float
        /// A well-seen surface lies on the wall face.
        var face: Bool
        /// The nearest well-seen surface standing proud of the face, facing out, and how far out.
        var relief: Float?
    }

    /// What the voxels along the wall's normal at (s, height) show, judged by voxel centers
    /// against the facade's offset.
    func faceSample(_ wall: WallFrame, s: Float, height: Float, facade: Float) -> FaceSample {
        let outward = frame.mapDirection(wall.segment(atS: s).outward)
        var sample = FaceSample(height: height, face: false, relief: nil)
        for out in stride(from: facade - config.recessDepth, through: facade + config.reliefDepth, by: config.voxelSize / 2) {
            guard let g = coordinate(wall, s: s, height: height, out: out), let voxel = grid.voxel(g), grid.isWellSeenSurface(g, config: config) else { continue }
            let centerOut = wall.out(of: frame.world(grid.center(of: g)), pieceAtS: s) - facade
            if centerOut >= -config.recessDepth - 1e-4, centerOut <= faceTolerance + 1e-4 {
                sample.face = true
            } else if centerOut <= config.reliefDepth + 1e-4, sample.relief == nil, simd_dot(voxel.normal ?? .zero, outward) >= cos(Float.pi / 4),
                      !Self.clutterClasses.contains(voxel.meshLabel) {
                sample.relief = centerOut
            }
        }
        return sample
    }

    /// Mesh classes that are never part of the facade (`Voxel.meshLabel` values).
    private static let clutterClasses: Set<UInt8> = Set([MeshClass.none, .floor, .ceiling, .table, .seat].map { $0.rawValue + 1 })

    /// Whether the relief rows at s are attached structure: no free voxel was seen between the
    /// relief and the wall at any of them (a gap would make it something standing in front of
    /// the wall).
    private func attachedRelief(_ wall: WallFrame, s: Float, rows: [FaceSample], facade: Float) -> Bool {
        for row in rows where !row.face {
            guard let front = row.relief else { return false }
            for out in stride(from: facade + faceTolerance, to: facade + front, by: config.voxelSize / 2) {
                if coordinate(wall, s: s, height: row.height, out: out).flatMap(grid.voxel)?.state(config) == .free { return false }
            }
        }
        return true
    }

    /// How far out from the wall the ground in front of a cell was seen without a break,
    /// meters, in whole rows of `groundRowSpacing`; nil when not even the first voxel in front
    /// of the wall was. Ground is checked every half voxel out (`groundHeight`), so no voxel
    /// between two rows goes unchecked.
    ///
    /// The reach is reported from the wall's line, but ground can only be judged from the first
    /// voxel past the facade's face (`nearStart`): nearer, the voxels hold the face. That strip
    /// counts as seen only where the facade shows at its foot at every sample (`footShowsFace`):
    /// the rays that reached the face's lowest row crossed the strip just above the ground, as
    /// the rays to the face do for `facingReach`.
    public func groundReach(cell index: Int, along wall: WallFrame) -> Float? {
        groundReach(cell: index, along: wall, facade: facadeOffset(cell: index, along: wall) ?? 0)
    }

    /// Where the space in front of the facade starts, meters out from the chain's line: the
    /// middle of the first voxel past the facade's face. Ground is judged from here.
    private func nearStart(_ facade: Float) -> Float { facade + faceTolerance + config.voxelSize / 2 }

    private func groundReach(cell index: Int, along wall: WallFrame, facade: Float) -> Float? {
        let ss = samples(in: cellRange(index))
        guard ss.allSatisfy({ footShowsFace(wall, s: $0, facade: facade) }) else { return nil }
        guard let seen = contiguousReach(from: nearStart(facade), to: config.outDepth, { out in
            ss.allSatisfy { groundHeight(wall, s: $0, out: out) != nil }
        }) else { return nil }
        return (seen / config.groundRowSpacing + 1e-4).rounded(.down) * config.groundRowSpacing
    }

    /// How far the facade face at its lowest row may turn up from facing out, radians. A low
    /// object standing at the foot, too near the face to part from it at 10 cm voxels, gives the
    /// face's voxel its top as well: in the synthetic foot scene (`Map3DFootTests`) a clear foot
    /// faces straight out, and a box 0.1 m tall and 0.05 m deep turns it 27 degrees up. 20
    /// degrees is between them: a guess from that scene, not measured on a phone.
    static let footFaceTilt: Float = 20 * .pi / 180

    /// Whether the facade shows at its lowest row at s: a well-seen surface on the face
    /// (`faceSample`), nothing proud of it there, and facing out within `footFaceTilt`.
    private func footShowsFace(_ wall: WallFrame, s: Float, facade: Float) -> Bool {
        let height = config.voxelSize
        let sample = faceSample(wall, s: s, height: height, facade: facade)
        guard sample.face, sample.relief == nil else { return false }
        let outward = frame.mapDirection(wall.segment(atS: s).outward)
        for out in stride(from: facade - config.recessDepth, through: facade + faceTolerance, by: config.voxelSize / 2) {
            guard let g = coordinate(wall, s: s, height: height, out: out), let voxel = grid.voxel(g), voxel.isWellSeenSurface(config),
                  let normal = voxel.normal else { continue }
            let centerOut = wall.out(of: frame.world(grid.center(of: g)), pieceAtS: s) - facade
            guard centerOut >= -config.recessDepth - 1e-4, centerOut <= faceTolerance + 1e-4 else { continue }
            if simd_dot(simd_normalize(normal), outward) >= cos(Self.footFaceTilt) { return true }
        }
        return false
    }

    /// Height of the ground seen at a point in front of the wall, meters above the chain's
    /// ground; nil where it was not seen. Looking down from `groundSearch` above to as far
    /// below, the first voxel that is not free must be a well-seen surface facing within 45
    /// degrees of up, and every voxel above it must be free, except within `groundClearance`
    /// of it: a ray that ended on the ground leaves the last stretch before it unmarked (see
    /// `VoxelGrid.carveFree`), and anything that low is not told apart from the ground anyway.
    /// Ground under a bush, or under anything else taller than that, is not seen.
    func groundHeight(_ wall: WallFrame, s: Float, out: Float) -> Float? {
        var unknownFrom: Float?
        for height in stride(from: config.groundSearch, through: -config.groundSearch, by: -config.voxelSize / 2) {
            guard let g = coordinate(wall, s: s, height: height, out: out), let voxel = grid.voxel(g) else { return nil }
            switch voxel.state(config) {
            case .free:
                guard unknownFrom == nil else { return nil }
            case .unknown:
                if unknownFrom == nil { unknownFrom = height }
            case .surface:
                guard grid.isWellSeenSurface(g, config: config), (voxel.normal?.y ?? 0) >= cos(Float.pi / 4) else { return nil }
                if let unknownFrom, unknownFrom - height > config.groundClearance { return nil }
                return frame.world(grid.center(of: g)).y - wall.groundY
            }
        }
        return nil
    }

    /// How far out from the wall the space in front of a cell was seen clear, meters, or nil.
    /// Only for a cell whose facade was seen: the rays that reached it crossed the space just
    /// in front of it, up to the last stretch before the face (`VoxelGrid.carveFree`), which is
    /// the face's own depth. From one voxel past `faceFront` out to the distance returned, the
    /// ground was seen and every voxel from `groundClearance` above it to headroom is free, and
    /// a voxel is free only where a ray crossed it and ended beyond it.
    public func facingReach(cell index: Int, along wall: WallFrame) -> Float? {
        let facade = facadeOffset(cell: index, along: wall)
        guard let facade, isWallSeen(cell: index, along: wall, facade: facade) else { return nil }
        return clearReach(cell: index, along: wall, facade: facade)
    }

    /// Space is judged from half a voxel past `nearStart`: the voxel next to the facade's face
    /// only ever holds the last stretch of rays that ended on the face, never known free. A
    /// reach short of `overheadDepth` (the battery's depth) is not reported: the server's
    /// facing check needs space past the battery's front, so it could never settle anything,
    /// and space that close to a surface is what depth measures least surely (ETH3D electro's
    /// laser truth can't confirm or refute it within 12 to 20 cm of a face).
    private func clearReach(cell index: Int, along wall: WallFrame, facade: Float) -> Float? {
        let ss = samples(in: cellRange(index))
        let reach = contiguousReach(from: nearStart(facade) + config.voxelSize / 2, to: config.outDepth) { out in
            ss.allSatisfy { isClear(wall, s: $0, out: out, upTo: config.headroom) }
        }
        return reach.flatMap { $0 >= config.overheadDepth ? $0 : nil }
    }

    /// How high above the ground the space over a battery at this cell was seen clear, meters,
    /// or nil. Only for a cell whose facade was seen, as for `facingReach`. From one voxel past
    /// `faceFront` out to `overheadDepth`, the ground was seen and every voxel from
    /// `groundClearance` above it up to the height returned is free; above headroom the face
    /// must also be seen at each height, so the near stretch the rays crossed goes up with it.
    public func overheadReach(cell index: Int, along wall: WallFrame) -> Float? {
        let facade = facadeOffset(cell: index, along: wall)
        return isWallSeen(cell: index, along: wall, facade: facade) ? clearHeight(cell: index, along: wall, facade: facade) : nil
    }

    /// The least, over the columns from one voxel past `faceFront` out to `overheadDepth`, of
    /// the height seen clear above each column's own ground: every voxel from
    /// `groundClearance` above it up to that height is free, and above headroom the facade face
    /// is seen at that height too.
    private func clearHeight(cell index: Int, along wall: WallFrame, facade: Float?) -> Float? {
        guard let facade else { return nil }
        let outs = Array(stride(from: nearStart(facade) + config.voxelSize / 2, through: config.overheadDepth, by: config.voxelSize / 2))
        var reach: Float = .infinity
        for s in samples(in: cellRange(index)) {
            var faceAbove: [Float: Bool] = [:]
            for out in outs {
                guard let ground = groundHeight(wall, s: s, out: out) else { return nil }
                var column: Float?
                for height in stride(from: ground + config.groundClearance, to: config.top - config.voxelSize / 2, by: config.voxelSize / 2) {
                    guard isFree(wall, s: s, height: height, out: out) else { break }
                    if height > config.headroom {
                        let face = faceAbove[height] ?? faceSample(wall, s: s, height: height, facade: facade).face
                        faceAbove[height] = face
                        guard face else { break }
                    }
                    column = height - ground
                }
                guard let column else { return nil }
                reach = min(reach, column)
            }
        }
        return reach.isFinite ? reach : nil
    }

    /// The ground at a point was seen and the space above it from `groundClearance` up to
    /// `height` is free.
    private func isClear(_ wall: WallFrame, s: Float, out: Float, upTo height: Float) -> Bool {
        guard let ground = groundHeight(wall, s: s, out: out) else { return false }
        return stride(from: ground + config.groundClearance, through: height, by: config.voxelSize / 2).allSatisfy {
            isFree(wall, s: s, height: $0, out: out)
        }
    }

    private func isFree(_ wall: WallFrame, s: Float, height: Float, out: Float) -> Bool {
        coordinate(wall, s: s, height: height, out: out).flatMap(grid.voxel)?.state(config) == .free
    }

    /// The largest distance, from `start` in steps of half a voxel up to `end`, up to which
    /// `passes` holds at every step; nil when it fails at `start`.
    private func contiguousReach(from start: Float, to end: Float, _ passes: (Float) -> Bool) -> Float? {
        var reach: Float?
        for distance in stride(from: start, through: end, by: config.voxelSize / 2) {
            guard passes(distance) else { break }
            reach = distance
        }
        return reach
    }

    // MARK: Sampling

    /// s values across a cell at most half a voxel apart, the first and last a hair inside its
    /// edges, so every voxel column the cell overlaps is sampled.
    func samples(in range: ClosedRange<Float>) -> [Float] {
        let inset: Float = 1e-4
        let low = range.lowerBound + inset
        let high = range.upperBound - inset
        let n = max(1, Int(((high - low) / (config.voxelSize / 2)).rounded(.up)))
        return (0...n).map { low + Float($0) * (high - low) / Float(n) }
    }

    /// The voxel at wall coordinates; nil outside the bounds.
    func coordinate(_ wall: WallFrame, s: Float, height: Float, out: Float) -> SIMD3<Int32>? {
        grid.coordinate(of: frame.map(wall.world(s: s, height: height, out: out)))
    }
}
