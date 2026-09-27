import Foundation
import HouseScanKit
import Observation
import OSLog
import simd
import UIKit

/// The integration build's capture upload: while the homeowner scans, each kept photo is sealed
/// into a 0.4 packet with its own ARFrame's raw pose and intrinsics and sent to the capture API;
/// when the scan is sent for placement, the packet is frozen with its streams and finalized.
///
/// It runs only when the build names a capture API (`HouseScanCaptureAPIURL`, or the
/// `-captureAPIURL` launch argument) and the homeowner said yes. The placement request
/// (`ResultClient`, scene.json) is unchanged and never waits for it.
///
/// One session is one ARKit world: a world reset or a start over abandons the packet and the next
/// photo starts a new one with a new packet id. Files live in Application Support/Captures/<packet
/// id>, outside the scan folders the store cleans up, until the capture is finished on the server.
@MainActor
@Observable
final class CaptureIntegration {
    static let consentKey = "captureUploadConsent.v1"
    static let infoKey = "HouseScanCaptureAPIURL"
    /// Checklist purposes the packet's `stills` take; any other still stays a keyframe only.
    static let stillPurposes: Set<String> = ["meter_close", "meter_oblique"]

    /// The build's capture API, whatever the homeowner answered.
    let endpoint: URL?
    /// Nil until the homeowner answers.
    private(set) var consent: Bool?
    private(set) var status: CaptureUploadStatus?

