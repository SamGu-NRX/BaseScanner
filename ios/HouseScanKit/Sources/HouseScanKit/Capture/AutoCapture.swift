import Foundation
import simd

/// Tracking as the capture logic needs it.
public enum TrackingStatus: Sendable, Equatable {
    case notAvailable
    case normal
    case limited
}

/// One frame offered to auto-capture.
public struct FrameSample: Sendable, Equatable {
    /// Seconds on the frame clock (ARFrame.timestamp, or the replay's timestamps).
    public var timestamp: Double
    public var camera: CameraFrame
    public var tracking: TrackingStatus
    /// Nil when this frame was not measured; the gate then reuses the last measurement.
    public var quality: FrameQuality?

    public init(timestamp: Double, camera: CameraFrame, tracking: TrackingStatus, quality: FrameQuality?) {
        self.timestamp = timestamp
        self.camera = camera
        self.tracking = tracking
        self.quality = quality
    }
}

/// Thresholds of the auto-capture gate. Each is a hypothesis with its reason; none is calibrated.
public struct AutoCaptureConfig: Sendable, Equatable {
    /// ARKit's first half second after (re)gaining normal tracking still moves the map around.
    public var stableTracking: Double = 0.5
    /// Brisk walking is about 1.4 m/s; faster than 1.5 m/s the homeowner is hurrying past the wall.
    /// Blur itself is judged by sharpness below; this is a coarse backstop.
    public var maxSpeed: Float = 1.5
    /// Panning faster than 60°/s smears a phone camera's image at typical outdoor shutter speeds.
    public var maxAngularSpeed: Float = 60 * .pi / 180
    /// A frame less than half as sharp as the recent median is probably motion-blurred.
    public var sharpnessRatio: Double = 0.5
    public var sharpnessWindow = 15
    /// Keyframe spacing from docs/00 (Conventions the code relies on) and Measure Lab: 0.5 m or 15° since the last kept frame.
    public var spacingMeters: Float = 0.5
    public var spacingRadians: Float = 15 * .pi / 180
    /// A frame that would see this many unseen cells (3 cells, about 0.45 m of one band) is worth
    /// keeping even before the spacing is reached.
    public var newCellsToKeep = 3
    /// At most about 3 kept frames per second, to bound storage and upload size.
    public var minInterval: Double = 0.33
    /// Mean luma below 40 of 255 is too dark to see ground texture; above 0.25 clipped is glare.
    public var minMeanLuma: Double = 40
    public var maxClippedFraction: Double = 0.25

    public init() {}
}

/// Why a frame was or wasn't kept. The skip reasons double as coaching.
public enum CaptureDecision: Sendable, Equatable {
    case keep(KeepReason)
    case skip(SkipReason)

    public enum KeepReason: Sendable, Equatable {
        case spacing
        case newCoverage
        case first
    }

    public enum SkipReason: Sendable, Equatable {
        case trackingNotReady
        case tooSoon
        /// The phone moved faster than `AutoCaptureConfig.maxSpeed`: walking too fast.
        case movingFast
        /// The phone turned faster than `AutoCaptureConfig.maxAngularSpeed` without moving too
        /// fast: a tilt or a pan, often while standing still. Kept apart from `movingFast` so
        /// coaching doesn't tell someone standing still to walk slower (#26).
        case turningFast
        case blurry
        case tooDark
        case tooBright
        case redundant
    }

    public var isKeep: Bool {
        if case .keep = self { return true }
        return false
    }
}

/// Decides which frames of the walk become keyframes.
public struct AutoCapture: Sendable {
    public let config: AutoCaptureConfig
    private var normalSince: Double?
    private var previous: FrameSample?
    private var lastKept: FrameSample?
    private var recentSharpness: [Double] = []
    private var lastQuality: FrameQuality?

    public init(config: AutoCaptureConfig = AutoCaptureConfig()) {
        self.config = config
    }

    /// Median sharpness of recent measured frames, nil before any.
    public var medianSharpness: Double? {
        guard !recentSharpness.isEmpty else { return nil }
        let sorted = recentSharpness.sorted()
        return sorted[sorted.count / 2]
    }

    /// Judges a frame. `newlySeenCells` is how many unseen coverage cells it would see.
    /// Call `didKeep` when the frame is actually stored.
    public mutating func evaluate(_ frame: FrameSample, newlySeenCells: Int) -> CaptureDecision {
        defer { previous = frame }
        if frame.tracking == .normal {
            if normalSince == nil { normalSince = frame.timestamp }
        } else {
            normalSince = nil
        }
        let medianBefore = medianSharpness
        if let quality = frame.quality {
            lastQuality = quality
            recentSharpness.append(quality.sharpness)
            if recentSharpness.count > config.sharpnessWindow { recentSharpness.removeFirst() }
        }
        guard let normalSince, frame.timestamp - normalSince >= config.stableTracking else {
            return .skip(.trackingNotReady)
        }
        if let previous, frame.timestamp > previous.timestamp {
            let dt = Float(frame.timestamp - previous.timestamp)
            let speed = simd_distance(frame.camera.position, previous.camera.position) / dt
            let turn = frame.camera.rotationAngle(to: previous.camera) / dt
            if speed > config.maxSpeed { return .skip(.movingFast) }
            if turn > config.maxAngularSpeed { return .skip(.turningFast) }
        }
        if let quality = frame.quality ?? lastQuality {
            if quality.meanLuma < config.minMeanLuma { return .skip(.tooDark) }
            if quality.clippedFraction > config.maxClippedFraction { return .skip(.tooBright) }
            if let medianBefore, quality.sharpness < medianBefore * config.sharpnessRatio { return .skip(.blurry) }
        }
        guard let lastKept else { return .keep(.first) }
        if frame.timestamp - lastKept.timestamp < config.minInterval { return .skip(.tooSoon) }
        let moved = simd_distance(frame.camera.position, lastKept.camera.position)
        let turned = frame.camera.rotationAngle(to: lastKept.camera)
        if moved >= config.spacingMeters || turned >= config.spacingRadians { return .keep(.spacing) }
        if newlySeenCells >= config.newCellsToKeep { return .keep(.newCoverage) }
        return .skip(.redundant)
    }

    public mutating func didKeep(_ frame: FrameSample) {
        lastKept = frame
    }

    /// Forget the kept-frame history, for example after a relocalization failure.
    public mutating func reset() {
        self = AutoCapture(config: config)
    }
}
