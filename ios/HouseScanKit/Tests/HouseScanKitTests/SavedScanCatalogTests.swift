import Foundation
@testable import HouseScanKit
import Testing

/// Saved scans: the completed scans the cleanup keeps, read from synthetic scan folders, and the
/// copies handed to the share sheet. Every archive here is made by `ZipWriter`, never a capture.
@Suite struct SavedScanCatalogTests {
    let root: URL
    let files = FileManager.default

    init() throws {
        root = files.temporaryDirectory.appending(path: "saved-scans-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A packet as the app zips it: manifest.json first, then a photo.
    static let packet: Data = {
        // A fixed photo payload so every test archive has the same bytes.
        let photo = Data((0..<4096).map { UInt8($0 % 251) })
        return try! ZipWriter.archive([
            ZipEntry(name: "manifest.json", data: Data(#"{"version":"1.1"}"#.utf8)),
            ZipEntry(name: "photos/p00001.jpg", data: photo),
        ])
    }()

    /// A scan folder with a keyframe, and optionally a bundle saved `minutesAgo` and a stamp.
    @discardableResult
    func scan(_ name: String, bundle: Data? = packet, minutesAgo: Double = 10, stamp: String? = nil) throws -> URL {
        let folder = root.appending(path: name)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: folder.appending(path: "k00001.jpg"))
        if let bundle {
            let archive = folder.appending(path: ScanFolderCleanup.bundleName)
            try bundle.write(to: archive)
            try files.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -minutesAgo * 60)], ofItemAtPath: archive.path)
        }
        if let stamp {
            try Data(stamp.utf8).write(to: folder.appending(path: ScanStamp.fileName))
        }
        return folder
    }

    func cleanUp() {
        try? files.removeItem(at: root)
    }

    // MARK: Listing

    /// The list is the cleanup's kept set, newest first, with each bundle's saved time and size.
    /// A folder never packaged is not a scan; an older completed one the cleanup will delete is
    /// not offered.
    @Test func listsTheCompletedScansTheCleanupKeeps() throws {
        defer { cleanUp() }
        try scan("unfinished", bundle: nil)
        try scan("oldest", minutesAgo: 90)
        try scan("older", minutesAgo: 30)
        try scan("newest", minutesAgo: 5)

        let scans = SavedScanCatalog(root: root).scans()
        #expect(scans.map(\.id) == ["newest", "older"])
        #expect(scans.map(\.id) == ScanFolderCleanup(root: root, keeping: "").keptCompleted.map(\.lastPathComponent))
        let newest = try #require(scans.first)
        #expect(newest.byteCount == Int64(Self.packet.count))
        #expect(newest.archive == root.appending(path: "newest/\(ScanFolderCleanup.bundleName)"))
        let saved = try #require(newest.savedAt)
        #expect(abs(saved.timeIntervalSinceNow + 5 * 60) < 5)
    }

    /// A relaunch makes a new store: its cleanup runs, and a fresh catalog over the same folders
    /// still lists the completed scans. The new scan's empty folder is not one of them.
    @Test func aCompletedScanIsListedAfterARelaunch() throws {
        defer { cleanUp() }
        try scan("finished", minutesAgo: 20)
        try scan("quitMidWalk", bundle: nil)
        try scan("relaunch", bundle: nil)

        let failed = ScanFolderCleanup(root: root, keeping: "relaunch").run()
        #expect(failed.isEmpty)
        #expect(SavedScanCatalog(root: root).scans().map(\.id) == ["finished"])
    }

    /// An empty or missing root lists nothing rather than failing.
    @Test func noFoldersListNothing() {
        defer { cleanUp() }
        #expect(SavedScanCatalog(root: root).scans().isEmpty)
        #expect(SavedScanCatalog(root: root.appending(path: "absent")).scans().isEmpty)
    }

    /// A bundle cut short, as a quit during its write leaves it, is not a completed scan, wherever
    /// it was cut. Nor is a zip that isn't a packet, or an empty file.
    @Test(arguments: [1, 21, 22, 23, 200, SavedScanCatalogTests.packet.count / 2, SavedScanCatalogTests.packet.count - 31])
    func aPartialBundleIsLeftOut(bytesMissing: Int) throws {
        defer { cleanUp() }
        try scan("partial", bundle: Self.packet.dropLast(bytesMissing), minutesAgo: 1)
        try scan("whole", minutesAgo: 30)
        #expect(SavedScanCatalog(root: root).scans().map(\.id) == ["whole"])
    }

