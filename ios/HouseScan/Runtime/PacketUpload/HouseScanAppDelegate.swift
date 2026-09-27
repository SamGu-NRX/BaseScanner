import UIKit

/// The app delegate, for the packet upload's background session: unfinished uploads resume at
/// launch, and the system's wake-up for finished transfers reaches `PacketUploadService`.
final class HouseScanAppDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The demo engine sends nothing, so it resumes nothing either.
        if !ProcessInfo.processInfo.arguments.contains("-uiDemo") {
            PacketUploadService.shared.resumePending()
        }
        return true
    }

    func application(_: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        PacketUploadService.shared.handleEvents(for: identifier, completion: completionHandler)
    }
}
