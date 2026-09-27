import Foundation
import simd

/// A photo the scan kept, as the app stores it: the JPEG on disk and the facts of the ARFrame
/// whose pixels it holds, in that frame's own terms (raw world pose, the camera image's
/// intrinsics and size).
public struct KeptPhoto: Sendable {
    public var t: Double
    public var cameraToWorld: simd_float4x4
    /// [fx, fy, cx, cy] in pixels of the camera image (`cameraImageSize`).
    public var cameraIntrinsics: SIMD4<Float>
    public var cameraImageSize: SIMD2<Float>
    /// Pixels of the stored JPEG.
    public var width: Int
    public var height: Int
    public var tracking: PacketTracking
    public var exposure: Packet04.Exposure?
    public var jpeg: URL
    /// The still's purpose ("meter_close"); nil for a keyframe.
    public var purpose: String?
    /// Reads the photo's ARKit depth; called off the main actor.
    public var depth: @Sendable () -> Packet04Depth?

    public init(
        t: Double, cameraToWorld: simd_float4x4, cameraIntrinsics: SIMD4<Float>, cameraImageSize: SIMD2<Float>, width: Int, height: Int,
        tracking: PacketTracking, exposure: Packet04.Exposure?, jpeg: URL, purpose: String?, depth: @escaping @Sendable () -> Packet04Depth? = { nil }
    ) {
        self.t = t
        self.cameraToWorld = cameraToWorld
        self.cameraIntrinsics = cameraIntrinsics
        self.cameraImageSize = cameraImageSize
        self.width = width
        self.height = height
        self.tracking = tracking
        self.exposure = exposure
        self.jpeg = jpeg
        self.purpose = purpose
        self.depth = depth
    }

    /// The observation in the stored JPEG's pixels: intrinsics scaled when the JPEG is not the
    /// camera image's size.
    public var observation: Packet04Observation {
        let scale = SIMD2(Float(width), Float(height)) / cameraImageSize
        let k = cameraIntrinsics
        return Packet04Observation(
            t: t, cameraToWorld: cameraToWorld, intrinsics: SIMD4(k.x * scale.x, k.y * scale.y, k.z * scale.x, k.w * scale.y),
            width: width, height: height, tracking: tracking, exposure: exposure)
    }
}

/// The frame under the homeowner's tap, read when the tap happened.
public struct TapObservation: Sendable {
    public var t: Double
    public var cameraToWorld: simd_float4x4
    /// [fx, fy, cx, cy] in pixels of the camera image, which the JPEG stores unscaled.
    public var intrinsics: SIMD4<Float>
    public var width: Int
    public var height: Int
    public var tracking: PacketTracking
    /// The tap in the sensor image's pixels, (0, 0) its top-left corner.
    public var pixel: SIMD2<Double>
    /// Encodes the frame's image; called off the main actor.
    public var jpeg: @Sendable () -> Data?

    public init(
        t: Double, cameraToWorld: simd_float4x4, intrinsics: SIMD4<Float>, width: Int, height: Int, tracking: PacketTracking,
        pixel: SIMD2<Double>, jpeg: @escaping @Sendable () -> Data?
    ) {
        self.t = t
        self.cameraToWorld = cameraToWorld
        self.intrinsics = intrinsics
        self.width = width
        self.height = height
        self.tracking = tracking
        self.pixel = pixel
        self.jpeg = jpeg
    }
}

/// Where the coordinator reads the world's recorded streams: `CaptureRecorder` in the app.
public struct RecordingSource: Sendable {
    /// Uptime and wall clock of the world's first recorded frame.
    public var start: @Sendable () -> (uptime: Double, date: Date)?
    /// Every row so far; called off the main actor.
    public var rows: @Sendable () -> RecorderRows

    public init(start: @escaping @Sendable () -> (uptime: Double, date: Date)?, rows: @escaping @Sendable () -> RecorderRows) {
        self.start = start
        self.rows = rows
    }
}

/// The recorder's raw rows: trajectory `[t, state, reason, 16 pose values]`, intrinsics
/// `[t, fx, fy, cx, cy, w, h]`, and Core Motion's `[t, x, y, z]`, each sensor at its own times.
public struct RecorderRows: Sendable {
    public var trajectory: [[Double]]
    public var intrinsics: [[Double]]
    public var accelerometer: [[Double]]
    public var gyroscope: [[Double]]

