import Foundation
@testable import HouseScanKit
import Testing

/// A completed scan outlives a relaunch; the scan being made always has a folder of its own.
@Suite struct KeptScansTests {
    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "kept-scans-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A capture packet as the app zips it, manifest.json first. Synthetic, never a capture.
    static let packet: Data = try! ZipWriter.archive([
        ZipEntry(name: "manifest.json", data: Data(#"{"version":"1.1"}"#.utf8)),
        ZipEntry(name: "photos/p00001.jpg", data: Data((0..<4096).map { UInt8($0 % 251) })),
    ])

    /// A scan folder, completed (with its bundle, written at `minutesAgo`) or not. A `partial`
    /// bundle is the packet cut short, as a quit during its write leaves it.
    static func scan(_ name: String, in root: URL, bundledMinutesAgo minutesAgo: Double? = nil, partial: Bool = false) throws {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: folder.appending(path: "k00001.jpg"))
        guard let minutesAgo else { return }
        let bundle = folder.appending(path: ScanFolderCleanup.bundleName)
        try (partial ? packet.prefix(packet.count / 2) : packet).write(to: bundle)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -minutesAgo * 60)], ofItemAtPath: bundle.path)
    }

    static func names(_ urls: [URL]) -> [String] {
        urls.map(\.lastPathComponent)
    }

    /// A relaunch makes a new store: the two most recent completed scans stay, with their
    /// bundles; an older completed scan and one never packaged go. Before, all of them went.
    @Test func aRelaunchKeepsTheLastCompletedScans() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.scan("abandoned", in: root)
        try Self.scan("run1", in: root, bundledMinutesAgo: 90)
        try Self.scan("run2", in: root, bundledMinutesAgo: 30)
        try Self.scan("run3", in: root, bundledMinutesAgo: 5)
        try Self.scan("now", in: root)

        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(cleanup.keptCompleted.map(\.lastPathComponent) == ["run3", "run2"])
        #expect(Set(cleanup.obsolete.map(\.lastPathComponent)) == ["abandoned", "run1"])
        let failed = cleanup.run()
        #expect(failed.isEmpty)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["now", "run2", "run3"])
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "run3/\(ScanFolderCleanup.bundleName)").path))
    }

    /// The scan being made is never listed, and a new scan is a new, empty folder beside the kept
    /// ones: nothing of a kept scan ends up in it.
    @Test func aNewScanStillGetsACleanFolder() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.scan("run2", in: root, bundledMinutesAgo: 30)
        let fresh = root.appending(path: "fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let cleanup = ScanFolderCleanup(root: root, keeping: "fresh")
        #expect(!cleanup.obsolete.contains(fresh) && !cleanup.keptCompleted.contains(fresh))
        _ = cleanup.run()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)
        // Once a newer completed scan exists, the kept one is still one of the two most recent.
        try Self.scan("run3", in: root, bundledMinutesAgo: 1)
        #expect(ScanFolderCleanup(root: root, keeping: "later").keptCompleted.map(\.lastPathComponent) == ["run3", "run2"])
    }

    /// A partial bundle takes no kept place, however new: both intact scans stay. Its folder
    /// is left alone too, however old, since nothing shows its writer has stopped. Before,
    /// presence alone counted, so the newer partial kept a place and an intact scan was deleted.
    @Test(arguments: [0.5, 20.0, 60.0 * 24 * 365])
    func aPartialBundleNeitherEvictsIntactScansNorIsDeleted(minutesAgo: Double) throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.scan("intact1", in: root, bundledMinutesAgo: 40)
        try Self.scan("intact2", in: root, bundledMinutesAgo: 90)
        try Self.scan("intact3", in: root, bundledMinutesAgo: 120)
        // Newer than every intact scan, unless it is the year-old one.
        try Self.scan("partial", in: root, bundledMinutesAgo: minutesAgo, partial: true)
        try Self.scan("unpackaged", in: root)

        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(Self.names(cleanup.keptCompleted) == ["intact1", "intact2"])
        #expect(Self.names(cleanup.incompleteBundles) == ["partial"])
        #expect(Self.names(cleanup.obsolete) == ["intact3", "unpackaged"])
        #expect(cleanup.run().isEmpty)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["intact1", "intact2", "partial"])
        #expect(try Data(contentsOf: root.appending(path: "partial/\(ScanFolderCleanup.bundleName)")) == Self.packet.prefix(Self.packet.count / 2))
    }

    /// A bundle that fails the check for any reason (empty, not a packet) is treated like a
    /// partial one; once its write finishes it competes like any completed scan.
    @Test func anUnreadableBundleIsLeftAloneUntilItIsWhole() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.scan("intact1", in: root, bundledMinutesAgo: 40)
        try Self.scan("intact2", in: root, bundledMinutesAgo: 90)
        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appending(path: ScanFolderCleanup.bundleName))

        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(Self.names(cleanup.incompleteBundles) == ["empty"])
        #expect(cleanup.obsolete.isEmpty)

        try Self.packet.write(to: empty.appending(path: ScanFolderCleanup.bundleName))
        let later = ScanFolderCleanup(root: root, keeping: "now")
        #expect(Self.names(later.keptCompleted) == ["empty", "intact1"])
        #expect(Self.names(later.obsolete) == ["intact2"])
    }

    /// A folder whose bundle can't be read, or whose bundle is a link or a folder, holds no place
    /// and is not deleted.
    @Test func bundlesThatCannotBeJudgedAreLeftAlone() throws {
        let root = try Self.makeRoot()
        let files = FileManager.default
        try Self.scan("intact1", in: root, bundledMinutesAgo: 40)
        try Self.scan("intact2", in: root, bundledMinutesAgo: 90)
        try Self.scan("locked", in: root, bundledMinutesAgo: 1)
        let locked = root.appending(path: "locked")
        try files.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? files.removeItem(at: root)
        }
        try Self.scan("linked", in: root)
        try files.createSymbolicLink(at: root.appending(path: "linked/\(ScanFolderCleanup.bundleName)"),
                                     withDestinationURL: root.appending(path: "intact1/\(ScanFolderCleanup.bundleName)"))
        try Self.scan("folderBundle", in: root)
        try files.createDirectory(at: root.appending(path: "folderBundle/\(ScanFolderCleanup.bundleName)"), withIntermediateDirectories: true)

        try Data("stray".utf8).write(to: root.appending(path: "stray.txt"))

        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(Self.names(cleanup.keptCompleted) == ["intact1", "intact2"])
        #expect(Set(Self.names(cleanup.incompleteBundles)) == ["locked", "linked", "folderBundle"])
        // A stray file is not a scan folder and goes, as before.
        #expect(Self.names(cleanup.obsolete) == ["stray.txt"])
        #expect(cleanup.run().isEmpty)
        #expect(try Set(files.contentsOfDirectory(atPath: root.path)) == ["intact1", "intact2", "locked", "linked", "folderBundle"])
    }

    /// A retry rewrites scan.zip in place while the check may still be reading the old file. A
    /// check that passes on the old file must not count the new, partial one as complete.
    @Test func aBundleReplacedDuringTheCheckIsNotComplete() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.scan("rewritten", in: root, bundledMinutesAgo: 5)
        let bundle = root.appending(path: "rewritten/\(ScanFolderCleanup.bundleName)")

        let state = ScanFolderCleanup.bundleState(bundle) { url in
            let size = try PacketArchiveCheck.verify(url)
            // As ZipWriter.write does: remove the file, then start a new one.
            try FileManager.default.removeItem(at: url)
            try Self.packet.prefix(Self.packet.count / 2).write(to: url)
            return size
        }
        #expect(state == .incomplete)

        // Left alone, the same bundle is complete.
        try Self.packet.write(to: bundle)
        let settled = ScanFolderCleanup.bundleState(bundle)
        #expect(settled != .incomplete && settled != .absent)
        #expect(ScanFolderCleanup.bundleState(root.appending(path: "none/\(ScanFolderCleanup.bundleName)")) == .absent)
    }

    /// The scan in use is never judged, whatever its bundle; a folder made after the listing is
    /// never deleted by it.
    @Test func theScanInUseAndLaterFoldersAreSafe() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.scan("current", in: root, bundledMinutesAgo: 60, partial: true)
        try Self.scan("old", in: root)
        let cleanup = ScanFolderCleanup(root: root, keeping: "current")
        #expect(!(cleanup.obsolete + cleanup.keptCompleted + cleanup.incompleteBundles).map(\.lastPathComponent).contains("current"))
        #expect(Self.names(cleanup.obsolete) == ["old"])

        try Self.scan("later", in: root, bundledMinutesAgo: 1)
        try Self.scan("laterPartial", in: root, bundledMinutesAgo: 60, partial: true)
        #expect(cleanup.run().isEmpty)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["current", "later", "laterPartial"])
    }

    /// Bundles saved at the same moment keep the order by name, newest name first, as before.
    @Test func equalSaveTimesFallBackToNameOrder() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = Date(timeIntervalSinceNow: -30 * 60)
        for name in ["a", "b", "c"] {
            try Self.scan(name, in: root, bundledMinutesAgo: 30)
            try FileManager.default.setAttributes([.modificationDate: bundled], ofItemAtPath: root.appending(path: "\(name)/\(ScanFolderCleanup.bundleName)").path)
        }
        let cleanup = ScanFolderCleanup(root: root, keeping: "new")
        #expect(Self.names(cleanup.keptCompleted) == ["c", "b"])
        #expect(Self.names(cleanup.obsolete) == ["a"])
    }

    /// The stamp carries the build, the server and the answer's rules, with nulls where there
    /// are none, so the file always has the same shape.
    @Test func theStampSaysWhatBuiltAndJudgedTheScan() throws {
        let result = try PlacementResult.decode(PlacementResultTests.sampleData())
        let stamp = ScanStamp(
            app: .init(version: "0.1.0", build: "1", commit: "abc123def456-dirty"),
            server: .init(url: "https://house-scanning-server.vercel.app"),
            answer: .init(result, sample: true))
        let value = try JSONSchemaValidator.Value.parse(stamp.jsonData())
        #expect(value["app"]?["commit"]?.string == "abc123def456-dirty")
        #expect(value["server"]?["url"]?.string == "https://house-scanning-server.vercel.app")
        #expect(value["answer"]?["rules_sha256"]?.string == result.policy.rulesSHA256)
        #expect(value["answer"]?["input_sha256"]?.string == result.stats.inputSHA256)
        #expect(value["answer"]?["sample"] == .bool(true))
        let bare = try JSONSchemaValidator.Value.parse(ScanStamp(app: stamp.app, server: .init(url: nil)).jsonData())
        #expect(bare["answer"] == .null && bare["server"]?["url"] == .null)
        #expect(try JSONDecoder().decode(ScanStamp.self, from: stamp.jsonData()) == stamp)
    }
}