    @Test func aBundleThatIsNotAPacketIsLeftOut() throws {
        defer { cleanUp() }
        let other = try ZipWriter.archive([ZipEntry(name: "notes.txt", data: Data("hello".utf8))])
        try scan("other", bundle: other)
        try scan("empty", bundle: Data())
        #expect(SavedScanCatalog(root: root).scans().isEmpty)
        let otherURL = root.appending(path: "other/\(ScanFolderCleanup.bundleName)")
        #expect(throws: PacketArchiveCheck.Failure.notAPacket) { try PacketArchiveCheck.verify(otherURL) }
        let emptyURL = root.appending(path: "empty/\(ScanFolderCleanup.bundleName)")
        #expect(throws: PacketArchiveCheck.Failure.incomplete) { try PacketArchiveCheck.verify(emptyURL) }
        #expect(throws: PacketArchiveCheck.Failure.unreadable) { try PacketArchiveCheck.verify(root.appending(path: "none.zip")) }
    }

    /// Bytes after the end record are a partial rewrite or something else, not a whole packet.
    @Test func bytesAfterTheEndRecordAreRefused() throws {
        defer { cleanUp() }
        try scan("padded", bundle: Self.packet + Data(repeating: 0, count: 8))
        #expect(SavedScanCatalog(root: root).scans().isEmpty)
    }

    /// A central directory whose first record doesn't point at the manifest at offset 0 doesn't
    /// belong with the entries before it.
    @Test func aDirectoryThatDisagreesWithTheFirstEntryIsRefused() throws {
        defer { cleanUp() }
        var bytes = Self.packet
        let end = bytes.count - 22
        let directoryOffset = bytes[(end + 16)..<(end + 20)].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        bytes[directoryOffset + 42] = 1
        try scan("forged", bundle: bytes)
        #expect(SavedScanCatalog(root: root).scans().isEmpty)
    }

