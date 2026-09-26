import Foundation
import simd

/// One depth map recorded between photos, without an image (packet/README.md, "Depth frames").
/// Photos are kept about every 0.5 m, but an on-device map fuses depth about 10 times a second,
/// so photo-rate depth alone cannot rebuild what the phone saw. The frame must sit on the
/// trajectory, as a photo does: `t` and `pose` are those of an ARFrame the trajectory recorded.
public struct PacketDepthFrame: Sendable {
    /// The manifest id and file stem; `PacketDepthFrame.id(number:)` gives the spec's d00001 form.
    public var id: String
    /// `ARFrame.timestamp`.
    public var t: Double
    /// Camera to meter frame (`MeterFrame.pose(_:)` of `ARFrame.camera.transform`).
    public var pose: simd_float4x4
    /// [fx, fy, cx, cy] in pixels of the depth map itself, not of the camera image: the camera's
    /// intrinsics scaled by the depth map's size (`DepthImage.intrinsics(scaling:...)`).
    public var intrinsics: SIMD4<Float>
    public var tracking: PacketTracking?
    public var depth: DepthPacket

    public init(id: String, t: Double, pose: simd_float4x4, intrinsics: SIMD4<Float>, tracking: PacketTracking?, depth: DepthPacket) {
        self.id = id
        self.t = t
        self.pose = pose
        self.intrinsics = intrinsics
        self.tracking = tracking
        self.depth = depth
    }

    /// "d00001" for 1: the packet's depth-frame naming, five digits.
    public static func id(number: Int) -> String {
        let digits = String(number)
        return "d" + String(repeating: "0", count: max(0, 5 - digits.count)) + digits
    }
}

/// Which depth frames a capture records: at most one every `interval` seconds, and at most
/// `limit` in all. Past the limit nothing more is admitted, so a long walk keeps its first
/// `limit` frames. The live recorder and a replay's packaging both use it.
public struct DepthFrameBudget: Sendable, Equatable {
    /// 2 Hz. packet/README.md asks for "a few hertz": a 256 × 192 frame with confidence is
    /// 245,760 bytes, so 10 Hz, the rate an on-device map fuses, would add about 2.5 MB a second.
    /// 2 Hz adds about 0.5 MB a second, and a frame every 0.5 s is also about one per photo
    /// spacing at walking pace. A choice, not measured: no device capture has been timed.
    public static let rateHz = 2.0
    /// 300 frames: 2.5 minutes at 2 Hz, 73.7 MB at 256 × 192 with confidence, about twice the
    /// README's 40 MB estimate for 80 photos. Share scan holds the recorded frames, the packet
    /// folder and its zip at once while it builds the zip, so the phone briefly needs about three
    /// times that. No measured walk length or storage budget backs the number; revisit it once a
    /// device capture has been measured.
    public static let maxFrames = 300
    /// Frame times jitter around their nominal spacing (ARKit's are not exact multiples of 1/60
    /// s, and a replay's 0.5 s steps may come out as 0.49999). Half a 60 Hz frame of slack keeps
    /// such a stream from losing every other frame to rounding.
    static let slack = 1.0 / 120

    public let interval: Double
    public let limit: Int
    public private(set) var admitted = 0
    private var lastT: Double?

    public init(rateHz: Double = DepthFrameBudget.rateHz, limit: Int = DepthFrameBudget.maxFrames) {
        precondition(rateHz > 0 && rateHz.isFinite && limit >= 0, "a depth-frame budget needs a positive rate and a limit >= 0")
        interval = 1 / rateHz
        self.limit = limit
    }

    public var isFull: Bool { admitted >= limit }

    /// Whether a frame at `t` would be admitted, without admitting it: lets a caller skip copying
    /// a depth map that would be dropped.
    public func wants(t: Double) -> Bool {
        guard !isFull, t.isFinite else { return false }
        guard let lastT else { return true }
        return t - lastT >= interval - Self.slack
    }

    /// Admits a frame at `t` when the budget allows it. Times must arrive in order; one at or
    /// before the last admitted is refused.
    public mutating func admit(t: Double) -> Bool {
        guard wants(t: t) else { return false }
        lastT = t
        admitted += 1
        return true
    }
}
