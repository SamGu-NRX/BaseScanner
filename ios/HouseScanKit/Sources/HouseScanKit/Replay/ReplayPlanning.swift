import Foundation
import simd

/// A replay frame reduced to what coverage needs.
public struct PlannedFrame: Sendable, Equatable {
    public var camera: CameraFrame
    public var timestamp: Double
    public var trackingNormal: Bool

    public init(camera: CameraFrame, timestamp: Double, trackingNormal: Bool) {
        self.camera = camera
        self.timestamp = timestamp
        self.trackingNormal = trackingNormal
    }
}

/// Plans for replays that carry no wall of their own, and for the autopilot's gap loop.
public enum ReplayPlanning {
    /// A wall assumed from the trajectory alone, for replays recorded without wall taps.
    ///
    /// The wall runs parallel to the principal horizontal walking direction, on the side the
    /// camera mostly looks toward. The ground is assumed 1.4 m below the mean camera height (a
    /// phone held at chest height), and the meter 1.5 m above the ground. The offset (searched from
    /// 1.5 m to 8 m in 0.25 m steps) and the meter's place along the wall are the pair that lets
    /// the most cells be covered within `reach` of the meter, the stretch the gap planner and the
    /// walk care about; among equal meter places, the one nearest the middle of the walk wins.
    ///
    /// The meter is not simply put at the middle of the walk because a walk need not look at the
    /// wall there: on the ADVIO replay (advio-20-0040-0075) the camera faces the wall only for
    /// frames 14 to 29, about 13 to 5.5 m before the middle, and faces away or straight ahead
    /// elsewhere. With the meter at the middle (and the 1.5 m offset that then covered most), the
    /// nearest covered cell was 2.9 m away and the ground from 2.9 m left to 6.1 m right of the
    /// meter was a gap no frame sees, so no held-back window could make a closable gap.
    /// This is an assumption for exercising the flow, not a measurement.
    public static func assumedWall(
        frames: [PlannedFrame], config: CoverageConfig = CoverageConfig(), reach: Float = GapPlannerConfig().reach
    ) -> (wall: WallFrame, coveredCells: Int, offset: Float)? {
        guard frames.count >= 2 else { return nil }
        let positions = frames.map(\.camera.position)
        let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
        var cxx: Float = 0, czz: Float = 0, cxz: Float = 0
        for p in positions {
            let d = p - centroid
            cxx += d.x * d.x
            czz += d.z * d.z
            cxz += d.x * d.z
        }
        let angle = 0.5 * atan2(2 * cxz, cxx - czz)
        let direction = SIMD3<Float>(cos(angle), 0, sin(angle))
        let perpendicular = SIMD3<Float>(-direction.z, 0, direction.x)
        let look = frames.map { SIMD3($0.camera.forward.x, 0, $0.camera.forward.z) }.reduce(.zero, +)
        let side: Float = simd_dot(look, perpendicular) >= 0 ? 1 : -1
        let outward = -perpendicular * side
        let groundY = centroid.y - 1.4
        let middle = middleOfPath(positions)

        var best: (wall: WallFrame, coveredCells: Int, offset: Float)?
        for step in 0...26 {
            let offset = 1.5 + Float(step) * 0.25
            let planePoint = centroid + perpendicular * side * offset
            let onLine = middle - outward * simd_dot(middle - planePoint, outward)
            guard let wall = WallFrame(meter: SIMD3(onLine.x, groundY + 1.5, onLine.z), outward: outward, groundY: groundY) else { continue }
            var map = CoverageMap(wall: wall, config: config)
            for frame in frames { map.observe(frame.camera, trackingNormal: frame.trackingNormal, time: frame.timestamp) }
            guard let (shift, count) = bestMeterShift(map, reach: reach), count > (best?.coveredCells ?? -1) else { continue }
            // A whole number of cells, so the shifted wall's cells are the ones counted here.
            let meter = wall.meter + wall.along * (Float(shift) * config.cellWidth)
            guard let shifted = WallFrame(meter: meter, outward: outward, groundY: groundY) else { continue }
            best = (shifted, count, offset)
        }
        return best
    }

