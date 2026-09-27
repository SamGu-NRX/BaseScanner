import Foundation
import HouseScanKit
import Observation
import OSLog
import simd
import UIKit

/// The integration build's capture upload, as the app wires it: the engine's events go to
/// `CaptureSessionCoordinator` (HouseScanKit), which seals each kept photo into a 0.4 packet on
/// the phone and sends it when that is allowed. This class only translates the app's types, keeps
/// the consent answer, and publishes the status line.
///
/// Only the integration build records a capture (`HouseScanIntegrationBuild`); a launch argument
/// can name another endpoint (`-captureAPIURL`) but can't turn a client build into one. Captures
/// are sent only when the build also allows device data at that endpoint
/// (`HouseScanCaptureSendDeviceData`) and the homeowner says yes before this scan starts, so its
/// photos go up during the walk. The yes covers this scan and this endpoint only; a new scan asks
/// again. The placement request (`ResultClient`, scene.json) and the client build's own sharing
/// flow are unchanged. Files live in Application Support/Captures/<packet id>, outside the scan
/// folders the store cleans up.
@MainActor
@Observable
final class CaptureIntegration {
    private(set) var status: CaptureUploadStatus?
    /// Bumped whenever the answer or the scan changes, so a view reading `needsConsent` updates.
    private(set) var revision = 0
    var needsConsent: Bool {
        _ = revision
        return coordinator?.needsConsent ?? false
    }