    public init(trajectory: [[Double]], intrinsics: [[Double]], accelerometer: [[Double]], gyroscope: [[Double]]) {
        self.trajectory = trajectory
        self.intrinsics = intrinsics
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
    }
}

/// What the integration build does with a scan: one 0.4 packet per ARKit world, each kept photo
/// sealed into it on the phone as it is kept, the packet frozen when the scan is sent for
/// placement. Sending is separate: only a build allowed to send device data (`sends`) sends, and
/// only after the homeowner's yes. From the yes on, every sealed file goes up, and later photos go
/// up as they are kept.
///
/// Work for one world runs in order on that world's chain; a world reset or start over ends the
/// session, and nothing queued for it reaches the next one.
@MainActor
public final class CaptureSessionCoordinator {
    public struct Environment: Sendable {
        public var endpoint: URL
        /// Whether device captures may go to `endpoint` at all (`CaptureIntegrationMode.send`).
        public var sends: Bool
        public var http: any CaptureHTTP
        /// Each session writes to `<folder>/<packet id>`.
        public var capturesFolder: URL
        public var sessionInfo: @Sendable (_ packetID: String, _ video: SIMD2<Float>) -> Packet04SessionInfo
        public var device: CaptureAPI.Device
        public var tier: Packet04.Tier
        public var policy: CaptureUploader.Policy
        public var log: @Sendable (String) -> Void

        public init(
            endpoint: URL, sends: Bool, http: any CaptureHTTP, capturesFolder: URL,
            sessionInfo: @escaping @Sendable (_ packetID: String, _ video: SIMD2<Float>) -> Packet04SessionInfo,
            device: CaptureAPI.Device, tier: Packet04.Tier, policy: CaptureUploader.Policy = .init(), log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.endpoint = endpoint
            self.sends = sends
            self.http = http
            self.capturesFolder = capturesFolder
            self.sessionInfo = sessionInfo
            self.device = device
            self.tier = tier
            self.policy = policy
            self.log = log
        }
    }

    /// Checklist purposes the packet's `stills` take; any other still stays a keyframe only.
    public static let stillPurposes: Set<String> = ["meter_close", "meter_oblique"]

    @MainActor
    public final class Session {
        public let packetID: String
        public let folder: URL
        /// Nil until the homeowner says yes on a build that sends.
        public fileprivate(set) var uploader: CaptureUploader?
        public private(set) var producer: Packet04Producer?
        let recording: RecordingSource
        var chain: Task<Void, Never>?
        var sealing = false
        var ended = false
        /// packet.json as frozen, once the scan was sent for placement.
        var frozen: Data?

        init(packetID: String, folder: URL, recording: RecordingSource) {
            self.packetID = packetID
            self.folder = folder
            self.recording = recording
        }

        /// Runs `work` after everything queued before it, unless the session has ended by then.
        func enqueue(_ work: @escaping @MainActor (Session) async -> Void) {
            let previous = chain
            chain = Task {
                await previous?.value
                guard !self.ended else { return }
                await work(self)
            }
        }

        func producer(first photo: (t: Double, video: SIMD2<Float>), info: (String, SIMD2<Float>) -> Packet04SessionInfo) throws -> Packet04Producer {
            if let producer { return producer }
            // The packet starts at the world's first recorded frame; a photo can't be older.
            let start = recording.start() ?? (photo.t, Date(timeIntervalSinceNow: photo.t - ProcessInfo.processInfo.systemUptime))
            let made = try Packet04Producer(folder: folder, info: info(packetID, photo.video), startedAtUptime: min(start.uptime, photo.t), startedAt: start.date)
            producer = made
            return made
        }
    }

    public let environment: Environment?
    /// The homeowner's answer: true once they said yes (for this device and endpoint), false for
    /// a no on this scan, nil before they were asked.
    public private(set) var consent: Bool?
    public private(set) var session: Session?
    private var recording: RecordingSource?
    /// The current session's status; nil when there is none or nothing is being sent.
    public var onStatus: (@MainActor (CaptureUploadStatus?) -> Void)?

