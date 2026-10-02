import Foundation

/// The old scan folders a new scan's store deletes, and the ones it keeps.
///
/// Kept: the new scan's own folder, the `keepCompleted` most recent completed scans (those whose
/// bundle, `bundleName`, is a whole capture packet, newest bundle first) until newer completed
/// scans push them out, and every folder whose bundle is there but not whole. Every other entry
/// goes: scans never packaged, and older completed ones. A scan the homeowner finished survives
/// the app being quit and relaunched, which makes a new store; before, every relaunch deleted it,
/// and a field run's export was lost that way.
///
/// A bundle counts as completed only when `PacketArchiveCheck` finds it written to the end. The
/// zip is written in place, so a quit or crash during the write leaves a partial `scan.zip`. When
/// the file's presence alone counted, that partial bundle took one of the kept places and an
/// intact older scan was deleted to make room.
///
/// A partial or unreadable bundle takes no kept place, and its folder is not deleted, however old
/// it is. Nothing here can tell an abandoned partial from one whose writer is still going: Start
/// over makes a new store while the previous scan's bundle may still be being written, and a
/// suspended phone can pause a write for any length of time, so the file's age proves nothing.
/// Deleting it could take the folder from under that write. The cost is that an abandoned partial
/// bundle stays on the phone. Reclaiming it needs a way to prove no writer holds it, which this
/// type does not have.
///
/// The folders to delete are listed when the new scan's folder is made, before any newer scan
/// can exist, and only those are deleted, whenever the deletion gets to run. Listing at deletion
/// time instead let a cleanup that ran late delete a scan started after it: store A is made,
/// Start over makes B, and A's cleanup then found B in the listing and deleted the scan in use.
public struct ScanFolderCleanup: Sendable {
    /// The bundle Share scan offers. A scan is completed when this file is a whole capture packet
    /// (`PacketArchiveCheck`); the file being there is not enough.
    public static let bundleName = "scan.zip"
    /// The most recent completed scan, and one more: a homeowner who starts another scan still
    /// has the one before it. Each is a few tens of megabytes of photos.
    public static let defaultKeepCompleted = 2
    /// The folders beside the kept one when the cleanup was made, to delete.
    public let obsolete: [URL]
    /// The completed scans kept, newest first.
    public let keptCompleted: [URL]
    /// Folders whose bundle is there but not whole: left alone, holding no kept place.
    public let incompleteBundles: [URL]

    /// Lists `root` now. An unreadable root lists nothing.
    public init(root: URL, keeping kept: String, keepCompleted: Int = defaultKeepCompleted) {
        let files = FileManager.default
        let names = ((try? files.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 != kept }.sorted()
        var completed: [(name: String, date: Date)] = []
        var incomplete: [String] = []
        for name in names {
            // Only a real folder is judged by its bundle. A plain file beside the scan folders holds
            // no bundle and goes, as before. A link (attributesOfItem doesn't follow one) would
            // reach another folder's bundle, so it and its target could take both kept places;
            // it, and an entry whose type can't be read, hold no place and are left alone.
            switch (try? files.attributesOfItem(atPath: root.appending(path: name).path))?[.type] as? FileAttributeType {
            case .typeDirectory?: break
            case .typeRegular?: continue
            default:
                incomplete.append(name)
                continue
            }
            let bundle = root.appending(path: name).appending(path: Self.bundleName)
            switch Self.bundleState(bundle) {
            case .absent:
                continue
            case .complete(let date):
                completed.append((name, date))
            case .incomplete:
                incomplete.append(name)
            }
        }
        completed.sort { ($0.date, $0.name) > ($1.date, $1.name) }
        let keptNames = completed.prefix(max(0, keepCompleted)).map(\.name)
        let keep = Set(keptNames + incomplete)
        keptCompleted = keptNames.map { root.appending(path: $0) }
        incompleteBundles = incomplete.map { root.appending(path: $0) }
        obsolete = names.filter { !keep.contains($0) }.map { root.appending(path: $0) }
    }

    enum BundleState: Equatable {
        case absent
        case complete(savedAt: Date)
        case incomplete
    }

    /// Only a bundle known to be missing is absent. A metadata read that fails for another reason
    /// is incomplete: the folder may hold a bundle, so it is kept without a place.
    ///
    /// A whole bundle must still be the same file after the check. A retry rewrites `scan.zip` in
    /// place (`ZipWriter.write` removes it and starts a new file), and a check that opened the old
    /// file can finish on it after the new partial one has replaced it; the file number tells them
    /// apart. A rewrite that starts after the second read is not caught: the folder then holds its
    /// place while its bundle is partial, until the next cleanup. Closing that needs the writer to
    /// replace the file atomically, which the packet code doesn't do.
    /// `verify` is `PacketArchiveCheck.verify`; tests pass one that rewrites the file mid-check.
    static func bundleState(_ bundle: URL, verify: (URL) throws -> Int64 = PacketArchiveCheck.verify) -> BundleState {
        let files = FileManager.default
        let before: [FileAttributeKey: Any]
        do {
            before = try files.attributesOfItem(atPath: bundle.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .incomplete
        }
        guard (try? verify(bundle)) != nil,
              let after = try? files.attributesOfItem(atPath: bundle.path),
              let number = before[.systemFileNumber] as? UInt64,
              after[.systemFileNumber] as? UInt64 == number,
              after[.size] as? UInt64 == before[.size] as? UInt64 else { return .incomplete }
        return .complete(savedAt: before[.modificationDate] as? Date ?? .distantPast)
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
