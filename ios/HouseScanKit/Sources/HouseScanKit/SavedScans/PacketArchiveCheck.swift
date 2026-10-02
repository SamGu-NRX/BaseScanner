import Foundation

/// Whether a file is a whole capture-packet zip, read from its two ends without unpacking it.
///
/// `scan.zip` is written in place (`ZipWriter.write`), so a scan quit or crashed during the write,
/// or a bundle still being written when a list is made, leaves a partial file under the name that
/// marks a completed scan. The zip's last record (the end of central directory) is written last,
/// so a file whose tail holds that record, pointing at a central directory that ends right before
/// it, was written to the end. The first entry must be `manifest.json`, which the packet always
/// writes first (`KeyframeStore.zipPacket`), so another zip under the name is not taken for a scan.
/// The central directory's first record must name the same entry at offset 0, which ties the
/// footer, the directory and the first entry together. A symbolic link is refused, so a copy of
/// the file is always the bytes themselves.
///
/// This detects a bundle that wasn't written to the end; it is not a defense against a crafted
/// zip. Only the app writes into its scan folders.
///
/// The check reads at most 64 KiB from each end, whatever the archive's size. It does not check
/// each entry's CRC: that would read every photo, and a write that reached the last record wrote
/// every entry before it.
public enum PacketArchiveCheck {
    public enum Failure: Error, Equatable, Sendable {
        /// The file can't be opened or read.
        case unreadable
        /// The end of central directory is missing or points somewhere else: a partial write.
        case incomplete
        /// A whole zip, but not a capture packet: its first entry isn't manifest.json.
        case notAPacket
        /// A symbolic link, a folder or anything else that isn't a plain file.
        case notAFile
    }

    static let firstEntryName = "manifest.json"
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let localHeaderSize = 30
    private static let endRecordSize = 22
    private static let centralHeaderSize = 46

    /// Returns the archive's size in bytes when it is a whole capture packet.
    public static func verify(_ url: URL) throws(Failure) -> Int64 {
        // attributesOfItem doesn't follow a final symbolic link.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { throw .unreadable }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw .notAFile }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw .unreadable }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            guard size >= UInt64(localHeaderSize + endRecordSize) else { throw Failure.incomplete }

            // The first local header, and its name.
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: localHeaderSize) ?? Data()
            guard header.count == localHeaderSize, header.le(UInt32.self, at: 0) == localHeaderSignature else {
                throw Failure.notAPacket
            }
            let nameLength = Int(header.le(UInt16.self, at: 26))
            let name = try handle.read(upToCount: nameLength) ?? Data()
            guard name == Data(firstEntryName.utf8) else { throw Failure.notAPacket }

            // The end record sits in the last 22 bytes plus its comment, at most 65535 bytes.
            let tailLength = min(size, UInt64(endRecordSize + 0xFFFF))
            let tailStart = size - tailLength
            try handle.seek(toOffset: tailStart)
            let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
            guard tail.count == Int(tailLength), let end = endRecord(in: tail) else { throw Failure.incomplete }
            let endOffset = tailStart + UInt64(end)
            let entries = tail.le(UInt16.self, at: end + 10)
            let directorySize = UInt64(tail.le(UInt32.self, at: end + 12))
            let directoryOffset = UInt64(tail.le(UInt32.self, at: end + 16))
            guard tail.le(UInt16.self, at: end + 4) == 0, tail.le(UInt16.self, at: end + 6) == 0,
                  tail.le(UInt16.self, at: end + 8) == entries, entries > 0,
                  directoryOffset + directorySize == endOffset else { throw Failure.incomplete }

            // The central directory starts where the record says, and its first record is the
            // manifest at offset 0.
            guard directorySize >= UInt64(centralHeaderSize) * UInt64(entries) else { throw Failure.incomplete }
            try handle.seek(toOffset: directoryOffset)
            let first = try handle.read(upToCount: centralHeaderSize) ?? Data()
            guard first.count == centralHeaderSize, first.le(UInt32.self, at: 0) == centralHeaderSignature else { throw Failure.incomplete }
            let firstName = try handle.read(upToCount: Int(first.le(UInt16.self, at: 28))) ?? Data()
            guard firstName == Data(firstEntryName.utf8), first.le(UInt32.self, at: 42) == 0 else { throw Failure.incomplete }
            return Int64(size)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unreadable
        }
    }

    /// The offset in `tail` of the end record whose comment runs exactly to the end, searching
    /// from the end; nil when there is none.
    private static func endRecord(in tail: Data) -> Int? {
        var offset = tail.count - endRecordSize
        while offset >= 0 {
            if tail.le(UInt32.self, at: offset) == endSignature,
               Int(tail.le(UInt16.self, at: offset + 20)) == tail.count - offset - endRecordSize {
                return offset
            }
            offset -= 1
        }
        return nil
    }
}

private extension Data {
    /// A little-endian integer at `offset` from the start of this data.
    func le<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for byte in 0..<MemoryLayout<T>.size {
            value |= T(self[startIndex + offset + byte]) << (8 * byte)
        }
        return value
    }
}