    /// `rememberedYes`: the homeowner already agreed to send to this environment's endpoint.
    public init(environment: Environment?, rememberedYes: Bool) {
        self.environment = environment
        consent = rememberedYes ? true : nil
    }

    /// Whether the homeowner should be asked now: a build that sends, no answer on this scan, and
    /// a capture with photos to send.
    public var needsConsent: Bool {
        environment?.sends == true && consent == nil && session?.producer != nil
    }

    public func answerConsent(_ yes: Bool) {
        consent = yes
        if yes, let session { startUploading(session) }
    }

    // MARK: Scan events

    /// The live source started recording a world.
    public func begin(recording: RecordingSource) {
        self.recording = recording
        if environment != nil, session == nil { startSession() }
    }

    /// The ARKit world was thrown away, or (`newScan`) the scan started over: this packet can't
    /// be finished, and the next one belongs to `recording`'s new world. A new scan asks again
    /// after a no; a yes stands.
    public func newWorld(_ reason: String, recording: RecordingSource, newScan: Bool) {
        endSession(reason)
        if newScan, consent == false { consent = nil }
        self.recording = recording
        if environment != nil { startSession() }
    }

    public func kept(_ photo: KeptPhoto) {
        guard let session, !session.sealing, let environment else { return }
        session.enqueue { session in
            do {
                let producer = try session.producer(first: (photo.t, photo.cameraImageSize), info: environment.sessionInfo)
                let (data, depth) = try await Task.detached(priority: .utility) { (try Data(contentsOf: photo.jpeg), photo.depth()) }.value
                var files: [SealedFile] = []
                if await producer.keyframeID(at: photo.t) == nil {
                    files += try await producer.sealKeyframe(
                        jpeg: data, observation: photo.observation, reason: photo.purpose == nil ? "auto" : "still", purpose: photo.purpose, depth: depth)
                }
                if let purpose = photo.purpose, Self.stillPurposes.contains(purpose), let keyframe = await producer.keyframeID(at: photo.t) {
                    files.append(try await producer.sealStill(purpose: purpose, keyframe: keyframe))
                }
                await session.uploader?.add(files)
            } catch {
                environment.log("capture packet: a kept photo was not sealed: \(error)")
            }
        }
    }

    /// The homeowner marked the meter: its frame becomes a keyframe and the tap goes on it.
    public func meterTapped(_ tap: TapObservation, hit: Packet04.TapHit?) {
        guard let session, !session.sealing, let environment else { return }
        session.enqueue { session in
            do {
                let producer = try session.producer(first: (tap.t, SIMD2(Float(tap.width), Float(tap.height))), info: environment.sessionInfo)
                guard let jpeg = await Task.detached(priority: .userInitiated, operation: { tap.jpeg() }).value else {
                    environment.log("capture packet: the meter tap's frame could not be encoded; no tap")
                    return
                }
                let observation = Packet04Observation(
                    t: tap.t, cameraToWorld: tap.cameraToWorld, intrinsics: tap.intrinsics, width: tap.width, height: tap.height, tracking: tap.tracking)
                let files = try await producer.sealTap(id: "meter", label: "meter", jpeg: jpeg, observation: observation, pixel: tap.pixel, hit: hit)
                await session.uploader?.add(files)
            } catch {
                environment.log("capture packet: the meter tap was not recorded: \(error)")
            }
        }
    }

    /// The scan was sent for placement: freeze the packet with the streams recorded so far. Later
    /// sends of the same scan (a retry, one more view) change nothing.
    public func captureEnded() {
        guard let session, !session.sealing, let environment else { return }
        session.sealing = true
        session.enqueue { session in
            guard let producer = session.producer else {
                await session.uploader?.abandon("no photos were kept")
                return
            }
            let recording = session.recording
            let rows = await Task.detached(priority: .utility) { recording.rows() }.value
            let poses = Packet04Streams.poseRows(trajectory: rows.trajectory, intrinsics: rows.intrinsics, tracking: PacketTracking.init(recorderState:reason:))
            do {
                let finished = try await producer.finish(
                    poses: poses, accelerometer: Packet04Streams.motionRows(rows.accelerometer),
                    gyroscope: Packet04Streams.motionRows(rows.gyroscope), endedAtUptime: poses.last?.t ?? 0)
                session.frozen = finished.packet
                await session.uploader?.seal(packet: finished.packet, files: await producer.sealedFiles)
            } catch {
                environment.log("capture packet not finished: \(error)")
                await session.uploader?.abandon("packet refused on the phone")
            }
        }
    }

