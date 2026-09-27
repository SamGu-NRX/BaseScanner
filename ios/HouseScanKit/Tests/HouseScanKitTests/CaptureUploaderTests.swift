import Foundation
import HouseScanKit
import Synchronization
import Testing

/// The uploader against `LoopbackCaptureAPI` over real HTTP, through the same `URLSession`
/// transport the app uses. Retries wait 10 ms instead of seconds.
@Suite(.serialized) struct CaptureUploaderTests {
    struct Rig {
        let server: LoopbackCaptureAPI
        let root: URL
        let capture: SyntheticCapture04
        let uploader: CaptureUploader
        let http: any CaptureHTTP

        init(
            packetID: String = UUID().uuidString, appVersion: String = "test (1)", server: LoopbackCaptureAPI? = nil,
            http: any CaptureHTTP = URLSessionCaptureHTTP.ephemeral(timeout: 10)
        ) throws {
            self.http = http
            self.server = try server ?? LoopbackCaptureAPI()
            root = FileManager.default.temporaryDirectory.appending(path: "uploader-\(UUID().uuidString)")
            capture = try SyntheticCapture04(folder: root.appending(path: "packet"), packetID: packetID)
            uploader = try CaptureUploader.start(
                folder: capture.folder, base: self.server.base, http: http,
                create: .init(packetId: packetID, tier: .arkit, device: .init(model: "iPhone15,4", systemVersion: "26.0", appVersion: appVersion)),
                policy: Self.fast, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })
        }

        static var fast: CaptureUploader.Policy {
            var policy = CaptureUploader.Policy()
            policy.eventsWait = 0
            return policy
        }

        func finishAndSeal() async throws {
            let (streams, packet) = try await capture.finish()
            await uploader.seal(packet: packet, files: streams)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// Photos go up during the capture; the frozen packet finalizes early, the streams follow, and
    /// the capture ends with a result for its own run.
    @Test func joinedPathCommitsPhotosBeforeTheCaptureEnds() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let images = try await rig.capture.sealImages()
        await rig.uploader.add(images)
        await rig.uploader.settled()

        let during = await rig.uploader.snapshot
        #expect(during.committedCount == images.count)
        #expect(during.packet == nil)
        #expect(rig.server.requests("POST captures/finalize").isEmpty)

        try await rig.finishAndSeal()
        await rig.uploader.settled()
        let done = await rig.uploader.snapshot
        #expect(done.end == .finished(status: "manual_review"))
        #expect(done.finalized?.status == "awaiting_files")
        #expect(done.finalized?.missing.sorted() == ["streams/arkit_poses.csv.gz", "streams/imu_raw.csv.gz"])
        #expect(done.committedCount == images.count + 2)
        #expect(done.result != nil)
        let marks = done.marks
        #expect(try #require(marks["firstCommit"]) < #require(marks["sealed"]))
        #expect(try #require(marks["sealed"]) <= #require(marks["lastCommit"]))

        let puts = rig.server.requests("PUT upload")
        #expect(puts.count == images.count + 2)
        #expect(puts.allSatisfy { $0.headers["authorization"] == nil && $0.headers["content-md5"] != nil })
        #expect(rig.server.requests("POST captures").count == 1)
    }

    /// A create and a finalize whose answers are lost are sent again as the same bytes, and the
    /// server keeps one capture.
    @Test func lostAnswersAreReplayedWithTheFrozenBodies() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.server.state.withLock { $0.dropNext = ["POST captures", "POST captures/finalize"] }
        await rig.uploader.add(try await rig.capture.sealImages(count: 2))
        await rig.uploader.settled()
        try await rig.finishAndSeal()
        await rig.uploader.settled()

