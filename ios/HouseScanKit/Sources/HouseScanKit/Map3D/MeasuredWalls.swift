import Foundation
import simd

/// What a measured wall was found from.
public enum WallSource: String, Sendable, Equatable {
    /// LiDAR: depth rays or ARKit's reconstructed mesh.
    case mesh
    /// Planes ARKit detected, on a phone without LiDAR.
    case plane
}

/// One straight piece of wall found in the map. Points are plan (x, z) in the map frame.
public struct MeasuredWall: Sendable, Equatable {
    /// Ends of the piece, left to right as seen from outside.
    public var start: SIMD2<Float>
    public var end: SIMD2<Float>
    /// Unit, from the wall toward the outside.
    public var outward: SIMD2<Float>
    public var source: WallSource
    /// Plan cells of vertical surface that support it.
    public var support: Int

    public var length: Float { simd_distance(start, end) }
    /// Unit, from `start` to `end`: the outward turned 90 degrees, as `WallFrame.along`.
    public var along: SIMD2<Float> { SIMD2(outward.y, -outward.x) }
}

/// The house outline near the meter: pieces of wall found in the map, joined into one chain
/// through the meter's piece. Consecutive pieces share an end, which is where their lines
/// cross (a corner) or the far end of a gap bridged along one line.
public struct MeasuredWallChain: Sendable, Equatable {
    /// Left to right as seen from outside.
    public var walls: [MeasuredWall]
    /// Index of the piece the meter is on.
    public var meterIndex: Int

    /// The chain's corners and ends, plan (x, z) in the map frame, left to right.
    public var vertices: [SIMD2<Float>] {
        guard let first = walls.first else { return [] }
        return [first.start] + walls.map(\.end)
    }

    /// The chain as a `WallFrame` for coverage and scene.json: its meter piece passes through
    /// `meter` (world) with the measured piece's direction, and each measured corner is a turn
    /// at the same distance along the chain from the meter. `frame` is the map's frame. Nil when
    /// the chain is empty.
    public func wallFrame(meter: SIMD3<Float>, groundY: Float, frame: MapFrame) -> WallFrame? {
        guard meterIndex < walls.count else { return nil }
        func worldOutward(_ wall: MeasuredWall) -> SIMD3<Float> {
            let d = frame.worldDirection(SIMD3(wall.outward.x, 0, wall.outward.y))
            return simd_normalize(SIMD3(d.x, 0, d.z))
        }
        guard var result = WallFrame(meter: meter, outward: worldOutward(walls[meterIndex]), groundY: groundY) else { return nil }
        let meterMap = frame.map(meter)
        let meterPiece = walls[meterIndex]
        // s of the meter's foot on its piece, from the piece's start.
        let meterS = simd_dot(SIMD2(meterMap.x, meterMap.z) - meterPiece.start, meterPiece.along)
        var s = meterPiece.length - meterS
        for index in walls.indices.dropFirst(meterIndex + 1) {
            result.turn(.right, at: WallCorner(s: s, outward: worldOutward(walls[index])))
            s += walls[index].length
        }
        s = -meterS
        for index in walls.indices.prefix(meterIndex).reversed() {
            result.turn(.left, at: WallCorner(s: s, outward: worldOutward(walls[index])))
            s -= walls[index].length
        }
        return result
    }
}

extension Map3D {
    /// Walls found in the map, joined into a chain through the meter (map origin). Nil when no
    /// piece passes within `cornerJoinDistance` of the meter.
    ///
    /// A plan cell is wall evidence where its voxels between `wallBottom` and `top` that are
    /// surface (or carry a mesh face), have a normal within 30 degrees of horizontal, and are not
    /// classified floor, ceiling, table or seat add up to `minWallHeight`. Feature points and
    /// estimated depth never make walls: they are too sparse or too uncertain for a wall line.
    /// Lines are then taken one at a time, the one with most evidence first, each fitted by
    /// least squares to the cells near it that face its way, and split where the evidence
    /// breaks for more than `maxWallGap`.
    public func measuredWalls() -> MeasuredWallChain? {
        chain(wallPieces())
    }

