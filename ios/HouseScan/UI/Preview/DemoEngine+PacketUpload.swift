import Foundation
import HouseScanKit

/// The packet upload in the UI demo: offered when `-packetUploadURL` is given, with a made-up
/// packet, and a fake transfer that sends nothing.
extension DemoEngine {
    private static let demoPacket = PacketUploadSummary(photos: 23, bytes: 18_400_000)
    private static let demoFiles = 58

    static func withPacketUpload(arguments: [String]) -> DemoEngine {
        let engine = DemoEngine(arguments: arguments)
        guard LaunchOptions(arguments: arguments).packetUpload != nil else { return engine }
        let index = arguments.firstIndex(of: "-uiDemoPacket")
        let start = index.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let partway = progress(files: 21)
        engine.state.packetUpload = switch start ?? "" {
        case "sending": .sending(partway)
        case "waiting": .waiting(partway)
        case "sent": .sent
        case "failed": .failed(partway)
        case "skipped": .skipped(demoPacket)
        default: .offered(demoPacket)
        }
        return engine
    }

    private static func progress(files: Int) -> PacketUploadProgress {
        PacketUploadProgress(
            filesSent: files, filesTotal: demoFiles, bytesSent: demoPacket.bytes * files / demoFiles, bytesTotal: demoPacket.bytes)
    }

    func sendPacket(_ consent: PacketUploadConsent) {
        guard state.packetUpload.offer != nil else { return }
        _ = consent
        runPacketTransfer(from: 0)
    }

    func skipPacket() {
        guard case .offered(let summary) = state.packetUpload else { return }
        state.packetUpload = .skipped(summary)
    }

    func retryPacket() {
        guard case .failed(let progress) = state.packetUpload else { return }
        runPacketTransfer(from: progress?.filesSent ?? 0)
    }

    /// A file about every 0.3 s; frozen, it stays a third of the way.
    private func runPacketTransfer(from files: Int) {
        packetScript?.cancel()
        guard !ProcessInfo.processInfo.arguments.contains("-uiDemoFreeze") else {
            state.packetUpload = .sending(Self.progress(files: max(files, Self.demoFiles / 3)))
            return
        }
        state.packetUpload = .preparing
        packetScript = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            for sent in files...Self.demoFiles {
                guard !Task.isCancelled else { return }
                self?.state.packetUpload = .sending(Self.progress(files: sent))
                try? await Task.sleep(for: .seconds(0.3))
            }
            guard !Task.isCancelled else { return }
            self?.state.packetUpload = .sent
        }
    }
}
