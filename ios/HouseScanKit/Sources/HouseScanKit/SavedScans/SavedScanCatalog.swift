import Foundation

/// The completed scans a homeowner can still share, read from the scan folders on disk.
///
/// A scan counts by the same rule the cleanup keeps it by (`ScanFolderCleanup`): a folder with a
/// `scan.zip`, newest bundle first, at most the `defaultKeepCompleted` the cleanup keeps. Listing
/// the cleanup's own choice means the list never shows an older scan that the next cleanup is
/// about to delete. On top of that rule a scan is listed only when its bundle is a whole capture
/// packet (`PacketArchiveCheck`), since a scan quit while its bundle was being written leaves a
/// partial `scan.zip` behind.
///
/// The list is a reading of the folders at one moment, and a scan can still go after it. A new
/// scan's cleanup deletes what its store listed when it was made, a little later and off the main
/// actor, so a bundle an earlier scan finished writing in between can be listed here and then
/// deleted. Sharing it then reports it missing (`SavedScanShareError.missing`) rather than
/// failing silently; listing exactly the cleanup's pending set would mean sharing state with
/// the store's cleanup, which this feature leaves as it is.
///
/// Everything here reads files synchronously; the app calls it off the main actor.
public struct SavedScanCatalog: Sendable {
    /// The folder holding one folder per scan, Caches/Scans in the app.
    public let root: URL
    /// The largest stamp read for its `practice` flag. A stamp is a few hundred bytes; anything
    /// past this is not one.
    static let stampByteLimit = 64 * 1024

    public init(root: URL) {
        self.root = root
    }

    /// The completed scans, newest first. Folders without a whole bundle are left out.
    public func scans() -> [SavedScan] {
        // No folder is the scan in use here: the cleanup's `keeping` excludes a name, and the
        // empty name matches no folder, so every folder competes by the cleanup's rule.
        ScanFolderCleanup(root: root, keeping: "").keptCompleted.compactMap(Self.scan(in:))
    }

    static func scan(in folder: URL) -> SavedScan? {
        // The scan folders are the app's own; a link among them is not a scan.
        guard (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeDirectory else { return nil }
        let archive = folder.appending(path: ScanFolderCleanup.bundleName)
        guard let size = try? PacketArchiveCheck.verify(archive) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path)
        return SavedScan(
            id: folder.lastPathComponent, archive: archive,
            savedAt: attributes?[.modificationDate] as? Date,
            byteCount: size,
            practice: practice(stamp: folder.appending(path: ScanStamp.fileName)))
    }

    /// The stamp's `practice` flag when the stamp is readable and holds a JSON boolean there;
    /// otherwise nil. A missing, oversized or corrupt stamp says nothing about the scan.
    static func practice(stamp: URL) -> Bool? {
        // Not a link (attributesOfItem doesn't follow one), and never more read than the limit.
        guard (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: stamp) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: stampByteLimit + 1), data.count <= stampByteLimit else { return nil }
        struct Flag: Decodable { let practice: Bool }
        return (try? JSONDecoder().decode(Flag.self, from: data))?.practice
    }
}

/// Why a saved scan couldn't be handed to the share sheet.
public enum SavedScanShareError: Error, Equatable, Sendable {
    /// The bundle is no longer on the phone: a newer scan's cleanup deleted it, or the system
    /// cleared the app's caches.
    case missing
    /// The bundle is there but not a whole capture packet.
    case damaged
    /// The copy for the share sheet couldn't be made, for example with the phone's storage full.
    case copyFailed
}

/// Copies of saved scans made for the share sheet, each in a folder of its own under `root`.
///
/// The share sheet reads the file it is given for as long as it is open, and a scan's own bundle
/// can be deleted under it by a new scan's cleanup. A copy outside the scan folders can't be.
/// The copy can be a full copy of the bundle's bytes, so it can fail on a full disk
/// (`SavedScanShareError.copyFailed`), and is deleted as soon as the sheet closes. Only this type
/// creates or deletes anything under `root`; the scan folders are never written.
public struct SavedScanStaging: Sendable {
    public let root: URL
    /// This app run's folder under `root`. Each run stages into its own, so a launch can delete
    /// the copies earlier runs left without judging by time, which a clock change would upset.
    public let session: String

    public init(root: URL, session: String = UUID().uuidString) {
        self.root = root
        self.session = session
    }

    private var sessionRoot: URL {
        root.appending(path: session, directoryHint: .isDirectory)
    }

    /// A whole copy of `scan`'s bundle under `root`, named `scan.shareFileName()`.
    public func stage(_ scan: SavedScan) throws(SavedScanShareError) -> URL {
        let files = FileManager.default
        let source = scan.archive
        func failure(_ check: PacketArchiveCheck.Failure) -> SavedScanShareError {
            guard files.fileExists(atPath: source.path) else { return .missing }
            return check == .unreadable ? .copyFailed : .damaged
        }
        do {
            _ = try PacketArchiveCheck.verify(source)
        } catch {
            throw failure(error)
        }
        let folder = sessionRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copy = folder.appending(path: scan.shareFileName())
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: copy)
        } catch {
            try? files.removeItem(at: folder)
            throw files.fileExists(atPath: source.path) ? .copyFailed : .missing
        }
        // The bundle could have been replaced or cut short while it was copied.
        do {
            _ = try PacketArchiveCheck.verify(copy)
        } catch {
            try? files.removeItem(at: folder)
            throw failure(error)
        }
        return copy
    }

    /// Deletes a copy `stage` made, with its folder. A URL that isn't one of this staging's copies
    /// is left alone.
    public func remove(_ copy: URL) {
        let folder = copy.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path == sessionRoot.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes the copies every other app run made, leaving this run's. At launch that is every
    /// copy an earlier run left (a share sheet open when the app was killed never reports back),
    /// while a share this run starts keeps its copy.
    public func removeOtherSessions() {
        let files = FileManager.default
        guard let sessions = try? files.contentsOfDirectory(atPath: root.path) else { return }
        for name in sessions where name != session {
            try? files.removeItem(at: root.appending(path: name))
        }
    }
}
