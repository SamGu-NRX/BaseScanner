import simd

// The live dots a LiDAR phone draws over the camera: the prototype's dot field
// (experiments/live-dots on t3/experience, `LiveDotsCore/DotField.swift`), bounded for a phone.
//
// Each kept keyframe's depth, every second pixel of it, with medium or high confidence and from
// 0.3 to 5 m, is unprojected and fused into 5 cm voxels. A voxel keeps its distinct view
// directions (a new one must differ from every stored one by more than 15 degrees, four at
// most), a normal from central differences on the depth map (averaged over keyframes), the most
// face-on view it has had, and a fixed jitter of up to 30% of the voxel in the plane of its
// first normal, so the field never reads as a grid.
//
// A voxel becomes an edge, and stays one, when
//   (a) a face neighbour's normal differs by more than 35 degrees (the wall-to-ground corner, a
//       bin's corners), or
//   (b) it has surface along one side and seen-empty space along another (a bin's silhouette).
//       Seen-empty means a confident depth reading passed the neighbour with 10 cm to spare, so
//       the edge of what has been scanned so far is never an edge.
// The prototype's third rule, a colour step in the photo (painted outlines), is left out: it
// needs the camera image at depth resolution on every keyframe, and the things this scan cares
// about (meters, bins, AC units) stand off the wall, so (a) and (b) find them.
//
// Every edge voxel gets a dot. Flat voxels get one per 2 x 2 x 2 group, chosen once by lowest
// hash and kept, a quarter of the edge density on a wall. Opacity is 45% at one view and rises
// 15 points a view to 90% at four. An edge on a surface within 45 degrees of vertical stays at or
// below 60% until one view saw it within 30 degrees of face-on. A dot more than 25 cm in front of
// the wall and more than 10 cm above the ground is on an occluder, and draws violet.
//
// The dots are guidance, never evidence: coverage (`CoverageMap`) decides what the scan has
// seen, from the same keyframes, and nothing here feeds it.

public typealias VoxelKey = SIMD3<Int32>

public struct SurfaceDotConfig: Sendable, Equatable {
    public var voxelSize: Float = 0.05
    /// ARKit confidence: 0 low, 1 medium, 2 high.
    public var minimumConfidence: UInt8 = 1
    /// 5 m, not the prototype's 6: ARKit's confidence falls off past about 5 m outdoors, and
    /// coverage does not count views from farther than `CoverageConfig.maxDistance` (6 m) anyway.
    public var depthRange: ClosedRange<Float> = 0.3...5
    /// Every `sampleStride`-th depth pixel on both axes. At 2, a 256 x 192 map gives 12,288
    /// samples, and a pixel step at 5 m (about 5 cm) still reaches every 5 cm voxel it crosses.
    public var sampleStride: Int = 2
    public var viewSeparationDegrees: Float = 15
    public var creaseDegrees: Float = 35
    /// A face neighbour lies along the surface when its direction is within 60 degrees of the
    /// tangent plane.
    public var alongSurfaceCosine: Float = 0.5
    public var freeSpaceMargin: Float = 0.1
    public var jitterFraction: Float = 0.3
    public var faceOnDegrees: Float = 30
    public var obliqueEdgeOpacityCap: Float = 0.6
    /// The oblique cap applies to edges whose normal is within 45 degrees of horizontal.
    public var cappedNormalMaxY: Float = 0.7071
    public var occluderMinOut: Float = 0.25
    public var groundBand: Float = 0.1
    /// Voxels kept at once. Past it, the ones farthest from the camera go first, down to 75%.
    /// A voxel costs about 100 bytes with its dictionary entry, so 60,000 is about 6 MB; a 20 m
    /// walk with the wall and the ground in front of it is about 25,000 surface voxels. Not
    /// measured on a phone.
    public var maxVoxels: Int = 60_000
    /// Most dots handed to the renderer. The prototype drew 6,000 in 0.54 ms of an M4 Pro's GPU;
    /// a phone GPU is several times slower and also draws the camera, so 5,000. Not measured on
    /// a phone.
    public var maxDots: Int = 5_000
    /// Dots farther than this from the latest camera are not handed out: off screen or too small
    /// to matter, and they would crowd nearer ones out of `maxDots`.
    public var dotRadius: Float = 6

