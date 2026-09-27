import simd

/// The no-LiDAR dot field, simulated from the fixture's depth because the fixture has no
/// feature points: stand-ins for ARKit's `rawFeaturePoints` and for plane detection on the wall.
/// It reads depth, which a phone without LiDAR does not have, so it shows the look of this mode,
/// not its accuracy.
public struct FeatureField: Sendable {
    struct Track {
        let id: UInt64
        /// First observation; a feature dot never moves after birth.
        let position: SIMD3<Float>
        var views = ViewDirections()
        /// Keyframe indices it was matched in, newest last, trimmed to the window.
        var observed: [Int] = []
        var lastSeen: Double
    }

    private var tracks: [UInt64: Track] = [:]
    /// 8 cm cells to the tracks inside them, for the re-observation match.
    private var grid: [SIMD3<Int32>: [UInt64]] = [:]
    private var nextTrack: UInt64 = 0
    private var planeViews: [SIMD2<Int32>: ViewDirections] = [:]
    private var frameIndex = 0
    private var frameTime: Double = 0
    /// Candidates kept by the last `integrate`, after thinning.
    public private(set) var lastSampleCount = 0

    static let featureTag: UInt64 = 1 << 63
    static let planeTag: UInt64 = 1 << 62
    static let planeColumns = Int(((FixtureWall.xRange.upperBound - FixtureWall.xRange.lowerBound) / Tuning.planeCell).rounded())
    static let planeRows = Int(((FixtureWall.yRange.upperBound - FixtureWall.yRange.lowerBound) / Tuning.planeCell).rounded())

    public init() {}

    public mutating func integrate(_ frame: FrameInput) {
        frameIndex = frame.index
        frameTime = frame.keyframe.timestamp
        let camera = frame.keyframe.cameraPosition
        let samples = strongGradientSamples(frame)
        lastSampleCount = samples.count
        for point in samples {
            if let id = nearestTrack(to: point) {
                tracks[id]?.lastSeen = frameTime
                if tracks[id]?.observed.last != frameIndex { tracks[id]?.observed.append(frameIndex) }
                tracks[id]?.views.insert(camera - point)
            } else {
                var track = Track(id: nextTrack, position: point, lastSeen: frameTime)
                track.observed = [frameIndex]
                track.views.insert(camera - point)
                tracks[track.id] = track
                grid[cell(point), default: []].append(track.id)
                nextTrack += 1
            }
        }
        for id in tracks.keys.sorted() {
            guard var track = tracks[id] else { continue }
            track.observed.removeAll { $0 <= frameIndex - Tuning.featureWindow }
            if frameTime - track.lastSeen > Tuning.featureLifetime {
                tracks[id] = nil
                grid[cell(track.position)]?.removeAll { $0 == id }
            } else {
                tracks[id] = track
            }
        }
        coverPlane(frame)
    }

    /// Depth samples whose image gradient reaches `Tuning.featureGradientThreshold`, merged to
    /// one per 4 cm cell and thinned to the `Tuning.featureTarget` lowest cell hashes.
    func strongGradientSamples(_ frame: FrameInput) -> [SIMD3<Float>] {
        Array(Self.candidates(frame, threshold: Tuning.featureGradientThreshold).prefix(Tuning.featureTarget))
    }

    /// All candidate features before thinning, lowest cell hash first.
    public static func candidates(_ frame: FrameInput, threshold: Float) -> [SIMD3<Float>] {
        let depth = frame.depth
        let pose = frame.keyframe.cameraToWorld
        let imageScale = Float(frame.keyframe.width) / Float(depth.width)
        let focal = frame.keyframe.intrinsics.x
        var cells: [SIMD3<Int32>: SIMD3<Float>] = [:]
        for j in 0..<depth.height {
            for i in 0..<depth.width {
                let index = j * depth.width + i
                let d = depth.meters[index]
                guard depth.confidence[index] >= Tuning.minimumConfidence, Tuning.depthRange.contains(d) else { continue }
                let u = Float(i) + 0.5, v = Float(j) + 0.5
                let level = GradientPyramid.level(depth: d, focal: focal)
                guard frame.gradient.magnitude(u: u * imageScale, v: v * imageScale, level: level) >= threshold else { continue }
                let world = CameraMath.transform(pose, CameraMath.unproject(u: u, v: v, depth: d, intrinsics: depth.intrinsics))
                let key = SIMD3<Int32>((world / Tuning.featureCell).rounded(.down))
                if cells[key] == nil { cells[key] = world }
            }
        }
        let ranked = cells.map { (point: $0.value, hash: StableHash.hash($0.key, seed: 0xFEA7)) }.sorted { $0.hash < $1.hash }
        return ranked.map(\.point)
    }

