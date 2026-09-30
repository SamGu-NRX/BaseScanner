import Foundation

/// Every plane ARKit tracks at one frame, horizontal and vertical. A live sampled frame reads
/// them from `ARFrame.anchors`, which Apple documents as "the list of anchors representing
/// positions tracked or objects detected in the scene". Empty lists mean ARKit tracks no such
/// plane, and a plane it stopped tracking is gone from the next snapshot.
///
/// A frame that carries no plane information has no snapshot at all (`SourceFrame.planes` is
/// nil): pose-only frames, replay frames and review frames. When both cases were empty arrays,
/// the engine ignored every empty list. A plane ARKit stopped tracking therefore stayed where the
/// space ends, and a walk-out behind it stayed blocked (review of #168).
public struct PlaneSnapshot: Sendable, Equatable {
    public var ground: [GroundPlaneEvidence]
    public var walls: [WallPlaneEvidence]

    public init(ground: [GroundPlaneEvidence] = [], walls: [WallPlaneEvidence] = []) {
        self.ground = ground
        self.walls = walls
    }

    /// Takes the planes a frame carries. A snapshot replaces what is held, empty lists included.
    /// Nil keeps what is held: the frame says nothing about planes. Returns which of the two
    /// lists changed.
    @discardableResult
    public mutating func update(from frame: PlaneSnapshot?) -> (ground: Bool, walls: Bool) {
        guard let frame else { return (false, false) }
        let changed = (ground: frame.ground != ground, walls: frame.walls != walls)
        self = frame
        return changed
    }
}