    public init() {}
}

/// One dot as the renderer draws it, before timing.
public struct SurfaceDot: Sendable, Equatable {
    /// Stable for the life of the voxel, so the renderer can tell a birth from a survivor.
    public let id: UInt64
    public let position: SIMD3<Float>
    public let isEdge: Bool
    /// Distinct view directions so far, up to four.
    public let views: Int
    /// Some view saw it within `faceOnDegrees` of face-on. Only edge dots are ever false.
    public let faceOn: Bool
    /// On something standing in front of the wall (a bin, a bush), drawn violet.
    public let onOccluder: Bool
    /// 0.45 at one view to 0.9 at four, capped at 0.6 for an edge never seen face-on.
    public let opacity: Float

    public init(id: UInt64, position: SIMD3<Float>, isEdge: Bool, views: Int, faceOn: Bool, onOccluder: Bool, opacity: Float) {
        self.id = id
        self.position = position
        self.isEdge = isEdge
        self.views = views
        self.faceOn = faceOn
        self.onOccluder = onOccluder
        self.opacity = opacity
    }

    public static func opacity(views: Int, faceOn: Bool, cap: Float) -> Float {
        guard views > 0 else { return 0 }
        let level = min(0.45 + 0.15 * Float(views - 1), 0.9)
        return faceOn ? level : min(level, cap)
    }
}

/// Up to four unit directions, stored inline so a voxel needs no heap allocation.
struct ViewSet: Sendable, Equatable {
    private var d0 = SIMD3<Float>.zero, d1 = SIMD3<Float>.zero, d2 = SIMD3<Float>.zero, d3 = SIMD3<Float>.zero
    private(set) var count: UInt8 = 0
    /// Opacity stops rising at four views.
    static let capacity: UInt8 = 4

    func direction(_ index: Int) -> SIMD3<Float> {
        switch index {
        case 0: d0
        case 1: d1
        case 2: d2
        default: d3
        }
    }

    /// Adds `unit` when it differs from every stored direction by more than the angle whose
    /// cosine is `limit`. Returns whether it was added.
    @discardableResult
    mutating func insert(_ unit: SIMD3<Float>, limit: Float) -> Bool {
        guard count < Self.capacity else { return false }
        for index in 0..<Int(count) where simd_dot(direction(index), unit) >= limit { return false }
        switch count {
        case 0: d0 = unit
        case 1: d1 = unit
        case 2: d2 = unit
        default: d3 = unit
        }
        count += 1
        return true
    }
}

struct Voxel: Sendable, Equatable {
    /// Sum of per-keyframe unit normals.
    var normalSum: SIMD3<Float>
    var views: ViewSet
    /// Highest cosine between a view direction and the voxel's normal at that view.
    var faceOnCosine: Float
    /// Fixed at the first hit, in the plane of the first normal.
    var jitter: SIMD3<Float>
    /// Sticky: an edge never turns back into a flat dot.
    var isEdge: Bool

    var normal: SIMD3<Float>? {
        let length = simd_length(normalSum)
        return length > 1e-3 ? normalSum / length : nil
    }
}

/// The LiDAR dot field. A value type confined to one owner; `integrate` is the hot path and
/// touches only the voxels this keyframe saw and their face neighbours.
///
/// Voxels live in the field's own frame, fixed at the first keyframe; `toWorld` carries them into
/// ARKit's world. An anchor correction changes only `toWorld`, so it is exact and costs nothing:
/// moving the voxels would snap them back to the 5 cm grid, and a run of 2 cm corrections would
/// leave the dots where they were while the wall moved.
public struct SurfaceDots: Sendable {
    public let config: SurfaceDotConfig
    /// Field frame to world. Identity until the first correction.
    private var toWorld = matrix_identity_float4x4
    private var toField = matrix_identity_float4x4
    private(set) var voxels: [VoxelKey: Voxel] = [:]
    /// Voxels a confident depth reading passed with room to spare. Only in-plane neighbours of
    /// occupied voxels are tested, which is all the boundary rule needs.
    private(set) var free: Set<VoxelKey> = []
    /// Each 2 x 2 x 2 group's flat voxel, keyed by the group.
    private var representatives: [VoxelKey: VoxelKey] = [:]

