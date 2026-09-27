import Foundation
import HouseScanKit
import simd
import Synchronization
import Testing

/// A scan shaped like the app's live capture, for the coordinator: 1920 x 1440 sensor JPEGs, the
/// camera 2 m from a wall at 1.5 m height walking +x, the recorder's raw rows (a 60 Hz trajectory
/// with each frame's intrinsics beside it, and Core Motion's accelerometer and gyro at about
/// 100 Hz on their own jittered clocks), the meter tap's frame and pixel, and the meter close-up
/// from its own frame. Pattern images, no house; the packet says `source.kind: synthetic`.
struct NativeCaptureFixture: Sendable {
    static let width = 1920, height = 1440
    static let k = SIMD4<Float>(1445, 1445, 960, 720)
    static let meter = SIMD3<Float>(0.4, 1.2, -2)
    let start = 5000.0
    let end = 5012.0
    let folder: URL

    func pose(_ t: Double) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(Float(t - start) * 0.1, 1.5, 0, 1)
        return m
    }

    /// Where `world` lands in the sensor image of the frame at `t`.
    func pixel(of world: SIMD3<Float>, at t: Double) -> SIMD2<Double> {
        let p = world - SIMD3(pose(t).columns.3.x, pose(t).columns.3.y, pose(t).columns.3.z)
        let depth = -p.z
        return SIMD2(Double(Self.k.z + Self.k.x * p.x / depth), Double(Self.k.w - Self.k.y * p.y / depth))
    }

    var recording: RecordingSource {
        let fixture = self
        return RecordingSource(start: { (fixture.start, Date(timeIntervalSince1970: 1_790_000_000)) }, rows: { fixture.rows })
    }

    var rows: RecorderRows {
        var trajectory: [[Double]] = [], intrinsics: [[Double]] = []
        for i in 0...Int((end - start) * 60) {
            let t = start + Double(i) / 60
            let m = pose(t)
            let columns: [SIMD4<Float>] = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
            let values: [Double] = columns.flatMap { (c: SIMD4<Float>) -> [Double] in [Double(c.x), Double(c.y), Double(c.z), Double(c.w)] }
            trajectory.append([t, 0, 0] + values)
            intrinsics.append([t, 1445, 1445, 960, 720, 1920, 1440])
        }
        // Two sensors on their own clocks: neither shares a timestamp with the other.
        var accel: [[Double]] = [], gyro: [[Double]] = []
        for i in 0..<Int((end - start) * 100) {
            let jitter = Double((i * 7919) % 11) * 0.0001
            accel.append([start + Double(i) * 0.01 + jitter, 0.01, -0.99, 0.02])
            gyro.append([start + Double(i) * 0.01 + 0.0037 - jitter, 0.001, -0.002, 0.0005])
        }
        return RecorderRows(trajectory: trajectory, intrinsics: intrinsics, accelerometer: accel, gyroscope: gyro)
    }

    func jpeg(named name: String) throws -> URL {
        let url = folder.appending(path: "\(name).jpg")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try makeJPEG(width: Self.width, height: Self.height, at: url)
        }
        return url
    }

    func photo(at t: Double, purpose: String? = nil) throws -> KeptPhoto {
        KeptPhoto(
            t: t, cameraToWorld: pose(t), cameraIntrinsics: Self.k, cameraImageSize: SIMD2(1920, 1440), width: Self.width, height: Self.height,
            tracking: .normal, exposure: .init(duration: 0.004, offset: 0, iso: 64, fNumber: 1.6), jpeg: try jpeg(named: "frame-\(t)"), purpose: purpose)
    }

    func tap(at t: Double) throws -> (TapObservation, Packet04.TapHit) {
        let data = try Data(contentsOf: try jpeg(named: "tap-\(t)"))
        let camera = pose(t).columns.3
        let tap = TapObservation(
            t: t, cameraToWorld: pose(t), intrinsics: Self.k, width: Self.width, height: Self.height, tracking: .normal,
            pixel: pixel(of: Self.meter, at: t), jpeg: { data })
        let hit = Packet04.TapHit(
            position: [Self.meter.x, Self.meter.y, Self.meter.z].map(Double.init), target: "estimatedPlane", alignment: "vertical",
            distance: Double(simd_distance(Self.meter, SIMD3(camera.x, camera.y, camera.z))))
        return (tap, hit)
    }

    static func environment(endpoint: URL, http: any CaptureHTTP, captures: URL, eventsWait: Int = 0, log: @escaping @Sendable (String) -> Void = { _ in }) -> CaptureSessionCoordinator.Environment {
        var policy = CaptureUploader.Policy()
        policy.eventsWait = eventsWait
        let device = CaptureAPI.Device(model: "iPhone15,4", systemVersion: "26.0", appVersion: "0.1.0 (1)")
        return .init(
            endpoint: endpoint, http: http, capturesFolder: captures,
            sessionInfo: { packetID, video in
                Packet04SessionInfo(
                    packetID: packetID, sessionID: packetID, source: .synthetic, appVersion: device.appVersion, deviceModel: device.model,
                    systemVersion: device.systemVersion, lidarAvailable: false, sceneDepthEnabled: false, meshReconstructionSupported: nil,
                    sceneReconstruction: nil, planeDetection: ["horizontal", "vertical"], videoWidth: Int(video.x), videoHeight: Int(video.y),
                    framesPerSecond: nil, timeZone: "America/Chicago")
            },
            device: device, tier: .arkit, policy: policy, log: log)
    }

    /// The whole scan through `coordinator`: the tap, the close-up, keyframes (one of them the
    /// close-up's own frame again), then the capture ends.
    @MainActor
    func run(_ coordinator: CaptureSessionCoordinator, beforeEnd: @MainActor () async -> Void = {}) async throws {
        coordinator.begin(recording: recording)
        let (tap, hit) = try self.tap(at: start + 1)
        coordinator.meterTapped(tap, hit: hit)
        coordinator.kept(try photo(at: start + 2.5, purpose: "meter_close"))
        for i in 0..<5 { coordinator.kept(try photo(at: start + 3 + Double(i) * 1.5)) }
        // The app keeps the close-up's frame twice when it is also a walk frame.
        coordinator.kept(try photo(at: start + 2.5))
        await coordinator.settle()
        await beforeEnd()
        coordinator.captureEnded()
        coordinator.captureEnded()
        await coordinator.settle()
    }
}

