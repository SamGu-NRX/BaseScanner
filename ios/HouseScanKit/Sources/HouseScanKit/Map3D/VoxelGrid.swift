import Foundation
import simd

/// What the map knows about a voxel.
public enum VoxelState: Sendable, Equatable {
    /// No ray has reached it, or the evidence either way is too thin to say.
    case unknown
    /// Rays passed through it.
    case free
    /// Rays stopped in it: something is there.
    case surface
}

/// Where a voxel's evidence came from. A voxel can have several.
public struct VoxelSources: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// LiDAR depth rays.
    public static let lidar = VoxelSources(rawValue: 1 << 0)
    /// ARKit's reconstructed mesh (labels and shape only: a mesh face carries no camera).
    public static let mesh = VoxelSources(rawValue: 1 << 1)
    /// Rays to detected planes, cast from a camera without LiDAR.
    public static let plane = VoxelSources(rawValue: 1 << 2)
    /// Rays to tracked feature points.
    public static let feature = VoxelSources(rawValue: 1 << 3)
    /// Rays of estimated (monocular) depth.
    public static let estimated = VoxelSources(rawValue: 1 << 4)
}

/// A voxel's evidence, read out of the map.
public struct VoxelEvidence: Sendable, Equatable {
    public var state: VoxelState
    /// Frames whose rays stopped in the voxel.
    public var hits: Int
    /// Frames whose rays passed through it without any stopping there.
    public var passes: Int
    /// Nearest camera distance of a ray that stopped here, meters; nil without hits.
    public var nearestDistance: Float?
    /// Smallest angle between a ray that stopped here and the surface normal at that point,
    /// radians; nil when no hit had a normal.
    public var bestViewAngle: Float?
    /// Unit surface normal, averaged over hits; nil when none had one.
    public var normal: SIMD3<Float>?
    /// ARKit's classification of the mesh here; nil where no classified mesh face fell.
    public var meshClass: MeshClass?
    public var sources: VoxelSources
}

/// One voxel, packed into 16 bytes.
struct Voxel {
    var logOdds: Int16 = 0
    var hits: UInt16 = 0
    var passes: UInt16 = 0
    /// Nearest hit distance in centimeters; `UInt16.max` without hits.
    var nearestCm: UInt16 = .max
    /// The frame that last updated `logOdds`, so one frame counts once.
    var stamp: UInt16 = 0
    /// Largest |cos| between a hit's ray and its normal, times 255.
    var bestCos: UInt8 = 0
    /// `MeshClass` raw value plus one; 0 for none recorded.
    var meshLabel: UInt8 = 0
    var sources: UInt8 = 0
    /// Unit normal times 127; all zero when unknown.
    var nx: Int8 = 0
    var ny: Int8 = 0
    var nz: Int8 = 0

    var normal: SIMD3<Float>? {
        guard nx != 0 || ny != 0 || nz != 0 else { return nil }
        return simd_normalize(SIMD3(Float(nx), Float(ny), Float(nz)))
    }

    mutating func setNormal(_ n: SIMD3<Float>) {
        let q: SIMD3<Float> = (simd_normalize(n) * Float(127)).rounded(.toNearestOrAwayFromZero)
        nx = Int8(q.x)
        ny = Int8(q.y)
        nz = Int8(q.z)
    }
}

/// One ray to integrate, in map coordinates, from the frame's camera.
struct RaySample {
    /// Where the ray stopped.
    var end: SIMD3<Float>
    /// Unit normal of the surface at `end`, facing the camera; zero when unknown.
    var normal: SIMD3<Float>
    /// Free space is carved along the ray up to this distance from the camera.
    var freeLength: Float
    /// Whether `end` is marked as a surface.
    var hit: Bool
}

/// Sparse voxels over fixed bounds: a dense index of 8 x 8 x 8 bricks, each brick stored only
/// once a ray reaches it. Memory is bounded by the bounds (`worstCaseBytes`).
struct VoxelGrid {
    static let brickShift: Int32 = 3
    static let brickEdge: Int32 = 1 << brickShift
    static let brickVolume = Int(brickEdge * brickEdge * brickEdge)

    let origin: SIMD3<Float>
    let voxelSize: Float
    /// Voxels along each axis, a whole number of bricks.
    let dims: SIMD3<Int32>
    let brickDims: SIMD3<Int32>
    /// Per brick, its first voxel in `pool`, or -1 while not stored.
    private(set) var brickSlot: [Int32]
    private(set) var pool: [Voxel] = []
    private var frameStamp: UInt16 = 0

