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
    /// A detected plane, where a camera without LiDAR saw it (shape only, like the mesh).
    public static let plane = VoxelSources(rawValue: 1 << 2)
    /// Rays to tracked feature points.
    public static let feature = VoxelSources(rawValue: 1 << 3)
    /// Rays of estimated (monocular) depth.
    public static let estimated = VoxelSources(rawValue: 1 << 4)
    /// A LiDAR or feature ray passed through: the voxel's free space was measured, not estimated.
    public static let measuredPass = VoxelSources(rawValue: 1 << 5)
    /// What a ray that measured the voxel, rather than estimated or outlined it, leaves.
    static let measuredHit: VoxelSources = [.lidar, .feature]
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

    /// Leaves the normal as it is when `n` has no direction (two opposite normals averaged).
    mutating func setNormal(_ n: SIMD3<Float>) {
        guard simd_length_squared(n) > 1e-12 else { return }
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
    /// |cos| between the ray and the surface normal, when the caller knows it better than the
    /// two directions do: an estimated ray's is widened for its normal's error. Nil takes it from
    /// `normal` and the ray.
    var cosine: Float?
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

    /// Covers `bounds` with voxels one of which is centred on `center`, so the planes through it
    /// (the meter's ground and wall face) run through voxel centers rather than along voxel
    /// faces, where rounding would split one surface between two layers.
    init(bounds: MapBounds, voxelSize: Float, center: SIMD3<Float>) {
        origin = center + (((bounds.min - center) / voxelSize + 0.5).rounded(.down) - 0.5) * voxelSize
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
    /// Estimated rays leave evidence that tells seen from unknown (the fog of war, the next
    /// view) but never certifies coverage: an estimated hit changes neither a voxel's viewing
    /// evidence nor the normal of one a measured ray hit, and an estimated pass neither lowers a
    /// voxel a measured ray hit nor makes one measured free (`VoxelSources.measuredPass`).
    mutating func integrate(camera: SIMD3<Float>, rays: [RaySample], sources: VoxelSources, config: Map3DConfig) {
        frameStamp = frameStamp == .max ? 1 : frameStamp + 1
        let stamp = frameStamp
        let measured = !sources.isDisjoint(with: VoxelSources.measuredHit)
        for ray in rays where ray.hit {
            guard let g = coordinate(of: ray.end) else { continue }
            let i = storedIndex(g)
            let offset = ray.end - camera
            let distance = simd_length(offset)
            let cosine = ray.cosine ?? (simd_length_squared(ray.normal) > 0 ? abs(simd_dot(ray.normal, offset / distance)) : 0)
            pool[i].recordHit(
                stamp: stamp, distance: distance, cosine: cosine, normal: ray.normal, sources: sources.rawValue, measured: measured, config: config)
        }
        for ray in rays where ray.freeLength > 0 {
            carveFree(from: camera, to: ray.end, length: ray.freeLength, stamp: stamp, measured: measured, config: config)
        }
    }

    /// A surface seen well enough to count as coverage (`Voxel.isWellSeenSurface`) by a ray that
    /// measured it: LiDAR or a feature point. Estimated depth never certifies one. The review of
    /// 2f17d67 made estimated hits claim walls behind occluders several ways; the fog of war and
    /// the next view still read estimated evidence through `Voxel.state`.
    func isWellSeenSurface(_ index: Int, config: Map3DConfig) -> Bool {
        let voxel = pool[index]
        return voxel.isWellSeenSurface(config) && !VoxelSources(rawValue: voxel.sources).isDisjoint(with: VoxelSources.measuredHit)
    }

    func isWellSeenSurface(_ g: SIMD3<Int32>, config: Map3DConfig) -> Bool {
        index(g).map { isWellSeenSurface($0, config: config) } ?? false
    }

    /// Free, and a measured ray passed through it: what the coverage bands count as free.
    func isMeasuredFree(_ g: SIMD3<Int32>, config: Map3DConfig) -> Bool {
        guard let voxel = voxel(g) else { return false }
        return voxel.state(config) == .free && voxel.sources & VoxelSources.measuredPass.rawValue != 0
    }

    /// Marks the voxels a segment from `from` toward `to` crosses completely within `length` as
    /// passed through (3D DDA, Amanatides and Woo 1987), clipped to the grid. A voxel the
    /// segment only enters is left alone: the ray ended somewhere past its free length, which
    /// may lie inside that voxel, so only voxels it left again are known empty.
    private mutating func carveFree(from: SIMD3<Float>, to: SIMD3<Float>, length: Float, stamp: UInt16, measured: Bool, config: Map3DConfig) {
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
            let axis = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2)
            guard tMax[axis] <= end else { return }
            pool[storedIndex(g)].recordPass(stamp: stamp, miss: miss, floor: floor, surface: config.surfaceLogOdds, measured: measured)
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

    // MARK: Mesh and planes

    /// Labels the voxels a mesh face falls in and gives them the face's normal where no ray
    /// gave one; returns their `pool` indices. `retain` then marks them as mesh.
    mutating func markMesh(_ triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), meshClass: MeshClass?) -> Set<Int32> {
        let (a, b, c) = triangle
        let normal = simd_cross(b - a, c - a)
        guard simd_length_squared(normal) > 0 else { return [] }
        let longest = max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a))
        // Samples half a voxel apart, so no voxel the face crosses is skipped.
        let n = max(1, Int((longest / (voxelSize / 2)).rounded(.up)))
        var marked: Set<Int32> = []
        for i in 0...n {
            for j in 0...(n - i) {
                let p = a + (b - a) * (Float(i) / Float(n)) + (c - a) * (Float(j) / Float(n))
                guard let g = coordinate(of: p) else { continue }
                let index = storedIndex(g)
                guard marked.insert(Int32(index)).inserted else { continue }
                pool[index].recordMesh(normal: normal, meshClass: meshClass)
            }
        }
        return marked
    }

    /// The voxel a detected plane was seen at, given the plane's normal where no ray gave one.
    mutating func markPlane(at point: SIMD3<Float>, normal: SIMD3<Float>) -> Int32? {
        guard let g = coordinate(of: point) else { return nil }
        let index = storedIndex(g)
        if pool[index].normal == nil { pool[index].setNormal(normal) }
        return Int32(index)
    }

    /// How many mesh chunks (x) and detected planes (y) mark each voxel. A voxel carries the
    /// `.mesh` or `.plane` source while its count is above zero, so replacing or removing one
    /// chunk or plane leaves the marks of the others alone.
    private(set) var marks: [Int32: SIMD2<UInt16>] = [:]

    mutating func retain(_ indices: some Sequence<Int32>, as source: VoxelSources) {
        let lane = source == .mesh ? 0 : 1
        for index in indices {
            var count = marks[index] ?? .zero
            count[lane] &+= 1
            marks[index] = count
            pool[Int(index)].sources |= source.rawValue
        }
    }

    /// Undoes `retain`. At zero the source goes, with the mesh label for mesh; a voxel no ray
    /// hit and nothing marks any more loses the normal a mark gave it.
    mutating func release(_ indices: some Sequence<Int32>, as source: VoxelSources) {
        let lane = source == .mesh ? 0 : 1
        for index in indices {
            guard var count = marks[index], count[lane] > 0 else { continue }
            count[lane] -= 1
            let i = Int(index)
            if count[lane] == 0 {
                pool[i].sources &= ~source.rawValue
                if source == .mesh { pool[i].meshLabel = 0 }
            }
            if count == .zero {
                marks[index] = nil
                if pool[i].hits == 0 { pool[i].nx = 0; pool[i].ny = 0; pool[i].nz = 0 }
            } else {
                marks[index] = count
            }
        }
    }
}

