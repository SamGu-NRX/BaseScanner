import ARKit
import CoreImage
import MeasureGeometry
import Synchronization

/// Writes keyframes to the current session folder: the unrotated sensor image as JPEG plus the
/// pose, intrinsics, timestamp and tracking state that go with it.
///
/// Two callers use it: the ARSession delegate queue offers every frame for motion keyframes, and
/// the main actor saves a frame for each tap or freeze. The folder, id counter and spacing state sit
/// in a `Mutex`; encoding happens outside the lock. `@unchecked Sendable` covers the `CIContext`,
/// which Core Image documents as safe to share between threads but older SDKs do not mark
/// `Sendable`.
final class KeyframeRecorder: @unchecked Sendable {
    struct Destination: Sendable, Equatable {
        let sessionID: String
        let folder: URL
        /// Frames captured at or before this ARFrame timestamp belong to the previous AR map and
        /// are refused. Zero accepts every frame.
        var acceptsFramesAfter: Double = 0
    }

    /// A saved keyframe, tagged with its session so one that finishes after a session switch is
    /// filed under the session it was reserved for.
    struct Saved: Sendable {
        let sessionID: String
        let record: KeyframeRecord
        let snapshot: FrameSnapshot
    }

    private struct State {
        var destination: Destination?
        var selector = KeyframeSelector()
        var count = 0
    }

    private let state = Mutex(State())
    private let context = CIContext()
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var spacing: (meters: Double, degrees: Double) {
        state.withLock { ($0.selector.minimumTranslation, $0.selector.minimumRotation) }
    }

    /// Starts writing into `folder`, which must already contain a `keyframes` directory.
    func start(_ destination: Destination) {
        state.withLock { state in
            state = State(destination: destination)
        }
    }

    /// Stops accepting frames until the next `start`.
    func stop() {
        state.withLock { state in
            state = State()
        }
    }

    /// Delegate queue. Saves a keyframe when the camera moved or turned past the spacing since the
    /// last saved one. Returns nil when no keyframe was due.
    func offerMotionFrame(_ frame: ARFrame) -> Result<Saved, RecorderError>? {
        if case .notAvailable = frame.camera.trackingState { return nil }
        let pose = CameraPose(frame.camera.transform)
        guard let reservation = reserve(pose: pose, timestamp: frame.timestamp, onlyIfDue: true) else { return nil }
        do {
            return .success(try write(frame, reason: .motion, reservation: reservation).saved)
        } catch {
            return .failure(error)
        }
    }

    /// Saves `frame` regardless of spacing. With `displayImage`, also returns the frame as a
    /// CGImage in sensor orientation for the frozen-frame view.
    func save(_ frame: ARFrame, reason: KeyframeRecord.Reason, displayImage: Bool = false) throws(RecorderError) -> (saved: Saved, image: CGImage?) {
        let pose = CameraPose(frame.camera.transform)
        guard let reservation = reserve(pose: pose, timestamp: frame.timestamp, onlyIfDue: false) else {
            throw isRecording ? .frameFromPreviousMap : .notRecording
        }
        return try write(frame, reason: reason, reservation: reservation, displayImage: displayImage)
    }

    private struct Reservation {
        let destination: Destination
        let id: String
    }

    private var isRecording: Bool {
        state.withLock { $0.destination != nil }
    }

    private func reserve(pose: CameraPose, timestamp: Double, onlyIfDue: Bool) -> Reservation? {
        state.withLock { state in
            guard let destination = state.destination, timestamp > destination.acceptsFramesAfter else { return nil }
            if onlyIfDue, !state.selector.wantsKeyframe(at: pose) { return nil }
            state.selector.didSave(at: pose)
            state.count += 1
            return Reservation(destination: destination, id: String(format: "k%05d", state.count))
        }
    }

    private func write(
        _ frame: ARFrame,
        reason: KeyframeRecord.Reason,
        reservation: Reservation,
        displayImage: Bool = false
    ) throws(RecorderError) -> (saved: Saved, image: CGImage?) {
        let buffer = frame.capturedImage
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        // No orientation is applied: the JPEG keeps the sensor's landscape layout, which is what
        // ARCamera.intrinsics describe.
        let image = CIImage(cvPixelBuffer: buffer)
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            throw .encodingFailed(reservation.id)
        }
        let imagePath = "keyframes/\(reservation.id).jpg"
        let folder = reservation.destination.folder
        do {
            try jpeg.write(to: folder.appending(path: imagePath))
        } catch {
            throw .writeFailed(imagePath, error.localizedDescription)
        }

        let depth = try writeDepth(frame, id: reservation.id, folder: folder)
        let intrinsics = CameraIntrinsics(frame.camera.intrinsics)
        let pose = CameraPose(frame.camera.transform)
        let tracking = TrackingState(frame.camera.trackingState)
        let record = KeyframeRecord(
            id: reservation.id,
            img: imagePath,
            w: width,
            h: height,
            intrinsics: [intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy],
            pose: pose.columnMajor,
            timestamp: frame.timestamp,
            tracking: tracking.manifestName,
            reason: reason,
            depth: depth
        )
        let snapshot = FrameSnapshot(
            sessionID: reservation.destination.sessionID,
            keyframeID: reservation.id,
            camera: CameraFrame(intrinsics: intrinsics, pose: pose),
            imageWidth: width,
            imageHeight: height,
            timestamp: frame.timestamp,
            tracking: tracking
        )
        let cgImage = displayImage ? context.createCGImage(image, from: image.extent) : nil
        return (Saved(sessionID: reservation.destination.sessionID, record: record, snapshot: snapshot), cgImage)
    }

    /// Writes LiDAR depth and confidence when the session asked for scene depth.
    private func writeDepth(_ frame: ARFrame, id: String, folder: URL) throws(RecorderError) -> KeyframeRecord.Depth? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthPath = "keyframes/\(id).depth.f32"
        let confidencePath = "keyframes/\(id).confidence.u8"
        let depthMap = sceneDepth.depthMap
        do {
            try Self.rows(of: depthMap, bytesPerPixel: 4).write(to: folder.appending(path: depthPath))
            if let confidence = sceneDepth.confidenceMap {
                try Self.rows(of: confidence, bytesPerPixel: 1).write(to: folder.appending(path: confidencePath))
            }
        } catch {
            throw .writeFailed(depthPath, error.localizedDescription)
        }
        return KeyframeRecord.Depth(
            file: depthPath,
            confidenceFile: sceneDepth.confidenceMap == nil ? nil : confidencePath,
            w: CVPixelBufferGetWidth(depthMap),
            h: CVPixelBufferGetHeight(depthMap)
        )
    }

    /// Copies a single-plane pixel buffer row by row, dropping any row padding.
    private static func rows(of buffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        var data = Data(capacity: width * height * bytesPerPixel)
        for row in 0..<height {
            data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * bytesPerPixel)
        }
        return data
    }
}

enum RecorderError: Error, Sendable, Equatable {
    case notRecording
    /// The frame predates the AR reset that started this session.
    case frameFromPreviousMap
    case encodingFailed(String)
    case writeFailed(String, String)

    var message: String {
        switch self {
        case .notRecording: "No session folder is open, so the frame wasn't saved."
        case .frameFromPreviousMap: "The camera is still delivering frames from before the reset. Try again in a moment."
        case .encodingFailed(let id): "Couldn't encode keyframe \(id) as JPEG."
        case .writeFailed(let path, let reason): "Couldn't save \(path): \(reason)"
        }
    }
}
