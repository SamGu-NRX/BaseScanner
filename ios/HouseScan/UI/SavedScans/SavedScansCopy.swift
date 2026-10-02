import Foundation
import HouseScanKit

/// The words of Saved scans. A saved scan can be shared and nothing else: none of these lines may
/// suggest it can be reopened, continued or rechecked.
enum SavedScansCopy {
    static let title = "Saved scans"
    static let entry = "Saved scans"

    /// How many completed scans the phone keeps, in words, from the cleanup's own count.
    static var kept: String {
        let count = ScanFolderCleanup.defaultKeepCompleted
        return count == 1 ? "your most recent finished scan" : "your \(count) most recent finished scans"
    }

    static var intro: String {
        "This phone keeps \(kept). You can send one to the House Scan team. A saved scan can't be reopened or continued."
    }

    static let shareFooter = "Sharing sends the scan's photos and measurements. Nothing leaves your phone until you choose where to send it."

    static let emptyTitle = "No saved scans"
    static var emptyDetail: String {
        "When you finish a scan, it's saved here so you can share it later. This phone keeps \(kept)."
    }

    static let share = "Share"
    static let practice = "Practice"
    /// Under a practice scan: a drawn sample stood in for the meter and its close-up, so the
    /// meter's place and number describe no real meter. The wall walk itself was real.
    static let practiceDetail = "Practice scan with a sample meter"
    static let unknownTime = "Saved time unknown"

    static func saved(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Saved today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Saved yesterday at \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return "Saved \(day) at \(time)"
    }

    static func problemTitle(_ error: SavedScanShareError) -> String {
        switch error {
        case .missing: "This scan is no longer on this phone"
        case .damaged: "This scan can't be shared"
        case .copyFailed: "Couldn't get the scan ready"
        }
    }

    static func problemDetail(_ error: SavedScanShareError) -> String {
        switch error {
        case .missing: "A newer scan replaced it, or the phone cleared space. The list now shows what's left."
        case .damaged: "Its file was not saved completely. The list now shows the scans that can be shared."
        case .copyFailed: "Your phone may be low on storage. Free up some space, then try again."
        }
    }
}
