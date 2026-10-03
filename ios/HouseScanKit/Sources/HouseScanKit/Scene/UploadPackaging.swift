import Foundation

/// What an upload sends, built from one captured basis. The engine captures the scene (without
/// its mesh measurements), the wall in world meters, the LiDAR mesh and the packet's inputs in one
/// main-actor turn; the mesh is then measured against that captured wall and span while the main
/// actor is free, and the scene is serialized from the capture and handed, as the same bytes, to
/// the captured packet.
///
/// Before this, the mesh was measured against the wall as it was before the wait, and the scene
/// and packet were built from the engine's live wall after it. A ground refinement or anchor
/// correction landing during the measurement put clearances measured against the old wall into a
/// scene describing the new one (#191 review of bd6b9331). Now a change during the measurement
/// can't reach this upload's scene or packet; the engine's ground-freshness rule decides whether
/// the upload stands (`GroundFreshness`), and a superseded upload serializes nothing.
public struct UploadPackaging<Packet: Sendable>: Sendable {
    /// The scene to send, without its mesh measurements, which `package` fills in.
    public var scene: SceneInput
    /// The wall in world meters, as captured. The mesh is in world meters too, so it is measured
    /// against this, not `scene.wall`, whose ground has been moved to height zero.
    public var worldWall: WallFrame
    /// The LiDAR mesh ARKit had built at the capture; nil without LiDAR or before any mesh.
    public var mesh: TriangleMesh?
    /// The capture packet's inputs, read in the same turn; nil when there is none to write. Its
    /// scene is attached by `package`.
    public var packet: Packet?

    public init(scene: SceneInput, worldWall: WallFrame, mesh: TriangleMesh?, packet: Packet?) {
        self.scene = scene
        self.worldWall = worldWall
        self.mesh = mesh
        self.packet = packet
    }

    /// The stretch the mesh is measured over: the scene's own exported stretch.
    public var span: ClosedRange<Float> { scene.baselineS }

    /// The mesh's facing gaps and headroom along the wall (`TriangleMesh.facingSpans`,
    /// `overheadSpans`).
    public struct MeshMeasurement: Sendable, Equatable {
        public var facing: [ObservedSpan]
        public var overheads: [ObservedSpan]

        public init(facing: [ObservedSpan] = [], overheads: [ObservedSpan] = []) {
            self.facing = facing
            self.overheads = overheads
        }
    }

    /// Measures `mesh` against a wall over a span. Injected so a test can hold the measurement
    /// at the point where the engine's main actor is free.
    public typealias Measure = @Sendable (_ mesh: TriangleMesh, _ wall: WallFrame, _ span: ClosedRange<Float>) async -> MeshMeasurement

    /// The real measurement, off the caller's actor: ray casts over a whole mesh take a while.
    public static var measureOffActor: Measure {
        { mesh, wall, span in
            await Task.detached(priority: .userInitiated) {
                MeshMeasurement(facing: mesh.facingSpans(wall: wall, over: span), overheads: mesh.overheadSpans(wall: wall, over: span))
            }.value
        }
    }

    public struct Packaged: Sendable {
        /// The serialized scene.
        public var scene: Data
        public var measurement: MeshMeasurement
        /// The captured packet, with `scene` attached.
        public var packet: Packet?
    }

    /// Measures the captured mesh against the captured wall and span, then serializes the
    /// captured scene with those measurements and attaches the same bytes to the captured packet.
    /// `isCurrent` is asked once the measurement is back, on the main actor: false means the
    /// upload was superseded (cancelled, withdrawn for a ground change, or the scan reset), and
    /// nothing is serialized or returned, so the caller schedules no bundle and no submit.
    @MainActor
    public func package(
        measure: Measure = Self.measureOffActor,
        attachScene: (inout Packet, Data) -> Void,
        isCurrent: () -> Bool
    ) async throws -> Packaged? {
        var measurement = MeshMeasurement()
        if let mesh {
            measurement = await measure(mesh, worldWall, span)
        }
        guard isCurrent() else { return nil }
        var input = scene
        input.meshFacing = measurement.facing
        input.meshOverheads = measurement.overheads
        let data = try SceneExport.jsonData(input)
        var packet = packet
        if packet != nil { attachScene(&packet!, data) }
        return Packaged(scene: data, measurement: measurement, packet: packet)
    }
}
