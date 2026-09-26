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
    /// An attempt that goes this long without a photo fails, whatever its frames did.
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
    /// Attempts that went `failAfter` seconds without a photo, plus rejected photos.
    public var failedAttempts: Int
}

/// Fires the meter close-up when the meter has been centered, near, sharp and well exposed for
/// `holdDuration`.
public struct CloseUpGate: Sendable {
    public let config: CloseUpConfig
    private var holdStart: Double?
    /// When the current attempt began: the first frame, or the frame after a failed attempt or a photo.
    private var attemptStart: Double?
    private var recentSharpness: [Double] = []
    private var lastQuality: FrameQuality?
    public private(set) var failedAttempts = 0

    public init(config: CloseUpConfig = CloseUpConfig()) {
        self.config = config
    }

    public mutating func evaluate(_ frame: FrameSample, meter: SIMD3<Float>) -> CloseUpStatus {
        let issue = issue(frame, meter: meter)
        let attempt = attemptStart ?? frame.timestamp
        attemptStart = attempt
        if let issue {
            holdStart = nil
            // Counted on any problem frame once the attempt is old enough, not only after one
            // unbroken problem: frames alternating good and blurry never finish the hold, and a
            // clock reset by every good frame never ran out, so the homeowner never saw the way out.
            // A hold still running at the deadline is left to end in a photo or in the next problem.
            if frame.timestamp - attempt >= config.failAfter {
                failedAttempts += 1
                attemptStart = frame.timestamp
            }
            return CloseUpStatus(hold: 0, issue: issue, fire: false, failedAttempts: failedAttempts)
        }
        let start = holdStart ?? frame.timestamp
        holdStart = start
        let hold = min(1, (frame.timestamp - start) / config.holdDuration)
        if hold >= 1 { attemptStart = nil }
        return CloseUpStatus(hold: hold, issue: nil, fire: hold >= 1, failedAttempts: failedAttempts)
    }

    /// The shutter fired but the stored photo failed a later check: counts as a failed attempt.
    public mutating func photoRejected() {
        failedAttempts += 1
        holdStart = nil
        attemptStart = nil
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