    /// Every piece of wall found, unchained.
    public func wallPieces() -> [MeasuredWall] {
        var cells = wallEvidence()
        var pieces: [MeasuredWall] = []
        let minCells = max(2, Int((config.minWallLength / config.voxelSize).rounded(.up)))
        let cosTolerance = cos(config.wallNormalTolerance)
        for _ in 0..<64 {
            guard cells.count >= minCells else { break }
            // The line through some cell, along its normal, with the most evidence near it.
            let stride = max(1, cells.count / 800)
            var best: (weight: Int, point: SIMD2<Float>, normal: SIMD2<Float>)?
            for i in Swift.stride(from: 0, to: cells.count, by: stride) {
                let candidate = cells[i]
                var weight = 0
                for cell in cells where isInlier(cell, point: candidate.point, normal: candidate.normal, cosTolerance: cosTolerance) {
                    weight += cell.count
                }
                if weight > best?.weight ?? 0 { best = (weight, candidate.point, candidate.normal) }
            }
            guard let seed = best else { break }
            var line = (point: seed.point, normal: seed.normal)
            var inliers: [WallCell] = []
            for _ in 0..<2 {
                inliers = cells.filter { isInlier($0, point: line.point, normal: line.normal, cosTolerance: cosTolerance) }
                line = fit(inliers, normal: line.normal)
            }
            inliers = cells.filter { isInlier($0, point: line.point, normal: line.normal, cosTolerance: cosTolerance) }
            guard inliers.count >= minCells else { break }
            cells.removeAll { isInlier($0, point: line.point, normal: line.normal, cosTolerance: cosTolerance) }
            pieces += split(inliers, line: line)
        }
        return pieces
    }

    // MARK: Evidence

    struct WallCell {
        var point: SIMD2<Float>
        var normal: SIMD2<Float>
        /// Voxels of vertical surface in the cell's column.
        var count: Int
        var measured: Int
        var planes: Int
    }

    func wallEvidence() -> [WallCell] {
        struct Column {
            var count = 0
            var normal = SIMD2<Float>.zero
            var measured = 0
            var planes = 0
        }
        let excluded: Set<UInt8> = Set([MeshClass.floor, .ceiling, .table, .seat].map { $0.rawValue + 1 })
        let wallSources = VoxelSources([.lidar, .mesh, .plane]).rawValue
        let maxVertical = sin(Float.pi / 6)
        var columns: [SIMD2<Int32>: Column] = [:]
        grid.forEachStored { g, voxel in
            guard voxel.sources & wallSources != 0, !excluded.contains(voxel.meshLabel) else { return }
            let height = grid.center(of: g).y
            guard height >= config.wallBottom, height <= config.top else { return }
            guard voxel.state(config) == .surface || voxel.sources & VoxelSources.mesh.rawValue != 0 else { return }
            guard let n = voxel.normal, abs(n.y) <= maxVertical else { return }
            let plan = simd_normalize(SIMD2(n.x, n.z))
            let key = SIMD2(g.x, g.z)
            var column = columns[key] ?? Column()
            // Normals of one wall agree; a neighbour turned the other way is flipped to match.
            column.normal += simd_dot(column.normal, plan) < 0 ? -plan : plan
            column.count += 1
            if voxel.sources & (VoxelSources.lidar.rawValue | VoxelSources.mesh.rawValue) != 0 { column.measured += 1 }
            if voxel.sources & VoxelSources.plane.rawValue != 0 { column.planes += 1 }
            columns[key] = column
        }
        let minCount = Int((config.minWallHeight / config.voxelSize).rounded(.up))
        return columns.compactMap { key, column in
            guard column.count >= minCount, simd_length(column.normal) > 0 else { return nil }
            let center = grid.center(of: SIMD3(key.x, 0, key.y))
            return WallCell(
                point: SIMD2(center.x, center.z), normal: simd_normalize(column.normal), count: column.count,
                measured: column.measured, planes: column.planes)
        }
        .sorted { ($0.point.x, $0.point.y) < ($1.point.x, $1.point.y) }
    }

