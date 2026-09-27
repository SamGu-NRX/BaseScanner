import Foundation

/// The old scan folders a new scan's store deletes, and the ones it keeps.
///
/// Kept: the new scan's own folder, and the `keepCompleted` most recent completed scans (those
/// with a packaged bundle, `bundleName`, newest bundle first), until newer completed scans push
/// them out. Every other entry goes: scans never packaged, and older completed ones. A scan the
/// homeowner finished survives the app being quit and relaunched, which makes a new store; before,
/// every relaunch deleted it, and a field run's export was lost that way.
///
/// The folders to delete are listed when the new scan's folder is made, before any newer scan
/// can exist, and only those are deleted, whenever the deletion gets to run. Listing at deletion
/// time instead let a cleanup that ran late delete a scan started after it: store A is made,
/// Start over makes B, and A's cleanup then found B in the listing and deleted the scan in use.
public struct ScanFolderCleanup: Sendable {
    /// The file whose presence marks a completed scan: the bundle Share scan offers.
    public static let bundleName = "scan.zip"
    /// The most recent completed scan, and one more: a homeowner who starts another scan still
    /// has the one before it. Each is a few tens of megabytes of photos.
    public static let defaultKeepCompleted = 2

    /// The folders beside the kept one when the cleanup was made, to delete.
    public let obsolete: [URL]
    /// The completed scans kept, newest first.
    public let keptCompleted: [URL]

    /// Lists `root` now. An unreadable root lists nothing.
    public init(root: URL, keeping kept: String, keepCompleted: Int = defaultKeepCompleted) {
        let files = FileManager.default
        let names = ((try? files.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != kept }.sorted()
        let completed = names.compactMap { name -> (name: String, date: Date)? in
            let bundle = root.appending(path: name).appending(path: Self.bundleName)
            guard let attributes = try? files.attributesOfItem(atPath: bundle.path) else { return nil }
            return (name, attributes[.modificationDate] as? Date ?? .distantPast)
        }
        .sorted { ($0.date, $0.name) > ($1.date, $1.name) }
        let keep = Set(completed.prefix(max(0, keepCompleted)).map(\.name))
        keptCompleted = completed.prefix(max(0, keepCompleted)).map { root.appending(path: $0.name) }
        obsolete = names.filter { !keep.contains($0) }.map { root.appending(path: $0) }
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
