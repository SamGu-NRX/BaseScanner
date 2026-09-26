import Foundation
import simd

/// A live 3D map of the space around the electric meter, built from what the phone's camera
/// and sensors saw, in the meter-anchored frame (`MapFrame`).
///
/// It is an occupancy map, not a signed-distance (TSDF) map: coverage asks whether a ray
/// reached a place, and occupancy answers that directly. A ray marks the voxels it passes
/// through as free and the voxel it stops in as surface; a voxel no ray reached stays unknown.
/// So a surface behind a bush is never seen unless some ray got past the bush. A TSDF keeps
/// surfaces more precisely but does not separate never-seen space from free space, and can't
/// take the sparse rays a phone without LiDAR gives.
///
/// With LiDAR, rays come from depth frames (`integrate(_: DepthFrame)`) and ARKit's mesh adds
/// its classification (`update(_: MeshChunk)`). Without it, rays go to tracked feature points
/// and to detected planes (`integrate(_: FeatureFrame)`, `update(_: PlaneObservation)`), and a
/// monocular depth model can supply estimated depth frames later. Only frames with normal
/// tracking should be integrated: a limited-tracking pose can put rays half a meter off.
public struct Map3D: Sendable {
    public let config: Map3DConfig
    public private(set) var frame: MapFrame
    public let bounds: MapBounds
    /// Increments whenever the map changes.
    public private(set) var revision = 0

    private(set) var grid: VoxelGrid
    /// Detected planes by id, in world coordinates as ARKit last reported them.
    public private(set) var planes: [UUID: PlaneObservation] = [:]
    /// Per mesh chunk, the voxels its faces labelled, so an update can clear them first.
    private var meshVoxels: [UUID: [Int32]] = [:]

    /// `bounds` defaults to everything the rules can ask about (`MapBounds.around`).
    public init(frame: MapFrame, config: Map3DConfig = Map3DConfig(), bounds: MapBounds? = nil) {
        self.config = config
        self.frame = frame
        self.bounds = bounds ?? .around(config, groundY: frame.groundY)
        grid = VoxelGrid(bounds: self.bounds, voxelSize: config.voxelSize, center: SIMD3(0, frame.groundY, 0))
    }

    /// Moves the map with the meter's anchor. What is stored keeps its place relative to the
    /// meter; frames integrated from now on are placed with the new frame. The voxels are laid
    /// out around the ground's height, so the new frame must keep it, as `following` does.
    public mutating func reanchor(_ frame: MapFrame) {
        precondition(frame.groundY == self.frame.groundY, "reanchoring moves the ground from \(self.frame.groundY) to \(frame.groundY) m")
        self.frame = frame
        revision += 1
    }

    // MARK: Reading

    /// State of the voxel holding a map point; unknown outside the bounds.
    public func state(at point: SIMD3<Float>) -> VoxelState {
        grid.voxel(at: point)?.state(config) ?? .unknown
    }

    public func evidence(at point: SIMD3<Float>) -> VoxelEvidence {
        grid.voxel(at: point)?.evidence(config)
            ?? VoxelEvidence(state: .unknown, hits: 0, passes: 0, nearestDistance: nil, bestViewAngle: nil, normal: nil, meshClass: nil, sources: [])
    }

    /// Bytes the voxels take now, and with every brick of the bounds stored.
    public var allocatedBytes: Int { grid.allocatedBytes }
    public var worstCaseBytes: Int { grid.worstCaseBytes }

    // MARK: Depth

