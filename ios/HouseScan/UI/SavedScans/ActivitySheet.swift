import SwiftUI
import UIKit

/// The system share sheet for one file, reporting when it is done with it.
///
/// `ShareLink` needs its file to exist before it is tapped and never says when the sheet lets go
/// of it. Saved scans makes its copy only after the tap, and deletes the copy once the sheet
/// finishes, so it needs `UIActivityViewController`'s completion.
struct ActivitySheet: UIViewControllerRepresentable {
    let file: URL
    /// Called once the share completes or is cancelled; the file is no longer read after this.
    let onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        // UIKit calls this on the main thread; the hop keeps it correct whatever the handler's
        // declared isolation.
        controller.completionWithItemsHandler = { _, _, _, _ in Task { @MainActor in onFinish() } }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
