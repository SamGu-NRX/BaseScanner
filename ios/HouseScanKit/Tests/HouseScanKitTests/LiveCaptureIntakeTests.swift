import Foundation
import HouseScanKit
import Synchronization
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
            create: .init(packetId: packetID, tier: .arkit, device: .init(model: "iPhone15,4", systemVersion: "26.0", appVersion: "synthetic-test")),
            consentedAt: Date())
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

/// The native-shaped scan through `CaptureSessionCoordinator` against a real capture API, run
/// only with both `HOUSESCAN_LIVE_CAPTURE_API` and `HOUSESCAN_EXPORT_EVIDENCE_DIR` set. It writes
/// the packet, the upload state (packet, capture and run ids), the result and the stage times to
/// the evidence folder, which must be outside the repository: the ids are not for publishing.
@Suite struct LiveNativeCaptureTests {
    static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: environment["HOUSESCAN_LIVE_CAPTURE_API"] != nil && environment["HOUSESCAN_EXPORT_EVIDENCE_DIR"] != nil), .timeLimit(.minutes(10)))
    @MainActor
    func nativeScanReachesAResult() async throws {
        guard case .on(let base) = CaptureUploadGate.decide(endpoint: Self.environment["HOUSESCAN_LIVE_CAPTURE_API"], consented: true),
              let evidence = Self.environment["HOUSESCAN_EXPORT_EVIDENCE_DIR"].map(URL.init(fileURLWithPath:)) else {
            Issue.record("HOUSESCAN_LIVE_CAPTURE_API must be an https URL")
            return
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "live-native-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = Mutex<[String]>([])
        let log: @Sendable (String) -> Void = { line in
            let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)"
            print(stamped)
            lines.withLock { $0.append(stamped) }
        }
        let coordinator = CaptureSessionCoordinator(
            environment: NativeCaptureFixture.environment(
                endpoint: base, http: URLSessionCaptureHTTP.ephemeral(timeout: 90), captures: root.appending(path: "Captures"), eventsWait: 20, log: log))
        let fixture = NativeCaptureFixture(folder: root.appending(path: "store"))
        let committedBeforeEnd = Mutex(0)
        try await fixture.run(coordinator) {
            let count = await coordinator.session!.uploader!.snapshot.committedCount
            committedBeforeEnd.withLock { $0 = count }
        }
        let session = try #require(coordinator.session)
        let state = await session.uploader!.snapshot

        let target = evidence.appending(path: "native-export-live")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: session.folder, to: target)
        if let result = state.result { try result.write(to: evidence.appending(path: "native-export-live.result.json")) }
        let started = state.marks["started"] ?? Date()
        var summary = [
            "packetId": state.packetID, "captureId": state.captureID ?? "", "runId": state.finalized?.runID ?? "",
            "end": String(describing: state.end), "backendStatus": state.backendStatus ?? "", "lastEvent": state.lastEvent ?? "",
            "committedBeforeScanEnded": "\(committedBeforeEnd.withLock { $0 }) of \(state.files.count)",
        ]
        for (name, at) in state.marks { summary["mark.\(name)"] = String(format: "%.2f", at.timeIntervalSince(started)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: evidence.appending(path: "native-export-live.summary.json"))
        try lines.withLock { $0.joined(separator: "\n") }.write(to: evidence.appending(path: "native-export-live.log"), atomically: true, encoding: .utf8)

        #expect(state.finalized != nil)
        #expect(state.result != nil)
    }
}
