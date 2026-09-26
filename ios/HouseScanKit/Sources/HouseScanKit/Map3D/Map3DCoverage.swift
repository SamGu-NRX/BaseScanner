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
    /// sample some voxel between `faceBehind` behind the chain's line and `faceFront` in front
    /// of it is a surface seen well (`Voxel.isWellSeenSurface`). The layer at the ground itself
    /// belongs to the ground band.
    public func isWallSeen(cell index: Int, along wall: WallFrame) -> Bool {
        let heights = stride(from: config.voxelSize, to: config.headroom, by: config.voxelSize).map { $0 } + [config.headroom]
        let outs = Array(stride(from: -config.faceBehind, through: config.faceFront, by: config.voxelSize / 2))
        for s in samples(in: cellRange(index)) {
            for height in heights {
                let seen = outs.contains { out in
                    voxel(wall, s: s, height: height, out: out)?.isWellSeenSurface(config) == true
                }
                guard seen else { return false }
            }
        }
        return true
    }

    /// How far out from the wall the ground in front of a cell was seen without a break,
    /// meters, in whole rows of `groundRowSpacing`; nil when not even the row at the wall was.
    /// A row is seen where, looking down from `groundSearch` above the ground, every voxel is
    /// free until one that is a well-seen surface facing up. Ground under a bush or anything
    /// else standing on it is not seen. The row at the wall is judged a voxel out, since the
    /// voxels at the wall's foot hold the wall.
    public func groundReach(cell index: Int, along wall: WallFrame) -> Float? {
        let rows = Int((config.outDepth / config.groundRowSpacing + 1e-3).rounded(.down))
        var reach: Float?
        for row in 0...rows {
            let out = Float(row) * config.groundRowSpacing
            let seen = samples(in: cellRange(index)).allSatisfy { s in
                isGroundSeen(wall, s: s, out: max(out, config.voxelSize))
            }
            guard seen else { break }
            reach = out
        }
        return reach
    }

    private func isGroundSeen(_ wall: WallFrame, s: Float, out: Float) -> Bool {
        for height in stride(from: config.groundSearch, through: -config.groundSearch, by: -config.voxelSize / 2) {
            guard let voxel = voxel(wall, s: s, height: height, out: out) else { return false }
            switch voxel.state(config) {
            case .free: continue
            case .unknown: return false
            case .surface: return voxel.isWellSeenSurface(config) && (voxel.normal?.y ?? 0) >= cos(Float.pi / 4)
            }
        }
        return false
    }

    /// How far out from the wall the space in front of a cell was seen clear, meters: every
    /// voxel from `spaceFloor` to headroom is free from `faceFront` out to the distance
    /// returned, in steps of half a voxel. Nil when the first step is not. Nearer the wall than
    /// `faceFront` is the wall band's (boxes and the meter stand there).
    public func facingReach(cell index: Int, along wall: WallFrame) -> Float? {
        let heights = Array(stride(from: config.spaceFloor, through: config.headroom, by: config.voxelSize / 2))
        let ss = samples(in: cellRange(index))
        var reach: Float?
        for out in stride(from: config.faceFront, through: config.outDepth, by: config.voxelSize / 2) {
            let clear = ss.allSatisfy { s in
                heights.allSatisfy { voxel(wall, s: s, height: $0, out: out)?.state(config) == .free }
            }
            guard clear else { break }
            reach = out
        }
        return reach
    }

    /// How high above the ground the space over a battery at this cell was seen clear, meters:
    /// every voxel from `faceFront` to `overheadDepth` out is free from `spaceFloor` up to the
    /// height returned, in steps of half a voxel. Nil when the lowest step is not.
    public func overheadReach(cell index: Int, along wall: WallFrame) -> Float? {
        let outs = Array(stride(from: config.faceFront, through: config.overheadDepth, by: config.voxelSize / 2))
        let ss = samples(in: cellRange(index))
        var reach: Float?
        for height in stride(from: config.spaceFloor, to: config.top, by: config.voxelSize / 2) {
            let clear = ss.allSatisfy { s in
                outs.allSatisfy { voxel(wall, s: s, height: height, out: $0)?.state(config) == .free }
            }
            guard clear else { break }
            reach = height
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

    /// The voxel at wall coordinates, nil outside the bounds or where nothing was stored.
    func voxel(_ wall: WallFrame, s: Float, height: Float, out: Float) -> Voxel? {
        grid.voxel(at: frame.map(wall.world(s: s, height: height, out: out)))
    }
}