    /// Covers `bounds` with voxels centred on whole multiples of `voxelSize`, so the meter's
    /// ground (y = 0) and wall face (z = 0) run through voxel centers rather than along voxel
    /// faces, where rounding would split one surface between two layers.
    init(bounds: MapBounds, voxelSize: Float) {
        origin = ((bounds.min / voxelSize + 0.5).rounded(.down) - 0.5) * voxelSize
        self.voxelSize = voxelSize
        let voxels = SIMD3<Int32>(((bounds.max - origin) / voxelSize).rounded(.up))
        brickDims = (voxels &+ (Self.brickEdge &- 1)) &>> Self.brickShift
        dims = brickDims &<< Self.brickShift
        brickSlot = Array(repeating: -1, count: Int(brickDims.x) * Int(brickDims.y) * Int(brickDims.z))
    }

    /// Bytes held now: the brick index plus stored bricks.
    var allocatedBytes: Int {
        brickSlot.count * MemoryLayout<Int32>.stride + pool.capacity * MemoryLayout<Voxel>.stride
    }

    /// Bytes with every brick stored.
    var worstCaseBytes: Int {
        brickSlot.count * MemoryLayout<Int32>.stride + brickSlot.count * Self.brickVolume * MemoryLayout<Voxel>.stride
    }

    // MARK: Addressing

    func coordinate(of p: SIMD3<Float>) -> SIMD3<Int32>? {
        let g = SIMD3<Int32>(((p - origin) / voxelSize).rounded(.down))
        guard all(g .>= 0), all(g .< dims) else { return nil }
        return g
    }

    func center(of g: SIMD3<Int32>) -> SIMD3<Float> {
        origin + (SIMD3<Float>(g) + 0.5) * voxelSize
    }

    @inline(__always)
    private func brickIndex(_ g: SIMD3<Int32>) -> Int {
        let b = g &>> Self.brickShift
        return Int(b.x) + Int(brickDims.x) * (Int(b.y) + Int(brickDims.y) * Int(b.z))
    }

    @inline(__always)
    private static func local(_ g: SIMD3<Int32>) -> Int {
        let l = g & (brickEdge &- 1)
        return Int(l.x | (l.y << brickShift) | (l.z << (2 * brickShift)))
    }

    /// Index into `pool`, or nil when the brick is not stored.
    func index(_ g: SIMD3<Int32>) -> Int? {
        let slot = brickSlot[brickIndex(g)]
        return slot < 0 ? nil : Int(slot) + Self.local(g)
    }

    @inline(__always)
    private mutating func storedIndex(_ g: SIMD3<Int32>) -> Int {
        let b = brickIndex(g)
        var slot = brickSlot[b]
        if slot < 0 {
            slot = Int32(pool.count)
            if pool.count + Self.brickVolume > pool.capacity {
                // Doubling as an array does, but never past every brick of the bounds.
                pool.reserveCapacity(min(brickSlot.count * Self.brickVolume, max(2 * pool.capacity, 64 * Self.brickVolume)))
            }
            pool.append(contentsOf: repeatElement(Voxel(), count: Self.brickVolume))
            brickSlot[b] = slot
        }
        return Int(slot) + Self.local(g)
    }

    func voxel(_ g: SIMD3<Int32>) -> Voxel? {
        index(g).map { pool[$0] }
    }

    func voxel(at p: SIMD3<Float>) -> Voxel? {
        coordinate(of: p).flatMap(voxel)
    }