    static let faceAxes: [VoxelKey] = [
        VoxelKey(1, 0, 0), VoxelKey(-1, 0, 0), VoxelKey(0, 1, 0),
        VoxelKey(0, -1, 0), VoxelKey(0, 0, 1), VoxelKey(0, 0, -1),
    ]

    public init(config: SurfaceDotConfig = SurfaceDotConfig()) {
        self.config = config
    }

    public var voxelCount: Int { voxels.count }
    public var isEmpty: Bool { voxels.isEmpty }

    public func key(for p: SIMD3<Float>) -> VoxelKey {
        VoxelKey((p / config.voxelSize).rounded(.toNearestOrAwayFromZero))
    }

    public func centre(of key: VoxelKey) -> SIMD3<Float> {
        SIMD3<Float>(key) * config.voxelSize
    }

    // MARK: Keyframes

    /// Fuses one keyframe's depth. `depth` is ARKit's scene depth for `camera`, in the landscape
    /// sensor orientation, with intrinsics for its own grid (`DepthImage.intrinsics(scaling:)`).
    public mutating func integrate(camera world: CameraFrame, depth: DepthImage) {
        let step = max(config.sampleStride, 1)
        let camera = CameraFrame(cameraToWorld: toField * world.cameraToWorld, intrinsics: world.intrinsics, imageSize: world.imageSize)
        let pose = camera.cameraToWorld
        let eye = camera.position

        struct Accumulator { var normals = 0; var normalSum = SIMD3<Float>.zero }
        var accumulators: [VoxelKey: Accumulator] = [:]
        accumulators.reserveCapacity(depth.width * depth.height / (step * step * 4))
        for j in stride(from: step / 2, to: depth.height, by: step) {
            for i in stride(from: step / 2, to: depth.width, by: step) {
                guard let d = reading(depth, i, j) else { continue }
                let local = Self.unproject(i, j, d, depth.intrinsics)
                let world4 = pose * SIMD4(local, 1)
                let world = SIMD3(world4.x, world4.y, world4.z)
                let key = key(for: world)
                var accumulator = accumulators[key] ?? Accumulator()
                if let normal = cameraNormal(depth, i, j, d, step: step) {
                    let rotated = pose * SIMD4(normal, 0)
                    accumulator.normals += 1
                    accumulator.normalSum += SIMD3(rotated.x, rotated.y, rotated.z)
                }
                accumulators[key] = accumulator
            }
        }
        let limit = cos(config.viewSeparationDegrees * .pi / 180)
        for (key, a) in accumulators {
            observe(key, normal: a.normals > 0 ? a.normalSum / Float(a.normals) : nil, camera: eye, viewLimit: limit)
        }
        let touched = Set(accumulators.keys)
        carveFreeSpace(around: touched, camera: camera, depth: depth)
        classify(touched)
        bound(around: eye)
    }

    /// Records one keyframe's samples in a voxel.
    mutating func observe(_ key: VoxelKey, normal: SIMD3<Float>?, camera: SIMD3<Float>, viewLimit: Float) {
        let centre = centre(of: key)
        var voxel = voxels[key] ?? Voxel(
            normalSum: .zero, views: ViewSet(), faceOnCosine: -1,
            jitter: Self.jitter(for: key, normal: normal ?? SIMD3(0, 0, 1), radius: config.jitterFraction * config.voxelSize),
            isEdge: false)
        if let normal, simd_length(normal) > 1e-3 { voxel.normalSum += simd_normalize(normal) }
        let toCamera = camera - centre
        let distance = simd_length(toCamera)
        if distance > 1e-6 {
            let unit = toCamera / distance
            voxel.views.insert(unit, limit: viewLimit)
            if let current = voxel.normal { voxel.faceOnCosine = max(voxel.faceOnCosine, simd_dot(unit, current)) }
        }
        voxels[key] = voxel
        free.remove(key)
    }

