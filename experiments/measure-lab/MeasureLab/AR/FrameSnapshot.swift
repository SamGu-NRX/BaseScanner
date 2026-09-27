import MeasureGeometry

/// What the app keeps of a saved keyframe to turn a tap on it into a ray later. ARFrame itself
/// is not kept: holding frames starves ARKit's camera buffer pool.
struct FrameSnapshot: Sendable {
    let sessionID: String
    let keyframeID: String
    let camera: CameraFrame
    let imageWidth: Int
    let imageHeight: Int
    let timestamp: Double
    let tracking: TrackingState

    func contains(pixel u: Double, _ v: Double) -> Bool {
        (0...Double(imageWidth)).contains(u) && (0...Double(imageHeight)).contains(v)
    }
}
