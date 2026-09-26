import ARKit
import CoreImage
import Foundation
import HouseScanKit
import RealityKit
import Synchronization
import SwiftUI

/// What the AR delegate should prepare with each sampled frame.
enum LiveMode: Sendable {
    /// Pose and quality only.
    case idle
    /// Encode a JPEG about three times a second while the phone is held on the meter.
    case closeUp
    /// Encode a JPEG when the phone has moved or turned enough that the frame could be kept.
    case walk
}

enum LiveEvent: Sendable {
    case interrupted
    case interruptionEnded
    case cameraDenied
    case failed(String)
}

struct VerticalPlaneHit {
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    let transform: simd_float4x4
    /// Which kind of plane the ray hit; the export widens the meter's error for an estimated one.
    let source: MeterPlaneSource
}

/// The live ARKit source: RealityKit's ARView running world tracking with `.gravity` alignment and
/// horizontal and vertical plane detection, without scene reconstruction or depth, so it runs on
/// iPhones without LiDAR.
@MainActor
final class LiveCapture {
    let arView: ARView
    private let delegate: LiveSessionDelegate

    init(onFrame: @escaping @MainActor @Sendable (SourceFrame) -> Void, onEvent: @escaping @MainActor @Sendable (LiveEvent) -> Void) {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        delegate = LiveSessionDelegate(onFrame: onFrame, onEvent: onEvent)
        arView.session.delegateQueue = DispatchQueue(label: "dev.housescanning.housescan.ar-delegate", qos: .userInitiated)
        arView.session.delegate = delegate
        arView.renderOptions.insert(.disableMotionBlur)
    }

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        // .gravity, not .gravityAndHeading: compass heading drifts near a house's metal and wiring.
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        arView.session.run(configuration)
    }

    func pause() {
        arView.session.pause()
    }

    /// Starts world tracking over with a fresh map, after relocalization failed.
    func restart() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        delegate.shared.withLock { $0.meterAnchorID = nil }
    }

    func setMode(_ mode: LiveMode) {
        delegate.shared.withLock { $0.mode = mode }
    }

    /// Raycast from a view point to a vertical surface: a detected plane's extent first, then a
    /// vertical plane ARKit estimates from feature points at the tap. Never `.existingPlaneInfinite`,
    /// which extends a fence's or another wall's plane past its edges, so a tap beside it lands on
    /// a surface that isn't there. The hit says which kind it was.
    func raycastExistingVerticalPlane(from point: CGPoint) -> VerticalPlaneHit? {
        let targets: [(ARRaycastQuery.Target, MeterPlaneSource)] = [(.existingPlaneGeometry, .detectedPlane), (.estimatedPlane, .estimatedPlane)]
        for (target, source) in targets {
            guard let result = arView.raycast(from: point, allowing: target, alignment: .vertical).first else { continue }
            // An estimated plane has no anchor; the result's own y axis is the surface normal.
            let transform = result.worldTransform
            let planeTransform = result.anchor?.transform ?? transform
            let normal = simd_normalize(SIMD3(planeTransform.columns.1.x, planeTransform.columns.1.y, planeTransform.columns.1.z))
            return VerticalPlaneHit(
                position: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
                normal: normal, transform: transform, source: source
            )
        }
        return nil
    }

    /// Anchors the meter so ARKit keeps refining its position; returns the anchor's id.
    func addMeterAnchor(at transform: simd_float4x4) -> UUID {
        let anchor = ARAnchor(name: "meter", transform: transform)
        arView.session.add(anchor: anchor)
        delegate.shared.withLock { $0.meterAnchorID = anchor.identifier }
        return anchor.identifier
    }

    func removeAnchor(_ id: UUID) {
        if let anchor = arView.session.currentFrame?.anchors.first(where: { $0.identifier == id }) {
            arView.session.remove(anchor: anchor)
        }
        delegate.shared.withLock { $0.meterAnchorID = nil }
    }
}

/// Shared between the main actor and the AR delegate queue.
struct LiveShared: Sendable {
    var mode: LiveMode = .idle
    var meterAnchorID: UUID?
}

/// Receives ARSession callbacks on a private serial queue. Each sampled frame is reduced to a
/// Sendable `SourceFrame` there (pose, intrinsics, a luma quality measure and, when it could be
/// kept, a JPEG of the unrotated sensor image) and then sent to the main actor. ARKit objects
/// never leave the delegate queue, except the camera image of the one frame being encoded.
///
/// JPEG encoding runs on its own queue, one frame at a time. Encoding on the delegate queue held
/// it for the length of an encode, so ARKit's next frames queued up, each holding a camera buffer
/// from ARKit's small pool. A keyframe candidate that arrives while an encode is running is sent
/// without a photo instead of waiting: it can't be kept, and the next sampled frame can be.
final class LiveSessionDelegate: NSObject, ARSessionDelegate, Sendable {
    let shared = Mutex(LiveShared())
    private let onFrame: @MainActor @Sendable (SourceFrame) -> Void
    private let onEvent: @MainActor @Sendable (LiveEvent) -> Void
    private let queueState = Mutex(QueueState())
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// Serial. Every sampled frame is delivered through it, so frames reach the main actor in order
    /// even when the one before was waiting on its JPEG.
    private let encodeQueue = DispatchQueue(label: "dev.housescanning.housescan.jpeg", qos: .userInitiated)

    private struct QueueState {
        var frameCount = 0
        var lastEncode: (time: Double, camera: CameraFrame)?
        var encoding = false
    }