    private func cell(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>((p / Tuning.featureMatchRadius).rounded(.down))
    }

    private func nearestTrack(to p: SIMD3<Float>) -> UInt64? {
        let c = cell(p)
        var best: (id: UInt64, distance: Float)?
        for dz in Int32(-1)...1 {
            for dy in Int32(-1)...1 {
                for dx in Int32(-1)...1 {
                    for id in grid[c &+ SIMD3(dx, dy, dz)] ?? [] {
                        guard let track = tracks[id] else { continue }
                        let distance = simd_distance(track.position, p)
                        guard distance <= Tuning.featureMatchRadius else { continue }
                        if let current = best, current.distance < distance || (current.distance == distance && current.id < id) { continue }
                        best = (id, distance)
                    }
                }
            }
        }
        return best?.id
    }

    /// Plane cells on the wall whose centre is in view within `Tuning.planeRange` and not hidden
    /// behind something nearer. The depth check stands in for the plane's own extent, and keeps
    /// plane dots off the bin.
    mutating func coverPlane(_ frame: FrameInput) {
        let depth = frame.depth
        let worldToCamera = frame.keyframe.cameraToWorld.inverse
        let camera = frame.keyframe.cameraPosition
        for row in 0..<Self.planeRows {
            for column in 0..<Self.planeColumns {
                let centre = Self.planeCentre(column: column, row: row)
                guard simd_distance(centre, camera) <= Tuning.planeRange,
                      let pixel = CameraMath.project(CameraMath.transform(worldToCamera, centre), intrinsics: depth.intrinsics),
                      let measured = depth.depth(atU: pixel.u, v: pixel.v),
                      measured > 0, abs(measured - pixel.depth) < Tuning.freeSpaceMargin
                else { continue }
                planeViews[SIMD2(Int32(column), Int32(row)), default: ViewDirections()].insert(camera - centre)
            }
        }
    }

    static func planeCentre(column: Int, row: Int) -> SIMD3<Float> {
        SIMD3(
            FixtureWall.xRange.lowerBound + (Float(column) + 0.5) * Tuning.planeCell,
            FixtureWall.yRange.lowerBound + (Float(row) + 0.5) * Tuning.planeCell, 0)
    }

    private func isAlive(_ track: Track) -> Bool {
        track.observed.count >= Tuning.featureMinObservations && frameTime - track.lastSeen <= Tuning.featureLifetime
    }

    public func dots() -> [FieldDot] {
        var dots: [FieldDot] = []
        for track in tracks.values where isAlive(track) {
            dots.append(FieldDot(
                id: Self.featureTag | track.id, position: track.position, kind: .feature,
                views: track.views.count, onOccluder: FieldDot.isOnOccluder(track.position)))
        }
        for (cell, views) in planeViews {
            let key = SIMD3<Int32>(cell.x, cell.y, 0)
            let position = Self.planeCentre(column: Int(cell.x), row: Int(cell.y))
                + Jitter.offset(for: key, normal: SIMD3(0, 0, 1), cellSize: Tuning.planeCell)
            dots.append(FieldDot(
                id: Self.planeTag | UInt64(UInt32(cell.x)) << 16 | UInt64(UInt32(cell.y)),
                position: position, kind: .plane, views: views.count, onOccluder: false,
                normal: SIMD3(0, 0, 1)))
        }
        return dots
    }

    public func seenWallCells() -> Set<WallCell> {
        var cells = Set<WallCell>()
        for cell in planeViews.keys {
            let c = Self.planeCentre(column: Int(cell.x), row: Int(cell.y))
            if let wallCell = WallCell.containing(x: c.x, y: c.y) { cells.insert(wallCell) }
        }
        for track in tracks.values where isAlive(track) && abs(track.position.z) <= 0.1 {
            if let wallCell = WallCell.containing(x: track.position.x, y: track.position.y) { cells.insert(wallCell) }
        }
        return cells
    }
}
