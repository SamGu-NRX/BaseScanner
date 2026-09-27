import Foundation
import simd

/// What the walk asks for next.
public enum GuidanceTask: Sendable, Equatable {
    /// Walk along the wall toward a side.
    case walk(WalkSide)
    /// The walk has gone `GuidanceConfig.reach` along this side; ask the homeowner to mark where
    /// the wall ends.
    case markEnd(WalkSide)
    /// The ground around `s` is missing: tilt down. The first request of the walk is this at
    /// s = 0, the ground in front of the meter.
    case aimAtGround(s: Float)
    /// The wall band lags around `s`: tilt up or step back.
    case aimAtWall(s: Float)
    /// The camera is too close to the wall to see the band.
    case stepBack
    /// LiDAR found something standing in front of the wall or ground around `s` (hidden cells):
    /// look at that part from another angle or step around the obstruction.
    case seeBehind(s: Float)
    /// Both ends marked and nothing lags between them.
    case complete
}

public struct GuidanceConfig: Sendable, Equatable {
    /// Keep a task at least this long unless it is satisfied, so instructions never flip A, B, A
    /// within 3 s except when a task was completed, which checklist item I6 allows (for example
    /// step back, done, walk on).
    public var minDwell: Double = 3
    /// Ask for the end once the walk has gone this far from the meter on a side: about 20 ft, past
    /// which Base's public 20 ft cable limit (docs/04, Public rule values) rules out for a
    /// placement anyway. It is the walked distance (`CoverageMap.walkedFarthest`), not unbroken
    /// coverage: a hole near the meter held the prompt back for the whole walk on device run 1,
    /// and holes are the aim tasks' and the gap loop's job. "Wall ends here" is on offer before
    /// this for a shorter wall.
    public var reach: Float = 6.1
    /// Closer to the wall than this, a portrait phone camera sees less than about 1.4 m of it.
    public var tooClose: Float = 1.2
    /// A band lagging over at least this much wall near the camera triggers an aim task
    /// (3 cells of 6 in: one missed stride).
    public var lagRun: Float = 0.45
    /// Where the homeowner should stand: this far out from the wall. The walked path is also the
    /// scan's evidence that the space in front of the wall is clear (`CoverageMap.facingSpans()`),
    /// and the server's facing check needs that clearance to exceed D + r = 1.83 + 3 = 4.83 ft
    /// under the public rules, after the position error of 0.3 ft plus 0.16 ft per foot from the
    /// meter is taken off. At the old 1.5 m (4.92 ft) that never happens: 4.92 - 0.3 = 4.62 ft.
    /// At 2 m (6.56 ft), 6.56 - 0.3 - 0.16 |s| > 4.83 holds within 8.9 ft of the meter; for a
    /// battery whose far edge is 5 ft out that leaves 0.63 ft (19 cm) for the walk to drift
    /// closer. Private rules may differ; the server's request names the depth it needs.
    public var standOff: Float = 2.0
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
    /// has been held for `minDwell` seconds and the preferred task differs. An unsatisfied aim
    /// task is kept while the preferred one asks for the same stretch (`sameStretch`), or for the
    /// same band while its own stretch is still in the camera's window and between the ends
    /// (`stillInView`).
    public mutating func update(coverage: CoverageMap, camera: CameraFrame?, time: Double) -> GuidanceOutput {
        let preferred = preferredTask(coverage: coverage, camera: camera)
        if let current, current != preferred {
            let satisfied = isSatisfied(current, coverage: coverage, camera: camera)
            let held = Self.sameStretch(current, preferred) || Self.stillInView(current, preferred, coverage: coverage, camera: camera)
            if satisfied || (time - since >= config.minDwell && !held) {
                self.current = preferred
                since = time
            }
        } else if current == nil {
            current = preferred
            since = time
        }
        return cues(for: current ?? preferred, coverage: coverage, camera: camera)
    }

    /// The target and path of `task` seen from `camera`, without choosing a task. The engine calls
    /// this for frames that must not move the task (a replay frame shown for a tap) so the cues
    /// never lag behind the camera the screen shows.
    public func cues(for task: GuidanceTask, coverage: CoverageMap, camera: CameraFrame?) -> GuidanceOutput {
        GuidanceOutput(task: task, target: target(for: task, coverage: coverage, camera: camera), path: path(for: task, coverage: coverage, camera: camera))
    }

    // MARK: Choosing

