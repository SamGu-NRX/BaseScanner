import ARKit
import SwiftUI

/// Full-screen camera with a status panel, or a plain message when AR cannot run.
struct CaptureScreen: View {
    @State private var model = CaptureSessionModel()

    var body: some View {
        if !ARWorldTrackingConfiguration.isSupported {
            ContentUnavailableView(
                "AR isn't available",
                systemImage: "arkit",
                description: Text("House Scan needs an iPhone that supports ARKit world tracking. The Simulator can't run it.")
            )
        } else if let failure = model.failure {
            FailureView(failure: failure)
        } else {
            ZStack(alignment: .top) {
                ARCaptureView(model: model)
                    .ignoresSafeArea()
                TrackingStatusPanel(model: model)
                    .padding()
            }
        }
    }
}

private struct TrackingStatusPanel: View {
    let model: CaptureSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.isInterrupted ? "Camera paused" : model.trackingState.instruction)
                .font(.headline)
            Text("Horizontal surfaces: \(model.horizontalPlaneCount)")
            Text("Vertical surfaces: \(model.verticalPlaneCount)")
        }
        .font(.subheadline)
        .monospacedDigit()
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct FailureView: View {
    let failure: SessionFailure
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch failure {
        case .cameraAccessDenied:
            ContentUnavailableView {
                Label("Camera access is off", systemImage: "camera")
            } description: {
                Text("House Scan needs the camera to measure your wall. Turn on Camera for House Scan in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        case .other(let message):
            ContentUnavailableView(
                "The camera session stopped",
                systemImage: "exclamationmark.triangle",
                description: Text("\(message) Close and reopen House Scan to try again.")
            )
        }
    }
}

private extension TrackingState {
    var instruction: String {
        switch self {
        case .notAvailable: "Waiting for the camera"
        case .normal: "Tracking"
        case .limited(.initializing): "Move your phone slowly to start"
        case .limited(.excessiveMotion): "Slow down"
        case .limited(.insufficientFeatures): "Move your phone slowly"
        case .limited(.relocalizing): "Point back at where you were"
        case .limited(.unknown): "Hold your phone steady"
        }
    }
}
