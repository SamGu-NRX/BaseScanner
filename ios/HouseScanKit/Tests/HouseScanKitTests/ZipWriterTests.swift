import Foundation
import HouseScanKit
import Testing

@Suite struct ZipWriterTests {
    static let entries = [
        ZipEntry(name: "scene.json", data: Data(#"{"schema_version":"1.0"}"#.utf8)),
        ZipEntry(name: "k1.jpg", data: Data((0..<5000).map { UInt8($0 % 251) })),
        ZipEntry(name: "stills/meter_close.jpg", data: Data()),
    ]

    @Test func crc32CheckValue() {
        // The standard CRC-32 check value for the ASCII string "123456789".
        #expect(ZipCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(ZipCRC32.checksum(Data()) == 0)
    }

    @Test func deterministicWithoutDate() throws {
        #expect(try ZipWriter.archive(Self.entries) == ZipWriter.archive(Self.entries))
    }

    /// Streaming to disk writes the bytes the in-memory archive would, and a failing loader leaves
    /// no partial file behind.
    @Test func streamedArchiveMatchesInMemory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zipwriter-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try ZipWriter.write(Self.entries.map { entry in (entry.name, { entry.data }) }, to: url, modified: date)
        #expect(try Data(contentsOf: url) == ZipWriter.archive(Self.entries, modified: date))

        struct LoadFailed: Error {}
        #expect(throws: LoadFailed.self) {
            try ZipWriter.write([("a", { Data([1]) }), ("b", { throw LoadFailed() })], to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rejectsBadNames() {
        #expect(throws: ZipWriterError.duplicateName("a")) {
            try ZipWriter.archive([ZipEntry(name: "a", data: Data()), ZipEntry(name: "a", data: Data())])
        }
        #expect(throws: ZipWriterError.self) { try ZipWriter.archive([ZipEntry(name: "", data: Data())]) }
        #expect(throws: ZipWriterError.self) { try ZipWriter.archive([ZipEntry(name: "/etc/x", data: Data())]) }
    }

    @Test func rejectsDatesOutsideDOSRange() {
        let date = Date(timeIntervalSince1970: 0)  // 1970, before the DOS epoch
        #expect(throws: ZipWriterError.dateOutOfRange(date)) { try ZipWriter.archive(Self.entries, modified: date) }
    }

    #if os(macOS)
    @Test func unzipAcceptsArchive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zipwriter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("bundle.zip")
        try ZipWriter.archive(Self.entries, modified: Date(timeIntervalSince1970: 1_790_000_000)).write(to: zip)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("No errors detected"), "\(output)")
        for entry in Self.entries { #expect(output.contains(entry.name), "\(output)") }
    }
    #endif
}
