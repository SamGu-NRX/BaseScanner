import ARKit
import MeasureGeometry
import Observation
import RealityKit
import UIKit

/// Owns the ARView and ARSession and turns screen taps into `TapInput`s for `LabSession`.
///
/// A live tap saves the current frame as a keyframe and maps the screen point to that frame's
/// pixel with ARKit's display transform, which matches what ARView draws. A frozen tap maps
/// through `PortraitFillMapping`, which matches how the frozen image is drawn. Either way the ray
/// is rebuilt from the saved frame's pose and intrinsics, never from the live camera.
@MainActor
@Observable
final class CaptureController {
    struct FrozenFrame {
        let snapshot: FrameSnapshot
        let image: UIImage
        let mapping: PortraitFillMapping
    }

    private(set) var frozen: FrozenFrame?
    let session: LabSession

    @ObservationIgnored private var arView: ARView?
    @ObservationIgnored private var delegate: SessionDelegate?
    @ObservationIgnored private let delegateQueue = DispatchQueue(label: "MeasureLab.ARSessionDelegate")
    @ObservationIgnored private var markerRoot: AnchorEntity?
    @ObservationIgnored private var drawnPoints = 0
    @ObservationIgnored private var drawnWalls = 0

    init(session: LabSession) {
        self.session = session
    }

    func makeView() -> ARView {
        // The app configures the session itself so nothing runs that it didn't ask for: no scene
        // reconstruction, and scene depth only when a LiDAR comparison run turns it on.
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        let delegate = SessionDelegate(session: session, recorder: session.recorder)
        view.session.delegateQueue = delegateQueue
        view.session.delegate = delegate
        self.delegate = delegate
        arView = view
        let root = AnchorEntity(world: .zero)
        view.scene.addAnchor(root)
        markerRoot = root
        run(reset: false)
        return view
    }

    func pause() {
        arView?.session.pause()
        session.save()
    }

