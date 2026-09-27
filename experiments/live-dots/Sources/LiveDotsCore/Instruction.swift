/// The one line of guidance at the bottom of the phone, as a small state machine driven by the
/// replay: point at the meter, hold still while it locks, walk left, walk right, recover from
/// the tilt, done. Every change is one of these transitions, so the 3 s minimum between other
/// changes never has anything to hold back on this replay.
public enum Instruction: Sendable, Equatable {
    case pointAtMeter, holdStill, walkLeft, walkRight, tiltDown, done

    public var text: String {
        switch self {
        case .pointAtMeter: "Point at your electric meter"
        case .holdStill: "Hold still"
        case .walkLeft: "Walk slowly to your left"
        case .walkRight: "Now walk to your right"
        case .tiltDown: "Tilt back down to the wall"
        case .done: "That's the whole wall"
        }
    }

    /// One instruction per keyframe: point at the meter for the first two, hold still on the
    /// third, walk left until the camera has been left of x = -2.5 m, then walk right. The
    /// fixture's last three keyframes tilt up at the sky: the first two ask to tilt back down,
    /// and the last says the wall is done.
    public static func sequence(for keyframes: [Keyframe]) -> [Instruction] {
        var reachedLeft = false
        let count = keyframes.count
        return keyframes.enumerated().map { index, keyframe in
            if keyframe.cameraPosition.x < -2.5 { reachedLeft = true }
            if index == count - 1 { return .done }
            if index >= count - 3 { return .tiltDown }
            if index < Schedule.holdIndex { return .pointAtMeter }
            if index == Schedule.holdIndex { return .holdStill }
            return reachedLeft ? .walkRight : .walkLeft
        }
    }
}