    /// Tests the empty in-plane neighbours of this keyframe's voxels against its depth: a
    /// neighbour is seen-empty when a confident reading at its pixel is farther than it by
    /// `freeSpaceMargin`. A neighbour outside the view, behind something, or under a low-confidence
    /// reading stays unknown, which is why the edge of what has been scanned so far never counts
    /// as a boundary.
    mutating func carveFreeSpace(around touched: Set<VoxelKey>, camera: CameraFrame, depth: DepthImage) {
        let toCamera = camera.worldToCamera
        var found: [VoxelKey] = []
        for key in touched {
            guard let normal = voxels[key]?.normal else { continue }
            for axis in Self.faceAxes where abs(simd_dot(SIMD3<Float>(axis), normal)) < config.alongSurfaceCosine {
                let neighbour = key &+ axis
                guard voxels[neighbour] == nil, !free.contains(neighbour) else { continue }
                let c4 = toCamera * SIMD4(centre(of: neighbour), 1)
                let z = -c4.z
                guard z >= config.depthRange.lowerBound else { continue }
                let k = depth.intrinsics
                let u = k.z + k.x * c4.x / z
                let v = k.w - k.y * c4.y / z
                guard u >= 0, v >= 0, u < Float(depth.width), v < Float(depth.height),
                      let measured = reading(depth, Int(u), Int(v), ignoringRange: true) else { continue }
                if measured > z + config.freeSpaceMargin { found.append(neighbour) }
            }
        }
        free.formUnion(found)
    }

    func edgeReason(for key: VoxelKey) -> EdgeReason? {
        guard let voxel = voxels[key] else { return nil }
        let normal = voxel.normal
        var surfaceNeighbour = false, emptyNeighbour = false
        let creaseCosine = cos(config.creaseDegrees * .pi / 180)
        for axis in Self.faceAxes {
            let along = normal.map { abs(simd_dot(SIMD3<Float>(axis), $0)) < config.alongSurfaceCosine } ?? false
            if let other = voxels[key &+ axis] {
                if let normal, let otherNormal = other.normal, simd_dot(normal, otherNormal) < creaseCosine {
                    return .crease
                }
                if along { surfaceNeighbour = true }
            } else if along, free.contains(key &+ axis) {
                emptyNeighbour = true
            }
        }
        return surfaceNeighbour && emptyNeighbour ? .boundary : nil
    }

    enum EdgeReason: Equatable {
        case crease
        case boundary
    }

    /// Marks new edges (sticky) among the touched voxels and their neighbours, then gives each
    /// touched group without one a flat representative.
    mutating func classify(_ touched: Set<VoxelKey>) {
        var candidates = touched
        for key in touched {
            for axis in Self.faceAxes where voxels[key &+ axis] != nil { candidates.insert(key &+ axis) }
        }
        for key in candidates where voxels[key]?.isEdge == false && edgeReason(for: key) != nil {
            voxels[key]?.isEdge = true
        }
        for key in touched {
            let group = key &>> 1
            guard representatives[group] == nil else { continue }
            var best: (key: VoxelKey, hash: UInt64)?
            for dx in Int32(0)...1 {
                for dy in Int32(0)...1 {
                    for dz in Int32(0)...1 {
                        let member = (group &<< 1) &+ VoxelKey(dx, dy, dz)
                        guard let voxel = voxels[member], !voxel.isEdge else { continue }
                        let hash = Self.hash(member, seed: 0xF1A7)
                        if best == nil || hash < best!.hash { best = (member, hash) }
                    }
                }
            }
            if let best { representatives[group] = best.key }
        }
    }