    /// How far from the meter coverage runs unbroken on a side, over both bands (skipped cells
    /// count as done). Where the walk heads and where it stalls behind something hidden; the end
    /// prompt and a walked end go by the walked path instead (`walkedFarthest`, `WalkedEnd`).
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
        if let camera, let blocked = hiddenNearCamera(coverage: coverage, camera: camera) {
            return blocked
        }
        if !groundByMeterDone(coverage) {
            return .aimAtGround(s: 0)
        }
        if let camera, let lag = laggingBand(coverage: coverage, camera: camera) {
            return lag
        }
        for side in [WalkSide.left, .right] {
            let end = side == .left ? coverage.leftEnd : coverage.rightEnd
            guard end == nil else { continue }
            return coverage.walkedFarthest(side) >= config.reach ? .markEnd(side) : .walk(side)
        }
        if let hole = firstHole(coverage: coverage) {
            return hole
        }
        return .complete
    }

    /// Half the stretch an aim task asks for, meters either side of its s: what `isSatisfied`
    /// checks and what the guidance log records.
    public static let aimHalfWidth: Float = 0.3
    /// An aim task is satisfied once this share of its stretch's cells is covered.
    public static let aimSatisfied = 0.8

    /// Whether the ground in front of the meter is done: the stretch an aim task at s = 0 asks
    /// for, with skipped cells counting, so "Can't get there" on it moves the walk on. Every check
    /// the server runs starts beside the meter, and on device run 1 nothing asked for this stretch:
    /// the tilt prompts all asked for ground from 2 ft 9 in right of the meter outward. So it is
    /// the walk's first request, before either side. Done when no cell of it is between the ends.
    func groundByMeterDone(_ coverage: CoverageMap) -> Bool {
        let window = -Self.aimHalfWidth...Self.aimHalfWidth
        let cells = coverage.indices(overlapping: window).filter(coverage.isWithinEnds)
        guard !cells.isEmpty else { return true }
        let done = cells.filter { index in
            let level = coverage.level(.ground, index)
            return level == .covered || level == .skipped
        }
        return Double(done.count) >= Self.aimSatisfied * Double(cells.count)
    }

    /// Two aim tasks for the same band whose stretches overlap by more than half: the lag window
    /// slides with the camera, so its middle drifts by a cell or two between updates. Switching on
    /// that drift made the card go from "3 ft 3 in" to "2 ft 9 in right of your meter" on device
    /// run 1 while it still asked for the same ground.
    static func sameStretch(_ a: GuidanceTask, _ b: GuidanceTask) -> Bool {
        switch (a, b) {
        case (.aimAtGround(let x), .aimAtGround(let y)), (.aimAtWall(let x), .aimAtWall(let y)):
            abs(x - y) < aimHalfWidth
        default:
            false
        }
    }

    /// Meters either side of the camera that `laggingBand` and `hiddenNearCamera` look at.
    static let lagWindow: Float = 1

    /// Two aim tasks for the same band while the current one's stretch is still within
    /// `lagWindow` of the camera. `sameStretch` compares with the preferred task at each update,
    /// so small drifts added up: on device run 2 the card went 5 ft 3 in, 4 ft 9 in, 4 ft 6 in,
    /// 4 ft, each step under half the stretch but 0.38 m in all, while the same ground was still
    /// in front of the homeowner. Not past a marked end, where nothing is recorded and the request
    /// could never be met.
    static func stillInView(_ current: GuidanceTask, _ preferred: GuidanceTask, coverage: CoverageMap, camera: CameraFrame?) -> Bool {
        guard let camera else { return false }
        let cameraS = coverage.wall.wallPoint(camera.position).s
        switch (current, preferred) {
        case (.aimAtGround(let s), .aimAtGround), (.aimAtWall(let s), .aimAtWall):
            return abs(s - cameraS) <= lagWindow && s >= (coverage.leftEnd ?? -.infinity) && s <= (coverage.rightEnd ?? .infinity)
        default:
            return false
        }
    }

    /// A band that lags the other around the camera: the other band is covered there but this one
    /// isn't, over at least `lagRun`. Only cells between the ends count: cells seen before an end
    /// was set stay in the map, but past it nothing is observed or skipped, so a task there could
    /// never be met or refused (issue #38).
    private func laggingBand(coverage: CoverageMap, camera: CameraFrame) -> GuidanceTask? {
        let s = coverage.wall.wallPoint(camera.position).s
        let window = (s - Self.lagWindow)...(s + Self.lagWindow)
        let indices = coverage.indices(overlapping: window).filter(coverage.isWithinEnds)
        let needed = Int((config.lagRun / coverage.config.cellWidth).rounded(.up))
        func done(_ level: CoverageLevel) -> Bool { level == .covered || level == .skipped }
        let groundLag = indices.filter { done(coverage.level(.wall, $0)) && !done(coverage.level(.ground, $0)) }
        let wallLag = indices.filter { done(coverage.level(.ground, $0)) && !done(coverage.level(.wall, $0)) }
        if groundLag.count >= needed, let mid = middle(groundLag, coverage) { return .aimAtGround(s: mid) }
        if wallLag.count >= needed, let mid = middle(wallLag, coverage) { return .aimAtWall(s: mid) }
        return nil
    }

    /// Cells hidden in either band around the camera, over at least `lagRun`, between the ends as
    /// for `laggingBand`. It comes before a lagging band: aiming at a band something stands in
    /// front of adds nothing.
    private func hiddenNearCamera(coverage: CoverageMap, camera: CameraFrame) -> GuidanceTask? {
        let s = coverage.wall.wallPoint(camera.position).s
        let needed = Int((config.lagRun / coverage.config.cellWidth).rounded(.up))
        let hidden = coverage.indices(overlapping: (s - Self.lagWindow)...(s + Self.lagWindow)).filter { index in
            coverage.isWithinEnds(index) && SurfaceBand.allCases.contains { coverage.level($0, index) == .hidden }
        }
        guard hidden.count >= needed, let mid = middle(hidden, coverage) else { return nil }
        return .seeBehind(s: mid)
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
            return coverage.coveredFraction(.ground, in: (s - Self.aimHalfWidth)...(s + Self.aimHalfWidth)) >= Self.aimSatisfied
        case .aimAtWall(let s):
            return coverage.coveredFraction(.wall, in: (s - Self.aimHalfWidth)...(s + Self.aimHalfWidth)) >= Self.aimSatisfied
        case .stepBack:
            guard let camera else { return false }
            return coverage.wall.wallPoint(camera.position).out >= config.tooClose + 0.2
        case .seeBehind(let s):
            return !coverage.indices(overlapping: (s - 0.3)...(s + 0.3)).contains { index in
                coverage.isWithinEnds(index) && SurfaceBand.allCases.contains { coverage.level($0, index) == .hidden }
            }
        case .complete:
            return false
        }
    }

    // MARK: Cues

    /// Where a walk toward `side` heads: 1 m past whichever is farther on that side, the unbroken
    /// coverage or the camera. Reach alone stops at the first hole, so a homeowner already past a
    /// hole would get a target behind them, and the arrow would point against "walk right". Holes
    /// are the job of the aim tasks, which ask for them once they are near or both ends are marked.
    func walkGoal(_ side: WalkSide, coverage: CoverageMap, camera: CameraFrame?) -> Float {
        var ahead = reach(side, coverage: coverage)
        if let camera { ahead = max(ahead, side.sign * coverage.wall.wallPoint(camera.position).s) }
        return side.sign * (ahead + 1)
    }

    func target(for task: GuidanceTask, coverage: CoverageMap, camera: CameraFrame?) -> SIMD3<Float>? {
        let wall = coverage.wall
        switch task {
        case .walk(let side):
            return wall.world(s: walkGoal(side, coverage: coverage, camera: camera), height: 1)
        case .aimAtGround(let s):
            return wall.world(s: s, height: 0, out: coverage.config.groundBandDepth / 2)
        case .aimAtWall(let s):
            return wall.world(s: s, height: 1.2)
        case .seeBehind(let s):
            // The wall's foot, where the two bands meet: either may be the hidden one.
            return wall.world(s: s, height: 0)
        // "Wall ends here" lands where the reticle meets the wall, so the reticle is the only aim;
        // the ring sat at the covered reach, which can be at the meter however far the walk went.
        case .markEnd, .stepBack, .complete:
            return nil
        }
    }

    func path(for task: GuidanceTask, coverage: CoverageMap, camera: CameraFrame?) -> [SIMD3<Float>] {
        guard let camera else { return [] }
        let wall = coverage.wall
        let from = wall.wallPoint(camera.position).s
        let goal: Float
        switch task {
        case .walk(let side): goal = walkGoal(side, coverage: coverage, camera: camera)
        case .aimAtGround(let s), .aimAtWall(let s): goal = s
        // No path for seeBehind: which way round the obstruction is clear is not known, and a path
        // to straight in front of it could lead to the same blocked view.
        case .markEnd, .stepBack, .seeBehind, .complete: return []
        }
        let clipped = from + max(-config.maxPathLength, min(config.maxPathLength, goal - from))
        let steps = max(1, Int((abs(clipped - from) / 0.5).rounded(.up)))
        return (0...steps).map { i in
            wall.world(s: from + (clipped - from) * Float(i) / Float(steps), height: 0, out: config.standOff)
        }
    }
}
