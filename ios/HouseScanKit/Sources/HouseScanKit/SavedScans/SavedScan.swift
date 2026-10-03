import Foundation

/// A completed scan still on the phone, as the Saved scans list shows it: its bundle and what the
/// files say about it. Nothing here is read from the capture itself, so a field the files don't
/// carry is nil rather than guessed.
public struct SavedScan: Sendable, Equatable, Identifiable {
    /// The scan folder's name, a UUID the store made. Not shown to the homeowner.
    public let id: String
    /// The bundle Share scan offers, `<folder>/scan.zip`.
    public let archive: URL
    /// When the bundle was last written: the file's modification time. The bundle is written when
    /// the scan is uploaded and again on a retry, so this is when the scan was saved, not when its
    /// photos were taken. Nil when the file system gives no date.
    public let savedAt: Date?
    /// The bundle's size in bytes.
    public let byteCount: Int64
    /// `scan-stamp.json`'s `practice`: true for a practice scan, false for a real one, nil when
    /// the folder has no readable stamp. Nil is "unknown", never "real".
    public let practice: Bool?

    public init(id: String, archive: URL, savedAt: Date?, byteCount: Int64, practice: Bool?) {
        self.id = id
        self.archive = archive
        self.savedAt = savedAt
        self.byteCount = byteCount
        self.practice = practice
    }

    /// The name the shared copy carries, so a recipient with several scans can tell them apart:
    /// "House Scan 2026-10-02 14.05.zip" in the phone's time zone, "House Scan practice …" for a
    /// practice scan, and plain "House Scan.zip" without a date. No colons, which Files and
    /// Windows refuse.
    public func shareFileName(timeZone: TimeZone = .current) -> String {
        var parts = ["House Scan"]
        if practice == true { parts.append("practice") }
        if let savedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH.mm"
            parts.append(formatter.string(from: savedAt))
        }
        return parts.joined(separator: " ") + ".zip"
    }
}
