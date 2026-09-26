import Foundation
import simd

/// The part of the region of interest nobody has seen yet, as boxes the UI can draw over the
/// camera feed. Everything is in the map frame (`Map3D.frame` converts to ARKit world), so the
/// boxes can hang off the meter's anchor.
public struct FogOfWar: Sendable, Equatable {
    public struct Cell: Sendable, Equatable {
        /// Center of a cube `FogOfWar.cellSize` on a side, map frame.
        public var center: SIMD3<Float>
        /// Share of the cell's region-of-interest voxels still unknown, 0 to 1.
        public var unknown: Float
    }

    public var cellSize: Float
    /// Cells with any unknown voxel of the region of interest.
    public var cells: [Cell]
    /// Share of the region of interest seen, 0 to 1: free or surface voxels over all of it.
    public var seen: Float
}

/// Where to stand and look next: the largest unseen part of the region of interest that a view
/// can still reveal, and a spot from which it is in sight.
public struct ViewSuggestion: Sendable, Equatable {
    /// Center of the unseen region's boundary with seen free space, map frame: what to aim at.
    public var target: SIMD3<Float>
    /// Unknown voxels in the region.
    public var voxels: Int
    /// Box around the region, map frame.
    public var regionMin: SIMD3<Float>
    public var regionMax: SIMD3<Float>
    /// Where to stand, on the ground (y = 0), map frame.
    public var stand: SIMD3<Float>
    /// Camera position and unit aim direction from there, map frame.
    public var eye: SIMD3<Float>
    public var aim: SIMD3<Float>
    /// Share of the region's boundary samples in unobstructed sight from `eye`, 0 to 1. Zero
    /// when no candidate spot sees any of it; `stand` is then straight out from the target.
    public var inSight: Float
}

extension Map3D {
    /// Fog over the region of interest along `wall` (normally the walk's chain, or
    /// `MeasuredWallChain.wallFrame`): within `alongExtent` of the meter along the chain, from
    /// `faceBehind` behind it out to `outDepth`, not behind any other piece of the chain, from
    /// the ground to headroom, and to `top` over the battery's depth.
    public func fogOfWar(along wall: WallFrame) -> FogOfWar {
        let region = RegionOfInterest(self, wall: wall)
        let factor = max(1, Int32((config.fogCellSize / config.voxelSize).rounded()))
        var counts: [SIMD3<Int32>: (unknown: Int, total: Int)] = [:]
        var unknown = 0
        region.forEachVoxel { g, voxel in
            let isUnknown = voxel?.state(config) ?? .unknown == .unknown
            let key = g / factor
            var count = counts[key] ?? (0, 0)
            count.total += 1
            if isUnknown {
                count.unknown += 1
                unknown += 1
            }
            counts[key] = count
        }
        let size = config.voxelSize * Float(factor)
        let cells = counts.compactMap { key, count -> FogOfWar.Cell? in
            guard count.unknown > 0 else { return nil }
            let center = grid.origin + (SIMD3<Float>(key) + 0.5) * size
            return FogOfWar.Cell(center: center, unknown: Float(count.unknown) / Float(count.total))
        }
        .sorted { ($0.center.x, $0.center.y, $0.center.z) < ($1.center.x, $1.center.y, $1.center.z) }
        let seen = region.count > 0 ? 1 - Float(unknown) / Float(region.count) : 0
        return FogOfWar(cellSize: size, cells: cells, seen: seen)
    }