    @ObservationIgnored private var session: Session?
    @ObservationIgnored private weak var store: KeyframeStore?
    @ObservationIgnored private var recorder: CaptureRecorder?
    @ObservationIgnored private let http = URLSessionCaptureHTTP.ephemeral(timeout: 60)
    @ObservationIgnored private var resumed: [CaptureUploader] = []

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        infoValue: String? = Bundle.main.object(forInfoDictionaryKey: CaptureIntegration.infoKey) as? String,
        defaults: UserDefaults = .standard
    ) {
        let argument = arguments.firstIndex(of: "-captureAPIURL").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        endpoint = if case .on(let url) = CaptureUploadGate.decide(endpoint: argument ?? infoValue, consented: true) { url } else { nil }
        consent = defaults.object(forKey: Self.consentKey) as? Bool
        if endpoint != nil { resumeSealedCaptures() }
    }

    var needsConsent: Bool { endpoint != nil && consent == nil }
    private var enabled: Bool { endpoint != nil && consent == true }

    func answerConsent(_ yes: Bool) {
        consent = yes
        UserDefaults.standard.set(yes, forKey: Self.consentKey)
        RuntimeLog.engine.info("capture upload consent: \(yes ? "yes" : "no", privacy: .public)")
        if yes, store != nil, session == nil { startSession() }
    }

    // MARK: Engine hooks

    /// The live source started: photos kept in `store` from now on go into the packet.
    func begin(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store: store, recorder: recorder)
        if enabled, session == nil { startSession() }
    }

    /// The ARKit world was thrown away: this packet can't be finished in it.
    func worldReset(store: KeyframeStore, recorder: CaptureRecorder) {
        endSession("world reset")
        attach(store: store, recorder: recorder)
        if enabled { startSession() }
    }

    func startOver(store: KeyframeStore, recorder: CaptureRecorder) {
        endSession("start over")
        attach(store: store, recorder: recorder)
        if enabled { startSession() }
    }

    /// The scan was sent for placement: freeze the packet with the streams recorded so far. Every
    /// later upload of the same scan (a retry, one more view) calls this again and changes nothing.
    func captureEnded() {
        guard let session, !session.sealing, let recorder else { return }
        session.sealing = true
        let previous = session.chain
        session.chain = Task {
            await previous?.value
            guard let producer = session.producer else {
                await session.uploader.abandon("no photos were kept")
                return
            }
            let rows = await Task.detached(priority: .utility) { Self.streamRows(recorder) }.value
            do {
                let finished = try await producer.finish(
                    poses: rows.poses, accelerometer: rows.accelerometer, gyroscope: rows.gyroscope,
                    endedAtUptime: rows.poses.last?.t ?? 0, closeUpDistanceM: nil)
                await session.uploader.seal(packet: finished.packet, files: await producer.sealedFiles)
            } catch {
                RuntimeLog.engine.error("capture packet not finished: \(String(describing: error), privacy: .public)")
                await session.uploader.abandon("packet refused on the phone")
            }
        }
    }

    // MARK: Sessions

    @MainActor
    final class Session {
        let packetID: String
        let folder: URL
        let uploader: CaptureUploader
        var producer: Packet04Producer?
        /// Photos are sealed one at a time, in the order they were kept.
        var chain: Task<Void, Never>?
        var sealing = false

        init(packetID: String, folder: URL, uploader: CaptureUploader) {
            self.packetID = packetID
            self.folder = folder
            self.uploader = uploader
        }
    }

    static var capturesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Captures", directoryHint: .isDirectory)
    }

    private func attach(store: KeyframeStore, recorder: CaptureRecorder) {
        if let old = self.store, old !== store { old.onKept = nil }
        self.store = store
        self.recorder = recorder
        store.onKept = { [weak self, weak store] photo, purpose, jpeg in
            guard let self, let store, store === self.store else { return }
            self.kept(photo, purpose: purpose, jpeg: jpeg, storeDirectory: store.directory)
        }
    }

    private func startSession() {
        guard let endpoint else { return }
        let packetID = UUID().uuidString
        let folder = Self.capturesFolder.appending(path: packetID, directoryHint: .isDirectory)
        let create = CaptureAPI.CreateRequest(
            packetId: packetID, tier: LiveCapture.supportsDepth ? .arkitLidar : .arkit,
            device: .init(model: ScanEngine.hardwareModel(), systemVersion: UIDevice.current.systemVersion, appVersion: Self.appVersion))
        do {
            let uploader = try CaptureUploader.start(folder: folder, base: endpoint, http: http, create: create)
            let session = Session(packetID: packetID, folder: folder, uploader: uploader)
            self.session = session
            // Status from an abandoned session's uploader never reaches the screen.
            let publish: @Sendable (CaptureUploadStatus) -> Void = { [weak self] status in
                Task { @MainActor in
                    guard let self, self.session === session else { return }
                    self.status = status
                }
            }
            Task {
                await uploader.observe(publish, log: { line in RuntimeLog.engine.info("\(line, privacy: .public)") })
                await uploader.kick()
            }
            RuntimeLog.engine.info("capture upload: new packet for this world")
        } catch {
            RuntimeLog.engine.error("capture upload not started: \(String(describing: error), privacy: .public)")
        }
    }

    private func endSession(_ reason: String) {
        guard let session else { return }
        self.session = nil
        status = nil
        let previous = session.chain
        Task {
            previous?.cancel()
            await session.uploader.abandon(reason)
        }
    }

    /// Seals one kept photo into this world's packet and hands its files to the uploader.
    private func kept(_ photo: StoredKeyframe, purpose: String?, jpeg: URL, storeDirectory: URL) {
        guard let session, !session.sealing, let recorder else { return }
        let previous = session.chain
        session.chain = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let producer = try session.producer ?? Self.makeProducer(session, first: photo, recorder: recorder)
                session.producer = producer
                let (data, depth) = try await Task.detached(priority: .utility) {
                    (try Data(contentsOf: jpeg), photo.depth.flatMap { KeyframeStore.loadDepth($0, in: storeDirectory) }.flatMap(Self.arkitDepth))
                }.value
                var files: [SealedFile] = []
                var keyframe = await producer.keyframeID(at: photo.t)
                if keyframe == nil {
                    files += try await producer.sealKeyframe(
                        jpeg: data, observation: Self.observation(photo), reason: purpose == nil ? "auto" : "still", purpose: purpose, depth: depth)
                    keyframe = await producer.keyframeID(at: photo.t)
                }
                if let purpose, Self.stillPurposes.contains(purpose), let keyframe {
                    files.append(try await producer.sealStill(purpose: purpose, keyframe: keyframe))
                }
                await session.uploader.add(files)
            } catch {
                RuntimeLog.engine.error("capture packet: photo \(photo.id, privacy: .public) not sealed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Building the packet

    private static func makeProducer(_ session: Session, first photo: StoredKeyframe, recorder: CaptureRecorder) throws -> Packet04Producer {
        // The packet starts at the world's first recorded frame; a photo can't be older.
        let start = recorder.sessionStart() ?? (photo.t, Date(timeIntervalSinceNow: photo.t - ProcessInfo.processInfo.systemUptime))
        let info = sessionInfo(packetID: session.packetID, video: photo.camera.imageSize)
        // The uploader reads each sealed file from the same folder.
        return try Packet04Producer(folder: session.folder, info: info, startedAtUptime: min(start.uptime, photo.t), startedAt: start.date)
    }

    /// "0.1.0 (1)": the short version and the build.
    private static var appVersion: String {
        let bundle = Bundle.main.infoDictionary ?? [:]
        let parts = [bundle["CFBundleShortVersionString"], bundle["CFBundleVersion"]].compactMap { $0 as? String }
        return parts.count == 2 ? "\(parts[0]) (\(parts[1]))" : parts.first ?? "unknown"
    }

    private static func sessionInfo(packetID: String, video: SIMD2<Float>) -> Packet04SessionInfo {
        // LiveCapture turns on scene depth exactly when the phone supports it.
        let depth = LiveCapture.supportsDepth
        return Packet04SessionInfo(
            packetID: packetID, sessionID: packetID, source: .device, appVersion: appVersion, deviceModel: ScanEngine.hardwareModel(),
            systemVersion: UIDevice.current.systemVersion, lidarAvailable: depth, sceneDepthEnabled: depth, meshReconstructionSupported: nil,
            sceneReconstruction: nil, planeDetection: ["horizontal", "vertical"], videoWidth: Int(video.x), videoHeight: Int(video.y),
            framesPerSecond: nil, timeZone: TimeZone.current.identifier)
    }

    /// The stored photo's own frame: raw ARKit camera-to-world, and intrinsics scaled to the JPEG
    /// that was written when it differs from the camera image.
    private nonisolated static func observation(_ photo: StoredKeyframe) -> Packet04Observation {
        let scale = SIMD2(Float(photo.width), Float(photo.height)) / photo.camera.imageSize
        let k = photo.camera.intrinsics
        return Packet04Observation(
            t: photo.t, cameraToWorld: photo.camera.cameraToWorld, intrinsics: SIMD4(k.x * scale.x, k.y * scale.y, k.z * scale.x, k.w * scale.y),
            width: photo.width, height: photo.height, tracking: TrackingCode(photo.tracking).packetTracking,
            exposure: photo.exposure.map { .init(duration: $0.durationS, offset: $0.offsetEV, iso: $0.iso, fNumber: $0.fNumber) })
    }

    /// Only ARKit's depth with its confidence goes in: the 0.4 keyframe depth is ARKit's.
    private nonisolated static func arkitDepth(_ depth: DepthPacket) -> Packet04Depth? {
        guard let confidence = depth.confidence, depth.source == .arkitSceneDepth || depth.source == .arkitSmoothedSceneDepth else { return nil }
        return Packet04Depth(meters: depth.meters, confidence: confidence, width: depth.width, height: depth.height)
    }

    struct StreamRows: Sendable {
        var poses: [Packet04Streams.PoseRow]
        var accelerometer: [Packet04Streams.MotionRow]
        var gyroscope: [Packet04Streams.MotionRow]
    }

    /// The recorder's raw rows for the two required streams. A pose row is kept only with the
    /// intrinsics row its frame wrote at the same time.
    nonisolated static func streamRows(_ recorder: CaptureRecorder) -> StreamRows {
        _ = recorder.flush()
        let poses = Packet04Streams.poseRows(trajectory: recorder.rows(.trajectory), intrinsics: recorder.rows(.intrinsics)) {
            TrackingCode(state: $0, reason: $1).packetTracking
        }
        return StreamRows(
            poses: poses, accelerometer: Packet04Streams.motionRows(recorder.rows(.accelerometer)),
            gyroscope: Packet04Streams.motionRows(recorder.rows(.gyroscope)))
    }

    // MARK: Relaunch

    /// Captures frozen before the app last quit finish uploading; ones still being captured can't
    /// be finished (their streams belonged to that process's world) and are left as they are.
    private func resumeSealedCaptures() {
        guard let endpoint, let folders = try? FileManager.default.contentsOfDirectory(at: Self.capturesFolder, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let saved = try? CaptureUploadState.load(from: CaptureUploader.stateURL(in: folder)), saved.end == nil, saved.packet != nil,
                  let uploader = try? CaptureUploader.resume(folder: folder, base: endpoint, http: http) else { continue }
            resumed.append(uploader)
            Task { await uploader.kick() }
        }
        if !resumed.isEmpty { RuntimeLog.engine.info("capture upload: resuming \(self.resumed.count) sealed captures") }
    }
}