    private func run(reset: Bool) {
        let configuration = ARWorldTrackingConfiguration()
        // .gravity, not .gravityAndHeading: the compass is unreliable next to a house (docs/00).
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal, .vertical]
        if session.sceneDepthEnabled, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        arView?.session.run(configuration, options: reset ? [.resetTracking, .removeExistingAnchors] : [])
    }

    /// Ends the session and opens a new one with its own world frame.
    ///
    /// Order matters: the recorder stops before the old session closes, and restarts only for
    /// frames newer than the last one the old map delivered, so no old-map frame is written into
    /// the new session. The restart is queued behind any delegate callback already in flight.
    func startNewSession(sceneDepth: Bool) {
        let lastOldFrame = arView?.session.currentFrame?.timestamp ?? 0
        session.recorder.stop()
        frozen = nil
        let destination = session.startNewSession(sceneDepth: sceneDepth)
        session.arSessionRestarted()
        clearMarkers()
        run(reset: true)
        guard var destination else { return }
        destination.acceptsFramesAfter = lastOldFrame
        delegateQueue.async { [recorder = session.recorder, destination] in
            recorder.start(destination)
        }
    }

    // MARK: - Freezing

    func freeze(viewSize: CGSize) {
        guard session.markBlocker == nil else {
            session.refuseUnresolvedTap(reason: "trackingNotReady", message: session.markBlocker ?? "")
            return
        }
        guard let frame = arView?.session.currentFrame else { return }
        do {
            let result = try session.recorder.save(frame, reason: .freeze, displayImage: true)
            session.keyframeSaved(result.saved)
            guard let cgImage = result.image else { return }
            let snapshot = result.saved.snapshot
            frozen = FrozenFrame(
                snapshot: snapshot,
                // .right rotates the landscape sensor image 90° clockwise for an upright phone,
                // the same rotation PortraitFillMapping assumes.
                image: UIImage(cgImage: cgImage, scale: 1, orientation: .right),
                mapping: PortraitFillMapping(
                    imageWidth: Double(snapshot.imageWidth),
                    imageHeight: Double(snapshot.imageHeight),
                    viewWidth: viewSize.width,
                    viewHeight: viewSize.height
                )
            )
        } catch {
            session.recorderFailed(error)
        }
    }

    func unfreeze() {
        frozen = nil
    }

    // MARK: - Taps

    /// Marks at a point of the full-screen camera layer, whose size is `viewSize`.
    func mark(at point: CGPoint, viewSize: CGSize) {
        if let blocker = session.markBlocker {
            session.refuseUnresolvedTap(reason: "trackingNotReady", message: blocker)
            return
        }
        let resolved: (snapshot: FrameSnapshot, pixel: (u: Double, v: Double), check: Double?)
        if let frozen {
            resolved = (frozen.snapshot, frozen.mapping.imagePixel(forViewPoint: point.x, point.y), nil)
        } else {
            guard let live = resolveLive(point, viewSize: viewSize) else { return }
            resolved = live
        }
        // The live check above uses the latest tracking callback; this one uses the tapped frame.
        guard resolved.snapshot.tracking == .normal else {
            session.refuseUnresolvedTap(reason: "trackingNotReady", message: "That frame wasn't in normal tracking. Hold steady and try again.")
            return
        }
        guard resolved.snapshot.contains(pixel: resolved.pixel.u, resolved.pixel.v) else {
            session.refuseUnresolvedTap(reason: "outsideImage", message: "That spot is outside the camera image.")
            return
        }
        let ray: Ray
        do {
            ray = try resolved.snapshot.camera.ray(throughPixel: resolved.pixel.u, resolved.pixel.v)
        } catch {
            session.refuseUnresolvedTap(reason: "invalidPose", message: "ARKit returned an unusable camera pose for that frame.")
            return
        }
        session.handle(TapInput(
            snapshot: resolved.snapshot,
            pixel: resolved.pixel,
            ray: ray,
            frozen: frozen != nil,
            displayMappingCheck: resolved.check,
            ground: session.tool.needsGround ? groundHit(along: ray) : nil
        ))
        // A two-view pair needs a second frame, so a frozen first view is let go right away.
        if session.tool == .twoView {
            frozen = nil
        }
        syncMarkers()
    }

    private func resolveLive(_ point: CGPoint, viewSize: CGSize) -> (snapshot: FrameSnapshot, pixel: (u: Double, v: Double), check: Double?)? {
        guard let frame = arView?.session.currentFrame else {
            session.refuseUnresolvedTap(reason: "noFrame", message: "The camera hasn't delivered a frame yet.")
            return nil
        }
        let saved: KeyframeRecorder.Saved
        do {
            saved = try session.recorder.save(frame, reason: .tap).saved
        } catch {
            session.recorderFailed(error)
            return nil
        }
        session.keyframeSaved(saved)
        let snapshot = saved.snapshot
        // displayTransform maps normalized image coordinates to normalized view coordinates for
        // this orientation and viewport, the same mapping ARView uses to draw the camera feed.
        let toImage = frame.displayTransform(for: .portrait, viewportSize: viewSize).inverted()
        let normalized = CGPoint(x: point.x / viewSize.width, y: point.y / viewSize.height).applying(toImage)
        let pixel = (u: Double(normalized.x) * Double(snapshot.imageWidth), v: Double(normalized.y) * Double(snapshot.imageHeight))
        let mapping = PortraitFillMapping(
            imageWidth: Double(snapshot.imageWidth),
            imageHeight: Double(snapshot.imageHeight),
            viewWidth: viewSize.width,
            viewHeight: viewSize.height
        )
        let mapped = mapping.imagePixel(forViewPoint: point.x, point.y)
        let check = ((mapped.u - pixel.u) * (mapped.u - pixel.u) + (mapped.v - pixel.v) * (mapped.v - pixel.v)).squareRoot()
        return (snapshot, pixel, check)
    }

    /// Ground raycast along the tap ray: a found plane first, then its infinite extension, then
    /// ARKit's estimate. The surface kind is kept so later analysis can drop weaker hits.
    private func groundHit(along ray: Ray) -> GroundHit? {
        guard let arSession = arView?.session else { return nil }
        let targets: [(ARRaycastQuery.Target, GroundHit.Surface)] = [
            (.existingPlaneGeometry, .detectedPlane),
            (.existingPlaneInfinite, .extendedPlane),
            (.estimatedPlane, .estimatedPlane),
        ]
        for (target, surface) in targets {
            let query = ARRaycastQuery(
                origin: SIMD3<Float>(ray.origin),
                direction: SIMD3<Float>(ray.direction),
                allowing: target,
                alignment: .horizontal
            )
            if let result = arSession.raycast(query).first {
                return GroundHit(
                    point: SIMD3<Double>(result.worldTransform.columns.3),
                    surface: surface,
                    planeAnchor: result.anchor?.identifier.uuidString
                )
            }
        }
        return nil
    }

    // MARK: - Markers

    /// Adds a dot for each new point and a line along the base of each new wall.
    func syncMarkers() {
        guard let root = markerRoot else { return }
        let points = session.manifest.points
        for point in points.dropFirst(drawnPoints) {
            let dot = ModelEntity(
                mesh: .generateSphere(radius: 0.015),
                materials: [UnlitMaterial(color: point.flags.isEmpty ? Theme.accentUIColor : .systemOrange)]
            )
            dot.position = SIMD3<Float>(point.position)
            root.addChild(dot)
        }
        drawnPoints = points.count
        let walls = session.manifest.walls
        for wall in walls.dropFirst(drawnWalls) {
            // Drawn between the two contacts in 3D, so a sloped ground line shows its slope.
            // Measurements use the horizontal length; this is only the overlay.
            let run = SIMD3<Float>(wall.end - wall.start)
            let line = ModelEntity(
                mesh: .generateBox(size: SIMD3(simd_length(run), 0.008, 0.008)),
                materials: [UnlitMaterial(color: Theme.accentUIColor.withAlphaComponent(0.8))]
            )
            line.position = SIMD3<Float>((wall.start + wall.end) / 2)
            // The box's long side is x; turn x onto the contact-to-contact direction.
            line.orientation = simd_quatf(from: SIMD3(1, 0, 0), to: simd_normalize(run))
            root.addChild(line)
        }
        drawnWalls = walls.count
    }

    private func clearMarkers() {
        markerRoot?.children.removeAll()
        drawnPoints = 0
        drawnWalls = 0
    }

    // MARK: - Two-view guide

    /// The first two-view ray drawn into the frozen frame as a line of view points, so the second
    /// tap can go on the same feature. Nil without a frozen frame or a first view.
    func epipolarGuide() -> [CGPoint]? {
        guard let frozen, let first = session.twoViewFirst else { return nil }
        // Sample the ray from 0.3 m to 30 m with denser samples close to the camera.
        let points = (0...60).compactMap { step -> CGPoint? in
            let distance = 0.3 * pow(100, Double(step) / 60)
            guard let pixel = frozen.snapshot.camera.project(first.ray.point(at: distance)) else { return nil }
            let view = frozen.mapping.viewPoint(forImagePixel: pixel.u, pixel.v)
            return CGPoint(x: view.x, y: view.y)
        }
        return points.count >= 2 ? points : nil
    }
}
