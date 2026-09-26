import ARKit
import RealityKit
import SwiftUI

/// RealityKit's ARView running world tracking with plane detection.
///
/// The app configures the session itself (`automaticallyConfigureSession: false`) so it controls
/// exactly what runs: no scene reconstruction and no scene depth, which keeps it working on
/// iPhones without LiDAR.
struct ARCaptureView: UIViewRepresentable {
    let model: CaptureSessionModel

    func makeCoordinator() -> SessionDelegate {
        SessionDelegate(model: model)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegateQueue = DispatchQueue(label: "HouseScan.ARSessionDelegate")
        view.session.delegate = context.coordinator

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        view.session.run(configuration)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: SessionDelegate) {
        view.session.pause()
    }
}
