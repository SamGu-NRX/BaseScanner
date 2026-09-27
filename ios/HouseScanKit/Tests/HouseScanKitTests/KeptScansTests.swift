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

    /// A scan folder, completed (with its bundle, written at `minutesAgo`) or not.
    static func scan(_ name: String, in root: URL, bundledMinutesAgo minutesAgo: Double? = nil) throws {
        let folder = root.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: folder.appending(path: "k00001.jpg"))
        guard let minutesAgo else { return }
        let bundle = folder.appending(path: ScanFolderCleanup.bundleName)
        try Data("zip".utf8).write(to: bundle)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -minutesAgo * 60)], ofItemAtPath: bundle.path)
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

/// Replacing a scan's bundle never leaves the folder without one.
@Suite struct AtomicBundleTests {
    struct Unreadable: Error {}

    @Test func aFailedRewriteLeavesThePreviousBundleAndTheScanIsKept() throws {
        let root = try KeptScansTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "run2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = folder.appending(path: ScanFolderCleanup.bundleName)
        try ZipWriter.write([(name: "manifest.json", load: { Data("{}".utf8) })], to: bundle)
        let before = try Data(contentsOf: bundle)
        // "It's clear" repackages the scan, and a file of the new packet can't be read.
        #expect(throws: Unreadable.self) {
            try ZipWriter.write([(name: "manifest.json", load: { Data("{\"new\":1}".utf8) }), (name: "photo.jpg", load: { throw Unreadable() })], to: bundle)
        }
        #expect(try Data(contentsOf: bundle) == before)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: ZipWriter.temporaryName(for: ScanFolderCleanup.bundleName)).path))
        // A relaunch keeps the scan.
        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(cleanup.keptCompleted.map(\.lastPathComponent) == ["run2"])
        // A successful rewrite replaces it.
        try ZipWriter.write([(name: "manifest.json", load: { Data("{\"new\":1}".utf8) })], to: bundle)
        #expect(try Data(contentsOf: bundle) != before)
    }

    /// A partial bundle file, written `minutesAgo`.
    static func partial(in folder: URL, minutesAgo: Double) throws {
        let file = folder.appending(path: ZipWriter.temporaryName(for: ScanFolderCleanup.bundleName))
        try Data("partial".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -minutesAgo * 60)], ofItemAtPath: file.path)
    }

    /// A folder caught mid-replacement (the old bundle and the new one's partial file) is kept,
    /// and counts by its bundle's date, not the newer partial's.
    @Test func aFolderMidReplacementIsKeptByItsBundle() throws {
        let root = try KeptScansTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try KeptScansTests.scan("run1", in: root, bundledMinutesAgo: 60)
        try KeptScansTests.scan("run2", in: root, bundledMinutesAgo: 30)
        try KeptScansTests.scan("run3", in: root, bundledMinutesAgo: 90)
        try Self.partial(in: root.appending(path: "run3"), minutesAgo: 1)
        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(cleanup.keptCompleted.map(\.lastPathComponent) == ["run2", "run1"])
        #expect(cleanup.obsolete.map(\.lastPathComponent) == ["run3"])
        #expect(cleanup.keptUnfinished == nil)
    }

    /// Greptile 4115191959: the app died during a scan's first bundle write, leaving only the
    /// partial file. That folder is not a completed scan: both completed scans stay, and it is
    /// kept apart, as the newest scan.
    @Test func anUnfinishedFirstWriteTakesNoCompletedSlot() throws {
        let root = try KeptScansTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try KeptScansTests.scan("run1", in: root, bundledMinutesAgo: 60)
        try KeptScansTests.scan("run2", in: root, bundledMinutesAgo: 30)
        try KeptScansTests.scan("crashed", in: root)
        try Self.partial(in: root.appending(path: "crashed"), minutesAgo: 5)
        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(cleanup.keptCompleted.map(\.lastPathComponent) == ["run2", "run1"])
        #expect(cleanup.keptUnfinished?.lastPathComponent == "crashed")
        #expect(cleanup.obsolete.isEmpty)
        #expect(cleanup.run().isEmpty)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) == ["crashed", "run1", "run2"])
    }

    /// Once a newer scan completes, the unfinished one goes; of two unfinished, only the newer
    /// can be kept.
    @Test func anUnfinishedScanGoesOnceANewerOneCompletes() throws {
        let root = try KeptScansTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try KeptScansTests.scan("run1", in: root, bundledMinutesAgo: 60)
        try KeptScansTests.scan("crashed", in: root)
        try Self.partial(in: root.appending(path: "crashed"), minutesAgo: 40)
        try KeptScansTests.scan("run2", in: root, bundledMinutesAgo: 30)
        try KeptScansTests.scan("crashedAgain", in: root)
        try Self.partial(in: root.appending(path: "crashedAgain"), minutesAgo: 10)
        try KeptScansTests.scan("crashedFirst", in: root)
        try Self.partial(in: root.appending(path: "crashedFirst"), minutesAgo: 20)
        let cleanup = ScanFolderCleanup(root: root, keeping: "now")
        #expect(cleanup.keptCompleted.map(\.lastPathComponent) == ["run2", "run1"])
        #expect(cleanup.keptUnfinished?.lastPathComponent == "crashedAgain")
        #expect(Set(cleanup.obsolete.map(\.lastPathComponent)) == ["crashed", "crashedFirst"])
    }
}
