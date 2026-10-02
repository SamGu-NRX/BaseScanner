import Foundation
import HouseScanKit

/// Where Saved scans reads scans from and stages the copies it shares.
enum SavedScansLocation {
    /// The scan store's folder (`KeyframeStore.scansRoot`). Debug builds take
    /// `-savedScansRoot <folder>` instead, so a UI test can list synthetic scans it wrote; the
    /// argument only changes which folder is listed, never what the store writes or deletes.
    static func catalog(arguments: [String] = ProcessInfo.processInfo.arguments) -> SavedScanCatalog {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-savedScansRoot"), index + 1 < arguments.count {
            return SavedScanCatalog(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }
        #endif
        return SavedScanCatalog(root: KeyframeStore.scansRoot)
    }

    /// In the app's temporary folder, apart from the scan folders, so the store's cleanup never
    /// sees a copy and a copy never outlives the system's own tmp purge.
    static let staging = SavedScanStaging(
        root: FileManager.default.temporaryDirectory.appending(path: "SavedScanShares", directoryHint: .isDirectory))
}