    /// Integrates a LiDAR or estimated depth frame: each sampled pixel is a ray from the camera,
    /// free up to just short of its depth, stopping at a surface there. LiDAR pixels below
    /// `minConfidence` are skipped. An estimated pixel carves free space to two standard
    /// deviations short of its depth and marks a surface only when that is within
    /// `maxSurfaceSigma`.
    public mutating func integrate(_ depth: DepthFrame) {
        let mapFromCamera = frame.mapFromWorld * depth.camera.cameraToWorld
        let camera = SIMD3(mapFromCamera.columns.3.x, mapFromCamera.columns.3.y, mapFromCamera.columns.3.z)
        let rotation = CameraFrame.rotation(mapFromCamera)
        let k = max(1, config.pixelStride)
        let columns = (depth.width + k - 1) / k
        let rows = (depth.height + k - 1) / k
        let intrinsics = depth.camera.intrinsics

        // Camera-space points of the sampled pixels; NaN where there is no usable depth.
        var points = [SIMD3<Float>](repeating: SIMD3(repeating: .nan), count: columns * rows)
        var sigmas = [Float](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            let v = row * k
            for column in 0..<columns {
                let u = column * k
                let index = v * depth.width + u
                let d = depth.depth[index]
                guard d.isFinite, d >= config.minDepth, d <= config.maxDepth else { continue }
                switch depth.kind {
                case .lidar(let confidence):
                    guard (confidence?[index] ?? 2) >= config.minConfidence else { continue }
                case .estimated(let sigma):
                    guard sigma[index].isFinite, sigma[index] >= 0 else { continue }
                    sigmas[row * columns + column] = sigma[index]
                }
                let x = (Float(u) + 0.5 - intrinsics.z) / intrinsics.x * d
                let y = -(Float(v) + 0.5 - intrinsics.w) / intrinsics.y * d
                points[row * columns + column] = SIMD3(x, y, -d)
            }
        }

        // Samples next to each other lie d k / fx apart across the ray. A normal is taken from
        // the samples about a voxel away on each side, so it describes the surface at the
        // map's scale: between neighbours 1.5 cm apart (1.4 m away) a 1 cm depth error alone
        // tilts it 30 degrees. A surface up to 80 degrees from facing the camera changes depth
        // by at most 5.7 times the spacing; a bigger jump is an edge, across which no normal is
        // taken.
        let spacing = Float(k) / min(intrinsics.x, intrinsics.y)
        var rays: [RaySample] = []
        rays.reserveCapacity(columns * rows)
        let estimated: Bool = if case .estimated = depth.kind { true } else { false }
        for row in 0..<rows {
            for column in 0..<columns {
                let p = points[row * columns + column]
                guard !p.z.isNaN else { continue }
                let reach = max(1, min(8, Int((config.voxelSize / (spacing * -p.z)).rounded())))
                func neighbour(_ dc: Int, _ dr: Int) -> SIMD3<Float>? {
                    let c = column + dc * reach
                    let r = row + dr * reach
                    guard c >= 0, c < columns, r >= 0, r < rows else { return nil }
                    let q = points[r * columns + c]
                    guard !q.z.isNaN, abs(q.z - p.z) <= 0.02 + 5.7 * spacing * Float(reach) * -p.z else { return nil }
                    return q
                }
                let length = simd_length(p)
                var normal = SIMD3<Float>.zero
                // Unknown without a normal: the free margin then assumes 60 degrees.
                var cosine: Float = 0.5
                if let dx = neighbour(1, 0).map({ $0 - p }) ?? neighbour(-1, 0).map({ p - $0 }),
                   let dy = neighbour(0, 1).map({ $0 - p }) ?? neighbour(0, -1).map({ p - $0 }) {
                    let n = simd_cross(dx, dy)
                    if simd_length_squared(n) > 0 {
                        // Facing the camera, which is at the camera-space origin.
                        let facing = simd_normalize(simd_dot(n, p) < 0 ? n : -n)
                        cosine = abs(simd_dot(facing, p / length))
                        normal = rotation * facing
                    }
                }
                var freeLength = length - freeMargin(cosine: cosine)
                var hit = true
                if estimated {
                    let sigma = sigmas[row * columns + column]
                    freeLength = min(freeLength, (-p.z - 2 * sigma) / -p.z * length)
                    hit = 2 * sigma <= config.maxSurfaceSigma
                }
                let end4 = mapFromCamera * SIMD4(p, 1)
                rays.append(RaySample(end: SIMD3(end4.x, end4.y, end4.z), normal: normal, freeLength: freeLength, hit: hit))
            }
        }
        grid.integrate(camera: camera, rays: rays, sources: estimated ? .estimated : .lidar, measured: true, config: config)
        revision += 1
    }

