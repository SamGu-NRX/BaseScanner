import RealityKit
import SwiftUI

/// The camera feed. `CaptureController` owns the ARView and its session.
struct ARContainerView: UIViewRepresentable {
    let capture: CaptureController

    func makeUIView(context: Context) -> ARView {
        capture.makeView()
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: ()) {
        view.session.pause()
    }
}