    /// The camera image handed to the encode queue. CVPixelBuffer is not Sendable; ARKit doesn't
    /// write to a delivered frame's image, and only the encode queue reads it.
    private struct PixelBufferBox: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// Every sixth frame (about 10 per second at 60 fps) is sampled for capture; more adds cost,
    /// not coverage. Every second frame carries the pose, so overlays drawn over the 60 fps camera
    /// view move at 30 fps instead of 10.
    private static let sampleEvery = 6
    private static let poseEvery = 2
    /// A walk JPEG is encoded once the phone moved 0.15 m or turned 5° since the last one: well
    /// under auto-capture's 0.5 m / 15° spacing, so no keepable frame lacks an image.
    private static let encodeMove: Float = 0.15
    private static let encodeTurn: Float = 5 * .pi / 180
    private static let encodeInterval = 0.3

    init(onFrame: @escaping @MainActor @Sendable (SourceFrame) -> Void, onEvent: @escaping @MainActor @Sendable (LiveEvent) -> Void) {
        self.onFrame = onFrame
        self.onEvent = onEvent
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let count = queueState.withLock { state -> Int in
            state.frameCount += 1
            return state.frameCount
        }
        guard count % Self.poseEvery == 0 else { return }
        let shared = shared.withLock { $0 }
        let intrinsics = frame.camera.intrinsics
        let resolution = frame.camera.imageResolution
        let camera = CameraFrame(
            cameraToWorld: frame.camera.transform,
            intrinsics: SIMD4(intrinsics.columns.0.x, intrinsics.columns.1.y, intrinsics.columns.2.x, intrinsics.columns.2.y),
            imageSize: SIMD2(Float(resolution.width), Float(resolution.height))
        )
        let tracking = Self.tracking(frame.camera.trackingState)
        let meterAnchor = shared.meterAnchorID.flatMap { id in frame.anchors.first { $0.identifier == id }?.transform }
        guard count % Self.sampleEvery == 0 else {
            let pose = SourceFrame(
                id: "live-\(count)", timestamp: frame.timestamp, camera: camera, tracking: tracking,
                quality: nil, jpeg: .none, still: nil, meterAnchor: meterAnchor, isPoseOnly: true
            )
            Task { @MainActor [onFrame] in onFrame(pose) }
            return
        }
        let quality = Self.quality(frame.capturedImage)
        let ground = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal }
            .map { plane -> SIMD4<Float> in
                let center = plane.transform * SIMD4(plane.center, 1)
                let radius = simd_length(SIMD2(plane.planeExtent.width, plane.planeExtent.height)) / 2
                return SIMD4(center.x, center.y, center.z, radius)
            }
        let snapshot = SourceFrame(
            id: "live-\(count)", timestamp: frame.timestamp, camera: camera, tracking: tracking,
            quality: quality, jpeg: .none, still: nil, meterAnchor: meterAnchor, groundPlanes: ground
        )
        let image = tracking == .normal && shouldEncode(mode: shared.mode, time: frame.timestamp, camera: camera)
            ? PixelBufferBox(buffer: frame.capturedImage) : nil
        encodeQueue.async { [self] in
            var delivered = snapshot
            if let image {
                if let data = encode(image.buffer) { delivered.jpeg = .data(data) }
                queueState.withLock { $0.encoding = false }
            }
            Task { @MainActor [onFrame] in onFrame(delivered) }
        }
    }

    /// Whether to encode this frame; claims the single encode slot when it says yes.
    private func shouldEncode(mode: LiveMode, time: Double, camera: CameraFrame) -> Bool {
        queueState.withLock { state in
            guard !state.encoding else { return false }
            let decision: Bool
            switch mode {
            case .idle:
                decision = false
            case .closeUp:
                decision = time - (state.lastEncode?.time ?? -.infinity) >= Self.encodeInterval
            case .walk:
                if let last = state.lastEncode {
                    let moved = simd_distance(camera.position, last.camera.position) >= Self.encodeMove
                        || camera.rotationAngle(to: last.camera) >= Self.encodeTurn
                    decision = moved && time - last.time >= Self.encodeInterval
                } else {
                    decision = true
                }
            }
            if decision {
                state.lastEncode = (time, camera)
                state.encoding = true
            }
            return decision
        }
    }

    /// JPEG of the sensor image as captured: landscape, unrotated, matching the intrinsics.
    private func encode(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8]
        return context.jpegRepresentation(of: image, colorSpace: space, options: options)
    }

    /// Sharpness and exposure from the luma plane, sampling every 8th pixel of every 8th row
    /// (240 x 180 for a 1920 x 1440 buffer).
    private static func quality(_ buffer: CVPixelBuffer) -> FrameQuality? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 1, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard width >= 8, height >= 8 else { return nil }
        let raw = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
        return FrameQuality(LumaImage(sampling: raw, width: width, height: height, bytesPerRow: bytesPerRow, step: 8))
    }

    private static func tracking(_ state: ARCamera.TrackingState) -> TrackingQuality {
        switch state {
        case .notAvailable: .notAvailable
        case .normal: .normal
        case .limited(let reason):
            switch reason {
            case .initializing: .limited(.initializing)
            case .excessiveMotion: .limited(.excessiveMotion)
            case .insufficientFeatures: .limited(.insufficientFeatures)
            case .relocalizing: .limited(.relocalizing)
            @unknown default: .limited(.unknown)
            }
        }
    }

    // MARK: Session events

    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        // Resume the walk in the same world frame after an interruption (checklist R4).
        true
    }

    func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [onEvent] in onEvent(.interrupted) }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [onEvent] in onEvent(.interruptionEnded) }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        let event: LiveEvent
        if let arError = error as? ARError, arError.code == .cameraUnauthorized {
            event = .cameraDenied
        } else {
            event = .failed(error.localizedDescription)
        }
        Task { @MainActor [onEvent] in onEvent(event) }
    }
}

/// The ARView as a SwiftUI view.
struct LiveCameraView: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ view: ARView, context: Context) {}
}
