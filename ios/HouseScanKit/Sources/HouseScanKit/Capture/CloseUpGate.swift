import Foundation
import simd

/// Thresholds of the meter close-up. Hypotheses from the research note's close-up gates, not
/// measured values.
public struct CloseUpConfig: Sendable, Equatable {
    /// The meter must project inside the middle half of the image in each direction, so the whole
    /// face is in frame with room around it.
    public var centralFraction: Float = 0.5
    /// Past 1.5 m a phone camera resolves meter digits poorly.
    public var maxDistance: Float = 1.5
    /// Hold still this long with every gate passing before the shutter fires.
    public var holdDuration: Double = 0.6
    /// A problem that persists this long ends an attempt as failed.
    public var failAfter: Double = 4
    /// Sharpness below half the recent median means shake.
    public var sharpnessRatio: Double = 0.5
    public var minMeanLuma: Double = 40
    public var maxMeanLuma: Double = 225
    public var maxClippedFraction: Double = 0.2

    public init() {}
}

public enum CloseUpIssue: Sendable, Equatable {
    case blurry
    case tooDark
    case tooBright
    case notCentered
    case tooFar
    case tracking
}

public struct CloseUpStatus: Sendable, Equatable {
    /// 0...1 progress of the hold.
    public var hold: Double
    public var issue: CloseUpIssue?
    /// True on the frame the shutter fires.
    public var fire: Bool
    /// Attempts that ended with a problem persisting `failAfter` seconds.
    public var failedAttempts: Int
}

/// Fires the meter close-up when the meter has been centered, near, sharp and well exposed for
/// `holdDuration`.
public struct CloseUpGate: Sendable {
    public let config: CloseUpConfig
    private var holdStart: Double?
    private var problemSince: Double?
    private var recentSharpness: [Double] = []
    private var lastQuality: FrameQuality?
    public private(set) var failedAttempts = 0

    public init(config: CloseUpConfig = CloseUpConfig()) {
        self.config = config
    }

    public mutating func evaluate(_ frame: FrameSample, meter: SIMD3<Float>) -> CloseUpStatus {
        let issue = issue(frame, meter: meter)
        if let issue {
            holdStart = nil
            if problemSince == nil { problemSince = frame.timestamp }
            if let since = problemSince, frame.timestamp - since >= config.failAfter {
                failedAttempts += 1
                problemSince = nil
            }
            return CloseUpStatus(hold: 0, issue: issue, fire: false, failedAttempts: failedAttempts)
        }
        problemSince = nil
        let start = holdStart ?? frame.timestamp
        holdStart = start
        let hold = min(1, (frame.timestamp - start) / config.holdDuration)
        return CloseUpStatus(hold: hold, issue: nil, fire: hold >= 1, failedAttempts: failedAttempts)
    }

    /// The shutter fired but the stored photo failed a later check: counts as a failed attempt.
    public mutating func photoRejected() {
        failedAttempts += 1
        holdStart = nil
    }

    private mutating func issue(_ frame: FrameSample, meter: SIMD3<Float>) -> CloseUpIssue? {
        let median: Double? = recentSharpness.isEmpty ? nil : recentSharpness.sorted()[recentSharpness.count / 2]
        if let quality = frame.quality {
            lastQuality = quality
            recentSharpness.append(quality.sharpness)
            if recentSharpness.count > 15 { recentSharpness.removeFirst() }
        }
        guard frame.tracking == .normal else { return .tracking }
        guard let pixel = frame.camera.pixel(of: meter) else { return .notCentered }
        let size = frame.camera.imageSize
        let half = size * (config.centralFraction / 2)
        let center = size / 2
        if abs(pixel.x - center.x) > half.x || abs(pixel.y - center.y) > half.y { return .notCentered }
        if simd_distance(frame.camera.position, meter) > config.maxDistance { return .tooFar }
        if let quality = frame.quality ?? lastQuality {
            if quality.meanLuma < config.minMeanLuma { return .tooDark }
            if quality.meanLuma > config.maxMeanLuma || quality.clippedFraction > config.maxClippedFraction { return .tooBright }
            if let median, quality.sharpness < median * config.sharpnessRatio { return .blurry }
        }
        return nil
    }
}
