import Foundation
import simd

/// What the walk asks for next.
public enum GuidanceTask: Sendable, Equatable {
    /// Walk along the wall toward a side.
    case walk(WalkSide)
    /// Coverage on this side reached the planner's reach; ask the homeowner to mark where the wall ends.
    case markEnd(WalkSide)
    /// The ground band lags around `s`: tilt down.
    case aimAtGround(s: Float)
    /// The wall band lags around `s`: tilt up or step back.
    case aimAtWall(s: Float)
    /// The camera is too close to the wall to see the band.
    case stepBack
    /// Both ends marked and nothing lags between them.
    case complete
}

public struct GuidanceConfig: Sendable, Equatable {
    /// Keep a task at least this long unless it is satisfied, so instructions never flip A, B, A
    /// within 3 s (verification checklist item I6).
    public var minDwell: Double = 3
    /// Ask for the end once coverage reaches this far from the meter on a side: about 20 ft, past
    /// which docs/01 expects the cable route to be too long for a placement anyway.
    public var reach: Float = 6.1
    /// Closer to the wall than this, a portrait phone camera sees less than about 1.4 m of it.
    public var tooClose: Float = 1.2
    /// A band lagging over at least this much wall near the camera triggers an aim task
    /// (3 cells of 6 in: one missed stride).
    public var lagRun: Float = 0.45
    /// Where the homeowner should stand: this far out from the wall.
    public var standOff: Float = 1.5
    /// The ground path is drawn at most this long, so it never leads far into unseen ground.
    public var maxPathLength: Float = 3

    public init() {}
}

public struct GuidanceOutput: Sendable, Equatable {
    public var task: GuidanceTask
    /// A world point to aim at.
    public var target: SIMD3<Float>?
    /// A ground path from the homeowner toward where to stand next, world points.
    public var path: [SIMD3<Float>]
}

/// Chooses the next walk task from coverage and the camera, with hysteresis.
public struct GuidancePlanner: Sendable {
    public let config: GuidanceConfig
    public private(set) var current: GuidanceTask?
    private var since: Double = 0

    public init(config: GuidanceConfig = GuidanceConfig()) {
        self.config = config
    }

    public mutating func reset() {
        current = nil
    }

    /// The task for this moment. Switches away from the current task only when it is satisfied or
    /// has been held for `minDwell` seconds and the preferred task differs.
    public mutating func update(coverage: CoverageMap, camera: CameraFrame?, time: Double) -> GuidanceOutput {
        let preferred = preferredTask(coverage: coverage, camera: camera)
        if let current, current != preferred {
            let satisfied = isSatisfied(current, coverage: coverage, camera: camera)
            if satisfied || time - since >= config.minDwell {
                self.current = preferred
                since = time
            }
        } else if current == nil {
            current = preferred
            since = time
        }
        let task = current ?? preferred
        return GuidanceOutput(task: task, target: target(for: task, coverage: coverage), path: path(for: task, coverage: coverage, camera: camera))
    }

    // MARK: Choosing

    /// How far from the meter coverage runs unbroken on a side, over both bands (skipped cells
    /// count as done).
    public func reach(_ side: WalkSide, coverage: CoverageMap) -> Float {
        let width = coverage.config.cellWidth
        var index = side == .right ? 0 : -1
        var reached: Float = 0
        let limit = Int((config.reach * 2) / width)
        for _ in 0..<limit {
            let done = SurfaceBand.allCases.allSatisfy {
                let level = coverage.level($0, index)
                return level == .covered || level == .skipped
            }
            if !done { break }
            let range = coverage.cellRange(index)
            reached = side == .right ? range.upperBound : -range.lowerBound
            index += side == .right ? 1 : -1
        }
        return reached
    }

    func preferredTask(coverage: CoverageMap, camera: CameraFrame?) -> GuidanceTask {
        if let camera, coverage.wall.wallPoint(camera.position).out < config.tooClose {
            return .stepBack
        }
        if let camera, let lag = laggingBand(coverage: coverage, camera: camera) {
            return lag
        }
        for side in [WalkSide.left, .right] {
            let end = side == .left ? coverage.leftEnd : coverage.rightEnd
            guard end == nil else { continue }
            return reach(side, coverage: coverage) >= config.reach ? .markEnd(side) : .walk(side)
        }
        if let hole = firstHole(coverage: coverage) {
            return hole
        }
        return .complete
    }

