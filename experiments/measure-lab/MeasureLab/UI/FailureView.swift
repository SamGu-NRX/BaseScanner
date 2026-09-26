import SwiftUI

struct FailureView: View {
    let failure: SessionFailure
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch failure {
        case .cameraAccessDenied:
            ContentUnavailableView {
                Label("Camera access is off", systemImage: "camera")
            } description: {
                Text("Measure Lab needs the camera to measure. Turn on Camera for Measure Lab in Settings.")
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
                description: Text("\(message) Everything so far is saved. Close and reopen Measure Lab to continue in a new session.")
            )
        }
    }
}
