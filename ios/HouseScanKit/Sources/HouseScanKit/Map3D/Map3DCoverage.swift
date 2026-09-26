import Foundation
import simd

/// What the 3D map saw along a wall chain, in the form scene.json's `coverage.observed` takes
/// (server/README.md "What settles each check", on t3/server). s and out are meters along and
/// out from the chain the spans were measured against.
public struct Map3DCoverage: Sendable, Equatable {
    /// Stretches where the wall face was seen from the ground to headroom.
    public var wall: [ClosedRange<Float>]
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
            leftEndMarked: leftEndMarked, rightEndMarked: rightEndMarked, wall: coverage.wall,
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
        var ground: [ObservedSpan] = []
        var facing: [ObservedSpan] = []
        var overhead: [ObservedSpan] = []
        for index in cellIndices {
            let range = cellRange(index)
            if isWallSeen(cell: index, along: wall) {
                if let last = seenWall.last, last.upperBound == range.lowerBound {
                    seenWall[seenWall.count - 1] = last.lowerBound...range.upperBound
                } else {
                    seenWall.append(range)
                }
            }
            if let out = groundReach(cell: index, along: wall) { ground.append(ObservedSpan(span: range, out: out)) }
            if let out = facingReach(cell: index, along: wall) { facing.append(ObservedSpan(span: range, out: out)) }
            if let height = overheadReach(cell: index, along: wall) { overhead.append(ObservedSpan(span: range, out: height)) }
        }
        let touching = config.cellWidth * 0.01
        return Map3DCoverage(
            wall: seenWall, ground: ObservedSpan.merge(ground, touching: touching),
            facing: ObservedSpan.merge(facing, touching: touching), overhead: ObservedSpan.merge(overhead, touching: touching))
    }

    // MARK: Per cell

    /// Whether the wall face over a cell was seen from `voxelSize` up to headroom: at every
    /// sample, some voxel whose center lies from `faceBehind` behind the chain's line to
    /// `faceFront` in front of it is a surface seen well (`Voxel.isWellSeenSurface`). Anything
    /// standing farther out, a box on the wall or a shrub against it, hides the face. The
    /// layer at the ground belongs to the ground band.
    public func isWallSeen(cell index: Int, along wall: WallFrame) -> Bool {
        let heights = Array(stride(from: config.voxelSize, to: config.headroom, by: config.voxelSize / 2)) + [config.headroom]
        let outs = Array(stride(from: -config.faceBehind, through: config.faceFront, by: config.voxelSize / 2))
        for s in samples(in: cellRange(index)) {
            for height in heights {
                let seen = outs.contains { out in
                    guard let g = coordinate(wall, s: s, height: height, out: out), let voxel = grid.voxel(g) else { return false }
                    let centerOut = wall.out(of: frame.world(grid.center(of: g)), pieceAtS: s)
                    return centerOut >= -config.faceBehind - 1e-4 && centerOut <= config.faceFront + 1e-4 && voxel.isWellSeenSurface(config)
                }
                guard seen else { return false }
            }
        }
        return true
    }

    /// How far out from the wall the ground in front of a cell was seen without a break,
    /// meters, in whole rows of `groundRowSpacing`; nil when not even the first voxel in front
    /// of the wall was. Ground is checked every half voxel out (`groundHeight`), so no voxel
    /// between two rows goes unchecked.
    public func groundReach(cell index: Int, along wall: WallFrame) -> Float? {
        let ss = samples(in: cellRange(index))
        guard let seen = contiguousReach(from: config.voxelSize, to: config.outDepth, { out in
            ss.allSatisfy { groundHeight(wall, s: $0, out: out) != nil }
        }) else { return nil }
        return (seen / config.groundRowSpacing + 1e-4).rounded(.down) * config.groundRowSpacing
    }

    /// Height of the ground seen at a point in front of the wall, meters above the chain's
    /// ground; nil where it was not seen. Looking down from `groundSearch` above to as far
    /// below, every voxel must be free until one that is a well-seen surface facing within 45
    /// degrees of up. Ground under a bush, or under anything else taller than `groundSearch`,
    /// is not seen.
    func groundHeight(_ wall: WallFrame, s: Float, out: Float) -> Float? {
        for height in stride(from: config.groundSearch, through: -config.groundSearch, by: -config.voxelSize / 2) {
            guard let g = coordinate(wall, s: s, height: height, out: out), let voxel = grid.voxel(g) else { return nil }
            switch voxel.state(config) {
            case .free: continue
            case .unknown: return nil
            case .surface:
                guard voxel.isWellSeenSurface(config), (voxel.normal?.y ?? 0) >= cos(Float.pi / 4) else { return nil }
                return frame.world(grid.center(of: g)).y - wall.groundY
            }
        }
        return nil
    }

    /// How far out from the wall the space in front of a cell was seen clear, meters: at every
    /// point from the first voxel in front of the wall out to the distance returned, the ground
    /// was seen and every voxel from `groundClearance` above it to headroom is free. Nil when
    /// the first point is not.
    public func facingReach(cell index: Int, along wall: WallFrame) -> Float? {
        let ss = samples(in: cellRange(index))
        return contiguousReach(from: config.voxelSize, to: config.outDepth) { out in
            ss.allSatisfy { isClear(wall, s: $0, out: out, upTo: config.headroom) }
        }
    }

    /// How high above the ground the space over a battery at this cell was seen clear, meters:
    /// at every point from the first voxel in front of the wall out to `overheadDepth`, the
    /// ground was seen and every voxel from `groundClearance` above it up to the height
    /// returned is free. Nil when not even the lowest is.
    public func overheadReach(cell index: Int, along wall: WallFrame) -> Float? {
        let ss = samples(in: cellRange(index))
        let outs = Array(stride(from: config.voxelSize, through: config.overheadDepth, by: config.voxelSize / 2))
        var ground: [Float] = []
        for s in ss {
            for out in outs {
                guard let height = groundHeight(wall, s: s, out: out) else { return nil }
                ground.append(height)
            }
        }
        let floor = (ground.max() ?? 0) + config.groundClearance
        var reach: Float?
        for height in stride(from: floor, to: config.top - config.voxelSize / 2, by: config.voxelSize / 2) {
            let clear = ss.allSatisfy { s in outs.allSatisfy { isFree(wall, s: s, height: height, out: $0) } }
            guard clear else { break }
            reach = height
        }
        return reach
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

    /// s values across a cell, at most half a voxel apart and clear of its edges.
    func samples(in range: ClosedRange<Float>) -> [Float] {
        let width = range.upperBound - range.lowerBound
        let n = max(1, Int((width / (config.voxelSize / 2)).rounded(.up)))
        return (0..<n).map { range.lowerBound + (Float($0) + 0.5) * width / Float(n) }
    }

    /// The voxel at wall coordinates; nil outside the bounds.
    func coordinate(_ wall: WallFrame, s: Float, height: Float, out: Float) -> SIMD3<Int32>? {
        grid.coordinate(of: frame.map(wall.world(s: s, height: height, out: out)))
    }
}
