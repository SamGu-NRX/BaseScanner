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
    /// camera mostly looks toward, at the offset (searched from 1.5 m to 8 m in 0.25 m steps) that
    /// lets the most cells be covered. The ground is assumed 1.4 m below the mean camera height
    /// (a phone held at chest height), and the meter 1.5 m above the ground at the wall point
    /// nearest the middle of the walk, so the walk covers both sides of it. This is an assumption
    /// for exercising the flow, not a measurement.
    public static func assumedWall(frames: [PlannedFrame], config: CoverageConfig = CoverageConfig()) -> (wall: WallFrame, coveredCells: Int, offset: Float)? {
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
            for frame in frames { map.observe(frame.camera, trackingNormal: frame.trackingNormal) }
            if map.coveredCount > (best?.coveredCells ?? -1) {
                best = (wall, map.coveredCount, offset)
            }
        }
        return best
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
                map.observe(frame.camera, trackingNormal: frame.trackingNormal)
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
    /// to do: without them the planner finds a gap, and replaying them alone satisfies it.
    /// Tries windows of 3 to 8 frames from the middle of the walk outward. Nil when no window
    /// works, for example when nothing is covered at all.
    public static func heldBackWindow(frames: [PlannedFrame], wall: WallFrame, planner: GapPlanner = GapPlanner(), config: CoverageConfig = CoverageConfig()) -> HeldBackWindow? {
        guard frames.count >= 6 else { return nil }
        let middle = frames.count / 2
        let starts = (1..<(frames.count - 2)).sorted { abs($0 - middle) < abs($1 - middle) }
        for size in [4, 6, 3, 8] {
            for start in starts where start + size < frames.count {
                let window = start..<(start + size)
                var rest = frames
                rest.removeSubrange(window)
                var walked = simulateWalk(rest, wall: wall, config: config)
                let extremes = (walked.coveredIntervals(.wall) + walked.coveredIntervals(.ground))
                guard let low = extremes.map(\.lowerBound).min(), let high = extremes.map(\.upperBound).max(), low < 0, high > 0 else { continue }
                walked.setEnd(.left, at: low)
                walked.setEnd(.right, at: high)
                guard let gap = planner.plan(walked) else { continue }
                // The app replays the window with a short lead-in so tracking is stable at its start.
                if satisfiedWithLeadIn(frames, window: window, walked: walked, gap: gap, planner: planner) {
                    return HeldBackWindow(frames: window, ends: low...high, gap: gap)
                }
            }
        }
        return nil
    }

    /// The frames the app replays for a held-back window: one lead-in frame before it, so the
    /// auto-capture's tracking-stable wait has passed when the window starts.
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
                restored.observe(frame.camera, trackingNormal: frame.trackingNormal)
            }
        }
        return planner.isSatisfied(gap, restored)
    }
}
