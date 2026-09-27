/// Decides when a moving camera has changed enough to save another keyframe: after it moves
/// `minimumTranslation` meters or turns `minimumRotation` degrees (docs/00-overview.md,
/// Conventions the code relies on: 0.5 m or 15°).
///
/// Spacing is measured from the newest keyframe that is saved or still being written. A write
/// is a reservation until the caller commits it; a cancelled reservation leaves spacing measured
/// from the last keyframe that did save, so one failed write doesn't suppress the next ones.
public struct KeyframeSelector: Sendable, Equatable {
    public struct Reservation: Hashable, Sendable {
        let id: Int
    }

    public var minimumTranslation: Double
    public var minimumRotation: Double
    /// The newest keyframe that was written successfully.
    public private(set) var lastSaved: CameraPose?
    private var lastSavedID = -1
    private var pending: [Int: CameraPose] = [:]
    /// Never reset, so a reservation from before `reset()` can't match a new one.
    private var nextID = 0

    public init(minimumTranslation: Double = 0.5, minimumRotation: Double = 15) {
        self.minimumTranslation = minimumTranslation
        self.minimumRotation = minimumRotation
    }

    /// The pose spacing is measured from: the newest reservation still being written if it is
    /// newer than the last saved keyframe, otherwise the last saved keyframe.
    var anchor: CameraPose? {
        if let newest = pending.max(by: { $0.key < $1.key }), newest.key > lastSavedID {
            return newest.value
        }
        return lastSaved
    }

    /// True for the first pose and for any pose that moved or turned past a threshold.
    public func wantsKeyframe(at pose: CameraPose) -> Bool {
        guard let anchor else { return true }
        return anchor.distance(to: pose) >= minimumTranslation
            || anchor.rotationDegrees(to: pose) >= minimumRotation
    }

    /// Call before writing any keyframe, including ones saved for a tap.
    public mutating func reserve(at pose: CameraPose) -> Reservation {
        let id = nextID
        nextID += 1
        pending[id] = pose
        return Reservation(id: id)
    }

    /// The write succeeded. Ignored for a reservation made before `reset()`.
    public mutating func commit(_ reservation: Reservation) {
        guard let pose = pending.removeValue(forKey: reservation.id) else { return }
        if reservation.id > lastSavedID {
            lastSaved = pose
            lastSavedID = reservation.id
        }
    }

    /// The write failed. Ignored for a reservation made before `reset()`.
    public mutating func cancel(_ reservation: Reservation) {
        pending.removeValue(forKey: reservation.id)
    }

    /// Forgets saved and pending keyframes, for a new session.
    public mutating func reset() {
        lastSaved = nil
        lastSavedID = -1
        pending = [:]
    }
}
