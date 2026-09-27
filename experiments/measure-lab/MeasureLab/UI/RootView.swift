import ARKit
import SwiftUI

/// The measuring screen, or a plain explanation when AR can't run.
struct RootView: View {
    @State private var session = LabSession()

    var body: some View {
        if !ARWorldTrackingConfiguration.isSupported {
            ContentUnavailableView(
                "AR isn't available",
                systemImage: "arkit",
                description: Text("Measure Lab needs an iPhone that supports ARKit world tracking. The Simulator can't run it.")
            )
        } else if let failure = session.failure {
            FailureView(failure: failure)
        } else {
            MeasureScreen(session: session)
        }
    }
}
