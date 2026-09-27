import ARKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import HouseScanKit
import Synchronization

/// Where the depth model is: compiled into the app bundle (Xcode compiles a bundled
/// `.mlpackage` to `.mlmodelc`), else compiled in Application Support/Models. Nil when neither
/// exists; the app then runs without estimated depth.
enum DepthModelLocator {
    /// Apple's Core ML Depth Anything V2 Small, Float16 (huggingface.co/apple/coreml-depth-anything-v2-small,
    /// revision cfef6f6f2a70783dedc0bfae40cecbc2052285d3, Apache-2.0).
    static let name = "DepthAnythingV2SmallF16"

    static func url(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.url(forResource: name, withExtension: "mlmodelc") { return bundled }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let cached = support.appending(path: "Models/\(name).mlmodelc", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }
}

/// What the depth model needs from one ARKit frame, copied on the AR delegate queue: the camera
/// image stretched to the model's input, and the frame's own geometry for the scale fit.
struct DepthEstimatorInput: Sendable {
    /// The `SourceFrame` id of the frame, so the engine can ask for it once the frame is kept.
    let frameID: String
    /// `DepthEstimator.inputWidth` x `inputHeight` BGRA, rows from the top of the unrotated
    /// landscape sensor image, as the intrinsics describe it.
    let bgra: [UInt8]
    let camera: CameraFrame
    /// ARKit's `rawFeaturePoints`, world meters.
    let points: [SIMD3<Float>]
    let planes: [PlaneObservation]
}

/// Estimated depth for a phone without LiDAR: runs the depth model on each kept keyframe, fits
/// its scale to that frame's feature points and detected planes (`MonocularDepth`), and hands
/// the `.estimated` depth frame to `onFrame` (the 3D map).
///
/// The delegate queue only converts a keyframe candidate (`input(from:id:context:)`) and offers
/// it (`offer`); the model runs on this type's own queue when the engine keeps the frame
/// (`estimate(frameID:)`), never on the delegate queue or the main actor. Candidates wait a few
/// at a time, since a frame is kept only after its JPEG is encoded and stored.
final class DepthEstimator: Sendable {
    static let inputWidth = 518
    static let inputHeight = 392
    /// Candidates held for a keep decision. The encode queue delivers a candidate within about
    /// one JPEG encode and the engine keeps it on arrival; four covers a second of candidates at
    /// the walk's fastest encode rate (one per 0.3 s). A guess, not measured.
    private static let waiting = 4
    /// Kept frames waiting for the model, beyond the one it runs on; older ones are dropped. Each
    /// holds the 518 x 392 image (812 KB) and the frame's geometry, and waiting longer only makes
    /// its estimate staler. Two keeps the model busy without a backlog. A guess, not measured.
    private static let queued = 2

    private let model: ModelBox
    private let queue = DispatchQueue(label: "dev.housescanning.housescan.depth-model", qos: .utility)
    private let candidates = Mutex<[DepthEstimatorInput]>([])
    /// Kept frames for the model with the generation they were kept in, and whether the model's
    /// queue is running through them.
    private let work = Mutex((pending: PendingWork<(input: DepthEstimatorInput, generation: Int)>(limit: DepthEstimator.queued), running: false))
    private let onFrame: @Sendable (DepthFrame, Int) -> Void

    /// Core ML documents a loaded model's predictions as safe to call from any thread; this
    /// type calls it from its one serial queue only.
    private struct ModelBox: @unchecked Sendable {
        let model: MLModel
    }

    private init(model: MLModel, onFrame: @escaping @Sendable (DepthFrame, Int) -> Void) {
        self.model = ModelBox(model: model)
        self.onFrame = onFrame
    }

