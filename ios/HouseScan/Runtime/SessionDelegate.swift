import ARKit

/// Receives ARSession callbacks and forwards them to `CaptureSessionModel`.
///
/// ARKit calls these methods on the session's `delegateQueue`, which `ARCaptureView` sets to a
/// private serial queue so per-frame work added later stays off the main thread. Each callback
/// copies what it needs into Sendable values on that queue, then hops to the main actor with
/// `Task { @MainActor in ... }`. The model is main-actor isolated and therefore Sendable, so
/// no `@unchecked Sendable` or `nonisolated(unsafe)` is needed. ARKit's own objects stay on the
/// delegate queue.
final class SessionDelegate: NSObject, ARSessionDelegate {
    private let model: CaptureSessionModel

    init(model: CaptureSessionModel) {
        self.model = model
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let state = TrackingState(camera.trackingState)
        Task { @MainActor [model] in model.trackingChanged(to: state) }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let planes = anchors.compactMap(DetectedPlane.init)
        guard !planes.isEmpty else { return }
        Task { @MainActor [model] in model.planesAdded(planes) }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let planes = anchors.compactMap(DetectedPlane.init)
        guard !planes.isEmpty else { return }
        Task { @MainActor [model] in model.planesRemoved(planes) }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [model] in model.interruptionChanged(isInterrupted: true) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [model] in model.interruptionChanged(isInterrupted: false) }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor [model] in model.sessionFailed(error) }
    }
}
