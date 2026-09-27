import Foundation
import HouseScanKit
import os

/// Runs the LiDAR dot field (`SurfaceDots`) off the main actor and publishes its dots for the
/// camera overlay (`ScanViewState.liveDots`).
///
/// The engine hands it each kept keyframe that has depth, the same frames coverage observes, so
/// the dots and the fog move together. Fusing a 256 x 192 map takes a few milliseconds (3.4 ms
/// median on an M4 Pro in a Release build; not measured on a phone), so it runs on its own
/// serial queue. A keyframe arriving while two are still waiting is dropped: the next one covers
/// the same wall. An anchor correction is a matrix product (`SurfaceDots.apply`) and republishes
/// only when no keyframe is waiting to publish anyway, so neither kind of work can pile up.
final class LiveDotsFeed: @unchecked Sendable {
    // `@unchecked Sendable`: everything below `queue` is read and written only on it; `pending`
    // is a lock.
    private let queue = DispatchQueue(label: "dev.housescanning.housescan.live-dots", qos: .utility)
    private var field = SurfaceDots()
    private var revision = 0
    private var last: (eye: SIMD3<Float>, wall: WallFrame)?
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private let publish: @MainActor @Sendable (LiveDots, _ generation: Int) -> Void

    /// Keyframes waiting on the queue past which new ones are dropped.
    static let maxPending = 2

    /// `publish` runs on the main actor with the scan generation the work was queued under, so
    /// the engine can ignore dots from before a Start over.
    init(publish: @escaping @MainActor @Sendable (LiveDots, _ generation: Int) -> Void) {
        self.publish = publish
    }

    func integrate(camera: CameraFrame, depth: DepthImage, wall: WallFrame, generation: Int) {
        let accepted = pending.withLock { count -> Bool in
            guard count < Self.maxPending else { return false }
            count += 1
            return true
        }
        guard accepted else {
            RuntimeLog.capture.info("live dots: dropped a keyframe, two still waiting")
            return
        }
        queue.async { [self] in
            field.integrate(camera: camera, depth: depth)
            last = (camera.position, wall)
            pending.withLock { $0 -= 1 }
            send(generation)
        }
    }

    /// ARKit's correction to the meter's anchor, applied as coverage applies it.
    func apply(_ correction: YawCorrection, wall: WallFrame, generation: Int) {
        queue.async { [self] in
            field.apply(correction)
            if let eye = last?.eye { last = (correction.point(eye), wall) }
            if pending.withLock({ $0 }) == 0 { send(generation) }
        }
    }

    func reset() {
        queue.async { [self] in
            field = SurfaceDots()
            last = nil
        }
    }

    /// On `queue`.
    private func send(_ generation: Int) {
        guard let last else { return }
        revision += 1
        let dots = LiveDots(
            dots: field.dots(near: last.eye, wall: last.wall).map {
                LiveDots.Dot(id: $0.id, position: $0.position, isEdge: $0.isEdge, onOccluder: $0.onOccluder, opacity: $0.opacity)
            },
            revision: revision)
        let publish = publish
        DispatchQueue.main.async {
            MainActor.assumeIsolated { publish(dots, generation) }
        }
    }
}
