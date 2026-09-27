import Foundation
import HouseScanKit

/// Words for the packet upload card on the result. The consent screen's own text is
/// `PacketConsentWording` in HouseScanKit, where its id is pinned to it.
enum PacketUploadCopy {
    static let offerTitle = "Help Base's survey team"
    static let offerBody = "Send them your photos and measurements so they can build a 3D model of your wall. It's up to you."
    static let review = "See what's sent"
    static let skippedBody = "You chose not to send your scan. You can still change your mind."
    static let sendingTitle = "Sending to Base's survey team"
    static let preparing = "Getting your scan ready to send"
    static let keepUsing = "You can keep using the app. Sending carries on if you leave it."
    static let waitingTitle = "Sending paused"
    static let waitingBody = "It will try again on its own when the connection is back."
    static let sentTitle = "Sent to Base's survey team"
    static let sentBody = "Thank you. They have your photos, measurements and 3D data."
    static let failedTitle = "Your scan didn't send"
    static let failedBody = "Your result isn't affected. You can try again."
    static let retry = "Try again"

    /// "7 of 23 files · 4.1 MB of 18.2 MB"
    static func progress(_ p: PacketUploadProgress) -> String {
        "\(p.filesSent) of \(p.filesTotal) files · \(size(p.bytesSent)) of \(size(p.bytesTotal))"
    }

    /// "7 of 23 files sent, 4.1 MB of 18.2 MB": VoiceOver reads the dot as a word.
    static func spokenProgress(_ p: PacketUploadProgress) -> String {
        "\(p.filesSent) of \(p.filesTotal) files sent, \(size(p.bytesSent)) of \(size(p.bytesTotal))"
    }

    static func size(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }

    /// "23 photos"
    static func photos(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }

    /// "About 18.4 MB in all"
    static func total(_ bytes: Int) -> String {
        "About \(size(bytes)) in all"
    }
}
