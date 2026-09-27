import Foundation

/// The old scan folders a new scan deletes: only the current scan is kept on the phone.
///
/// The folders to delete are listed when the new scan's folder is made, before any newer scan
/// can exist, and only those are deleted, whenever the deletion gets to run. Listing at deletion
/// time instead let a cleanup that ran late delete a scan started after it: store A is made,
/// Start over makes B, and A's cleanup then found B in the listing and deleted the scan in use.
public struct ScanFolderCleanup: Sendable {
    /// The folders beside the kept one when the cleanup was made.
    public let obsolete: [URL]

    /// Lists every entry of `root` but `kept`, now. An unreadable root lists nothing.
    public init(root: URL, keeping kept: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        obsolete = names.filter { $0 != kept }.sorted().map { root.appending(path: $0) }
    }

    /// Deletes the listed folders; returns each one that could not be deleted with the reason. A
    /// folder already gone is not an error.
    public func run() -> [(url: URL, error: any Error)] {
        let files = FileManager.default
        return obsolete.compactMap { url in
            guard files.fileExists(atPath: url.path) else { return nil }
            do {
                try files.removeItem(at: url)
                return nil
            } catch {
                return (url, error)
            }
        }
    }
}