    /// Loads the model found by `DepthModelLocator`, or returns nil when there is none or it
    /// fails to load. The first load on a device specializes the model for the Neural Engine
    /// and can take seconds; later loads read Core ML's cache.
    /// `onFrame` gets each estimate with the generation its frame was kept in (`estimate`).
    static func load(onFrame: @escaping @Sendable (DepthFrame, Int) -> Void) async -> DepthEstimator? {
        guard let url = DepthModelLocator.url() else {
            RuntimeLog.engine.info("depth model: none in the bundle or Application Support; estimated depth off")
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        do {
            let started = ProcessInfo.processInfo.systemUptime
            let model = try await MLModel.load(contentsOf: url, configuration: configuration)
            RuntimeLog.engine.info("depth model loaded in \(ProcessInfo.processInfo.systemUptime - started) s")
            return DepthEstimator(model: model, onFrame: onFrame)
        } catch {
            RuntimeLog.engine.error("depth model failed to load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: AR delegate queue

    /// The model's input for a frame: its camera image scaled to 518 x 392 (Lanczos, stretched
    /// from the sensor's 4:3, as Apple's evaluation of the model stretched its images) and its
    /// feature points and planes. Nil when the render fails.
    static func input(from frame: ARFrame, id: String, context: CIContext) -> DepthEstimatorInput? {
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = CIFilter.lanczosScaleTransform()
        scale.inputImage = image
        scale.scale = Float(CGFloat(inputHeight) / size.height)
        scale.aspectRatio = Float((CGFloat(inputWidth) / size.width) / (CGFloat(inputHeight) / size.height))
        guard let scaled = scale.outputImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bgra = [UInt8](repeating: 0, count: inputWidth * inputHeight * 4)
        // Rows come out top first, as the pixel buffer's are.
        bgra.withUnsafeMutableBytes { bytes in
            context.render(
                scaled, toBitmap: bytes.baseAddress!, rowBytes: inputWidth * 4,
                bounds: CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight), format: .BGRA8, colorSpace: space)
        }
        let feature = Map3DFeed.featureFrame(frame)
        return DepthEstimatorInput(frameID: id, bgra: bgra, camera: feature.camera, points: feature.points, planes: Map3DFeed.planes(frame))
    }

    /// Keeps a candidate until the engine keeps or passes over its frame; the oldest goes first.
    func offer(_ input: DepthEstimatorInput) {
        candidates.withLock { waiting in
            waiting.append(input)
            if waiting.count > Self.waiting { waiting.removeFirst(waiting.count - Self.waiting) }
        }
    }

    // MARK: Any actor

    /// Estimates depth for a kept frame offered earlier; does nothing when it was not offered
    /// (a replay, a LiDAR phone) or has already left the candidates. `generation` (the 3D map's,
    /// `Map3DSession.generation`) goes back with the estimate, so one from before a reset is
    /// dropped. At most `queued` frames wait for the model, the oldest dropped first.
    func estimate(frameID: String, generation: Int) {
        let input = candidates.withLock { waiting -> DepthEstimatorInput? in
            guard let index = waiting.firstIndex(where: { $0.frameID == frameID }) else { return nil }
            return waiting.remove(at: index)
        }
        guard let input else { return }
        let start = work.withLock { work -> Bool in
            work.pending.add((input, generation))
            guard !work.running else { return false }
            work.running = true
            return true
        }
        if start { queue.async { [self] in runPending() } }
    }

    /// Drops the frames waiting for the model and the candidates: after a reset they belong to a
    /// world frame the map no longer has.
    func reset() {
        candidates.withLock { $0.removeAll() }
        work.withLock { $0.pending.removeAll() }
    }

    // MARK: Model queue

    /// Runs the model on waiting frames, newest last, until none wait.
    private func runPending() {
        while let (input, generation) = work.withLock({ work -> (DepthEstimatorInput, Int)? in
            guard let next = work.pending.take() else {
                work.running = false
                return nil
            }
            return (next.input, next.generation)
        }) {
            estimateNow(input, generation: generation)
        }
    }

    private func estimateNow(_ input: DepthEstimatorInput, generation: Int) {
        let started = ProcessInfo.processInfo.systemUptime
        guard let prediction = predict(input.bgra) else { return }
        let predicted = ProcessInfo.processInfo.systemUptime
        let anchors = DepthAnchor.anchors(points: input.points, camera: input.camera) + DepthAnchor.anchors(planes: input.planes, confirmedBy: input.points, camera: input.camera)
        guard let estimate = MonocularDepth.estimate(prediction, anchors: anchors, photo: input.camera) else {
            RuntimeLog.engine.info("depth \(input.frameID, privacy: .public): no scale fit from \(anchors.count) anchors; frame skipped")
            return
        }
        let fitted = ProcessInfo.processInfo.systemUptime
        RuntimeLog.engine.info("depth \(input.frameID, privacy: .public): model \(Int((predicted - started) * 1000)) ms, fit \(Int((fitted - predicted) * 1000)) ms, \(estimate.fit.inlierCount)/\(anchors.count) anchors, relative sigma \(estimate.fit.relativeSigma)")
        onFrame(estimate.frame, generation)
    }

    private func predict(_ bgra: [UInt8]) -> RelativeInverseDepth? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, Self.inputWidth, Self.inputHeight, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            bgra.withUnsafeBytes { source in
                for row in 0..<Self.inputHeight {
                    base.advanced(by: row * rowBytes).copyMemory(from: source.baseAddress!.advanced(by: row * Self.inputWidth * 4), byteCount: Self.inputWidth * 4)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        do {
            let output = try model.model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
            guard let depth = output.featureValue(for: "depth")?.imageBufferValue,
                  CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_OneComponent16Half,
                  CVPixelBufferGetWidth(depth) == Self.inputWidth, CVPixelBufferGetHeight(depth) == Self.inputHeight
            else {
                RuntimeLog.engine.error("depth model: output is not a 518 x 392 Float16 image")
                return nil
            }
            CVPixelBufferLockBaseAddress(depth, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRow(depth)
            var values = [Float](repeating: 0, count: Self.inputWidth * Self.inputHeight)
            for row in 0..<Self.inputHeight {
                let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float16.self)
                for column in 0..<Self.inputWidth { values[row * Self.inputWidth + column] = Float(line[column]) }
            }
            return RelativeInverseDepth(width: Self.inputWidth, height: Self.inputHeight, values: values)
        } catch {
            RuntimeLog.engine.error("depth model prediction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
