import Foundation
import HouseScanKit
import Testing

/// One synthetic capture through a real capture API, run only when
/// `HOUSESCAN_LIVE_CAPTURE_API` names its base URL (with `/v1`). The packet says
/// `source.kind: synthetic`, holds generated pattern images and no house, and proves transport
/// only: a result from it is not an analysis. Prints stage times, never ids or URLs.
@Suite struct LiveCaptureIntakeTests {
    static let endpoint = ProcessInfo.processInfo.environment["HOUSESCAN_LIVE_CAPTURE_API"]

    @Test(.enabled(if: endpoint != nil), .timeLimit(.minutes(10)))
    func syntheticCaptureReachesAResult() async throws {
        guard case .on(let base) = CaptureUploadGate.decide(endpoint: Self.endpoint, consented: true) else {
            Issue.record("HOUSESCAN_LIVE_CAPTURE_API is not an https URL")
            return
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let packetID = UUID().uuidString
        let capture = try SyntheticCapture04(folder: root.appending(path: "packet"), packetID: packetID)
        let uploader = try CaptureUploader.start(
            folder: capture.folder, base: base, http: URLSessionCaptureHTTP.ephemeral(timeout: 90),
            create: .init(packetId: packetID, tier: .arkit, device: .init(model: "iPhone15,4", systemVersion: "26.0", appVersion: "synthetic-test")))
        await uploader.observe({ _ in }, log: { print($0) })

        await uploader.add(try await capture.sealImages())
        await uploader.settled()
        let during = await uploader.snapshot
        #expect(during.committedCount == during.files.count, "photos committed before the capture ends")

        let (streams, packet) = try await capture.finish()
        await uploader.seal(packet: packet, files: streams)
        await uploader.settled()

        let done = await uploader.snapshot
        let started = done.marks["started"] ?? Date()
        for (name, at) in done.marks.sorted(by: { $0.value < $1.value }) {
            print("live-intake mark \(name) +\(String(format: "%.2f", at.timeIntervalSince(started)))s")
        }
        print("live-intake end=\(String(describing: done.end)) backend=\(done.backendStatus ?? "-") last=\(done.lastEvent ?? "-")")
        if let result = done.result, let text = String(data: result, encoding: .utf8) {
            print("live-intake result bytes=\(result.count) status-field-present=\(text.contains("\"status\""))")
        }
        #expect(done.finalized != nil)
        #expect(done.result != nil)
    }
}
