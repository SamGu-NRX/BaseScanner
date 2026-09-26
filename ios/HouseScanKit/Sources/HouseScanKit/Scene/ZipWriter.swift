import Foundation

// Store-only ZIP writer for the scan bundle (scene.json plus JPEGs). JPEGs do not compress, so
// method 0 (stored) costs almost nothing and keeps the writer free of a deflate dependency.
// Layout per PKWARE APPNOTE 6.3.x: local header + data for each file, then the central directory,
// then the end-of-central-directory record. No ZIP64: anything that would need it throws.

public struct ZipEntry: Sendable, Equatable {
    /// Path inside the archive, forward slashes, UTF-8.
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum ZipWriterError: Error, Equatable, CustomStringConvertible {
    case tooManyEntries(Int)
    case entryTooLarge(name: String, bytes: Int)
    case archiveTooLarge
    case invalidName(String, reason: String)
    case duplicateName(String)
    case dateOutOfRange(Date)

    public var description: String {
        switch self {
        case .tooManyEntries(let n): "\(n) entries; a ZIP without ZIP64 holds at most 65535"
        case .entryTooLarge(let name, let bytes): "\(name) is \(bytes) bytes; a ZIP without ZIP64 holds at most 4 GiB per file"
        case .archiveTooLarge: "archive exceeds 4 GiB, which needs ZIP64"
        case .invalidName(let name, let reason): "invalid entry name \"\(name)\": \(reason)"
        case .duplicateName(let name): "duplicate entry name \"\(name)\""
        case .dateOutOfRange(let date): "\(date) is outside the DOS date range 1980-2107"
        }
    }
}

public enum ZipCRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320) as ZIP uses it.
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

public enum ZipWriter {
    /// Builds a stored (uncompressed) ZIP archive in memory.
    /// - Parameters:
    ///   - modified: timestamp written for every entry; nil writes the DOS epoch 1980-01-01 00:00 so
    ///     the same inputs give byte-identical archives.
    ///   - timeZone: zone the DOS local time is expressed in.
    public static func archive(_ entries: [ZipEntry], modified: Date? = nil, timeZone: TimeZone = .gmt) throws -> Data {
        var out = Data()
        try build(entries.map { entry in (entry.name, { entry.data }) }, modified: modified, timeZone: timeZone) { out.append($0) }
        return out
    }

    /// Writes the same archive as `archive` to `url`, loading one entry at a time, so memory holds
    /// one file and the central directory instead of the whole bundle. Replaces any file at `url`;
    /// on a throw the partial file is removed.
    /// - Parameter entries: each entry's name and a loader called once, in order.
    public static func write(
        _ entries: [(name: String, load: () throws -> Data)], to url: URL, modified: Date? = nil, timeZone: TimeZone = .gmt
    ) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try build(entries, modified: modified, timeZone: timeZone) { try handle.write(contentsOf: $0) }
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    private static func build(
        _ entries: [(name: String, load: () throws -> Data)], modified: Date?, timeZone: TimeZone, emit: (Data) throws -> Void
    ) throws {
        guard entries.count <= 0xFFFF else { throw ZipWriterError.tooManyEntries(entries.count) }
        let (dosTime, dosDate) = try dosTimestamp(modified, timeZone: timeZone)

        var seen = Set<String>()
        var written = 0
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            guard !name.isEmpty else { throw ZipWriterError.invalidName(entry.name, reason: "empty") }
            guard name.count <= 0xFFFF else { throw ZipWriterError.invalidName(entry.name, reason: "longer than 65535 bytes") }
            guard !entry.name.hasPrefix("/"), !entry.name.contains("\\") else {
                throw ZipWriterError.invalidName(entry.name, reason: "must be relative with forward slashes")
            }
            guard seen.insert(entry.name).inserted else { throw ZipWriterError.duplicateName(entry.name) }
            let data = try entry.load()
            guard data.count <= 0xFFFF_FFFF else {
                throw ZipWriterError.entryTooLarge(name: entry.name, bytes: data.count)
            }
            guard written <= 0xFFFF_FFFF else { throw ZipWriterError.archiveTooLarge }

            let offset = UInt32(written)
            let crc = ZipCRC32.checksum(data)
            let size = UInt32(data.count)

            var local = Data()
            local.appendLE(UInt32(0x0403_4B50))  // local file header signature
            local.appendLE(versionNeeded)
            local.appendLE(flagUTF8)
            local.appendLE(UInt16(0))  // method: stored
            local.appendLE(dosTime)
            local.appendLE(dosDate)
            local.appendLE(crc)
            local.appendLE(size)  // compressed size
            local.appendLE(size)  // uncompressed size
            local.appendLE(UInt16(name.count))
            local.appendLE(UInt16(0))  // extra field length
            local.append(name)
            try emit(local)
            try emit(data)
            written += local.count + data.count

            central.appendLE(UInt32(0x0201_4B50))  // central directory header signature
            central.appendLE(versionMadeBy)
            central.appendLE(versionNeeded)
            central.appendLE(flagUTF8)
            central.appendLE(UInt16(0))
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))  // extra field length
            central.appendLE(UInt16(0))  // comment length
            central.appendLE(UInt16(0))  // disk number start
            central.appendLE(UInt16(0))  // internal attributes
            central.appendLE(regularFileMode << 16)  // external attributes: Unix mode in the high half
            central.appendLE(offset)
            central.append(name)
        }

        guard written <= 0xFFFF_FFFF, central.count <= 0xFFFF_FFFF,
              written + central.count <= 0xFFFF_FFFF else { throw ZipWriterError.archiveTooLarge }
        var tail = central
        tail.appendLE(UInt32(0x0605_4B50))  // end of central directory signature
        tail.appendLE(UInt16(0))  // this disk
        tail.appendLE(UInt16(0))  // disk with the central directory
        tail.appendLE(UInt16(entries.count))
        tail.appendLE(UInt16(entries.count))
        tail.appendLE(UInt32(central.count))
        tail.appendLE(UInt32(written))
        tail.appendLE(UInt16(0))  // comment length
        try emit(tail)
    }

    /// 2.0: the lowest version that defines the UTF-8 name flag readers check against.
    private static let versionNeeded: UInt16 = 20
    /// High byte 3 = Unix, so readers apply the mode in the external attributes.
    private static let versionMadeBy: UInt16 = (3 << 8) | 20
    /// General purpose bit 11: names are UTF-8.
    private static let flagUTF8: UInt16 = 1 << 11
    /// S_IFREG | 0644.
    private static let regularFileMode: UInt32 = 0o100644

    private static func dosTimestamp(_ date: Date?, timeZone: TimeZone) throws -> (time: UInt16, date: UInt16) {
        guard let date else { return (0, (1 << 5) | 1) }  // 1980-01-01 00:00:00
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, let month = c.month, let day = c.day,
              let hour = c.hour, let minute = c.minute, let second = c.second,
              (1980...2107).contains(year) else { throw ZipWriterError.dateOutOfRange(date) }
        let time = UInt16(hour << 11 | minute << 5 | second / 2)
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        return (time, dosDate)
    }
}

extension Data {
    fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