extension Voxel {
    @inline(__always)
    /// A voxel that stops being surface loses its viewing evidence, so it counts as seen again
    /// only on a new observation.
    mutating func recordPass(stamp: UInt16, miss: Int16, floor: Int16, surface: Int16, measured: Bool) {
        guard self.stamp != stamp else { return }
        // An estimate can't take back what a measured ray found, such as an occluder LiDAR saw.
        guard measured || sources & VoxelSources.measuredHit.rawValue == 0 else { return }
        if measured { sources |= VoxelSources.measuredPass.rawValue }
        self.stamp = stamp
        logOdds = max(floor, logOdds &+ miss)
        if passes < .max { passes += 1 }
        if logOdds < surface {
            nearestCm = .max
            bestCos = 0
        }
    }

    @inline(__always)
    mutating func recordHit(
        stamp: UInt16, distance: Float, cosine: Float, normal: SIMD3<Float>, sources: UInt8, measured: Bool, config: Map3DConfig
    ) {
        // Estimated evidence is not allowed to shape what a measured ray found.
        let keepsMeasured = !measured && self.sources & VoxelSources.measuredHit.rawValue != 0
        if self.stamp != stamp {
            self.stamp = stamp
            // A measured hit means something is there now, however long the space was seen
            // empty: start from even odds, so one hit is surface, never still free.
            logOdds = min(config.maxLogOdds, max(logOdds, 0) &+ config.hitLogOdds)
            if simd_length_squared(normal) > 0, !keepsMeasured {
                // A running mean over up to 16 frames, so a normal keeps adapting as views improve.
                let weight = Float(min(hits, 16))
                setNormal((self.normal ?? .zero) * weight + normal)
            }
            if hits < .max { hits += 1 }
        }
        nearestCm = min(nearestCm, UInt16(min(Float(UInt16.max - 1), distance * 100)))
        // The best angle only from measured views within range, so one view is both near enough
        // and square enough when the voxel counts as well seen.
        if measured, distance <= config.maxViewDistance {
            bestCos = max(bestCos, UInt8(min(255, (cosine * 255).rounded(.down))))
        }
        self.sources |= sources
    }

    mutating func recordMesh(normal: SIMD3<Float>, meshClass: MeshClass?) {
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

    /// A surface seen well enough to count as coverage: by one view from within
    /// `maxViewDistance` and within `maxViewAngle` of its normal, a ray that measured it (not a
    /// mesh face or a plane, and not a feature point off every plane, which carries no normal).
    func isWellSeenSurface(_ config: Map3DConfig) -> Bool {
        state(config) == .surface && Float(bestCos) / 255 >= cos(config.maxViewAngle)
    }
}