    /// The rules for each source, read at launch. Which one applies is decided by the source that
    /// actually starts (`begin` for the camera, `beginReplay` for a replay the engine is playing),
    /// never by the launch arguments alone.
    @ObservationIgnored private let environments: (device: CaptureSessionCoordinator.Environment?, replay: CaptureSessionCoordinator.Environment?)
    /// Made by the first source to start; one process runs one kind of source.
    @ObservationIgnored private var coordinator: CaptureSessionCoordinator?
    @ObservationIgnored private weak var store: KeyframeStore?
    @ObservationIgnored private var resumed: [CaptureUploader] = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments, bundle: Bundle = .main) {
        #if HOUSESCAN_INTEGRATION
        let argument = arguments.firstIndex(of: "-captureAPIURL").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        func mode(_ source: CaptureIntegrationMode.Source) -> CaptureIntegrationMode {
            CaptureIntegrationMode.resolve(
                integrationBuild: bundle.object(forInfoDictionaryKey: "HouseScanIntegrationBuild") as? String,
                endpoint: argument ?? bundle.object(forInfoDictionaryKey: "HouseScanCaptureAPIURL") as? String,
                sendDeviceData: bundle.object(forInfoDictionaryKey: "HouseScanCaptureSendDeviceData") as? String, source: source)
        }
        // A replay's pictures are a recording's: sent only to a receiver on this machine, and only
        // when the run asks (the UI tests).
        let modes = (device: mode(.device), replay: mode(.replay(sendToLocalReceiver: arguments.contains("-captureSendReplayToLocalReceiver"))))
        #else
        let off = CaptureIntegrationMode.off("not the integration build")
        let modes = (device: off, replay: off)
        #endif
        environments = (Self.environment(modes.device, source: .device), Self.environment(modes.replay, source: .replay))
        if let device = environments.device {
            resumed = CaptureSessionCoordinator(environment: device).resumeSealedCaptures()
            if !resumed.isEmpty { RuntimeLog.engine.info("capture upload: resuming \(self.resumed.count) sealed captures") }
        }
    }

    private static func environment(_ mode: CaptureIntegrationMode, source: Packet04.Source.Kind) -> CaptureSessionCoordinator.Environment? {
        let modeName = switch mode {
        case .off: "off"
        case .recordOnly: "record only"
        case .send: "send after consent"
        }
        RuntimeLog.engine.info("capture packet mode for \(source.rawValue, privacy: .public): \(modeName, privacy: .public)")
        guard let endpoint = mode.endpoint else { return nil }
        let depth = LiveCapture.supportsDepth
        let device = CaptureAPI.Device(model: ScanEngine.hardwareModel(), systemVersion: UIDevice.current.systemVersion, appVersion: Self.appVersion)
        let zone = TimeZone.current.identifier
        let sends = if case .send = mode { true } else { false }
        return .init(
            endpoint: endpoint, sends: sends, http: URLSessionCaptureHTTP.ephemeral(timeout: 60), capturesFolder: Self.capturesFolder,
            sessionInfo: { packetID, video in
                // LiveCapture turns on scene depth exactly when the phone supports it.
                Packet04SessionInfo(
                    packetID: packetID, sessionID: packetID, source: source, appVersion: device.appVersion, deviceModel: device.model,
                    systemVersion: device.systemVersion, lidarAvailable: depth, sceneDepthEnabled: depth, meshReconstructionSupported: nil,
                    sceneReconstruction: nil, planeDetection: ["horizontal", "vertical"], videoWidth: Int(video.x), videoHeight: Int(video.y),
                    framesPerSecond: nil, timeZone: zone)
            },
            device: device, tier: depth ? .arkitLidar : .arkit, log: { line in RuntimeLog.engine.info("\(line, privacy: .public)") })
    }

    /// The coordinator for the source that is starting; the first source to start decides it.
    private func coordinator(for environment: CaptureSessionCoordinator.Environment?) -> CaptureSessionCoordinator {
        if let coordinator { return coordinator }
        let made = CaptureSessionCoordinator(environment: environment)
        made.onStatus = { [weak self] in self?.publish($0) }
        coordinator = made
        return made
    }

    /// The answer for this scan. A yes is recorded with the capture it covers, for that capture's
    /// resume; nothing is remembered for the next scan.
    func answerConsent(_ yes: Bool) {
        RuntimeLog.engine.info("capture upload consent: \(yes ? "yes" : "no", privacy: .public)")
        coordinator?.answerConsent(yes)
        revision += 1
    }

    /// At most one status change a second reaches the screen; the last one always does.
    @ObservationIgnored private var lastPublished = Date.distantPast
    @ObservationIgnored private var pendingStatus: Task<Void, Never>?

    private func publish(_ next: CaptureUploadStatus?) {
        pendingStatus?.cancel()
        let wait = 1 - Date().timeIntervalSince(lastPublished)
        guard next != nil, wait > 0 else {
            status = next
            lastPublished = Date()
            return
        }
        pendingStatus = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.status = next
            self.lastPublished = Date()
        }
    }

    // MARK: Engine hooks

    /// The live camera started: photos kept in `store` from now on go into the packet, under the
    /// camera's rules (the device-data switch).
    func begin(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator(for: environments.device).begin(recording: Self.recording(recorder))
        revision += 1
    }

    /// The engine is playing a replay (`LaunchOptions.replayFolder`): the same, under the replay's
    /// rules and labelled as a replay.
    func beginReplay(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator(for: environments.replay).begin(recording: Self.recording(recorder))
        revision += 1
    }

    /// The ARKit world was thrown away: this packet can't be finished in it.
    func worldReset(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator?.newWorld("world reset", recording: Self.recording(recorder), newScan: false)
    }

    func startOver(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator?.newWorld("start over", recording: Self.recording(recorder), newScan: true)
        revision += 1
    }

    /// The homeowner marked the meter; `hit` is what the app's raycast found. The recorded frame
    /// can be a frame or two newer than the raycast's, so the tap is placed where the hit lands in
    /// that frame (`TapObservation.pointing(at:)`), keeping pixel, ray and hit in one frame.
    func meterTapped(_ observed: TapObservation?, hit: VerticalPlaneHit) {
        guard let tap = observed?.pointing(at: hit.position) else {
            RuntimeLog.engine.info("capture packet: no frame shows the meter tap's hit; no tap recorded")
            return
        }
        let camera = SIMD3(tap.cameraToWorld.columns.3.x, tap.cameraToWorld.columns.3.y, tap.cameraToWorld.columns.3.z)
        coordinator?.meterTapped(tap, hit: Packet04.TapHit(
            position: [hit.position.x, hit.position.y, hit.position.z].map(Double.init),
            target: hit.source == .detectedPlane ? "existingPlaneGeometry" : "estimatedPlane", alignment: "vertical",
            distance: Double(simd_distance(hit.position, camera))))
    }

    /// The scan was sent for placement: the packet is frozen. `acceptedCloseUpAt` is the frame time
    /// of the close-up the scan accepted, nil after a skip. Later sends change nothing.
    func captureEnded(acceptedCloseUpAt: Double?) {
        coordinator?.captureEnded(acceptedCloseUpAt: acceptedCloseUpAt)
    }

    // MARK: Translation

    static var capturesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Captures", directoryHint: .isDirectory)
    }

    private func attach(_ store: KeyframeStore) {
        if let old = self.store, old !== store { old.onKept = nil }
        self.store = store
        store.onKept = { [weak self, weak store] photo, purpose, jpeg in
            guard let self, let store, store === self.store else { return }
            self.coordinator?.kept(Self.kept(photo, purpose: purpose, jpeg: jpeg, storeDirectory: store.directory))
        }
    }

    private static func kept(_ photo: StoredKeyframe, purpose: String?, jpeg: URL, storeDirectory: URL) -> KeptPhoto {
        let stored = photo.depth
        return KeptPhoto(
            // The pose exactly as ARKit reported it; anchor corrections apply only to scene.json and the 1.1 packet.
            t: photo.t, cameraToWorld: photo.rawPose, cameraIntrinsics: photo.camera.intrinsics, cameraImageSize: photo.camera.imageSize,
            width: photo.width, height: photo.height, tracking: TrackingCode(photo.tracking).packetTracking,
            exposure: photo.exposure.map { .init(duration: $0.durationS, offset: $0.offsetEV, iso: $0.iso, fNumber: $0.fNumber) },
            jpeg: jpeg, purpose: purpose,
            depth: {
                // Only ARKit's depth with its confidence goes in: the 0.4 keyframe depth is ARKit's.
                guard let depth = stored.flatMap({ KeyframeStore.loadDepth($0, in: storeDirectory) }), let confidence = depth.confidence,
                      depth.source == .arkitSceneDepth || depth.source == .arkitSmoothedSceneDepth else { return nil }
                return Packet04Depth(meters: depth.meters, confidence: confidence, width: depth.width, height: depth.height)
            })
    }

    private static func recording(_ recorder: CaptureRecorder) -> RecordingSource {
        RecordingSource(start: { recorder.sessionStart() }, rows: {
            _ = recorder.flush()
            return RecorderRows(
                trajectory: recorder.rows(.trajectory), intrinsics: recorder.rows(.intrinsics),
                accelerometer: recorder.rows(.accelerometer), gyroscope: recorder.rows(.gyroscope))
        })
    }

    /// "0.1.0 (1)": the short version and the build.
    private static var appVersion: String {
        let bundle = Bundle.main.infoDictionary ?? [:]
        let parts = [bundle["CFBundleShortVersionString"], bundle["CFBundleVersion"]].compactMap { $0 as? String }
        return parts.count == 2 ? "\(parts[0]) (\(parts[1]))" : parts.first ?? "unknown"
    }
}