    /// Calls `body` with the coordinate and value of every stored voxel.
    func forEachStored(_ body: (SIMD3<Int32>, Voxel) -> Void) {
        for bz in 0..<brickDims.z {
            for by in 0..<brickDims.y {
                for bx in 0..<brickDims.x {
                    let slot = brickSlot[Int(bx) + Int(brickDims.x) * (Int(by) + Int(brickDims.y) * Int(bz))]
                    guard slot >= 0 else { continue }
                    let base = SIMD3(bx, by, bz) &<< Self.brickShift
                    for lz in 0..<Self.brickEdge {
                        for ly in 0..<Self.brickEdge {
                            for lx in 0..<Self.brickEdge {
                                let g = base &+ SIMD3(lx, ly, lz)
                                body(g, pool[Int(slot) + Self.local(g)])
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Integration

    /// Integrates one frame's rays from `camera` (map coordinates). Hits first, so a voxel both
    /// hit and passed through in one frame counts as hit (OctoMap's rule); then free space along
    /// each ray, each voxel counted once per frame.
    mutating func integrate(camera: SIMD3<Float>, rays: [RaySample], sources: VoxelSources, config: Map3DConfig) {
        frameStamp = frameStamp == .max ? 1 : frameStamp + 1
        let stamp = frameStamp
        for ray in rays where ray.hit {
            guard let g = coordinate(of: ray.end) else { continue }
            let i = storedIndex(g)
            let offset = ray.end - camera
            let distance = simd_length(offset)
            let cosine = simd_length_squared(ray.normal) > 0 ? abs(simd_dot(ray.normal, offset / distance)) : 0
            pool[i].recordHit(
                stamp: stamp, distance: distance, cosine: cosine, normal: ray.normal, sources: sources.rawValue,
                config: config)
        }
        for ray in rays where ray.freeLength > 0 {
            carveFree(from: camera, to: ray.end, length: ray.freeLength, stamp: stamp, config: config)
        }
    }

    /// Marks the voxels a segment from `from` toward `to` passes through, up to `length`, as
    /// passed through (3D DDA, Amanatides and Woo 1987), clipped to the grid.
    private mutating func carveFree(from: SIMD3<Float>, to: SIMD3<Float>, length: Float, stamp: UInt16, config: Map3DConfig) {
        let span = to - from
        let total = simd_length(span)
        guard total > 0 else { return }
        let direction = span / total
        guard let (start, end) = clip(from: from, direction: direction, length: min(length, total)) else { return }
        var g = SIMD3<Int32>(((from + direction * start - origin) / voxelSize).rounded(.down))
        g = simd_clamp(g, .zero, dims &- 1)
        let step = Self.step(direction)
        let inverse = 1 / direction
        let boundary = origin + SIMD3<Float>(g &+ SIMD3<Int32>(repeating: 0).replacing(with: 1, where: step .> 0)) * voxelSize
        // Distance along the ray to the next voxel boundary on each axis, and between boundaries.
        var tMax = SIMD3<Float>(repeating: .infinity)
        var tDelta = SIMD3<Float>(repeating: .infinity)
        for axis in 0..<3 where step[axis] != 0 {
            tMax[axis] = (boundary[axis] - from[axis]) * inverse[axis]
            tDelta[axis] = voxelSize * abs(inverse[axis])
        }
        let miss = config.missLogOdds
        let floor = config.minLogOdds
        while true {
            pool[storedIndex(g)].recordPass(stamp: stamp, miss: miss, floor: floor)
            let axis = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2)
            guard tMax[axis] < end else { return }
            g[axis] &+= step[axis]
            guard g[axis] >= 0, g[axis] < dims[axis] else { return }
            tMax[axis] += tDelta[axis]
        }
    }

    @inline(__always)
    private static func step(_ direction: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(repeating: 0).replacing(with: 1, where: direction .> 0).replacing(with: -1, where: direction .< 0)
    }

    /// The part of a ray from `from` along unit `direction`, up to `length`, inside the grid, as
    /// distances along it; nil when it misses.
    func clip(from: SIMD3<Float>, direction: SIMD3<Float>, length: Float) -> (Float, Float)? {
        let upper = origin + SIMD3<Float>(dims) * voxelSize
        var near: Float = 0
        var far = length
        for axis in 0..<3 {
            if direction[axis] == 0 {
                guard from[axis] >= origin[axis], from[axis] < upper[axis] else { return nil }
                continue
            }
            let a = (origin[axis] - from[axis]) / direction[axis]
            let b = (upper[axis] - from[axis]) / direction[axis]
            near = max(near, min(a, b))
            far = min(far, max(a, b))
        }
        return near < far ? (near, far) : nil
    }

    /// Walks the voxels a ray passes through, from `from` along unit `direction`, up to `length`,
    /// calling `body` with each voxel's coordinate and the distance at which the ray enters it
    /// until `body` returns false. Voxels not stored are passed as nil. Read-only.
    func march(from: SIMD3<Float>, direction: SIMD3<Float>, length: Float, _ body: (SIMD3<Int32>, Voxel?, Float) -> Bool) {
        guard let (start, end) = clip(from: from, direction: direction, length: length) else { return }
        var g = SIMD3<Int32>(((from + direction * start - origin) / voxelSize).rounded(.down))
        g = simd_clamp(g, .zero, dims &- 1)
        let step = Self.step(direction)
        let inverse = 1 / direction
        let boundary = origin + SIMD3<Float>(g &+ SIMD3<Int32>(repeating: 0).replacing(with: 1, where: step .> 0)) * voxelSize
        var tMax = SIMD3<Float>(repeating: .infinity)
        var tDelta = SIMD3<Float>(repeating: .infinity)
        for axis in 0..<3 where step[axis] != 0 {
            tMax[axis] = (boundary[axis] - from[axis]) * inverse[axis]
            tDelta[axis] = voxelSize * abs(inverse[axis])
        }
        var entered = start
        while true {
            guard body(g, voxel(g), entered) else { return }
            let axis = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2)
            guard tMax[axis] < end else { return }
            entered = tMax[axis]
            g[axis] &+= step[axis]
            guard g[axis] >= 0, g[axis] < dims[axis] else { return }
            tMax[axis] += tDelta[axis]
        }
    }

    // MARK: Mesh

    /// Labels the voxels a mesh face falls in; returns their `pool` indices.
    mutating func markMesh(_ triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), meshClass: MeshClass?) -> [Int32] {
        let (a, b, c) = triangle
        let normal = simd_cross(b - a, c - a)
        guard simd_length_squared(normal) > 0 else { return [] }
        let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
        // Samples half a voxel apart, so no voxel the face crosses is skipped.
        let n = max(1, Int((longest / (voxelSize / 2)).rounded(.up)))
        var marked: [Int32] = []
        var last = -1
        for i in 0...n {
            for j in 0...(n - i) {
                let p = a + (b - a) * (Float(i) / Float(n)) + (c - a) * (Float(j) / Float(n))
                guard let g = coordinate(of: p) else { continue }
                let index = storedIndex(g)
                guard index != last else { continue }
                last = index
                pool[index].recordMesh(normal: normal, meshClass: meshClass)
                marked.append(Int32(index))
            }
        }
        return marked
    }

    mutating func clearMesh(_ indices: [Int32]) {
        for index in indices {
            pool[Int(index)].sources &= ~VoxelSources.mesh.rawValue
            pool[Int(index)].meshLabel = 0
        }
    }
}

extension Voxel {
    @inline(__always)
    mutating func recordPass(stamp: UInt16, miss: Int16, floor: Int16) {
        guard self.stamp != stamp else { return }
        self.stamp = stamp
        logOdds = max(floor, logOdds &+ miss)
        if passes < .max { passes += 1 }
    }

    @inline(__always)
    mutating func recordHit(stamp: UInt16, distance: Float, cosine: Float, normal: SIMD3<Float>, sources: UInt8, config: Map3DConfig) {
        if self.stamp != stamp {
            self.stamp = stamp
            logOdds = min(config.maxLogOdds, logOdds &+ config.hitLogOdds)
            if simd_length_squared(normal) > 0 {
                // A running mean over up to 16 frames, so a normal keeps adapting as views improve.
                let weight = Float(min(hits, 16))
                setNormal((self.normal ?? .zero) * weight + normal)
            }
            if hits < .max { hits += 1 }
        }
        nearestCm = min(nearestCm, UInt16(min(Float(UInt16.max - 1), distance * 100)))
        bestCos = max(bestCos, UInt8(min(255, (cosine * 255).rounded())))
        self.sources |= sources
    }

    mutating func recordMesh(normal: SIMD3<Float>, meshClass: MeshClass?) {
        sources |= VoxelSources.mesh.rawValue
        if let meshClass, meshClass != .none || meshLabel == 0 { meshLabel = meshClass.rawValue + 1 }
        // Mesh winding is not trusted to face the camera, so a mesh normal only fills in a
        // voxel no ray has given one.
        if self.normal == nil { setNormal(normal) }
    }

    func evidence(_ config: Map3DConfig) -> VoxelEvidence {
        VoxelEvidence(
            state: state(config), hits: Int(hits), passes: Int(passes),
            nearestDistance: nearestCm == .max ? nil : Float(nearestCm) / 100,
            bestViewAngle: bestCos == 0 ? nil : acos(Float(bestCos) / 255),
            normal: normal, meshClass: meshLabel == 0 ? nil : MeshClass(rawValue: meshLabel - 1),
            sources: VoxelSources(rawValue: sources))
    }

    func state(_ config: Map3DConfig) -> VoxelState {
        if logOdds >= config.surfaceLogOdds, hits > 0 { return .surface }
        if logOdds <= config.freeLogOdds, passes > 0 { return .free }
        return .unknown
    }

    /// A surface seen well enough to count as coverage: from within `maxViewDistance`, from
    /// within `maxViewAngle` of its normal, by a ray that measured it (not a mesh face or a
    /// feature point alone, which carry no normal).
    func isWellSeenSurface(_ config: Map3DConfig) -> Bool {
        state(config) == .surface
            && Float(nearestCm) / 100 <= config.maxViewDistance
            && Float(bestCos) / 255 >= cos(config.maxViewAngle)
    }
}
