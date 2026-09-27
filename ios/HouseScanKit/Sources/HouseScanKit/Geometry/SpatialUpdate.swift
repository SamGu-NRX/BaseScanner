import Foundation
import simd

/// Whether the ground under the wall is measured, and the error a guess carries.
public struct GroundEvidence: Sendable, Equatable {
    public private(set) var measured: Bool
    /// The error of the chest-height guess, meters, restored when the plane that measured the
    /// ground stops supporting it.
    public let guessError: Float

    public init(measured: Bool, guessError: Float) {
        self.measured = measured
        self.guessError = guessError
    }

    mutating func set(measured: Bool) {
        self.measured = measured
    }
}

/// What one frame from the live session does to the captured geometry, in the order that keeps
/// both parts in the same frame: the meter anchor's correction first, which moves everything
/// captured into the frame ARKit reports now, then the ground from the planes it reports now.
/// The other way round the ground was set in the new frame and then moved by the correction
/// again: a plane and an anchor both lowered 0.10 m put the ground 0.20 m down.
public enum SpatialUpdate {
    public struct Outcome: Sendable, Equatable {
        /// The anchor correction applied, when there was one; the caller moves what it holds
        /// outside the map (tapped marks) by it.
        public var correction: YawCorrection?
        /// The ground moved, or became measured or a guess again.
        public var groundChanged = false
        /// The plane taken as ground and why, when the ground moved to one or became measured.
        public var groundChoice: GroundPlaneChoice.Choice?

        /// Whether the captured geometry changed: an answer to a scene sent before it is stale
        /// (`AnswerFreshness`).
        public var changed: Bool { correction != nil || groundChanged }
    }

    /// Ground moves under 1 cm are plane jitter and republish nothing.
    public static let groundJitter: Float = 0.01

    /// The height a later plane may not raise the ground by more than
    /// `GroundPlaneChoice.maximumRaise`: the measured ground, once coverage has kept a view. A
    /// raise re-projects every row, so cells the homeowner was told were done would go back to
    /// unseen (#62). Before any view is kept (the meter mark and its close-up) there are no such
    /// cells, so a plane found later may still raise it: the one under where the phone stood,
    /// arriving after a lower one reached the foot line first, or the ground at the foot of a wall
    /// a re-fit moved. Nil while the ground is a guess, or no view is kept.
    public static func raiseLimit(map: CoverageMap, ground: GroundEvidence) -> Float? {
        ground.measured && !map.observedCameras.isEmpty ? map.wall.groundY : nil
    }

    /// `apply` without where the phone stood when the meter was marked.
    public static func apply(
        anchor: simd_float4x4?, planes: [GroundPlaneEvidence]?, time: Double,
        map: inout CoverageMap, tracking: inout MeterAnchorTracking?, ground: inout GroundEvidence
    ) -> Outcome {
        var phone: SIMD3<Float>?
        return apply(anchor: anchor, planes: planes, time: time, phone: &phone, map: &map, tracking: &tracking, ground: &ground)
    }

    /// `anchor` is the meter anchor's pose on this frame, nil when the frame has none. `planes`
    /// are the horizontal planes ARKit reports on this frame; nil when the frame carries no plane
    /// information (a pose-only frame), empty when ARKit reports none. `phone` is where the phone
    /// stood when the meter was marked, which the ground choice prefers the plane under; a
    /// correction moves it with everything else, since it was recorded in the old frame. A
    /// measured ground whose supporting plane is gone, or no longer qualifies (reclassified as
    /// furniture, shrunk away from the wall, or more than `GroundPlaneChoice.maximumRaise` above it
    /// once `raiseLimit` holds), goes back to a guess: the height stays where it was, and the
    /// guess's error comes back on every height.
    public static func apply(
        anchor: simd_float4x4?, planes: [GroundPlaneEvidence]?, time: Double, phone: inout SIMD3<Float>?,
        map: inout CoverageMap, tracking: inout MeterAnchorTracking?, ground: inout GroundEvidence
    ) -> Outcome {
        var outcome = Outcome()
        if let anchor, let correction = tracking?.update(to: anchor, at: time) {
            map.apply(correction)
            phone = phone.map(correction.point)
            outcome.correction = correction
        }
        guard let planes else { return outcome }
        let wall = map.wall
        if let choice = GroundPlaneChoice.choose(
            meter: wall.meter, along: wall.along, phone: phone, current: raiseLimit(map: map, ground: ground), planes: planes
        ) {
            let y = choice.plane.y
            guard !ground.measured || abs(y - wall.groundY) > groundJitter else { return outcome }
            var moved = wall
            moved.groundY = y
            ground.set(measured: true)
            map.heightError = 0
            map.updateWall(moved)
            outcome.groundChanged = true
            outcome.groundChoice = choice
        } else if ground.measured {
            ground.set(measured: false)
            map.heightError = ground.guessError
            outcome.groundChanged = true
        }
        return outcome
    }
}
