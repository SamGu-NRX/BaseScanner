import Foundation
import HouseScanKit

// The capture-packet upload's part of the boundary between the engine and the screens
// (`ScanContract.swift`). The engine writes `ScanViewState.packetUpload`; the result screen offers
// the upload and shows its progress, and the consent screen sends the homeowner's answer back.

/// Where sending the capture packet to Base's survey team stands, for the scan on screen.
enum PacketUploadStatus: Equatable, Sendable {
    /// No upload endpoint is configured, or the scan's packet isn't written yet: nothing is
    /// offered and nothing is sent.
    case unavailable
    /// Offered on the result; the homeowner hasn't answered.
    case offered(PacketUploadSummary)
    /// The homeowner chose Skip. They can still open the consent screen again.
    case skipped(PacketUploadSummary)
    /// Consent given; the packet is being read and hashed.
    case preparing
    case sending(PacketUploadProgress)
    /// A call failed in a way that can clear up (offline, a server error); it retries on its own.
    case waiting(PacketUploadProgress)
    case sent
    /// Stopped. "Try again" (`retryPacket`) carries on from what was stored.
    case failed(PacketUploadProgress?)

    /// The packet the consent screen describes, while there is an answer to give.
    var offer: PacketUploadSummary? {
        switch self {
        case .offered(let summary), .skipped(let summary): summary
        default: nil
        }
    }
}

/// The homeowner's intents about the packet upload. `ScanActions` includes them.
@MainActor
protocol PacketUploadActions: AnyObject {
    /// Send on the consent screen, with the consent the toggle gave. Only valid while
    /// `packetUpload.offer` is set.
    func sendPacket(_ consent: PacketUploadConsent)
    /// Skip on the consent screen: nothing is sent.
    func skipPacket()
    /// "Try again" after `.failed`.
    func retryPacket()
}