    /// The largest unseen part of the region of interest along `wall` that borders seen free
    /// space, and where to stand to see it. Unseen voxels shut in by surfaces (the inside of a
    /// bush) are left out: no view can reveal them. Nil when nothing unseen borders free space.
    ///
    /// Candidate spots stand `viewDistances` from the target at every 30 degrees around it, in
    /// front of the chain and not inside anything; the camera is at `eyeHeight` aiming at the
    /// target. The spot seeing the most of the region's boundary past known surfaces wins,
    /// nearer spots first on a tie.
    public func nextBestView(along wall: WallFrame) -> ViewSuggestion? {
        precondition(!config.viewDistances.isEmpty, "Map3DConfig.viewDistances is empty")
        let region = RegionOfInterest(self, wall: wall)
        // 1: unknown voxel of the region, 2: visited.
        var marks = [UInt8](repeating: 0, count: Int(grid.dims.x) * Int(grid.dims.y) * Int(grid.dims.z))
        func flat(_ g: SIMD3<Int32>) -> Int { Int(g.x) + Int(grid.dims.x) * (Int(g.y) + Int(grid.dims.y) * Int(g.z)) }
        var seeds: [SIMD3<Int32>] = []
        region.forEachVoxel { g, voxel in
            guard voxel?.state(config) ?? .unknown == .unknown else { return }
            marks[flat(g)] = 1
            seeds.append(g)
        }
        let faces: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        func inGrid(_ g: SIMD3<Int32>) -> Bool { all(g .>= 0) && all(g .< grid.dims) }
        func bordersFree(_ g: SIMD3<Int32>) -> Bool {
            faces.contains { f in
                let n = g &+ f
                return inGrid(n) && grid.voxel(n)?.state(config) == .free
            }
        }
        var best: (voxels: [SIMD3<Int32>], frontier: [SIMD3<Int32>])?
        for seed in seeds where marks[flat(seed)] == 1 {
            marks[flat(seed)] = 2
            var queue = [seed]
            var head = 0
            var frontier: [SIMD3<Int32>] = []
            while head < queue.count {
                let g = queue[head]
                head += 1
                if bordersFree(g) { frontier.append(g) }
                for dz: Int32 in -1...1 {
                    for dy: Int32 in -1...1 {
                        for dx: Int32 in -1...1 {
                            let n = g &+ SIMD3(dx, dy, dz)
                            guard inGrid(n), marks[flat(n)] == 1 else { continue }
                            marks[flat(n)] = 2
                            queue.append(n)
                        }
                    }
                }
            }
            if !frontier.isEmpty, queue.count > best?.voxels.count ?? 0 { best = (queue, frontier) }
        }
        guard let region = best else { return nil }
        let frontier = region.frontier.map(grid.center)
        let target = frontier.reduce(.zero, +) / Float(frontier.count)
        let centers = region.voxels.map(grid.center)
        let lower = centers.reduce(SIMD3<Float>(repeating: .infinity), simd_min) - config.voxelSize / 2
        let upper = centers.reduce(SIMD3<Float>(repeating: -.infinity), simd_max) + config.voxelSize / 2
        // Up to 64 boundary voxels, spread through the list, stand in for the region.
        let step = max(1, frontier.count / 64)
        let probes = Swift.stride(from: 0, to: frontier.count, by: step).map { frontier[$0] }

        var chosen: (stand: SIMD3<Float>, eye: SIMD3<Float>, seen: Int)?
        for distance in config.viewDistances {
            for step in 0..<12 {
                let angle = Float(step) * .pi / 6
                let stand = SIMD3(target.x + cos(angle) * distance, 0, target.z + sin(angle) * distance)
                guard canStand(at: stand, wall: wall) else { continue }
                let eye = SIMD3(stand.x, config.eyeHeight, stand.z)
                let seen = probes.count { inSight($0, from: eye, aim: simd_normalize(target - eye)) }
                if seen > chosen?.seen ?? 0 { chosen = (stand, eye, seen) }
            }
        }
        let fallback: SIMD3<Float> = {
            let point = wall.wallPoint(frame.world(target))
            let world = wall.world(s: point.s, height: 0, out: max(point.out, 0) + config.viewDistances[0])
            return frame.map(SIMD3(world.x, wall.groundY, world.z))
        }()
        let stand = chosen?.stand ?? SIMD3(fallback.x, 0, fallback.z)
        let eye = chosen?.eye ?? SIMD3(stand.x, config.eyeHeight, stand.z)
        return ViewSuggestion(
            target: target, voxels: region.voxels.count, regionMin: lower, regionMax: upper, stand: stand, eye: eye,
            aim: simd_normalize(target - eye), inSight: Float(chosen?.seen ?? 0) / Float(probes.count))
    }