    /// Waits until the current session's queued work and uploads are idle. For tests and the
    /// evidence run.
    public func settle() async {
        guard let session else { return }
        while let chain = session.chain {
            await chain.value
            if session.chain == chain { break }
        }
        await session.uploader?.settled()
    }

    /// After a relaunch: captures frozen before the app quit, created on this endpoint, finish
    /// uploading, but only with the homeowner's standing yes for this endpoint. Returns them.
    public func resumeSealedCaptures() -> [CaptureUploader] {
        guard let environment, environment.sends, consent == true,
              let folders = try? FileManager.default.contentsOfDirectory(at: environment.capturesFolder, includingPropertiesForKeys: nil)
        else { return [] }
        var resumed: [CaptureUploader] = []
        for folder in folders {
            guard let saved = try? CaptureUploadState.load(from: CaptureUploader.stateURL(in: folder)), saved.end == nil, saved.packet != nil,
                  let uploader = try? CaptureUploader.resume(folder: folder, base: environment.endpoint, http: environment.http, policy: environment.policy)
            else { continue }
            resumed.append(uploader)
            Task { await uploader.kick() }
        }
        return resumed
    }

    // MARK: Sessions

    private func startSession() {
        guard let environment, let recording else { return }
        let packetID = UUID().uuidString
        let session = Session(packetID: packetID, folder: environment.capturesFolder.appending(path: packetID, directoryHint: .isDirectory), recording: recording)
        self.session = session
        environment.log("capture packet: new packet for this world")
        if consent == true { startUploading(session) }
    }

    /// Opens the capture on the server and queues everything sealed so far, then the frozen
    /// packet if the scan was already sent. Photos kept later go up as they are sealed.
    private func startUploading(_ session: Session) {
        guard let environment, environment.sends, consent == true, session.uploader == nil, !session.ended else { return }
        do {
            let uploader = try CaptureUploader.start(
                folder: session.folder, base: environment.endpoint, http: environment.http,
                create: .init(packetId: session.packetID, tier: environment.tier, device: environment.device), policy: environment.policy)
            session.uploader = uploader
            // Status from an ended session's uploader never reaches the screen.
            let publish: @Sendable (CaptureUploadStatus) -> Void = { [weak self] status in
                Task { @MainActor in
                    guard let self, self.session === session else { return }
                    self.onStatus?(status)
                }
            }
            let log = environment.log
            Task {
                await uploader.observe(publish, log: log)
                await uploader.kick()
            }
            session.enqueue { session in
                guard let producer = session.producer else { return }
                let files = await producer.sealedFiles
                if let frozen = session.frozen {
                    await uploader.seal(packet: frozen, files: files)
                } else {
                    await uploader.add(files)
                }
            }
            environment.log("capture upload: sending this world's packet")
        } catch {
            environment.log("capture upload not started: \(error)")
        }
    }

    private func endSession(_ reason: String) {
        guard let session else { return }
        self.session = nil
        session.ended = true
        onStatus?(nil)
        if let uploader = session.uploader { Task { await uploader.abandon(reason) } }
    }
}

extension PacketTracking {
    /// The recorder's codes: state 0 normal, 1 limited, 2 not available; reason 0 none or
    /// unknown, 1 initializing, 2 relocalizing, 3 excessive motion, 4 insufficient features.
    public init(recorderState state: Int, reason: Int) {
        let why: Reason? = switch reason {
        case 1: .initializing
        case 2: .relocalizing
        case 3: .excessiveMotion
        case 4: .insufficientFeatures
        default: nil
        }
        self = switch state {
        case 0: .normal
        case 1: .limited(why)
        default: .notAvailable
        }
    }
}
