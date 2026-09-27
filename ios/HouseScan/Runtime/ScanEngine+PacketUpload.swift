import Foundation
import HouseScanKit
import OSLog

/// Sending the capture packet to Base's survey team: offered on the result once the packet is
/// written, sent only after the homeowner agrees on the consent screen. The scene.json upload to
/// the placement server never waits for it. `PacketUploadService` does the sending.
extension ScanEngine: PacketUploadActions {
    private var packetUploads: PacketUploadService { .shared }

    /// A new bundle was written (`saveBundle`): offer it, unless the homeowner already sent one.
    /// The summary reads manifest.json only.
    func packetBundleReady() {
        guard packetUploads.isEnabled else { return }
        switch state.packetUpload {
        case .unavailable, .offered, .skipped: break
        case .preparing, .sending, .waiting, .sent, .failed: return
        }
        let folder = store.packetFolder
        let directory = store.directory
        Task {
            let summary = await Task.detached(priority: .utility) { try? PacketUploadPacket.summary(folder: folder) }.value
            // A start over or a newer bundle in between makes this one stale.
            guard store.directory == directory, state.shareableScan != nil, let summary else { return }
            switch state.packetUpload {
            case .skipped: state.packetUpload = .skipped(summary)
            case .unavailable, .offered: state.packetUpload = .offered(summary)
            case .preparing, .sending, .waiting, .sent, .failed: break
            }
        }
    }

    func sendPacket(_ consent: PacketUploadConsent) {
        // Offered means the packet folder is complete; a bundle being rewritten hides the scan.
        guard state.packetUpload.offer != nil, state.shareableScan != nil else { return }
        RuntimeLog.engine.info("packet upload: consent \(consent.textID, privacy: .public) given")
        state.packetUpload = .preparing
        packetUploads.send(scanFolder: store.directory, packetFolder: store.packetFolder, consent: consent) { [weak self] status in
            self?.state.packetUpload = status
        }
    }

    func skipPacket() {
        guard case .offered(let summary) = state.packetUpload else { return }
        RuntimeLog.engine.info("packet upload: skipped")
        state.packetUpload = .skipped(summary)
    }

    func retryPacket() {
        guard case .failed = state.packetUpload else { return }
        guard packetUploads.canSend else {
            RuntimeLog.engine.error("packet upload: no intake is selected; nothing sent")
            return
        }
        packetUploads.retry(scanFolder: store.directory)
    }

    /// Start over: the scan's upload stops before the scan's files are deleted.
    func cancelPacketUpload() {
        packetUploads.cancel(scanFolder: store.directory)
        state.packetUpload = .unavailable
    }
}