    /// Whether someone can stand at a map point: inside the bounds, in front of the chain by more
    /// than a battery's depth and not
    /// where the map holds a surface between `groundClearance` and just above eye height.
    private func canStand(at point: SIMD3<Float>, wall: WallFrame) -> Bool {
        guard bounds.contains(SIMD3(point.x, config.eyeHeight, point.z)), RegionOfInterest.isInFront(self, wall: wall, map: point, minOut: config.overheadDepth) else { return false }
        for height in Swift.stride(from: config.groundClearance, through: config.eyeHeight + 0.3, by: config.voxelSize / 2) where state(at: SIMD3(point.x, height, point.z)) == .surface {
            return false
        }
        return true
    }

    /// Whether a voxel center is within a phone's view from `eye` aimed along `aim`, and no
    /// surface lies between them. A camera sees about 30 degrees either side of its aim across
    /// the narrower side of the image (ARKit's wide camera held in portrait: 53 degrees across),
    /// less a margin, so 25 is used.
    private func inSight(_ point: SIMD3<Float>, from eye: SIMD3<Float>, aim: SIMD3<Float>) -> Bool {
        let offset = point - eye
        let distance = simd_length(offset)
        guard distance > 0, distance <= config.maxViewDistance else { return false }
        let direction = offset / distance
        guard simd_dot(direction, aim) >= cos(25 * Float.pi / 180) else { return false }
        return firstSurface(from: eye, direction: direction, length: distance - config.voxelSize) == nil
    }
}

/// The voxels of the map the rules need seen, along one wall chain: from the ground to
/// headroom, and on up to `top` over the battery's depth (`overheadDepth`), where headroom is
/// judged. Higher up farther out, only open sky would be left to see, and sky returns no depth.
struct RegionOfInterest {
    let map: Map3D
    let wall: WallFrame
    /// Per plan column of the grid (x + dims.x * z), the highest layer in the region, or -1
    /// when the column is not in it.
    let columns: [Int32]
    let low: Int32
    let count: Int

    init(_ map: Map3D, wall: WallFrame) {
        self.map = map
        self.wall = wall
        let grid = map.grid
        let config = map.config
        // From the layer holding the ground to the layer holding headroom, or the top: the
        // voxels coverage reads (`Map3DCoverage`).
        let layer = { (height: Float) in min(grid.dims.y - 1, max(0, Int32(((height - grid.origin.y) / grid.voxelSize).rounded(.down)))) }
        low = layer(0)
        let headroomLayer = layer(config.headroom)
        let topLayer = layer(config.top)
        var columns = [Int32](repeating: -1, count: Int(grid.dims.x) * Int(grid.dims.z))
        var count = 0
        for z in 0..<grid.dims.z {
            for x in 0..<grid.dims.x {
                let center = grid.center(of: SIMD3(x, 0, z))
                let point = SIMD3(center.x, 0, center.z)
                guard Self.isInFront(map, wall: wall, map: point, minOut: -config.faceBehind) else { continue }
                let local = wall.wallPoint(map.frame.world(point))
                guard abs(local.s) <= config.alongExtent else { continue }
                let high = local.out <= config.overheadDepth + config.voxelSize / 2 ? topLayer : headroomLayer
                guard high >= low else { continue }
                columns[Int(x) + Int(grid.dims.x) * Int(z)] = high
                count += Int(high - low + 1)
            }
        }
        self.columns = columns
        self.count = count
    }

    /// In front of the chain by at least `minOut` and at most `outDepth`, and not behind any
    /// other piece of it within that piece's span.
    static func isInFront(_ map: Map3D, wall: WallFrame, map point: SIMD3<Float>, minOut: Float) -> Bool {
        let world = map.frame.world(point)
        let local = wall.wallPoint(world)
        guard local.out >= minOut, local.out <= map.config.outDepth else { return false }
        let offset = world - wall.origin
        for piece in wall.segments {
            let c = piece.coordinates(ofOffset: offset)
            if piece.span.contains(c.s), c.out < -map.config.faceBehind, -c.out < map.config.outDepth { return false }
        }
        return true
    }

    func forEachVoxel(_ body: (SIMD3<Int32>, Voxel?) -> Void) {
        let grid = map.grid
        for z in 0..<grid.dims.z {
            for x in 0..<grid.dims.x {
                let high = columns[Int(x) + Int(grid.dims.x) * Int(z)]
                guard high >= low else { continue }
                for y in low...high {
                    let g = SIMD3(x, y, z)
                    body(g, grid.voxel(g))
                }
            }
        }
    }
}
