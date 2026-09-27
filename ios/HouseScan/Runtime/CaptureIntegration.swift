import Foundation
import HouseScanKit
import Observation
import OSLog
import simd
import UIKit

/// The integration build's capture upload, as the app wires it: the engine's events go to
/// `CaptureSessionCoordinator` (HouseScanKit), which seals each kept photo into a 0.4 packet and
/// uploads it while the homeowner scans. This class only translates the app's types, keeps the
/// consent answer, and publishes the status line.
///
/// It runs only when the build names a capture API (`HouseScanCaptureAPIURL`, or the
/// `-captureAPIURL` launch argument) and the homeowner said yes. The placement request
/// (`ResultClient`, scene.json) is unchanged and never waits for it. Files live in Application
/// Support/Captures/<packet id>, outside the scan folders the store cleans up.
@MainActor
@Observable
final class CaptureIntegration {
    static let consentKey = "captureUploadConsent.v1"
    static let infoKey = "HouseScanCaptureAPIURL"

    private(set) var status: CaptureUploadStatus?
    private(set) var needsConsent: Bool

    @ObservationIgnored private let coordinator: CaptureSessionCoordinator
    @ObservationIgnored private weak var store: KeyframeStore?
    @ObservationIgnored private var resumed: [CaptureUploader] = []

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        infoValue: String? = Bundle.main.object(forInfoDictionaryKey: CaptureIntegration.infoKey) as? String,
        defaults: UserDefaults = .standard
    ) {
        let argument = arguments.firstIndex(of: "-captureAPIURL").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        var environment: CaptureSessionCoordinator.Environment?
        if case .on(let endpoint) = CaptureUploadGate.decide(endpoint: argument ?? infoValue, consented: true) {
            let depth = LiveCapture.supportsDepth
            let device = CaptureAPI.Device(model: ScanEngine.hardwareModel(), systemVersion: UIDevice.current.systemVersion, appVersion: Self.appVersion)
            let zone = TimeZone.current.identifier
            environment = .init(
                endpoint: endpoint, http: URLSessionCaptureHTTP.ephemeral(timeout: 60), capturesFolder: Self.capturesFolder,
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
        coordinator = CaptureSessionCoordinator(environment: environment, consent: defaults.object(forKey: Self.consentKey) as? Bool)
        needsConsent = coordinator.needsConsent
        coordinator.onStatus = { [weak self] in self?.status = $0 }
        if let environment { resumeSealedCaptures(environment) }
    }

    func answerConsent(_ yes: Bool) {
        UserDefaults.standard.set(yes, forKey: Self.consentKey)
        RuntimeLog.engine.info("capture upload consent: \(yes ? "yes" : "no", privacy: .public)")
        coordinator.answerConsent(yes)
        needsConsent = coordinator.needsConsent
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
        coordinator.newWorld("world reset", recording: Self.recording(recorder))
    }

    func startOver(store: KeyframeStore, recorder: CaptureRecorder) {
        attach(store)
        coordinator.newWorld("start over", recording: Self.recording(recorder))
    }

    /// The homeowner marked the meter on `tap`'s frame; `hit` is what the app's raycast found.
    func meterTapped(_ tap: TapObservation?, hit: VerticalPlaneHit) {
        guard coordinator.isEnabled else { return }
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

    // MARK: Relaunch

    /// Captures frozen before the app last quit finish uploading; ones still being captured can't
    /// be finished (their streams belonged to that process's world) and are left as they are.
    private func resumeSealedCaptures(_ environment: CaptureSessionCoordinator.Environment) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: Self.capturesFolder, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let saved = try? CaptureUploadState.load(from: CaptureUploader.stateURL(in: folder)), saved.end == nil, saved.packet != nil,
                  let uploader = try? CaptureUploader.resume(folder: folder, base: environment.endpoint, http: environment.http) else { continue }
            resumed.append(uploader)
            Task { await uploader.kick() }
        }
        if !resumed.isEmpty { RuntimeLog.engine.info("capture upload: resuming \(self.resumed.count) sealed captures") }
    }
}
