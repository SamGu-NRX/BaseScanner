import Foundation
import simd

/// A rigid move about gravity: a turn about +y, then a translation. ARKit's `.gravity` world
/// alignment keeps +y up, so the correction it makes to an anchor as it refines its map is one of
/// these (any tilt left over is noise and is dropped).
public struct YawCorrection: Sendable, Equatable {
    /// Radians, counterclockwise seen from above (+y toward the viewer).
    public var yaw: Float
    public var translation: SIMD3<Float>

    public static let identity = YawCorrection(yaw: 0, translation: .zero)

    public init(yaw: Float, translation: SIMD3<Float>) {
        self.yaw = yaw
        self.translation = translation
    }

    /// The correction that takes an anchor at `old` to `new`, keeping only the turn about +y: it
    /// maps the old anchor's origin onto the new one's and turns the old axes by the yaw between
    /// them. The yaw is read from both horizontal axes, so an anchor whose own axes are tilted (a
    /// wall hit's, whose y axis is the wall's normal) gives the same answer.
    public init(from old: simd_float4x4, to new: simd_float4x4) {
        let turn = Self.rotation(new) * Self.rotation(old).transpose
        let x = turn * SIMD3<Float>(1, 0, 0)
        let z = turn * SIMD3<Float>(0, 0, 1)
        // A turn by θ about +y takes x to (cos θ, 0, -sin θ) and z to (sin θ, 0, cos θ).
        let yaw = atan2(z.x - x.z, x.x + z.z)
        let oldOrigin = SIMD3(old.columns.3.x, old.columns.3.y, old.columns.3.z)
        let newOrigin = SIMD3(new.columns.3.x, new.columns.3.y, new.columns.3.z)
        self.init(yaw: yaw, translation: .zero)
        translation = newOrigin - direction(oldOrigin)
    }

    public func direction(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return SIMD3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z)
    }

    public func point(_ p: SIMD3<Float>) -> SIMD3<Float> { direction(p) + translation }

    /// A camera-to-world pose moved with the world.
    public func pose(_ m: simd_float4x4) -> simd_float4x4 { matrix * m }

    /// A camera moved with the world; its lens is unchanged.
    public func moved(_ camera: CameraFrame) -> CameraFrame {
        CameraFrame(cameraToWorld: pose(camera.cameraToWorld), intrinsics: camera.intrinsics, imageSize: camera.imageSize)
    }

    /// This correction followed by `next`.
    public func then(_ next: YawCorrection) -> YawCorrection {
        YawCorrection(yaw: yaw + next.yaw, translation: next.direction(translation) + next.translation)
    }

    public var matrix: simd_float4x4 {
        let x = direction(SIMD3(1, 0, 0)), z = direction(SIMD3(0, 0, 1))
        return simd_float4x4(SIMD4(x, 0), SIMD4(0, 1, 0, 0), SIMD4(z, 0), SIMD4(translation, 1))
    }

    private static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }
}

/// The meter anchor's pose that the captured geometry (the wall, its corners, the kept cameras,
/// the tapped marks) currently agrees with, and the corrections to apply to all of it as ARKit
/// refines the anchor. Everything captured moves with the anchor as one rigid body, so the
/// relations between the wall and what was seen of it never change: nothing has to be rebuilt,
/// and a later correction can't undo an earlier one.
public struct MeterAnchorTracking: Sendable, Equatable {
    /// The anchor pose the captured geometry agrees with. The AR result is attached in this pose's
    /// frame (`LiveCapture.showResult`), so it follows the anchor however far it has moved since.
    public private(set) var pose: simd_float4x4

    /// The anchor's pose when the meter was anchored (tapped, or anchored again by a re-fit):
    /// where everything captured since started out.
    public private(set) var anchoredPose: simd_float4x4

    /// How many corrections have been applied since the meter was anchored.
    public private(set) var corrections = 0

    /// A correction is applied once it moves the meter 2 cm, or turns the wall 0.4 degrees, which
    /// moves a point 3 m from the meter (about where a battery stands) 2 cm. ARKit nudges the
    /// anchor by millimetres most frames, and each correction redraws the overlays; 2 cm is far
    /// below the 6 in cell and doesn't show. Smaller ones add up until they reach it.
    public static let minimumMove: Float = 0.02
    public static let minimumTurn: Float = 0.4 * .pi / 180

    /// Every correction applied, with the frame time it was applied at, oldest first.
    public private(set) var log: [(time: Double, correction: YawCorrection)] = []

    public init(pose: simd_float4x4) {
        self.pose = pose
        anchoredPose = pose
    }

    /// All the corrections applied since the meter was anchored, as one: how far ARKit has moved
    /// the meter (world x, y, z, in meters) and turned the wall about gravity (radians). What
    /// hasn't reached `minimumMove` or `minimumTurn` yet isn't in it. A device log of it, with
    /// `MeterAnchorPresence`, tells a map ARKit corrected from drift it never corrected (#73): the
    /// marks and the result follow the first, and nothing on the phone can follow the second.
    public var sinceAnchored: (moved: SIMD3<Float>, yaw: Float) {
        (Self.origin(pose) - Self.origin(anchoredPose), YawCorrection(from: anchoredPose, to: pose).yaw)
    }

