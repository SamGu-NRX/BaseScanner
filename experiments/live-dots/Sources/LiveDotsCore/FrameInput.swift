/// One keyframe's inputs to a field.
public struct FrameInput: Sendable {
    public let index: Int
    public let keyframe: Keyframe
    public let depth: DepthMap
    public let gradient: GradientPyramid

    public init(index: Int, keyframe: Keyframe, depth: DepthMap, gradient: GradientPyramid) {
        self.index = index
        self.keyframe = keyframe
        self.depth = depth
        self.gradient = gradient
    }
}