    /// A link is never listed, whether the bundle or the scan folder is the link, and a linked
    /// stamp says nothing: a copy of a link would not be the bundle's bytes.
    @Test func linksAreNotScans() throws {
        defer { cleanUp() }
        let real = try scan("real", minutesAgo: 30)
        let elsewhere = root.appending(path: "elsewhere.zip")
        try Self.packet.write(to: elsewhere)
        let linked = try scan("linkedBundle", bundle: nil)
        try files.createSymbolicLink(at: linked.appending(path: ScanFolderCleanup.bundleName), withDestinationURL: elsewhere)
        try files.createSymbolicLink(at: root.appending(path: "linkedFolder"), withDestinationURL: real)
        let stamp = root.appending(path: "stamp.json")
        try Data(#"{"practice": true}"#.utf8).write(to: stamp)
        try files.createSymbolicLink(at: real.appending(path: ScanStamp.fileName), withDestinationURL: stamp)

        let listed = SavedScanCatalog(root: root).scans()
        #expect(listed.map(\.id) == ["real"])
        #expect(listed.first?.practice == nil)
        let link = linked.appending(path: ScanFolderCleanup.bundleName)
        #expect(throws: PacketArchiveCheck.Failure.notAFile) { try PacketArchiveCheck.verify(link) }
    }

    // MARK: Practice

    /// The stamp's practice flag is passed through only when it is a JSON boolean. A missing,
    /// corrupt or oddly typed stamp leaves it unknown, and the scan is still listed.
    @Test(arguments: [
        (#"{"practice": true, "app": {}}"#, true as Bool?),
        (#"{"practice": false}"#, false),
        (#"{"app": {}}"#, nil),
        (#"{"practice": 1}"#, nil),
        (#"{"practice": "true"}"#, nil),
        ("{not json", nil),
        ("", nil),
    ])
    func practiceComesOnlyFromAReadableStamp(stamp: String, practice: Bool?) throws {
        defer { cleanUp() }
        try scan("one", stamp: stamp)
        let listed = try #require(SavedScanCatalog(root: root).scans().first)
        #expect(listed.practice == practice)
    }

    @Test func noStampAndAnOversizedStampSayNothing() throws {
        defer { cleanUp() }
        try scan("bare", minutesAgo: 5)
        let padding = String(repeating: " ", count: SavedScanCatalog.stampByteLimit)
        try scan("huge", minutesAgo: 10, stamp: #"{"practice": true}"# + padding)
        let scans = SavedScanCatalog(root: root).scans()
        #expect(scans.map(\.id) == ["bare", "huge"])
        #expect(scans.allSatisfy { $0.practice == nil })
    }

    // MARK: Sharing

    /// The share sheet gets a copy outside the scan folder with the bundle's exact bytes and a
    /// name a recipient can tell apart. Removing it deletes only the copy.
    @Test func stagingCopiesTheBundleExactly() throws {
        defer { cleanUp() }
        let folder = try scan("one", stamp: #"{"practice": false}"#)
        let staging = SavedScanStaging(root: root.appending(path: "share"))
        let listed = try #require(SavedScanCatalog(root: root).scans().first)

        let copy = try staging.stage(listed)
        #expect(try Data(contentsOf: copy) == Self.packet)
        #expect(copy.lastPathComponent == listed.shareFileName())
        #expect(!copy.path.hasPrefix(folder.path))

        staging.remove(copy)
        #expect(!files.fileExists(atPath: copy.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: listed.archive) == Self.packet)
    }

    /// A scan the cleanup deleted after the list was made is reported missing, and leaves no copy.
    @Test func aBundleGoneSinceListingIsMissing() throws {
        defer { cleanUp() }
        let folder = try scan("gone")
        let staging = SavedScanStaging(root: root.appending(path: "share"))
        let listed = try #require(SavedScanCatalog(root: root).scans().first)
        try files.removeItem(at: folder)

        #expect(throws: SavedScanShareError.missing) { try staging.stage(listed) }
        #expect((try? files.contentsOfDirectory(atPath: staging.root.path))?.isEmpty ?? true)
    }

    /// A bundle cut short after the list was made is reported damaged, and leaves no copy.
    @Test func aBundleCutShortSinceListingIsDamaged() throws {
        defer { cleanUp() }
        try scan("cut")
        let staging = SavedScanStaging(root: root.appending(path: "share"))
        let listed = try #require(SavedScanCatalog(root: root).scans().first)
        try Self.packet.prefix(100).write(to: listed.archive)

        #expect(throws: SavedScanShareError.damaged) { try staging.stage(listed) }
        #expect((try? files.contentsOfDirectory(atPath: staging.root.path))?.isEmpty ?? true)
    }

    /// `remove` deletes only folders it made; `removeAll` clears every copy and nothing else.
    @Test func removalStaysInsideTheStagingFolder() throws {
        defer { cleanUp() }
        let folder = try scan("keep")
        let staging = SavedScanStaging(root: root.appending(path: "share"))
        let listed = try #require(SavedScanCatalog(root: root).scans().first)

        staging.remove(listed.archive)
        #expect(files.fileExists(atPath: listed.archive.path))

        let first = try staging.stage(listed)
        let second = try staging.stage(listed)
        #expect(first != second)
        staging.removeAll()
        #expect(!files.fileExists(atPath: staging.root.path))
        #expect(files.fileExists(atPath: folder.appending(path: ScanFolderCleanup.bundleName).path))
    }

    // MARK: Names

    @Test func theShareNameSaysWhenAndWhetherPractice() {
        let archive = URL(fileURLWithPath: "/x/scan.zip")
        let saved = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(SavedScan(id: "a", archive: archive, savedAt: saved, byteCount: 1, practice: false).shareFileName(timeZone: utc)
            == "House Scan 2026-09-21 14.13.zip")
        #expect(SavedScan(id: "a", archive: archive, savedAt: saved, byteCount: 1, practice: true).shareFileName(timeZone: utc)
            == "House Scan practice 2026-09-21 14.13.zip")
        #expect(SavedScan(id: "a", archive: archive, savedAt: nil, byteCount: 1, practice: nil).shareFileName() == "House Scan.zip")
    }
}
