import simd

public enum CaptureMode: String, Sendable, CaseIterable {
    case lidar
    /// Simulated from the same depth; see `FeatureField`.
    case noLidar
}

/// One dot as the renderer draws it at one keyframe: where it is and the times its animations
/// start, all on the playback clock (seconds, keyframe k shown at k / 4). The shader evaluates
/// the curves, so the vertex buffer changes only at keyframes.
public struct DotSprite: Sendable, Equatable {
    public let id: UInt64
    public let position: SIMD3<Float>
    public let kind: DotKind
    public let onOccluder: Bool
    public let birthTime: Float
    /// Opacity eases from `fromOpacity` to `toOpacity` over 250 ms starting at `opacityTime`.
    public let fromOpacity: Float
    public let toOpacity: Float
    public let opacityTime: Float
    /// When the dot became an edge: -infinity if it was born one, +infinity if it is flat.
    public let edgeSince: Float
    /// When it stopped being in the field (a feature point dying, a flat dot capped out),
    /// +infinity while it is alive. A dying dot fades out over 250 ms.
    public let deathTime: Float
    /// Unit surface normal, zero when unknown.
    public let normal: SIMD3<Float>

    public init(
        id: UInt64, position: SIMD3<Float>, kind: DotKind, onOccluder: Bool, birthTime: Float,
        fromOpacity: Float, toOpacity: Float, opacityTime: Float, edgeSince: Float, deathTime: Float,
        normal: SIMD3<Float> = .zero
    ) {
        self.normal = normal
        self.id = id
        self.position = position
        self.kind = kind
        self.onOccluder = onOccluder
        self.birthTime = birthTime
        self.fromOpacity = fromOpacity
        self.toOpacity = toOpacity
        self.opacityTime = opacityTime
        self.edgeSince = edgeSince
        self.deathTime = deathTime
    }

    /// The opacity the CPU expects at playback time `t`, ignoring the birth ramp.
    public func evidenceOpacity(at t: Float) -> Float {
        let progress = (t - opacityTime) / Tuning.evidenceDuration
        return fromOpacity + (toOpacity - fromOpacity) * CubicBezier.strongEaseOut(progress)
    }
}

public struct KeyframeState: Sendable {
    public let index: Int
    /// Playback time at which this keyframe appears.
    public let time: Float
    /// Dots to draw: alive, in the phone's view and not hidden behind nearer depth, capped at
    /// `Tuning.dotCap`, plus this keyframe's deaths.
    public let sprites: [DotSprite]
    /// Dots in the field, in view or not.
    public let fieldCount: Int
    public let edgeCount: Int
    public let coverage: Float
    public let unseenCells: [WallCell]
    public let instruction: Instruction
}

public struct DotTimeline: Sendable {
    public let mode: CaptureMode
    public let states: [KeyframeState]