    /// Keeps at most `maxVoxels`: past it, drops the voxels farthest from `eye` down to 75% of
    /// the cap, with the free space and representatives that referred to them.
    mutating func bound(around eye: SIMD3<Float>) {
        if voxels.count > config.maxVoxels {
            let keep = config.maxVoxels * 3 / 4
            let ranked = voxels.keys.map { ($0, simd_distance_squared(centre(of: $0), eye)) }.sorted { $0.1 < $1.1 }
            let cutoff = ranked[keep].1
            voxels = voxels.filter { simd_distance_squared(centre(of: $0.key), eye) < cutoff }
            representatives = representatives.filter { voxels[$0.value] != nil }
        }
        if free.count > config.maxVoxels {
            let ranked = free.map { simd_distance_squared(centre(of: $0), eye) }.sorted()
            let cutoff = ranked[config.maxVoxels * 3 / 4]
            free = free.filter { simd_distance_squared(centre(of: $0), eye) < cutoff }
        }
    }

    /// ARKit's correction to the meter's anchor (`YawCorrection`): the dots move with the wall the
    /// scan measured. Composes into `toWorld`; no voxel moves.
    public mutating func apply(_ correction: YawCorrection) {
        toWorld = correction.pose(toWorld)
        toField = toWorld.inverse
    }

    // MARK: Dots

    /// Every edge voxel and each group's flat representative within `dotRadius` of `eye`, at
    /// most `maxDots`: past it, flat dots drop in hash order, then the farthest edges. `wall`
    /// decides which dots stand on an occluder; without one, none do. Sorted by id.
    public func dots(near worldEye: SIMD3<Float>, wall: WallFrame?) -> [SurfaceDot] {
        let eye = Self.transform(toField, worldEye)
        let radius2 = config.dotRadius * config.dotRadius
        var edges: [(VoxelKey, Voxel, Float)] = []
        var flats: [(VoxelKey, Voxel)] = []
        for (key, voxel) in voxels where voxel.isEdge {
            let d2 = simd_distance_squared(centre(of: key), eye)
            if d2 <= radius2 { edges.append((key, voxel, d2)) }
        }
        for key in representatives.values {
            guard let voxel = voxels[key], !voxel.isEdge, simd_distance_squared(centre(of: key), eye) <= radius2 else { continue }
            flats.append((key, voxel))
        }
        if edges.count > config.maxDots {
            edges.sort { $0.2 < $1.2 }
            edges.removeLast(edges.count - config.maxDots)
        }
        let room = config.maxDots - edges.count
        if flats.count > room {
            flats.sort { Self.hash($0.0, seed: 0xD075) < Self.hash($1.0, seed: 0xD075) }
            flats.removeLast(flats.count - room)
        }
        var result = edges.map { dot($0.0, $0.1, wall: wall) } + flats.map { dot($0.0, $0.1, wall: wall) }
        result.sort { $0.id < $1.id }
        return result
    }

    private func dot(_ key: VoxelKey, _ voxel: Voxel, wall: WallFrame?) -> SurfaceDot {
        let centre = Self.transform(toWorld, centre(of: key))
        let jitter = Self.rotate(toWorld, voxel.jitter)
        // Corrections turn only about the vertical, so a normal's y is the same in both frames.
        let wallLike = voxel.normal.map { abs($0.y) < config.cappedNormalMaxY } ?? false
        let faceOn = !voxel.isEdge || !wallLike || voxel.faceOnCosine >= cos(config.faceOnDegrees * .pi / 180)
        let views = Int(voxel.views.count)
        var onOccluder = false
        if let wall {
            let p = wall.wallPoint(centre)
            onOccluder = p.out > config.occluderMinOut && p.height > config.groundBand
        }
        return SurfaceDot(
            id: Self.id(for: key), position: centre + jitter, isEdge: voxel.isEdge, views: views,
            faceOn: faceOn, onOccluder: onOccluder,
            opacity: SurfaceDot.opacity(views: views, faceOn: faceOn, cap: config.obliqueEdgeOpacityCap))
    }

    // MARK: Depth helpers

    static func transform(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4(p, 1)
        return SIMD3(q.x, q.y, q.z)
    }

    static func rotate(_ m: simd_float4x4, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let q = m * SIMD4(v, 0)
        return SIMD3(q.x, q.y, q.z)
    }