    private func isInlier(_ cell: WallCell, point: SIMD2<Float>, normal: SIMD2<Float>, cosTolerance: Float) -> Bool {
        abs(simd_dot(cell.point - point, normal)) <= config.wallInlierDistance && abs(simd_dot(cell.normal, normal)) >= cosTolerance
    }

    /// Weighted total least squares: the line through the cells' centroid along their principal
    /// axis, its normal turned to agree with `normal`.
    private func fit(_ cells: [WallCell], normal: SIMD2<Float>) -> (point: SIMD2<Float>, normal: SIMD2<Float>) {
        let total = Float(cells.reduce(0) { $0 + $1.count })
        guard total > 0 else { return (.zero, normal) }
        let centroid = cells.reduce(SIMD2<Float>.zero) { $0 + $1.point * Float($1.count) } / total
        var xx: Float = 0
        var xz: Float = 0
        var zz: Float = 0
        for cell in cells {
            let d = cell.point - centroid
            let w = Float(cell.count)
            xx += w * d.x * d.x
            xz += w * d.x * d.y
            zz += w * d.y * d.y
        }
        let angle = 0.5 * atan2(2 * xz, xx - zz)
        let direction = SIMD2(cos(angle), sin(angle))
        var fitted = SIMD2(-direction.y, direction.x)
        if simd_dot(fitted, normal) < 0 { fitted = -fitted }
        return (centroid, fitted)
    }

    /// The runs of a line's cells without a gap longer than `maxWallGap`, each at least
    /// `minWallLength` long, facing the side of the line that was seen free.
    private func split(_ cells: [WallCell], line: (point: SIMD2<Float>, normal: SIMD2<Float>)) -> [MeasuredWall] {
        var outward = line.normal
        let lineDirection = SIMD2(outward.y, -outward.x)
        let sorted = cells.map { (t: simd_dot($0.point - line.point, lineDirection), cell: $0) }.sorted { $0.t < $1.t }
        var runs: [[(t: Float, cell: WallCell)]] = []
        for item in sorted {
            if let last = runs.last?.last, item.t - last.t - config.voxelSize <= config.maxWallGap {
                runs[runs.count - 1].append(item)
            } else {
                runs.append([item])
            }
        }
        // The outward side is the one seen free, 0.3 m off the line and 1 m up. Depth normals
        // already face the camera; mesh normals may not.
        let middle = SIMD3(line.point.x, 1, line.point.y)
        let offset = SIMD3(outward.x, 0, outward.y) * 0.3
        if state(at: middle + offset) != .free, state(at: middle - offset) == .free { outward = -outward }
        let rightward = SIMD2(outward.y, -outward.x)
        return runs.compactMap { run in
            guard let first = run.first, let last = run.last else { return nil }
            let half = config.voxelSize / 2
            var a = line.point + lineDirection * (first.t - half)
            var b = line.point + lineDirection * (last.t + half)
            guard simd_distance(a, b) >= config.minWallLength else { return nil }
            if simd_dot(b - a, rightward) < 0 { swap(&a, &b) }
            let measured = run.reduce(0) { $0 + $1.cell.measured }
            let planes = run.reduce(0) { $0 + $1.cell.planes }
            return MeasuredWall(start: a, end: b, outward: outward, source: measured >= planes ? .mesh : .plane, support: run.count)
        }
    }

    // MARK: Chain

