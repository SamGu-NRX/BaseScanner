import Foundation
import HouseScanKit
import simd
import Testing

// The upload's packaging step (`UploadPackaging.package`), the function `ScanEngine.upload` calls
// between capturing its scene and packet (`captureUpload`) and writing the bundle and submitting.
// The measurement is held at the point where the engine's main actor is free, the source is
// changed while it is held, and the result is checked once it resumes.
//
// Boundary: these tests run the package's real `package` with the real mesh measurement behind a
// gate. The app target has no unit tests, so `Source` below stands in for the engine: its
// `capture` reads the same kinds of state the engine's `captureUpload` does in one synchronous
// turn, and its `upload` keeps the engine's order (capture, mark the scene packaged, package, then
// bundle and submit). The engine's own wiring of that order, and `answerAfter`'s use of
// `GroundFreshness`, are covered by review, not by these tests; the policy itself is covered by
// `GroundFreshnessTests`.

/// What the tests' packet carries: the geometry the engine's `PacketInputs` captures with the
/// scene, and the scene bytes attached by `package`.
struct TestPacket: Sendable, Equatable {
    var wall: SceneWall
    var groundWorldY: Float
    var marks: [SIMD3<Float>]
    var scene = Data()
}

/// Holds a measurement until the test releases it, and records what it was asked to measure.
actor MeasurementGate {
    private(set) var walls: [WallFrame] = []
    private(set) var spans: [ClosedRange<Float>] = []
    private var arrival: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    private var released = false

    private func hold(_ wall: WallFrame, _ span: ClosedRange<Float>) async {
        walls.append(wall)
        spans.append(span)
        arrival?.resume()
        arrival = nil
        guard !released else { return }
        await withCheckedContinuation { held = $0 }
    }

    /// Returns once a measurement is held.
    func arrived() async {
        guard walls.isEmpty else { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func release() {
        released = true
        held?.resume()
        held = nil
    }

    /// The real measurement, held first.
    nonisolated var measure: UploadPackaging<TestPacket>.Measure {
        { mesh, wall, span in
            await self.hold(wall, span)
            return await UploadPackaging<TestPacket>.measureOffActor(mesh, wall, span)
        }
    }
}

/// The scan the engine would hold: a coverage map, the exported stretch, the marks (a gas meter's
/// tap, world meters) and the LiDAR mesh; and the upload state `upload` keeps as the engine does.
@MainActor
final class Source {
    var map: CoverageMap
    var span: ClosedRange<Float> = -3...3
    var marks: [SIMD3<Float>]
    var mesh: TriangleMesh?
    var hasPacket = true

    var generation = 0
    var freshness = GroundFreshness()
    var scenePackaged = false
    var uploadTask: Task<Void, Never>?
    var failed = false
    /// Scenes attached to a packet, bundles written and scenes submitted, in order.
    var attached = 0
    var bundles: [TestPacket] = []
    var submits: [Data] = []

    init(groundY: Float, mesh: TriangleMesh?) {
        map = CoverageMap(wall: WallFrame(meter: SIMD3(0, 1.5 + groundY, 0), outward: SIMD3(0, 0, 1), groundY: groundY)!)
        marks = [SIMD3(1.5, 1.0 + groundY, 0)]
        self.mesh = mesh
    }

    /// Everything one upload sends, read in this one turn, as `ScanEngine.captureUpload` does: the
    /// scene with its ground moved to zero, the wall in world meters, the mesh and the packet.
    func capture() -> UploadPackaging<TestPacket> {
        let wall = map.wall
        let drop = SIMD3<Float>(0, wall.groundY, 0)
        let worldWall = SceneWall(meter: wall.meter, outward: wall.outward, groundY: wall.groundY)
        let scene = SceneInput(
            wall: SceneWall(meter: wall.meter - drop, outward: wall.outward, groundY: 0),
            baselineS: span,
            features: marks.map { .pointObject(kind: .gasMeter, tap: $0 - drop, bottom: nil, top: nil) },
            coverage: SceneCoverage(map, leftEndMarked: false, rightEndMarked: false))
        let packet = hasPacket ? TestPacket(wall: worldWall, groundWorldY: wall.groundY, marks: marks) : nil
        return UploadPackaging(scene: scene, worldWall: wall, mesh: mesh, packet: packet)
    }

    /// `ScanEngine.upload` from its capture on: mark the scene packaged, package, and only a
    /// current upload writes its bundle and submits.
    func upload(_ gate: MeasurementGate) async {
        let scan = generation
        guard !Task.isCancelled else { return }
        let capture = capture()
        scenePackaged = true
        let packaged = try? await capture.package(
            measure: gate.measure,
            attachScene: { packet, data in
                self.attached += 1
                packet.scene = data
            },
            isCurrent: { scan == self.generation && !Task.isCancelled })
        guard let packaged else { return }
        if let packet = packaged.packet { bundles.append(packet) }
        submits.append(packaged.scene)
    }

    func startUpload(_ gate: MeasurementGate) {
        scenePackaged = false
        uploadTask?.cancel()
        uploadTask = Task { await upload(gate) }
    }

    /// `ScanEngine.answerAfter` on the upload screen.
    @discardableResult
    func changed(_ change: GroundFreshness.Change, replacement: MeasurementGate?) -> GroundFreshness.Action {
        let action = freshness.after(change, on: .sending, scenePackaged: scenePackaged)
        switch action {
        case .keep:
            break
        case .sendAgain:
            startUpload(replacement ?? MeasurementGate())
        case .fail:
            uploadTask?.cancel()
            uploadTask = nil
            failed = true
        }
        return action
    }

    /// The ground refined: same meter and axes, the ground `by` higher.
    func raiseGround(by rise: Float) {
        let wall = map.wall
        map.updateWall(WallFrame(meter: wall.meter, outward: wall.outward, groundY: wall.groundY + rise)!)
    }
}

/// The standard wall's surroundings with the ground `groundY` up: the wall face z = 0, the ground,
/// a fence 2.0 m out over s in [-1, 1] and an eave 2.5 m above the ground over the same stretch.
func raisedScene(groundY g: Float) -> TriangleMesh {
    var builder = MeshBuilder()
    builder.quad(SIMD3(-10, g, 0), SIMD3(10, g, 0), SIMD3(10, g + 4, 0), SIMD3(-10, g + 4, 0))
    builder.quad(SIMD3(-10, g, 0), SIMD3(-10, g, 10), SIMD3(10, g, 10), SIMD3(10, g, 0))
    builder.box(SIMD3(-1, g, 2.0), SIMD3(1, g + 1.5, 2.2))
    builder.box(SIMD3(-1, g + 2.5, 0), SIMD3(1, g + 2.7, 1.0))
    return builder.mesh
}

@MainActor
@Suite struct UploadPackagingTests {
    /// The world's ground is 0.5 m up, so a wall with its ground moved to zero would put every
    /// overhead ray's start 0.5 m under the mesh's ground.
    static let groundY: Float = 0.5

    /// The captured scene serialized with the mesh measured against the captured world wall and
    /// span: what an upload of `capture` must send, byte for byte.
    static func expected(_ capture: UploadPackaging<TestPacket>) throws -> Data {
        var input = capture.scene
        if let mesh = capture.mesh {
            input.meshFacing = mesh.facingSpans(wall: capture.worldWall, over: capture.span)
            input.meshOverheads = mesh.overheadSpans(wall: capture.worldWall, over: capture.span)
        }
        return try SceneExport.jsonData(input)
    }

    /// Boundary: `package` with the real measurement. Nothing changes while it runs; the fence
    /// and eave come back measured from the world's ground (6.5 ft and 8.2 ft, rounded down to
    /// 0.1 ft), in the scene and in the packet's copy of it.
    @Test func anUnchangedScanKeepsItsFacingAndOverheadMeasurements() async throws {
        let source = Source(groundY: Self.groundY, mesh: raisedScene(groundY: Self.groundY))
        let gate = MeasurementGate()
        await gate.release()
        let capture = source.capture()
        let packaged = try #require(try await capture.package(measure: gate.measure, attachScene: { $0.scene = $1 }, isCurrent: { true }))

        #expect(await gate.walls == [source.map.wall])
        #expect(await gate.walls.first?.groundY == Self.groundY)
        // Measured against a wall with its ground at zero, the overhead rays would start under
        // the mesh's ground and meet it 0.5 m (1.6 ft) up.
        #expect(packaged.measurement.facing.contains { nearlyEqual($0.out, 6.5 * 0.3048) })
        #expect(packaged.measurement.overheads.contains { nearlyEqual($0.out, 8.2 * 0.3048) })
        #expect(packaged.measurement.overheads.allSatisfy { $0.out > 2 })
        #expect(packaged.scene == (try Self.expected(capture)))
        #expect(packaged.packet?.scene == packaged.scene)
    }

    /// Boundary: `package` held mid-measurement while the source's ground, wall, span and marks
    /// all change. What it sends is the capture, measured against the captured wall: the scene's
    /// bytes, the packet's geometry and the packet's copy of the scene, which a capture taken
    /// after the change would not match.
    @Test func changesWhileTheMeshIsMeasuredDontReachTheUpload() async throws {
        let source = Source(groundY: Self.groundY, mesh: raisedScene(groundY: Self.groundY))
        let gate = MeasurementGate()
        let capture = source.capture()
        let worldWall = source.map.wall
        let task = Task { try await capture.package(measure: gate.measure, attachScene: { $0.scene = $1 }, isCurrent: { true }) }
        await gate.arrived()

        source.raiseGround(by: 0.12)
        source.map.updateWall(WallFrame(meter: source.map.wall.meter + SIMD3(0.3, 0, 0), outward: SIMD3(0, 0, 1), groundY: source.map.wall.groundY)!)
        source.span = -2...4
        source.marks = [SIMD3(-1, 1.4, 0)]
        let later = source.capture()
        await gate.release()
        let packaged = try #require(try await task.value)

        #expect(await gate.walls == [worldWall])
        #expect(await gate.spans == [-3...3])
        #expect(packaged.scene == (try Self.expected(capture)))
        #expect(packaged.scene != (try Self.expected(later)))
        let packet = try #require(packaged.packet)
        #expect(packet.wall == SceneWall(meter: worldWall.meter, outward: worldWall.outward, groundY: worldWall.groundY))
        #expect(packet.groundWorldY == Self.groundY)
        #expect(packet.marks == [SIMD3(1.5, 1.0 + Self.groundY, 0)])
        #expect(packet.scene == packaged.scene)
    }

    /// Boundary: `Source.upload` around `package`, held mid-measurement while an anchor correction
    /// moves the wall, its ground and the marks as one body. The rule keeps the upload, nothing is
    /// sent again, and the upload completes with the geometry it captured.
    @Test func anAnchorCorrectionKeepsTheCapturedUploadWithoutResending() async throws {
        let source = Source(groundY: Self.groundY, mesh: raisedScene(groundY: Self.groundY))
        let gate = MeasurementGate()
        let capture = source.capture()
        source.startUpload(gate)
        let first = try #require(source.uploadTask)
        await gate.arrived()

        let correction = YawCorrection(yaw: 0.05, translation: SIMD3(0.2, 0.04, -0.1))
        source.map.apply(correction)
        source.marks = source.marks.map { correction.direction($0) + correction.translation }
        #expect(source.changed(.anchorCorrection, replacement: nil) == .keep)
        #expect(source.uploadTask == first)
        #expect(!source.freshness.awaitingNewAnswer)
        await gate.release()
        await first.value

        #expect(source.submits == [try Self.expected(capture)])
        #expect(source.bundles.map(\.wall) == [capture.packet?.wall])
        #expect(source.bundles.map(\.marks) == [capture.packet?.marks])
        #expect(source.bundles.map(\.scene) == source.submits)
        #expect(!source.failed)
    }

    /// Boundary: `Source.upload` around `package` with `GroundFreshness` deciding. A ground change
    /// mid-measurement withdraws the first upload, whose completion then sends nothing, and the
    /// replacement, captured on the new ground, is what is bundled and submitted.
    @Test func aGroundChangeRejectsTheOldUploadAndItsReplacementIsSent() async throws {
        let source = Source(groundY: Self.groundY, mesh: raisedScene(groundY: Self.groundY))
        let firstGate = MeasurementGate()
        source.startUpload(firstGate)
        let first = try #require(source.uploadTask)
        await firstGate.arrived()

        source.raiseGround(by: 0.12)
        let secondGate = MeasurementGate()
        #expect(source.changed(.ground, replacement: secondGate) == .sendAgain)
        let second = try #require(source.uploadTask)
        await secondGate.arrived()
        let replacement = source.capture()
        await firstGate.release()
        await first.value
        #expect(source.submits.isEmpty)
        #expect(source.bundles.isEmpty)
        #expect(source.attached == 0)

        await secondGate.release()
        await second.value
        #expect(await secondGate.walls.first?.groundY == Self.groundY + 0.12)
        #expect(source.submits == [try Self.expected(replacement)])
        #expect(source.bundles.map(\.groundWorldY) == [Self.groundY + 0.12])
        #expect(source.bundles.map(\.scene) == source.submits)
    }

    /// Boundary: as above, with a second ground change while the replacement is measured. The
    /// rule fails the upload, neither completion sends anything, and a further change keeps the
    /// failure rather than sending again.
    @Test func aSecondGroundChangeKeepsTheFailure() async throws {
        let source = Source(groundY: Self.groundY, mesh: raisedScene(groundY: Self.groundY))
        let firstGate = MeasurementGate()
        source.startUpload(firstGate)
        let first = try #require(source.uploadTask)
        await firstGate.arrived()
        source.raiseGround(by: 0.12)
        let secondGate = MeasurementGate()
        #expect(source.changed(.ground, replacement: secondGate) == .sendAgain)
        let second = try #require(source.uploadTask)
        await secondGate.arrived()

        source.raiseGround(by: 0.05)
        #expect(source.changed(.ground, replacement: nil) == .fail)
        #expect(source.uploadTask == nil)
        await firstGate.release()
        await secondGate.release()
        await first.value
        await second.value
        #expect(source.failed)
        #expect(source.submits.isEmpty)
        #expect(source.bundles.isEmpty)
        #expect(source.attached == 0)
        source.raiseGround(by: 0.05)
        #expect(source.changed(.ground, replacement: nil) == .fail)
        #expect(source.uploadTask == nil)
    }

    /// Boundary: `Source.upload` around `package`. A reset (a new scan generation) or a
    /// cancelled task while the mesh is measured: the completion serializes nothing into a
    /// packet, and nothing is bundled or submitted.
    @Test(arguments: [false, true])
    func aResetOrCancelledUploadSendsNothing(cancel: Bool) async throws {
        let source = Source(groundY: Self.groundY, mesh: raisedScene(groundY: Self.groundY))
        let gate = MeasurementGate()
        source.startUpload(gate)
        let task = try #require(source.uploadTask)
        await gate.arrived()
        if cancel { task.cancel() } else { source.generation += 1 }
        await gate.release()
        await task.value
        #expect(source.attached == 0)
        #expect(source.bundles.isEmpty)
        #expect(source.submits.isEmpty)
    }

    /// Boundary: `package` alone. Without a mesh nothing is measured, and the scene still goes,
    /// with its packet's copy; without a packet the scene still goes on its own.
    @Test func noMeshOrNoPacketStillSendsTheScene() async throws {
        let source = Source(groundY: Self.groundY, mesh: nil)
        let gate = MeasurementGate()
        let capture = source.capture()
        let packaged = try #require(try await capture.package(measure: gate.measure, attachScene: { $0.scene = $1 }, isCurrent: { true }))
        #expect(await gate.walls.isEmpty)
        #expect(packaged.measurement == .init())
        #expect(packaged.scene == (try Self.expected(capture)))
        #expect(packaged.packet?.scene == packaged.scene)

        source.hasPacket = false
        let alone = source.capture()
        let sent = try #require(try await alone.package(measure: gate.measure, attachScene: { $0.scene = $1 }, isCurrent: { true }))
        #expect(sent.packet == nil)
        #expect(sent.scene == (try Self.expected(alone)))
    }
}