    /// Meters at a depth pixel, or nil without a confident reading in range. `ignoringRange` keeps
    /// far readings, which the free-space test needs.
    private func reading(_ depth: DepthImage, _ i: Int, _ j: Int, ignoringRange: Bool = false) -> Float? {
        let index = j * depth.width + i
        if let confidence = depth.confidence, confidence[index] < config.minimumConfidence { return nil }
        let millimeters = depth.millimeters[index]
        guard millimeters > 0 else { return nil }
        let meters = Float(millimeters) / 1000
        return ignoringRange || config.depthRange.contains(meters) ? meters : nil
    }

    /// Camera space: +x right and +y up in the sensor image, looking along -z; v grows down.
    static func unproject(_ i: Int, _ j: Int, _ d: Float, _ k: SIMD4<Float>) -> SIMD3<Float> {
        let u = Float(i) + 0.5, v = Float(j) + 0.5
        return SIMD3((u - k.z) / k.x * d, (k.w - v) / k.y * d, -d)
    }

    /// Camera-space unit normal from central differences `step` pixels apart, falling back to one
    /// side where the other jumps by more than 10% of the depth (a silhouette), facing the
    /// camera. Nil when neither side is usable on either axis.
    private func cameraNormal(_ depth: DepthImage, _ i: Int, _ j: Int, _ d0: Float, step: Int) -> SIMD3<Float>? {
        func point(_ i: Int, _ j: Int) -> SIMD3<Float>? {
            guard i >= 0, j >= 0, i < depth.width, j < depth.height, let d = reading(depth, i, j), abs(d - d0) < 0.1 * d0 else { return nil }
            return Self.unproject(i, j, d, depth.intrinsics)
        }
        let centre = Self.unproject(i, j, d0, depth.intrinsics)
        func tangent(_ plus: SIMD3<Float>?, _ minus: SIMD3<Float>?) -> SIMD3<Float>? {
            switch (plus, minus) {
            case let (p?, m?): p - m
            case let (p?, nil): p - centre
            case let (nil, m?): centre - m
            case (nil, nil): nil
            }
        }
        guard let tx = tangent(point(i + step, j), point(i - step, j)),
              let ty = tangent(point(i, j + step), point(i, j - step)) else { return nil }
        let n = simd_cross(tx, ty)
        let length = simd_length(n)
        guard length > 1e-9 else { return nil }
        let unit = n / length
        return simd_dot(unit, -centre) < 0 ? -unit : unit
    }

    // MARK: Hashing

    /// SplitMix64: Swift's `Hasher` is seeded per process, and the field must look the same twice.
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func hash(_ key: VoxelKey, seed: UInt64) -> UInt64 {
        var h = mix(seed)
        h = mix(h ^ UInt64(UInt32(bitPattern: key.x)))
        h = mix(h ^ UInt64(UInt32(bitPattern: key.y)))
        h = mix(h ^ UInt64(UInt32(bitPattern: key.z)))
        return h
    }

    static func unit(_ h: UInt64) -> Float {
        Float(h >> 40) / Float(1 << 24)
    }

    /// Uniform over a disc of `radius` perpendicular to `normal`, from a hash of the key.
    static func jitter(for key: VoxelKey, normal: SIMD3<Float>, radius: Float) -> SIMD3<Float> {
        let length = simd_length(normal)
        let n = length > 1e-6 ? normal / length : SIMD3<Float>(0, 0, 1)
        let helper: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let t = simd_normalize(simd_cross(helper, n))
        let b = simd_cross(n, t)
        let h = hash(key, seed: 0x6A17)
        let angle = unit(h) * 2 * .pi
        let r = radius * unit(mix(h)).squareRoot()
        return (t * cos(angle) + b * sin(angle)) * r
    }

    /// Packs the key into 21 bits per axis (plus or minus 52 km at 5 cm), so ids never collide.
    static func id(for key: VoxelKey) -> UInt64 {
        let bias: Int64 = 1 << 20
        let x = UInt64(Int64(key.x) + bias) & 0x1F_FFFF
        let y = UInt64(Int64(key.y) + bias) & 0x1F_FFFF
        let z = UInt64(Int64(key.z) + bias) & 0x1F_FFFF
        return x | (y << 21) | (z << 42)
    }
}