    /// A band that lags the other around the camera: the other band is covered there but this one
    /// isn't, over at least `lagRun`.
    private func laggingBand(coverage: CoverageMap, camera: CameraFrame) -> GuidanceTask? {
        let s = coverage.wall.wallPoint(camera.position).s
        let window = (s - 1)...(s + 1)
        let indices = coverage.indices(overlapping: window)
        let needed = Int((config.lagRun / coverage.config.cellWidth).rounded(.up))
        func done(_ level: CoverageLevel) -> Bool { level == .covered || level == .skipped }
        let groundLag = indices.filter { done(coverage.level(.wall, $0)) && !done(coverage.level(.ground, $0)) }
        let wallLag = indices.filter { done(coverage.level(.ground, $0)) && !done(coverage.level(.wall, $0)) }
        if groundLag.count >= needed, let mid = middle(groundLag, coverage) { return .aimAtGround(s: mid) }
        if wallLag.count >= needed, let mid = middle(wallLag, coverage) { return .aimAtWall(s: mid) }
        return nil
    }

    /// After both ends are marked: the first stretch between them where a band is not done.
    private func firstHole(coverage: CoverageMap) -> GuidanceTask? {
        guard let left = coverage.leftEnd, let right = coverage.rightEnd, left < right else { return nil }
        let needed = Int((config.lagRun / coverage.config.cellWidth).rounded(.up))
        for band in [SurfaceBand.ground, .wall] {
            var run: [Int] = []
            for index in coverage.indices(overlapping: left...right) {
                let level = coverage.level(band, index)
                if level == .covered || level == .skipped {
                    if run.count >= needed { break }
                    run = []
                } else {
                    run.append(index)
                }
            }
            if run.count >= needed, let mid = middle(run, coverage) {
                return band == .ground ? .aimAtGround(s: mid) : .aimAtWall(s: mid)
            }
        }
        return nil
    }

    private func middle(_ indices: [Int], _ coverage: CoverageMap) -> Float? {
        guard let first = indices.first, let last = indices.last else { return nil }
        return (coverage.cellRange(first).lowerBound + coverage.cellRange(last).upperBound) / 2
    }

    func isSatisfied(_ task: GuidanceTask, coverage: CoverageMap, camera: CameraFrame?) -> Bool {
        switch task {
        case .walk(let side), .markEnd(let side):
            return (side == .left ? coverage.leftEnd : coverage.rightEnd) != nil
        case .aimAtGround(let s):
            return coverage.coveredFraction(.ground, in: (s - 0.3)...(s + 0.3)) >= 0.8
        case .aimAtWall(let s):
            return coverage.coveredFraction(.wall, in: (s - 0.3)...(s + 0.3)) >= 0.8
        case .stepBack:
            guard let camera else { return false }
            return coverage.wall.wallPoint(camera.position).out >= config.tooClose + 0.2
        case .complete:
            return false
        }
    }

    // MARK: Cues

    func target(for task: GuidanceTask, coverage: CoverageMap) -> SIMD3<Float>? {
        let wall = coverage.wall
        switch task {
        case .walk(let side):
            let s = side.sign * (reach(side, coverage: coverage) + 1)
            return wall.world(s: s, height: 1)
        case .markEnd(let side):
            return wall.world(s: side.sign * reach(side, coverage: coverage), height: 0.5)
        case .aimAtGround(let s):
            return wall.world(s: s, height: 0, out: coverage.config.groundBandDepth / 2)
        case .aimAtWall(let s):
            return wall.world(s: s, height: 1.2)
        case .stepBack, .complete:
            return nil
        }
    }

    func path(for task: GuidanceTask, coverage: CoverageMap, camera: CameraFrame?) -> [SIMD3<Float>] {
        guard let camera else { return [] }
        let wall = coverage.wall
        let from = wall.wallPoint(camera.position).s
        let goal: Float
        switch task {
        case .walk(let side): goal = side.sign * (reach(side, coverage: coverage) + 1)
        case .aimAtGround(let s), .aimAtWall(let s): goal = s
        case .markEnd, .stepBack, .complete: return []
        }
        let clipped = from + max(-config.maxPathLength, min(config.maxPathLength, goal - from))
        let steps = max(1, Int((abs(clipped - from) / 0.5).rounded(.up)))
        return (0...steps).map { i in
            wall.world(s: from + (clipped - from) * Float(i) / Float(steps), height: 0, out: config.standOff)
        }
    }
}