    /// The meter shift along the wall, in whole cells, with the most covered cells (both bands)
    /// within `reach` of the shifted meter, and that count. Ties go to the shift whose thinner side
    /// has the most covered cells, so the walk covers both sides of the meter, then to the
    /// smallest shift.
    private static func bestMeterShift(_ map: CoverageMap, reach: Float) -> (shift: Int, count: Int)? {
        guard let extent = map.seenExtent else { return nil }
        let width = map.config.cellWidth
        func covered(_ range: ClosedRange<Float>) -> Int {
            map.indices(overlapping: range).reduce(0) { total, index in
                total + SurfaceBand.allCases.filter { map.level($0, index) == .covered }.count
            }
        }
        var best: (shift: Int, count: Int, balance: Int)?
        for shift in map.indices(overlapping: extent) {
            let center = Float(shift) * width
            let left = covered((center - reach)...center)
            let right = covered(center...(center + reach))
            let candidate = (shift: shift, count: left + right, balance: min(left, right))
            if let current = best {
                let better = candidate.count != current.count ? candidate.count > current.count
                    : candidate.balance != current.balance ? candidate.balance > current.balance
                    : abs(shift) < abs(current.shift)
                guard better else { continue }
            }
            best = candidate
        }
        return best.map { ($0.shift, $0.count) }
    }

    private static func middleOfPath(_ positions: [SIMD3<Float>]) -> SIMD3<Float> {
        var lengths: [Float] = [0]
        for i in 1..<positions.count { lengths.append(lengths[i - 1] + simd_distance(positions[i], positions[i - 1])) }
        let half = (lengths.last ?? 0) / 2
        let index = lengths.firstIndex { $0 >= half } ?? 0
        return positions[index]
    }

