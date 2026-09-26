/// Decides when a moving camera has changed enough to save another keyframe: after it moves
/// `minimumTranslation` meters or turns `minimumRotation` degrees since the last saved one
/// (docs/02-implementation-plan.md, Lane A step 3: about every 0.5 m or 15°).
public struct KeyframeSelector: Sendable, Equatable {
    public var minimumTranslation: Double
    public var minimumRotation: Double
    public private(set) var lastSaved: CameraPose?

    public init(minimumTranslation: Double = 0.5, minimumRotation: Double = 15) {
        self.minimumTranslation = minimumTranslation
        self.minimumRotation = minimumRotation
    }

    /// True for the first pose and for any pose that moved or turned past a threshold.
    public func wantsKeyframe(at pose: CameraPose) -> Bool {
        guard let lastSaved else { return true }
        return lastSaved.distance(to: pose) >= minimumTranslation
            || lastSaved.rotationDegrees(to: pose) >= minimumRotation
    }

    /// Call for every saved keyframe, including ones saved for a tap, so spacing restarts there.
    public mutating func didSave(at pose: CameraPose) {
        lastSaved = pose
    }

    public mutating func reset() {
        lastSaved = nil
    }
}