    /// Joins pieces into one chain from the meter's piece outward on each side, until no piece
    /// joins or the chain runs `alongExtent` from the meter, where it is cut.
    func chain(_ pieces: [MeasuredWall]) -> MeasuredWallChain? {
        let origin = SIMD2<Float>.zero
        func distance(_ wall: MeasuredWall) -> Float {
            let t = min(max(simd_dot(origin - wall.start, wall.along), 0), wall.length)
            return simd_distance(origin, wall.start + wall.along * t)
        }
        guard let meterIndex = pieces.indices.min(by: { distance(pieces[$0]) < distance(pieces[$1]) }),
              distance(pieces[meterIndex]) <= config.cornerJoinDistance else { return nil }
        var used: Set<Int> = [meterIndex]
        var meterPiece = pieces[meterIndex]
        var right: [MeasuredWall] = []
        var left: [MeasuredWall] = []
        for side in [WalkSide.right, .left] {
            var current = meterPiece
            var joined: [MeasuredWall] = []
            while let (index, joint) = nextJoin(from: current, side: side, pieces: pieces, used: used) {
                used.insert(index)
                var next = pieces[index]
                switch (joint, side) {
                case (.straight, .right):
                    current.end = current.start + current.along * simd_dot(next.end - current.start, current.along)
                    current.support += next.support
                    continue
                case (.straight, .left):
                    current.start = current.end - current.along * simd_dot(current.end - next.start, current.along)
                    current.support += next.support
                    continue
                case (.corner(let point), .right):
                    current.end = point
                    next.start = point
                case (.corner(let point), .left):
                    current.start = point
                    next.end = point
                }
                if joined.isEmpty { meterPiece = current } else { joined[joined.count - 1] = current }
                joined.append(next)
                current = next
            }
            if joined.isEmpty { meterPiece = current } else { joined[joined.count - 1] = current }
            if side == .right { right = joined } else { left = joined }
        }
        var walls = left.reversed() + [meterPiece] + right
        var meter = left.count
        // Cut at alongExtent from the meter's foot along the chain, each side.
        let limit = config.alongExtent
        let meterT = min(max(simd_dot(origin - meterPiece.start, meterPiece.along), 0), meterPiece.length)
        var reach = meterPiece.length - meterT
        if reach > limit { walls[meter].end = meterPiece.start + meterPiece.along * (meterT + limit) }
        var index = meter + 1
        while index < walls.count {
            guard reach < limit else {
                walls.removeSubrange(index...)
                break
            }
            if reach + walls[index].length > limit {
                walls[index].end = walls[index].start + walls[index].along * (limit - reach)
            }
            reach += walls[index].length
            index += 1
        }
        reach = meterT
        if reach > limit { walls[meter].start = meterPiece.start + meterPiece.along * (meterT - limit) }
        index = meter - 1
        while index >= 0 {
            guard reach < limit else {
                walls.removeSubrange(...index)
                meter -= index + 1
                break
            }
            if reach + walls[index].length > limit {
                walls[index].start = walls[index].end - walls[index].along * (limit - reach)
            }
            reach += walls[index].length
            index -= 1
        }
        return MeasuredWallChain(walls: walls, meterIndex: meter)
    }

    private enum Joint {
        /// The next piece continues the same line across a gap.
        case straight
        /// The pieces' lines cross at this point.
        case corner(SIMD2<Float>)
    }

    /// The unused piece that best continues `current` past its end on `side`.
    private func nextJoin(from current: MeasuredWall, side: WalkSide, pieces: [MeasuredWall], used: Set<Int>) -> (Int, Joint)? {
        let end = side == .right ? current.end : current.start
        let sign = side.sign
        var best: (index: Int, joint: Joint, score: Float)?
        for (index, piece) in pieces.enumerated() where !used.contains(index) {
            let near = side == .right ? piece.start : piece.end
            let cosine = simd_dot(current.along, piece.along)
            let joint: Joint
            let score: Float
            if cosine >= cos(config.minCornerAngle) {
                let offset = near - end
                let gap = sign * simd_dot(offset, current.along)
                let lateral = abs(simd_dot(offset, current.outward))
                guard lateral <= 2 * config.wallInlierDistance, gap >= -config.wallInlierDistance, gap <= config.maxWallBridge else { continue }
                joint = .straight
                score = max(gap, 0)
            } else {
                let cross = current.along.x * piece.along.y - current.along.y * piece.along.x
                guard abs(cross) > 1e-4 else { continue }
                let t = ((near.x - end.x) * piece.along.y - (near.y - end.y) * piece.along.x) / cross
                let point = end + current.along * t
                let reach = simd_distance(point, end) + simd_distance(point, near)
                guard simd_distance(point, end) <= config.cornerJoinDistance, simd_distance(point, near) <= config.cornerJoinDistance else { continue }
                joint = .corner(point)
                score = reach
            }
            if score < best?.score ?? .infinity { best = (index, joint, score) }
        }
        return best.map { ($0.index, $0.joint) }
    }
}