        let creates = rig.server.requests("POST captures")
        let finals = rig.server.requests("POST captures/finalize")
        #expect(creates.count == 2)
        #expect(Set(creates.map(\.body)).count == 1)
        #expect(finals.count == 2)
        #expect(Set(finals.map(\.body)).count == 1)
        #expect(rig.server.state.withLock { $0.captures.count } == 1)
        #expect(await rig.uploader.snapshot.end == .finished(status: "manual_review"))
    }

    /// A relaunch resumes the saved capture: same packet and capture ids, no second create, and the
    /// old process's attempt id is replaced.
    @Test func relaunchResumesTheSameCapture() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        await rig.uploader.add(try await rig.capture.sealImages(count: 2))
        await rig.uploader.settled()
        let before = await rig.uploader.snapshot

        let resumed = try #require(try CaptureUploader.resume(
            folder: rig.capture.folder, base: rig.server.base, http: rig.http, policy: Rig.fast, sleep: { _ in }))
        let after = await resumed.snapshot
        #expect(after.packetID == before.packetID)
        #expect(after.captureID == before.captureID)
        #expect(after.createBody == before.createBody)
        #expect(after.attemptID != before.attemptID)

        let (streams, packet) = try await rig.capture.finish()
        await resumed.seal(packet: packet, files: streams)
        await resumed.settled()
        #expect(await resumed.snapshot.end == .finished(status: "manual_review"))
        #expect(rig.server.requests("POST captures").count == 1)
    }

    /// The same packet id with a different create body is the server's idempotency conflict; the
    /// uploader stops instead of retrying it.
    @Test func aChangedCreateBodyIsRefusedNotRetried() async throws {
        let packetID = UUID().uuidString
        let first = try Rig(packetID: packetID)
        defer { first.cleanUp() }
        await first.uploader.kick()
        await first.uploader.settled()
        #expect(await first.uploader.snapshot.captureID != nil)

        let second = try Rig(packetID: packetID, appVersion: "test (2)", server: first.server)
        defer { second.cleanUp() }
        await second.uploader.kick()
        await second.uploader.settled()
        #expect(await second.uploader.snapshot.end == .failed(step: "create", codes: ["idempotency_conflict"], status: 409))
        #expect(first.server.requests("POST captures").count == 2)
    }

    /// A storage URL answered 403 (expired) is registered again and the file sent to the new URL.
    @Test func anExpiredURLIsFetchedAgain() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.server.state.withLock { $0.expireNextPuts = 1 }
        let images = try await rig.capture.sealImages(count: 1)
        await rig.uploader.add(images)
        await rig.uploader.settled()
        let snapshot = await rig.uploader.snapshot
        #expect(snapshot.committedCount == images.count)
        #expect(rig.server.requests("PUT upload").count == images.count + 1)
        let registered = rig.server.requests("POST captures/files").flatMap { request -> [String] in
            let body = try? JSONDecoder().decode(CaptureAPI.RegisterRequest.self, from: request.body)
            return body?.files.map(\.path) ?? []
        }
        #expect(registered.count == images.count + 1)
    }

    /// Only paths the commit names as committed advance; notFound and mismatch go up again.
    @Test func mixedCommitAnswersAdvanceOnlyCommittedFiles() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let images = try await rig.capture.sealImages(count: 2)
        // Priority order: the still, then k00001, then k00002.
        let paths = ["stills/meter_close.jpg", "keyframes/k00001.jpg", "keyframes/k00002.jpg"]
        #expect(Set(images.map(\.path)) == Set(paths))
        rig.server.state.withLock { $0.commitOverride = (committed: [paths[0]], notFound: [paths[1]], mismatch: [paths[2]]) }
        let seen = Mutex<[Int]>([])
        await rig.uploader.observe { status in seen.withLock { $0.append(status.committed) } }
        await rig.uploader.add(images)
        await rig.uploader.settled()

        #expect(await rig.uploader.snapshot.committedCount == 3)
        // After the first commit exactly one file counted as received.
        #expect(seen.withLock { $0.first { $0 > 0 } } == 1)
        let puts = rig.server.requests("PUT upload")
        #expect(puts.count == 5)
    }

    /// A world reset while a register answer is in flight: the late answer changes nothing, and the
    /// next capture is a new packet that never reuses the old one.
    @Test func resetDuringAPendingAnswerDropsTheLateReply() async throws {
        // A background session's transfer outlives the task that asked for it, so the reply
        // still arrives after the reset; only the attempt check keeps it out.
        let rig = try Rig(http: UncancellableHTTP(URLSessionCaptureHTTP.ephemeral(timeout: 10)))
        defer { rig.cleanUp() }
        rig.server.state.withLock { $0.held = ["POST captures/files"] }
        await rig.uploader.add(try await rig.capture.sealImages(count: 2))
        for _ in 0..<500 where rig.server.requests("POST captures/files").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.server.requests("POST captures/files").count == 1)

        await rig.uploader.abandon("world reset")
        rig.server.release("POST captures/files")
        try await Task.sleep(for: .milliseconds(300))
        await rig.uploader.settled()

        let after = await rig.uploader.snapshot
        #expect(after.end == .abandoned("world reset"))
        #expect(after.files.values.allSatisfy { $0.phase == .queued })
        #expect(rig.server.requests("PUT upload").isEmpty)
        // Nothing more is sent for the abandoned capture.
        let late = try await rig.capture.producer.sealKeyframe(
            jpeg: try SyntheticCapture04.jpeg(in: rig.root), observation: rig.capture.observation(SyntheticCapture04.start + 1.9), reason: "motion")
        await rig.uploader.add(late)
        await rig.uploader.settled()
        #expect(rig.server.requests("POST captures/files").count == 1)

        let next = try Rig(server: rig.server)
        defer { next.cleanUp() }
        await next.uploader.add(try await next.capture.sealImages(count: 1))
        await next.uploader.settled()
        #expect(await next.uploader.snapshot.captureID != after.captureID)
        #expect(await next.uploader.snapshot.committedCount == 2)
    }

    /// A finalize the server accepted and then lost (`failed`, next `retry_finalize`) is sent
    /// again as the same bytes, and the run then completes.
    @Test func aLostFinalizeIsSentAgainOnRetryFinalize() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.server.state.withLock { $0.loseNextFinalize = true }
        await rig.uploader.add(try await rig.capture.sealImages(count: 1))
        try await rig.finishAndSeal()
        await rig.uploader.settled()
        let finals = rig.server.requests("POST captures/finalize")
        #expect(finals.count == 2)
        #expect(Set(finals.map(\.body)).count == 1)
        #expect(await rig.uploader.snapshot.end == .finished(status: "manual_review"))
        #expect(await rig.uploader.snapshot.finalizeRetries == 1)
    }

    /// Storage that keeps refusing the sealed bytes' digest stops the upload after one retry
    /// instead of cycling through register and PUT.
    @Test func aDigestRefusedTwiceStopsTheUpload() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.server.state.withLock { $0.badDigestPuts = 100 }
        await rig.uploader.add(try await rig.capture.sealImages(count: 1))
        await rig.uploader.settled()
        #expect(await rig.uploader.snapshot.end == .failed(step: "put", codes: ["bad_digest"], status: 400))
        #expect(rig.server.requests("PUT upload").count <= 4)
    }

    /// A file listed in the frozen packet that reached `seal` before its own `add` is still sent.
    @Test func sealQueuesListedFilesItHasNotSeen() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let images = try await rig.capture.sealImages(count: 2)
        await rig.uploader.add(Array(images.prefix(1)))
        await rig.uploader.settled()
        let (streams, packet) = try await rig.capture.finish()
        await rig.uploader.seal(packet: packet, files: images + streams)
        await rig.uploader.add(Array(images.suffix(1)))
        await rig.uploader.settled()
        let done = await rig.uploader.snapshot
        #expect(done.end == .finished(status: "manual_review"))
        #expect(done.committedCount == images.count + streams.count)
    }

    @Test func noEndpointOrNoConsentMeansNoUpload() {
        #expect(CaptureUploadGate.decide(endpoint: nil, consented: true) == .off("no capture endpoint in this build"))
        #expect(CaptureUploadGate.decide(endpoint: "", consented: true) == .off("no capture endpoint in this build"))
        #expect(CaptureUploadGate.decide(endpoint: "$(HOUSESCAN_CAPTURE_API_URL)", consented: true) == .off("no capture endpoint in this build"))
        #expect(CaptureUploadGate.decide(endpoint: "http://example.com/v1", consented: true) == .off("capture endpoint must be https"))
        #expect(CaptureUploadGate.decide(endpoint: "https://user:secret@example.com/v1", consented: true) == .off("capture endpoint is not a URL"))
        #expect(CaptureUploadGate.decide(endpoint: "https://example.com/v1", consented: false) == .off("the homeowner has not agreed to send the capture"))
        #expect(CaptureUploadGate.decide(endpoint: "https://example.com/v1", consented: true) == .on(URL(string: "https://example.com/v1")!))
    }
}

/// Runs each request in a detached task, so cancelling the caller doesn't cancel the request:
/// the way a background URLSession behaves.
struct UncancellableHTTP: CaptureHTTP {
    let inner: any CaptureHTTP
    init(_ inner: any CaptureHTTP) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        try await Task.detached { try await inner.send(request) }.value
    }

    func upload(_ request: URLRequest, file: URL) async throws -> HTTPReply {
        try await Task.detached { try await inner.upload(request, file: file) }.value
    }
}
