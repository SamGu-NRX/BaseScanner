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
/// (`HouseScanCaptureSendDeviceData`) and the homeowner says yes on the screen after the result.
/// A yes is remembered for that endpoint, so later scans send while scanning. The placement
/// request (`ResultClient`, scene.json) is unchanged and never waits for this. Files live in
/// Application Support/Captures/<packet id>, outside the scan folders the store cleans up.
@MainActor
@Observable
final class CaptureIntegration {
    /// The endpoint the homeowner said yes to, as a string; a yes counts only for that endpoint.
    static let consentKey = "captureUploadConsentEndpoint.v2"

    private(set) var status: CaptureUploadStatus?
    /// Bumped on each answer, so a view reading `needsConsent` updates.
    private(set) var answers = 0
    var needsConsent: Bool {
        _ = answers
        return coordinator.needsConsent
    }

    @ObservationIgnored private let coordinator: CaptureSessionCoordinator
    @ObservationIgnored private weak var store: KeyframeStore?
    @ObservationIgnored private var resumed: [CaptureUploader] = []

    init(arguments: [String] = ProcessInfo.processInfo.arguments, bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let argument = arguments.firstIndex(of: "-captureAPIURL").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let mode = CaptureIntegrationMode.resolve(
            integrationBuild: bundle.object(forInfoDictionaryKey: "HouseScanIntegrationBuild") as? String,
            endpoint: argument ?? bundle.object(forInfoDictionaryKey: "HouseScanCaptureAPIURL") as? String,
            sendDeviceData: bundle.object(forInfoDictionaryKey: "HouseScanCaptureSendDeviceData") as? String)
        let modeName = switch mode {
        case .off: "off"
        case .recordOnly: "record only"
        case .send: "send after consent"
        }
        RuntimeLog.engine.info("capture packet mode: \(modeName, privacy: .public)")
        var environment: CaptureSessionCoordinator.Environment?
        if let endpoint = mode.endpoint {
            let depth = LiveCapture.supportsDepth
            let device = CaptureAPI.Device(model: ScanEngine.hardwareModel(), systemVersion: UIDevice.current.systemVersion, appVersion: Self.appVersion)
            let zone = TimeZone.current.identifier
            let sends = if case .send = mode { true } else { false }
            environment = .init(
                endpoint: endpoint, sends: sends, http: URLSessionCaptureHTTP.ephemeral(timeout: 60), capturesFolder: Self.capturesFolder,
                sessionInfo: { packetID, video in
                    // LiveCapture turns on scene depth exactly when the phone supports it.
                    Packet04SessionInfo(
                        packetID: packetID, sessionID: packetID, source: .device, appVersion: device.appVersion, deviceModel: device.model,
                        systemVersion: device.systemVersion, lidarAvailable: depth, sceneDepthEnabled: depth, meshReconstructionSupported: nil,
                        sceneReconstruction: nil, planeDetection: ["horizontal", "vertical"], videoWidth: Int(video.x), videoHeight: Int(video.y),
                        framesPerSecond: nil, timeZone: zone)
                },
                device: device, tier: depth ? .arkitLidar : .arkit, log: { line in RuntimeLog.engine.info("\(line, privacy: .public)") })
        }
        let remembered = environment.map { defaults.string(forKey: Self.consentKey) == $0.endpoint.absoluteString } ?? false
        coordinator = CaptureSessionCoordinator(environment: environment, rememberedYes: remembered)
        coordinator.onStatus = { [weak self] in self?.status = $0 }
        resumed = coordinator.resumeSealedCaptures()
        if !resumed.isEmpty { RuntimeLog.engine.info("capture upload: resuming \(self.resumed.count) sealed captures") }
    }

    /// A yes is remembered for this endpoint; a no holds for this scan only.
    func answerConsent(_ yes: Bool) {
        if yes, let endpoint = coordinator.environment?.endpoint {
            UserDefaults.standard.set(endpoint.absoluteString, forKey: Self.consentKey)
        }
        RuntimeLog.engine.info("capture upload consent: \(yes ? "yes" : "no", privacy: .public)")
        coordinator.answerConsent(yes)
        answers += 1
    }

    // MARK: Engine hooks

    /// The live source started: photos kept in `store` from now on go into the packet.
    func begin(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator.begin(recording: Self.recording(recorder))
    }

    /// The ARKit world was thrown away: this packet can't be finished in it.
    func worldReset(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator.newWorld("world reset", recording: Self.recording(recorder), newScan: false)
    }

    func startOver(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator.newWorld("start over", recording: Self.recording(recorder), newScan: true)
        answers += 1
    }

    /// The homeowner marked the meter on `tap`'s frame; `hit` is what the app's raycast found.
    func meterTapped(_ tap: TapObservation?, hit: VerticalPlaneHit) {
        guard let tap else {
            RuntimeLog.engine.info("capture packet: no frame for the meter tap; no tap recorded")
            return
        }
        let camera = SIMD3(tap.cameraToWorld.columns.3.x, tap.cameraToWorld.columns.3.y, tap.cameraToWorld.columns.3.z)
        coordinator.meterTapped(tap, hit: Packet04.TapHit(
            position: [hit.position.x, hit.position.y, hit.position.z].map(Double.init),
            target: hit.source == .detectedPlane ? "existingPlaneGeometry" : "estimatedPlane", alignment: "vertical",
            distance: Double(simd_distance(hit.position, camera))))
    }

    /// The scan was sent for placement: the packet is frozen. Later sends change nothing.
    func captureEnded() {
        coordinator.captureEnded()
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
            self.coordinator.kept(Self.kept(photo, purpose: purpose, jpeg: jpeg, storeDirectory: store.directory))
        }
    }

    private static func kept(_ photo: StoredKeyframe, purpose: String?, jpeg: URL, storeDirectory: URL) -> KeptPhoto {
        let stored = photo.depth
        return KeptPhoto(
            t: photo.t, cameraToWorld: photo.camera.cameraToWorld, cameraIntrinsics: photo.camera.intrinsics, cameraImageSize: photo.camera.imageSize,
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