    /// Runs both fields over every keyframe once. `progress` gets (done, total) after each.
    public static func build(
        replay: Replay, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws(FixtureError) -> (lidar: DotTimeline, noLidar: DotTimeline) {
        let instructions = Instruction.sequence(for: replay.keyframes)
        var voxels = VoxelField()
        var features = FeatureField()
        var lidar = Builder(), noLidar = Builder()
        for (index, keyframe) in replay.keyframes.enumerated() {
            let frame = FrameInput(
                index: index, keyframe: keyframe, depth: try replay.depth(for: keyframe),
                gradient: GradientPyramid(image: try replay.image(for: keyframe)))
            voxels.integrate(frame)
            features.integrate(frame)
            lidar.append(frame, dots: voxels.dots(), seen: voxels.seenWallCells(), instruction: instructions[index])
            noLidar.append(frame, dots: features.dots(), seen: features.seenWallCells(), instruction: instructions[index])
            progress?(index + 1, replay.keyframes.count)
        }
        return (DotTimeline(mode: .lidar, states: lidar.states), DotTimeline(mode: .noLidar, states: noLidar.states))
    }

    /// Turns each keyframe's field into sprites with birth, evidence and death times.
    struct Builder {
        struct Track {
            var birthTime: Float
            var from: Float
            var to: Float
            var opacityTime: Float
            var edgeSince: Float
            var last: FieldDot
        }

        private(set) var states: [KeyframeState] = []
        private var tracks: [UInt64: Track] = [:]

        mutating func append(_ frame: FrameInput, dots: [FieldDot], seen: Set<WallCell>, instruction: Instruction) {
            let t = Schedule.start(of: frame.index)
            let view = View(frame)
            var inView: [(sprite: DotSprite, kind: DotKind)] = []
            var alive = Set<UInt64>()
            for dot in dots {
                alive.insert(dot.id)
                let level = dot.opacity
                var track: Track
                if var existing = tracks[dot.id] {
                    if level != existing.to {
                        existing.from = sprite(existing, deathTime: .infinity).evidenceOpacity(at: t)
                        existing.to = level
                        existing.opacityTime = t
                    }
                    if dot.kind == .edge, existing.edgeSince == .infinity { existing.edgeSince = t }
                    existing.last = dot
                    track = existing
                } else {
                    track = Track(
                        birthTime: t, from: level, to: level, opacityTime: -.infinity,
                        edgeSince: dot.kind == .edge ? -.infinity : .infinity, last: dot)
                }
                tracks[dot.id] = track
                if view.shows(dot.position) { inView.append((sprite(track, deathTime: .infinity), dot.kind)) }
            }
            var sprites = Self.capped(inView)
            for (id, track) in tracks where !alive.contains(id) {
                if view.shows(track.last.position) { sprites.append(sprite(track, deathTime: t)) }
                tracks[id] = nil
            }
            // Additive blending into an 8-bit target rounds after every sprite, so a fixed order
            // keeps exports byte-identical between runs.
            sprites.sort { $0.id < $1.id }
            states.append(KeyframeState(
                index: frame.index, time: t, sprites: sprites, fieldCount: dots.count,
                edgeCount: dots.count { $0.kind == .edge }, coverage: Coverage.fraction(of: dots),
                unseenCells: WallCell.all.filter { !seen.contains($0) }, instruction: instruction))
        }

        /// Past `Tuning.dotCap` dots in view, drops flat dots in hash order; never edge dots.
        static func capped(_ inView: [(sprite: DotSprite, kind: DotKind)]) -> [DotSprite] {
            guard inView.count > Tuning.dotCap else { return inView.map(\.sprite) }
            let edges = inView.filter { $0.kind == .edge }.map(\.sprite)
            let others = inView.filter { $0.kind != .edge }.map(\.sprite)
                .sorted { StableHash.mix($0.id) < StableHash.mix($1.id) }
            return edges + others.prefix(max(Tuning.dotCap - edges.count, 0))
        }

        private func sprite(_ track: Track, deathTime: Float) -> DotSprite {
            DotSprite(
                id: track.last.id, position: track.last.position, kind: track.last.kind, onOccluder: track.last.onOccluder,
                birthTime: track.birthTime, fromOpacity: track.from, toOpacity: track.to, opacityTime: track.opacityTime,
                edgeSince: track.edgeSince, deathTime: deathTime, normal: track.last.normal)
        }

        /// What the phone shows at a keyframe: the 390 x 844 pt portrait crop of the camera, minus
        /// anything the keyframe's depth shows something nearer in front of by
        /// `Tuning.occlusionMargin`, so a wall dot never draws on top of the bin.
        struct View {
            let projection: ScreenProjection
            let depth: DepthMap

            init(_ frame: FrameInput) {
                projection = ScreenProjection(keyframe: frame.keyframe, viewSize: SIMD2(390, 844))
                depth = frame.depth
            }

            func shows(_ p: SIMD3<Float>) -> Bool {
                guard let screen = projection.screenPoint(p),
                      screen.x >= 0, screen.y >= 0, screen.x <= projection.viewSize.x, screen.y <= projection.viewSize.y
                else { return false }
                let camera = CameraMath.transform(projection.worldToCamera, p)
                guard let pixel = CameraMath.project(camera, intrinsics: depth.intrinsics),
                      let measured = depth.depth(atU: pixel.u, v: pixel.v)
                else { return false }
                return !(measured > 0 && measured < pixel.depth - Tuning.occlusionMargin)
            }
        }
    }
}