    /// How far short of a surface free space stops, meters. A ray within one voxel of a surface
    /// it meets at a glancing angle runs voxel / cos along it, through voxels the surface also
    /// crosses; stopping that far short keeps glancing rays from erasing the surface. Capped at
    /// four voxels.
    private func freeMargin(cosine: Float) -> Float {
        config.voxelSize / max(cosine, 0.25)
    }

    // MARK: Without LiDAR

    /// Integrates a frame from a phone without LiDAR.
    ///
    /// Each tracked feature point is a ray the camera really saw along: free up to just short of
    /// the point, surface at it. A point lying on a detected plane (within `planeSnap`) takes
    /// that plane's normal, which makes it a measured surface coverage can count.
    ///
    /// Detected planes are then drawn through a grid of `planeRenderColumns` x
    /// `planeRenderRows` pixels, where no surface already in the map is in front of them. They
    /// add surface for wall geometry only: they carve no free space and never count as seen,
    /// because a plane's extent says nothing about what stands in front of it. A box with no
    /// feature points on it would otherwise read as open space and hide the wall behind it
    /// while leaving that wall "seen".
    public mutating func integrate(_ features: FeatureFrame) {
        let camera = frame.map(features.camera.position)
        let mapPlanes = planesInMap()
        var featureRays: [RaySample] = []
        for point in features.points {
            let end = frame.map(point)
            let length = simd_distance(end, camera)
            guard length.isFinite, length >= config.minDepth, length <= config.maxDepth else { continue }
            let direction = (end - camera) / length
            let normal = mapPlanes.first { plane in
                abs(simd_dot(end - plane.point, plane.normal)) <= config.planeSnap && plane.contains(end)
            }.map { simd_dot($0.normal, direction) > 0 ? -$0.normal : $0.normal } ?? .zero
            featureRays.append(RaySample(end: end, normal: normal, freeLength: length - 2 * config.voxelSize, hit: true))
        }
        grid.integrate(camera: camera, rays: featureRays, sources: .feature, measured: true, config: config)
        grid.integrate(camera: camera, rays: planeRays(from: features.camera, camera: camera, planes: mapPlanes), sources: .plane, measured: false, config: config)
        revision += 1
    }

    /// Adds or replaces a detected plane. It shows up in the map on the next feature frame that
    /// views it.
    public mutating func update(_ plane: PlaneObservation) {
        planes[plane.id] = plane
        revision += 1
    }

    public mutating func removePlane(id: UUID) {
        planes[id] = nil
        revision += 1
    }

    private struct MapPlane {
        var point: SIMD3<Float>
        var normal: SIMD3<Float>
        var planeFromMap: simd_float4x4
        var boundary: [SIMD2<Float>]

        func contains(_ p: SIMD3<Float>) -> Bool {
            let local = planeFromMap * SIMD4(p, 1)
            return Map3D.polygon(boundary, contains: SIMD2(local.x, local.z))
        }
    }

    private func planesInMap() -> [MapPlane] {
        planes.values.compactMap { plane in
            guard plane.boundary.count >= 3 else { return nil }
            let mapFromPlane = frame.mapFromWorld * plane.worldFromPlane
            let normal = SIMD3(mapFromPlane.columns.1.x, mapFromPlane.columns.1.y, mapFromPlane.columns.1.z)
            guard simd_length_squared(normal) > 0 else { return nil }
            return MapPlane(
                point: SIMD3(mapFromPlane.columns.3.x, mapFromPlane.columns.3.y, mapFromPlane.columns.3.z),
                normal: simd_normalize(normal), planeFromMap: mapFromPlane.inverse, boundary: plane.boundary)
        }
    }

