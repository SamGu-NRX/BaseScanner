import Foundation
import HouseScanKit
import Testing

@Suite struct ZipWriterTests {
    static let entries = [
        ZipEntry(name: "scene.json", data: Data(#"{"schema_version":"1.0"}"#.utf8)),
        ZipEntry(name: "k1.jpg", data: Data((0..<5000).map { UInt8($0 % 251) })),
        ZipEntry(name: "stills/meter_close.jpg", data: Data()),
        ZipEntry(name: "streams/motion.csv", data: ZipWriterTests.motionCSV(rows: 2000)),
    ]

    /// Synthetic 100 Hz motion rows shaped like a packet stream: text that deflates well.
    static func motionCSV(rows: Int) -> Data {
        var text = "t,qx,qy,qz,qw,ax,ay,az\n"
        for i in 0..<rows {
            let t = Double(i) / 100
            text += "\(t),0.0123,\(0.5 + Double(i % 7) / 1000),-0.0042,0.8660,0.001,-0.981,\(Double(i % 13) / 100)\n"
        }
        return Data(text.utf8)
    }

    /// Bytes from a fixed linear congruential generator: no redundancy for DEFLATE to remove.
    static func noise(count: Int) -> Data {
        var state: UInt32 = 0x1234_5678
        return Data((0..<count).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        })
    }

    /// One entry as the local header and the central directory both describe it.
    struct Parsed {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var body: [UInt8]
    }

    /// Walks the central directory from the end record and reads each local header it points to,
    /// checking the two agree on method, CRC and sizes.
    static func parse(_ archive: Data) throws -> [Parsed] {
        let bytes = [UInt8](archive)
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        let end = bytes.count - 22  // no archive comment
        try #require(end >= 0 && u32(end) == 0x0605_4B50)
        let count = Int(u16(end + 10))
        var at = Int(u32(end + 16))
        var parsed: [Parsed] = []
        for _ in 0..<count {
            try #require(u32(at) == 0x0201_4B50)
            let nameLength = Int(u16(at + 28))
            let name = String(decoding: bytes[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            let entry = Parsed(
                name: name, method: u16(at + 10), crc: u32(at + 16),
                compressedSize: u32(at + 20), size: u32(at + 24), body: []
            )
            let local = Int(u32(at + 42))
            try #require(u32(local) == 0x0403_4B50)
            #expect(u16(local + 8) == entry.method, "\(name)")
            #expect(u32(local + 14) == entry.crc, "\(name)")
            #expect(u32(local + 18) == entry.compressedSize, "\(name)")
            #expect(u32(local + 22) == entry.size, "\(name)")
            let start = local + 30 + Int(u16(local + 26)) + Int(u16(local + 28))
            var withBody = entry
            withBody.body = Array(bytes[start..<(start + Int(entry.compressedSize))])
            parsed.append(withBody)
            at += 46 + nameLength + Int(u16(at + 30)) + Int(u16(at + 32))
        }
        return parsed
    }

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

    #if canImport(Compression)
    /// Text deflates (method 8) and inflates back to the original; the CRC and the uncompressed
    /// size describe the raw data.
    @Test func textEntryIsDeflated() throws {
        let csv = Self.motionCSV(rows: 2000)
        let parsed = try Self.parse(ZipWriter.archive([ZipEntry(name: "streams/motion.csv", data: csv)]))
        let entry = try #require(parsed.first)
        #expect(entry.method == 8)
        #expect(entry.size == UInt32(csv.count))
        #expect(entry.compressedSize < entry.size / 2, "\(entry.compressedSize) of \(entry.size)")
        #expect(entry.crc == ZipCRC32.checksum(csv))
        // NSData's zlib algorithm is the same raw DEFLATE, so it inflates the entry as a reader would.
        let inflated = try (Data(entry.body) as NSData).decompressed(using: .zlib) as Data
        #expect(inflated == csv)
    }

    /// An entry whose compressed form spans several of the encoder's 64 KiB output chunks still
    /// deflates and round-trips, and large noise is stored even though its first chunks were
    /// already encoded.
    @Test func largeEntriesCrossOutputChunks() throws {
        let halfEntropy = Data(Self.noise(count: 400_000).map { $0 & 0x0F })  // about 200 KB deflated
        let noise = Self.noise(count: 400_000)
        let parsed = try Self.parse(ZipWriter.archive([
            ZipEntry(name: "depth/k1.bin", data: halfEntropy),
            ZipEntry(name: "depth/k2.bin", data: noise),
        ]))
        try #require(parsed.count == 2)
        #expect(parsed[0].method == 8)
        #expect(parsed[0].compressedSize > 128 * 1024, "\(parsed[0].compressedSize)")
        #expect(parsed[0].compressedSize < parsed[0].size)
        let inflated = try (Data(parsed[0].body) as NSData).decompressed(using: .zlib) as Data
        #expect(inflated == halfEntropy)
        #expect(parsed[1].method == 0)
        #expect(Data(parsed[1].body) == noise)
    }
    #endif

    /// JPEGs are stored even when their bytes would deflate, and so is anything that wouldn't
    /// shrink: random bytes, a single byte, an empty file.
    @Test func incompressibleEntriesAreStored() throws {
        let compressibleJPEG = Data(repeating: 0x41, count: 4096)
        let noise = Self.noise(count: 4096)
        let entries = [
            ZipEntry(name: "photos/k1.jpg", data: compressibleJPEG),
            ZipEntry(name: "stills/Meter.JPG", data: compressibleJPEG),
            ZipEntry(name: "depth/k1.f32", data: noise),
            ZipEntry(name: "a", data: Data([1])),
            ZipEntry(name: "empty", data: Data()),
        ]
        let parsed = try Self.parse(ZipWriter.archive(entries))
        #expect(parsed.map(\.name) == entries.map(\.name))
        for (entry, original) in zip(parsed, entries) {
            #expect(entry.method == 0, "\(entry.name)")
            #expect(entry.compressedSize == entry.size, "\(entry.name)")
            #expect(Data(entry.body) == original.data, "\(entry.name)")
        }
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
