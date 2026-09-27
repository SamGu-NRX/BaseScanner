/// The one line of guidance at the bottom of the phone.
public enum Instruction: Sendable, Equatable {
    case walkLeft, walkRight, tiltUp

    public var text: String {
        switch self {
        case .walkLeft: "Walk slowly to your left"
        case .walkRight: "Now walk to your right"
        case .tiltUp: "Tilt up to show above the meter"
        }
    }

    /// One instruction per keyframe: walk left until the camera has been left of x = -2.5 m,
    /// then walk right, and tilt up for the last three keyframes (the fixture's tilt-up shots).
    public static func sequence(for keyframes: [Keyframe]) -> [Instruction] {
        var reachedLeft = false
        return keyframes.enumerated().map { index, keyframe in
            if keyframe.cameraPosition.x < -2.5 { reachedLeft = true }
            if index >= keyframes.count - 3 { return .tiltUp }
            return reachedLeft ? .walkRight : .walkLeft
        }
    }
}