@Suite(.serialized) @MainActor struct CaptureSessionCoordinatorTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "coordinator-\(UUID().uuidString)")
    var fixture: NativeCaptureFixture { NativeCaptureFixture(folder: root.appending(path: "store")) }
    var captures: URL { root.appending(path: "Captures") }

    @Test func nativeScanExportsAValidPacketAndUploadsItDuringTheScan() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LoopbackCaptureAPI()
        let coordinator = CaptureSessionCoordinator(
            environment: NativeCaptureFixture.environment(endpoint: server.base, http: URLSessionCaptureHTTP.ephemeral(timeout: 10), captures: captures),
            consent: true)
        let committedBeforeEnd = Mutex(0)
        try await fixture.run(coordinator) {
            let uploader = coordinator.session!.uploader
            committedBeforeEnd.withLock { $0 = 0 }
            let count = await uploader.snapshot.committedCount
            committedBeforeEnd.withLock { $0 = count }
        }
        let session = try #require(coordinator.session)
        let state = await session.uploader.snapshot
        let packet = try JSONDecoder().decode(Packet04.Packet.self, from: try #require(state.packet))

        #expect(Packet04Check.problems(packet, folder: session.folder).isEmpty)
        // Tap frame, close-up frame and five walk frames; the repeated close-up frame is not a new keyframe.
        #expect(packet.keyframes.count == 7)
        #expect(packet.keyframes.map(\.reason) == ["tap", "still", "auto", "auto", "auto", "auto", "auto"])
        #expect(packet.stills?.map(\.purpose) == ["meter_close"])
        #expect(packet.scaleReference.meterCloseUp.still == "meter_close")
        let tap = try #require(packet.taps?.first)
        #expect(tap.label == "meter" && tap.keyframe == "k00001" && tap.epoch == "e1")
        // The ray through the tap pixel reaches the meter the raycast hit.
        let toMeter = simd_normalize(SIMD3(tap.hit!.position[0] - tap.rayOrigin[0], tap.hit!.position[1] - tap.rayOrigin[1], tap.hit!.position[2] - tap.rayOrigin[2]))
        #expect(simd_distance(toMeter, SIMD3(tap.rayDirection[0], tap.rayDirection[1], tap.rayDirection[2])) < 1e-5)
        // Raw world poses, straight from the frames.
        #expect(packet.keyframes[2].pose[12...14].map { $0 } == [0.3, 1.5, 0])
        // Both sensors' own times travel beside the proposed pairing.
        #expect(packet.ext?["imuRawPairingStatus"]?.hasPrefix("proposal") == true)
        #expect(Set(packet.files.filter { $0.role == .stream }.map(\.path))
            == ["streams/arkit_poses.csv.gz", "streams/imu_raw.csv.gz", "streams/accelerometer_raw.csv.gz", "streams/gyroscope_raw.csv.gz"])

        #expect(committedBeforeEnd.withLock { $0 } == packet.files.count - 4, "every image was received before the scan ended")
        #expect(state.end == .finished(status: "manual_review"))
        #expect(server.requests("POST captures").count == 1)
        #expect(server.requests("POST captures/finalize").count == 1)

        if let dir = ProcessInfo.processInfo.environment["HOUSESCAN_EXPORT_EVIDENCE_DIR"] {
            let target = URL(fileURLWithPath: dir).appending(path: "native-export-local")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: session.folder, to: target)
        }
    }

    @Test func noEndpointNoConsentOrANoSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LoopbackCaptureAPI()
        let http = URLSessionCaptureHTTP.ephemeral(timeout: 10)
        for (environment, consent) in [
            (nil, true), (NativeCaptureFixture.environment(endpoint: server.base, http: http, captures: captures), nil),
            (NativeCaptureFixture.environment(endpoint: server.base, http: http, captures: captures), false),
        ] as [(CaptureSessionCoordinator.Environment?, Bool?)] {
            let coordinator = CaptureSessionCoordinator(environment: environment, consent: consent)
            try await fixture.run(coordinator)
            #expect(coordinator.session == nil)
        }
        #expect(server.state.withLock { $0.log.isEmpty })
    }

    /// A world reset while the first world's photos are still going up: that packet is abandoned,
    /// the new world gets its own packet id, and nothing kept after the reset joins the old one.
    @Test func aWorldResetStartsANewPacketAndDropsTheOld() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LoopbackCaptureAPI()
        server.state.withLock { $0.held = ["POST captures/files"] }
        let coordinator = CaptureSessionCoordinator(
            environment: NativeCaptureFixture.environment(endpoint: server.base, http: UncancellableHTTP(URLSessionCaptureHTTP.ephemeral(timeout: 10)), captures: captures),
            consent: true)
        coordinator.begin(recording: fixture.recording)
        coordinator.kept(try fixture.photo(at: fixture.start + 2))
        let first = try #require(coordinator.session)
        for _ in 0..<500 where server.requests("POST captures/files").isEmpty { try await Task.sleep(for: .milliseconds(10)) }

        coordinator.newWorld("world reset", recording: fixture.recording)
        coordinator.kept(try fixture.photo(at: fixture.start + 4))
        server.release("POST captures/files")
        server.state.withLock { $0.held = [] }
        await coordinator.settle()
        await first.uploader.settled()

        let second = try #require(coordinator.session)
        #expect(second.packetID != first.packetID)
        let old = await first.uploader.snapshot
        #expect(old.end == .abandoned("world reset"))
        #expect(old.files.values.allSatisfy { $0.phase == .queued })
        #expect(await second.uploader.snapshot.files.keys.sorted() == ["keyframes/k00001.jpg"])
        #expect(await second.uploader.snapshot.committedCount == 1)
        let creates = server.requests("POST captures").compactMap { try? JSONDecoder().decode(CaptureAPI.CreateRequest.self, from: $0.body).packetId }
        #expect(Set(creates) == [first.packetID, second.packetID])
    }

    /// Photos kept after the scan was sent don't change the frozen packet or start more uploads.
    @Test func photosAfterTheScanWasSentAreNotAdded() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LoopbackCaptureAPI()
        let coordinator = CaptureSessionCoordinator(
            environment: NativeCaptureFixture.environment(endpoint: server.base, http: URLSessionCaptureHTTP.ephemeral(timeout: 10), captures: captures),
            consent: true)
        try await fixture.run(coordinator)
        let before = await coordinator.session!.uploader.snapshot
        coordinator.kept(try fixture.photo(at: fixture.end - 0.5))
        await coordinator.settle()
        let after = await coordinator.session!.uploader.snapshot
        #expect(after.packet == before.packet)
        #expect(after.files.count == before.files.count)
    }
}