    public static func == (a: MeterAnchorTracking, b: MeterAnchorTracking) -> Bool {
        a.pose == b.pose && a.anchoredPose == b.anchoredPose && a.corrections == b.corrections
            && a.log.map(\.time) == b.log.map(\.time) && a.log.map(\.correction) == b.log.map(\.correction)
    }

    /// The correction from `pose` to `anchor`, seen on the frame at `time`, when it is large
    /// enough to apply; the pose then becomes `anchor` and the correction is logged. Nil, and
    /// nothing changes, otherwise.
    public mutating func update(to anchor: simd_float4x4, at time: Double = 0) -> YawCorrection? {
        let correction = YawCorrection(from: pose, to: anchor)
        let origin = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let moved = simd_distance(correction.point(origin), origin)
        guard moved > Self.minimumMove || abs(correction.yaw) > Self.minimumTurn else { return nil }
        pose = anchor
        corrections += 1
        log.append((time, correction))
        return correction
    }

    /// The meter anchored again at `pose`, in the same world frame (a re-fit moved the wall to a
    /// detected plane): later corrections, and the totals since anchored, are measured from it.
    /// The log stays, because it is still what takes a pose captured before now into the current
    /// frame; starting it over would leave the close-up photo, and any keyframe saved before the
    /// re-fit, uncorrected for the moves ARKit made after it was taken.
    public mutating func anchorAgain(at pose: simd_float4x4) {
        self.pose = pose
        anchoredPose = pose
        corrections = 0
    }

    /// What takes a pose captured at `time` into the frame the wall agrees with now: every
    /// correction applied after it, in order. A frame's own anchor is already the corrected one,
    /// so a correction applied on the frame at `time` itself doesn't apply to it.
    public func correction(since time: Double) -> YawCorrection {
        log.filter { $0.time > time }.reduce(.identity) { $0.then($1.correction) }
    }

    /// A camera-to-world pose ARKit reported at `time`, raw, in the frame the wall agrees with
    /// now. The raw pose is kept wherever it is stored (`StoredKeyframe.rawPose`); this is what
    /// scene.json and the packet use.
    public func correctedPose(_ raw: simd_float4x4, capturedAt time: Double) -> simd_float4x4 {
        correction(since: time).pose(raw)
    }

    public func correctedCamera(_ raw: CameraFrame, capturedAt time: Double) -> CameraFrame {
        correction(since: time).moved(raw)
    }

    private static func origin(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}

/// Whether the frames since the meter was anchored carried its anchor, for the drift log (#73).
/// A correction can only reach the marks from a frame that carries the anchor, so a walk with no
/// corrections logged is read against this: frames that had the anchor and never moved it
/// (drift ARKit never corrected), or frames that lost it (nothing could follow it).
public struct MeterAnchorPresence: Sendable, Equatable {
    public enum Sighting: String, Sendable, CaseIterable {
        /// The frame carries the anchor's pose.
        case present
        /// The frame names the anchor, but ARKit no longer lists it among the frame's anchors.
        case missing
        /// The frame names another anchor or none: made before the meter was anchored again, or
        /// after the session let the anchor go.
        case otherAnchor = "other anchor"
    }

    /// What the latest frame showed; nil before the first frame since the meter was anchored.
    public private(set) var last: Sighting?
    public private(set) var present = 0
    public private(set) var missing = 0
    public private(set) var otherAnchor = 0

    public init() {}

    /// Counts a frame. Returns `sighting` when it differs from the frame before's (the first
    /// frame included), nil when it is the same.
    public mutating func observe(_ sighting: Sighting) -> Sighting? {
        switch sighting {
        case .present: present += 1
        case .missing: missing += 1
        case .otherAnchor: otherAnchor += 1
        }
        let changed = sighting != last
        last = sighting
        return changed ? sighting : nil
    }
}

/// The corrections to apply to poses captured at given times, for work off the main actor (the
/// packet writer). Identity when the scan has no anchor (a replay).
public struct PoseCorrections: Sendable {
    private let log: [(time: Double, correction: YawCorrection)]

    public static let none = PoseCorrections(log: [])

    init(log: [(time: Double, correction: YawCorrection)]) {
        self.log = log
    }

    public init(_ tracking: MeterAnchorTracking?) {
        log = tracking?.log ?? []
    }

    public func pose(_ raw: simd_float4x4, capturedAt time: Double) -> simd_float4x4 {
        log.filter { $0.time > time }.reduce(YawCorrection.identity) { $0.then($1.correction) }.pose(raw)
    }
}

extension WallFrame {
    /// Moves the wall with the world: the meter and the ground with the translation, the meter's
    /// piece and every corner's piece turned by the yaw. Every s (the ends, the corners, what was
    /// seen) is measured along the chain from the meter, so none of them changes.
    public mutating func apply(_ correction: YawCorrection) {
        meter = correction.point(meter)
        groundY += correction.translation.y
        turn(by: correction)
    }
}