    /// Where each rendered pixel's ray meets the nearest plane, unless a surface already in the
    /// map is in front of it; the normal faces the camera. No free space.
    private func planeRays(from cameraFrame: CameraFrame, camera: SIMD3<Float>, planes mapPlanes: [MapPlane]) -> [RaySample] {
        guard !mapPlanes.isEmpty else { return [] }
        var rays: [RaySample] = []
        let columns = max(1, config.planeRenderColumns)
        let rows = max(1, config.planeRenderRows)
        for row in 0..<rows {
            for column in 0..<columns {
                let pixel = SIMD2(
                    (Float(column) + 0.5) / Float(columns) * cameraFrame.imageSize.x,
                    (Float(row) + 0.5) / Float(rows) * cameraFrame.imageSize.y)
                let direction = simd_normalize(frame.mapDirection(cameraFrame.ray(throughPixel: pixel).direction))
                var nearest: (t: Float, normal: SIMD3<Float>)?
                for plane in mapPlanes {
                    let denominator = simd_dot(plane.normal, direction)
                    guard abs(denominator) > 1e-4 else { continue }
                    let t = simd_dot(plane.normal, plane.point - camera) / denominator
                    guard t >= config.minDepth, t <= config.maxDepth, t < nearest?.t ?? .infinity, plane.contains(camera + direction * t) else { continue }
                    nearest = (t, denominator > 0 ? -plane.normal : plane.normal)
                }
                guard let nearest else { continue }
                let limit = nearest.t - freeMargin(cosine: abs(simd_dot(nearest.normal, direction)))
                guard firstSurface(from: camera, direction: direction, length: limit) == nil else { continue }
                rays.append(RaySample(end: camera + direction * nearest.t, normal: nearest.normal, freeLength: 0, hit: true))
            }
        }
        return rays
    }

    /// Distance along a ray at which it enters the first surface voxel, within `length`.
    func firstSurface(from origin: SIMD3<Float>, direction: SIMD3<Float>, length: Float) -> Float? {
        guard length > 0 else { return nil }
        var found: Float?
        grid.march(from: origin, direction: direction, length: length) { _, voxel, entered in
            if let voxel, voxel.state(config) == .surface {
                found = entered
                return false
            }
            return true
        }
        return found
    }

    /// Even-odd rule.
    static func polygon(_ polygon: [SIMD2<Float>], contains p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: Mesh

    /// Adds or replaces a chunk of ARKit's mesh. It labels the voxels its faces cross with their
    /// classification and gives voxels no ray has given a normal the face's. It adds no
    /// occupancy: a mesh face carries no camera, so it can't say what was seen from where.
    public mutating func update(_ chunk: MeshChunk) {
        if let old = meshVoxels.removeValue(forKey: chunk.id) { grid.clearMesh(old) }
        let mapFromChunk = frame.mapFromWorld * chunk.worldFromChunk
        let vertices = chunk.vertices.map { v in
            let p = mapFromChunk * SIMD4(v, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        var marked: [Int32] = []
        for (index, face) in chunk.faces.enumerated() {
            guard face.x < vertices.count, face.y < vertices.count, face.z < vertices.count else { continue }
            let triangle = (vertices[Int(face.x)], vertices[Int(face.y)], vertices[Int(face.z)])
            // Faces wholly outside the bounds are skipped before sampling them.
            let low = simd_min(triangle.0, simd_min(triangle.1, triangle.2))
            let high = simd_max(triangle.0, simd_max(triangle.1, triangle.2))
            guard all(high .>= bounds.min), all(low .< bounds.max) else { continue }
            marked += grid.markMesh(triangle, meshClass: chunk.classes.isEmpty ? nil : chunk.classes[index])
        }
        meshVoxels[chunk.id] = Array(Set(marked))
        revision += 1
    }

    public mutating func removeMeshChunk(id: UUID) {
        if let old = meshVoxels.removeValue(forKey: id) { grid.clearMesh(old) }
        revision += 1
    }
}