    /// Coverage from walking `frames` through auto-capture (without image quality, which a
    /// planner has no pixels for) and the coverage map.
    public static func simulateWalk(_ frames: [PlannedFrame], wall: WallFrame, config: CoverageConfig = CoverageConfig()) -> CoverageMap {
        var map = CoverageMap(wall: wall, config: config)
        var capture = AutoCapture()
        for frame in frames {
            let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.trackingNormal ? .normal : .limited, quality: nil)
            let decision = capture.evaluate(sample, newlySeenCells: map.newlySeenCount(from: frame.camera))
            if decision.isKeep {
                capture.didKeep(sample)
                map.observe(frame.camera, trackingNormal: frame.trackingNormal, time: frame.timestamp)
            }
        }
        return map
    }

    public struct HeldBackWindow: Sendable, Equatable {
        /// Frame indices held back from the walk and replayed for the gap.
        public var frames: Range<Int>
        /// Wall ends to mark: the covered extremes of the walk without the window.
        public var ends: ClosedRange<Float>
        /// The gap the planner finds after that walk.
        public var gap: GapPlan
    }

    /// Chooses frames to hold back from the autopilot's walk so the gap loop has something real
    /// to do: without them the planner finds a gap, and replaying them alone closes it.
    ///
    /// Candidates are contiguous windows of 3 to 10 frames, tried from the middle of the walk
    /// outward. Each is screened on coverage rebuilt from what every frame sees (computed once),
    /// then confirmed with the full auto-capture simulation the app runs. Nil when no window works,
    /// for example when the planner's nearest gap is one no frame of the replay can close.
    public static func heldBackWindow(frames: [PlannedFrame], wall: WallFrame, planner: GapPlanner = GapPlanner(), config: CoverageConfig = CoverageConfig()) -> HeldBackWindow? {
        guard frames.count >= 6 else { return nil }
        let empty = CoverageMap(wall: wall, config: config)
        let sightings = frames.map { $0.trackingNormal ? empty.visibleCells(from: $0.camera) : [] }
        let kept = Set(keptIndices(frames, wall: wall, config: config))
        let middle = frames.count / 2
        let starts = (2..<(frames.count - 1)).sorted { abs($0 - middle) < abs($1 - middle) }
        var confirmations = 0
        for size in [4, 6, 3, 8, 10] {
            for start in starts where start + size <= frames.count {
                let window = start..<(start + size)
                var rest = CoverageMap(wall: wall, config: config)
                for index in kept.sorted() where !window.contains(index) {
                    rest.record(sightings[index], from: frames[index].camera.position)
                }
                guard let ends = coveredExtremes(rest) else { continue }
                rest.setEnd(.left, at: ends.lowerBound)
                rest.setEnd(.right, at: ends.upperBound)
                guard let gap = planner.plan(rest) else { continue }
                var restored = rest
                for index in window { restored.record(sightings[index], from: frames[index].camera.position) }
                guard planner.isSatisfied(gap, restored) else { continue }
                // Screened: confirm with the exact auto-capture path, a few times at most.
                confirmations += 1
                if let confirmed = confirm(frames, window: window, wall: wall, planner: planner, config: config) {
                    return confirmed
                }
                if confirmations >= 12 { return nil }
            }
        }
        return nil
    }

    /// `heldBackWindow` for a replay whose coverage comes from the 3D map (`-coverage map3d`), which
    /// counts what LiDAR depth saw from every frame, not only what kept frames pointed at. `depths`
    /// holds each frame's depth, nil where it has none.
    ///
    /// A window is held back only if the map is left with a gap without it, and the window's own
    /// frames close it: a map built from every other frame, in replay order, leaves the planner a
    /// gap between the covered extremes, and integrating the frames the app replays for the gap
    /// (`gapReplayRange`) satisfies it. Frames with limited tracking add nothing, as in the app.
    ///
    /// Building a map costs one integration per frame, so windows are tried in order of how many
    /// cells their frames' depth alone shows (`CoverageMap.visibleCells(from:depth:)` with nothing
    /// else seeing the cell) between the cells the other frames show: ground before wall, nearest
    /// the meter first, as `GapPlanner.plan` chooses its gap. A window whose gap would come after
    /// one the map keeps with every frame is not tried: the planner would ask for that one. At
    /// most `maxTries` are built. Nil when none works, as on a replay whose nearest gap is a
    /// stretch no frame's depth reaches.
    public static func heldBackWindow(
        frames: [PlannedFrame], depths: [DepthImage?], wall: WallFrame, planner: GapPlanner = GapPlanner(),
        config: CoverageConfig = CoverageConfig(), mapConfig: Map3DConfig = Map3DConfig(), maxTries: Int = 4
    ) -> HeldBackWindow? {
        precondition(depths.count == frames.count, "\(depths.count) depth entries for \(frames.count) frames")
        guard frames.count >= 6 else { return nil }
        let depthFrames = frames.indices.map { index -> DepthFrame? in
            guard frames[index].trackingNormal, let image = depths[index] else { return nil }
            return DepthFrame(image: image, pose: frames[index].camera)
        }
        let empty = CoverageMap(wall: wall, config: config)
        struct Cell: Hashable {
            var band: SurfaceBand
            var index: Int
        }
        let seen: [Set<Cell>] = frames.indices.map { index in
            guard let image = depths[index], frames[index].trackingNormal else { return [] }
            let sightings = empty.visibleCells(from: frames[index].camera, depth: CoverageMap.storedDepth(image))
            return Set(sightings.filter { !$0.rows.isEmpty }.map { Cell(band: $0.band, index: $0.index) })
        }
        var seenBy: [Cell: Int] = [:]
        for cells in seen { for cell in cells { seenBy[cell, default: 0] += 1 } }
        let reach = planner.config.reach
        var candidates: [(window: Range<Int>, band: Int, distance: Float, only: Int)] = []
        for size in [4, 6, 3, 8, 10] {
            for start in 2..<max(2, frames.count - 1) where start + size <= frames.count {
                let window = start..<(start + size)
                var inWindow: [Cell: Int] = [:]
                for index in window { for cell in seen[index] { inWindow[cell, default: 0] += 1 } }
                // The walk's ends go at what the other frames cover, so only a hole between those
                // is a gap; cells past them would just move an end.
                let outside = seenBy.filter { cell, count in count > inWindow[cell, default: 0] }.map(\.key.index)
                guard let low = outside.min(), let high = outside.max() else { continue }
                let only = inWindow.keys.filter { cell in
                    seenBy[cell] == inWindow[cell] && cell.index > low && cell.index < high && abs(empty.cellRange(cell.index).lowerBound) <= reach
                }
                // The planner asks for the ground run nearest the meter first, then the wall's, so
                // a window is only useful if its gap is nearer than any stretch no frame shows.
                let nearest = only.map { cell in
                    (cell.band == .ground ? 0 : 1, abs(empty.cellRange(cell.index).lowerBound + empty.config.cellWidth / 2))
                }.min { $0 < $1 }
                if let nearest, only.count >= 2 { candidates.append((window, nearest.0, nearest.1, only.count)) }
            }
        }
        candidates.sort { a, b in
            (a.band, a.distance, -a.only, a.window.count) < (b.band, b.distance, -b.only, b.window.count)
        }

        func measured(_ map: Map3D, into coverage: inout CoverageMap) {
            coverage.setMeasuredCovered(coverage.cells(seenIn: map.coverage(along: wall)))
        }
        // A gap the map has with every frame (a stretch behind a bin that no view gets past) is
        // one no window removes, and the planner asks for it before any gap farther out or on the
        // wall. One map of every frame finds it; only windows whose gap would come first are tried.
        var full = Map3D(frame: MapFrame(wall: wall), config: mapConfig)
        for depth in depthFrames.compactMap({ $0 }) { full.integrate(depth) }
        var fullCoverage = CoverageMap(wall: wall, config: config)
        measured(full, into: &fullCoverage)
        if let ends = coveredExtremes(fullCoverage) {
            fullCoverage.setEnd(.left, at: ends.lowerBound)
            fullCoverage.setEnd(.right, at: ends.upperBound)
            if let standing = planner.plan(fullCoverage) {
                let band = standing.band == .ground ? 0 : 1
                let span = standing.span
                let distance: Float = span.contains(0) ? 0 : min(abs(span.lowerBound), abs(span.upperBound))
                candidates.removeAll { ($0.band, $0.distance) >= (band, distance) }
            }
        }
        for candidate in candidates.prefix(maxTries) {
            let window = candidate.window
            var rest = Map3D(frame: MapFrame(wall: wall), config: mapConfig)
            for index in frames.indices where !window.contains(index) {
                if let depth = depthFrames[index] { rest.integrate(depth) }
            }
            var walked = CoverageMap(wall: wall, config: config)
            measured(rest, into: &walked)
            guard let ends = coveredExtremes(walked) else { continue }
            walked.setEnd(.left, at: ends.lowerBound)
            walked.setEnd(.right, at: ends.upperBound)
            guard let gap = planner.plan(walked) else { continue }
            var restored = rest
            for index in gapReplayRange(window) {
                if let depth = depthFrames[index] { restored.integrate(depth) }
            }
            var after = walked
            measured(restored, into: &after)
            guard planner.isSatisfied(gap, after) else { continue }
            return HeldBackWindow(frames: window, ends: ends, gap: gap)
        }
        return nil
    }

    private static func keptIndices(_ frames: [PlannedFrame], wall: WallFrame, config: CoverageConfig) -> [Int] {
        var map = CoverageMap(wall: wall, config: config)
        var capture = AutoCapture()
        var kept: [Int] = []
        for (index, frame) in frames.enumerated() {
            let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.trackingNormal ? .normal : .limited, quality: nil)
            if capture.evaluate(sample, newlySeenCells: map.newlySeenCount(from: frame.camera)).isKeep {
                capture.didKeep(sample)
                map.observe(frame.camera, trackingNormal: frame.trackingNormal, time: frame.timestamp)
                kept.append(index)
            }
        }
        return kept
    }

    private static func coveredExtremes(_ map: CoverageMap) -> ClosedRange<Float>? {
        let intervals = map.coveredIntervals(.wall) + map.coveredIntervals(.ground)
        guard let low = intervals.map(\.lowerBound).min(), let high = intervals.map(\.upperBound).max(), low < 0, high > 0 else { return nil }
        return low...high
    }

    private static func confirm(_ frames: [PlannedFrame], window: Range<Int>, wall: WallFrame, planner: GapPlanner, config: CoverageConfig) -> HeldBackWindow? {
        var rest = frames
        rest.removeSubrange(window)
        var walked = simulateWalk(rest, wall: wall, config: config)
        guard let ends = coveredExtremes(walked) else { return nil }
        walked.setEnd(.left, at: ends.lowerBound)
        walked.setEnd(.right, at: ends.upperBound)
        guard let gap = planner.plan(walked),
              satisfiedWithLeadIn(frames, window: window, walked: walked, gap: gap, planner: planner) else { return nil }
        return HeldBackWindow(frames: window, ends: ends, gap: gap)
    }

    /// The frames the app replays for a held-back window: two lead-in frames before it, so the
    /// auto-capture's tracking-stable wait (0.5 s) has passed when the window starts.
    public static func gapReplayRange(_ window: Range<Int>) -> Range<Int> {
        max(0, window.lowerBound - 2)..<window.upperBound
    }

    private static func satisfiedWithLeadIn(_ frames: [PlannedFrame], window: Range<Int>, walked: CoverageMap, gap: GapPlan, planner: GapPlanner) -> Bool {
        var restored = walked
        var capture = AutoCapture()
        for frame in frames[gapReplayRange(window)] {
            let sample = FrameSample(timestamp: frame.timestamp, camera: frame.camera, tracking: frame.trackingNormal ? .normal : .limited, quality: nil)
            if capture.evaluate(sample, newlySeenCells: restored.newlySeenCount(from: frame.camera)).isKeep {
                capture.didKeep(sample)
                restored.observe(frame.camera, trackingNormal: frame.trackingNormal, time: frame.timestamp)
            }
        }
        return planner.isSatisfied(gap, restored)
    }
}
