import CoreGraphics
import CryptoKit
import Foundation
import HouseScanKit
import ImageIO
import simd
import Testing

/// The capture packet's manifest schema, byte for byte from origin/t3/packet at d82a903
/// (packet/manifest.schema.json). `vendoredManifestSchemaIsTheRecordedRevision` fails if the copy
/// is edited by hand; `vendoredManifestSchemaMatchesThePacketTree` compares it with the repo's
/// packet/ folder once that branch is merged.
enum PacketSchema {
    static let name = "manifest.schema.json"
    static let repoPath = "packet/manifest.schema.json"
    static let sha256 = "30a1140fa56f1d30126027e5eb5b85a377eab8fc909c47f3676535c028ffe5aa"

    static func validator() throws -> JSONSchemaValidator { try JSONSchemaValidator(schema: SceneSchemas.data(name)) }
}

/// A JPEG of `width` x `height` with a colour pattern, written by ImageIO. `orientation` sets the
/// EXIF orientation tag.
func makeJPEG(width: Int, height: Int, at url: URL, orientation: Int? = nil) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4 * width, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: 4 * width * height)
    for y in 0..<height {
        for x in 0..<width {
            let p = 4 * (y * width + x)
            pixels[p] = UInt8((x * 9 + y * 3) % 256)
            pixels[p + 1] = UInt8((x * y) % 256)
            pixels[p + 2] = UInt8((y * 11) % 256)
            pixels[p + 3] = 255
        }
    }
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

/// The JPEG decoded by ImageIO into RGBX, then Pillow's luma: what the app does before scoring.
func jpegLuma(_ url: URL) throws -> (luma: [UInt8], width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let (w, h) = (image.width, image.height)
    let context = try #require(CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let bytes = UnsafeRawBufferPointer(start: try #require(context.data), count: 4 * w * h)
    return (PacketSharpness.luma(rgbx: bytes, width: w, height: h, bytesPerRow: 4 * w), w, h)
}

private func temporaryFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
}

/// A synthetic scan: the standard wall (meter (0, 1.5, 0), outward +z, ground 0) seen from a
/// camera walking left to right 2.5 m out, 60 Hz for 2 s from uptime 100, three photos on the
/// trajectory, IMU at 100 Hz, a barometer, a two-triangle mesh, two planes, marks and guidance.
struct SyntheticPacket {
    static let start = 100.0
    let wall = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)
    let frame: MeterFrame
    let session: PacketSessionInfo

    init() throws {
        frame = try #require(MeterFrame(wall: wall))
        session = PacketSessionInfo(
            id: "synthetic-swift", producer: .init(kind: .app, name: "HouseScanKit tests", version: "0"),
            device: .init(model: "synthetic", iosVersion: "26.0", lidar: true, sceneDepthEnabled: true, meshEnabled: true),
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), startedAtUptime: Self.start, meterFrame: frame, groundWorldY: 0)
    }

    /// World camera at frame `i` (60 Hz): x from -1 to 1 over 120 frames, 1.25 m up, 2.5 m out,
    /// facing the wall.
    func worldCamera(_ i: Int) -> simd_float4x4 {
        let x = Float(-1) + Float(i) / 60
        return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(x, 1.25, 2.5, 1))
    }

    func t(_ i: Int) -> Double { Self.start + Double(i) / 60 }

    /// Writes the whole packet into `folder` and returns the finished folder.
    func write(to folder: URL, jpegs: URL) throws -> URL {
        var writer = try PacketWriter(folder: folder, session: session)
        for i in 0...120 {
            try writer.appendTrajectory(t: t(i), tracking: i < 3 ? .limited(.initializing) : .normal, pose: frame.pose(worldCamera(i)))
        }
        try writer.setNominalRate(60, for: .trajectory)
        for i in 0..<200 {
            let t = Self.start + Double(i) / 100
            try writer.appendAccelerometer(t: t, g: SIMD3(-1, 0, 0))
            try writer.appendGyroscope(t: t, radiansPerSecond: SIMD3(0.01, 0, -0.02))
            try writer.appendMagnetometer(t: t, microtesla: SIMD3(20, -5, -40))
            try writer.appendDeviceMotion(DeviceMotionSample(
                t: t, attitude: SIMD4(0, 0, 0, 1), gravity: SIMD3(-1, 0, 0), userAcceleration: .zero, rotationRate: .zero,
                headingDegrees: -1))
        }
        for stream in [PacketStream.accelerometer, .gyroscope, .magnetometer, .deviceMotion] { try writer.setNominalRate(100, for: stream) }
        try writer.appendBarometer(t: 100.5, pressureKPa: 101.3, relativeAltitudeM: 0)
        try writer.appendBarometer(t: 101.5, pressureKPa: 101.29, relativeAltitudeM: 0.08)
        try writer.setNominalRate(1, for: .barometer)

        // Photos at frames 90, 15 and 60, added out of order; 96 x 72 with fx = 80.
        for (number, i) in [(3, 90), (1, 15), (2, 60)] {
            let id = PacketPhoto.id(number: number)
            let jpeg = jpegs.appendingPathComponent("\(id).jpg")
            try makeJPEG(width: 96, height: 72, at: jpeg)
            let luma = try jpegLuma(jpeg)
            var meters = [Float](repeating: 2.5, count: 24 * 18)
            meters[0] = .nan
            meters[1] = -1
            let depth = DepthPacket(
                meters: meters, width: 24, height: 18, confidence: [UInt8](repeating: 2, count: 24 * 18), source: .arkitSceneDepth)
            try writer.addPhoto(PacketPhoto(
                id: id, jpeg: jpeg, width: 96, height: 72, t: t(i), pose: frame.pose(worldCamera(i)),
                intrinsics: SIMD4(80, 80, 48, 36), tracking: .normal,
                exposure: PacketExposure(durationS: 0.002, iso: 50), lens: PacketLens(focalLengthMM: 5.1, fNumber: 1.8, camera: "wide"),
                sharpness: PacketSharpness.laplacianVarianceLuma640(luma: luma.luma, width: luma.width, height: luma.height),
                depth: number == 3 ? nil : depth))
        }

        let worldMesh = TriangleMesh(
            vertices: [SIMD3(-3, 0, 0), SIMD3(3, 0, 0), SIMD3(3, 2.5, 0), SIMD3(-3, 2.5, 0)], indices: [0, 1, 2, 0, 2, 3])
        try writer.setMesh(frame.mesh(worldMesh), classification: [1, 1])
        let wallPlane = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 1.25, 0, 1))
        try writer.setPlanes([
            PacketPlane(id: "wall", alignment: .vertical, classification: .wall, pose: frame.pose(wallPlane), extent: SIMD2(6, 2.4)),
            PacketPlane(id: "ground", alignment: .horizontal, classification: nil, pose: frame.pose(matrix_identity_float4x4), extent: SIMD2(6, 3)),
        ])
        try writer.setMarks([
            .meter(id: "m1", t: 100.1, photoIDs: ["p00001"]),
            .wallEnd(id: "m2", side: .left, endKind: .unexplored, s: -3, wall: wall, frame: frame, t: 100.2),
            .wallEnd(id: "m3", side: .right, endKind: .limit, s: 3, wall: wall, frame: frame, t: 101.9),
            try .from(.opening(kind: .window, span: -2 ... -1.25, bottom: 1, top: 2, operable: true), id: "m4", wall: wall, frame: frame, t: 100.4),
            try .from(.pointObject(kind: .gasMeter, tap: SIMD3(1.5, 1, 0.1), bottom: nil, top: nil), id: "m5", wall: wall, frame: frame),
            try .from(.driveway(edge: [SIMD3(2, 0, 0.5), SIMD3(2, 0, 4)]), id: "m6", wall: wall, frame: frame, t: 101.5),
        ])
        try writer.setGuidance([
            PacketGuidanceEntry(id: "g1", kind: .walk, origin: .phone, message: "Walk slowly to your left", tShown: 100, tResolved: 100.8, outcome: .met),
            PacketGuidanceEntry(
                id: "g2", kind: .gapBand, origin: .server, message: "Show the ground around your meter", band: .ground, span: 1 ... 2.5,
                tShown: 101.6, tResolved: 101.9, outcome: .cannotReach),
            PacketGuidanceEntry(id: "g3", kind: .stepBack, origin: .phone, message: nil, tShown: 101.95, tResolved: nil, outcome: .unresolved),
        ])
        try writer.setScene(Data(#"{"schema_version":"1.0","meter":{"pos":[0,4.921,0],"wall_id":"wall"}}"#.utf8))
        return try writer.finish()
    }
}

@Suite struct PacketWriterTests {
    private func decodedManifest(_ folder: URL) throws -> PacketManifest {
        try JSONDecoder().decode(PacketManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    /// Every file named in the manifest, with where it is named.
    private func files(_ m: PacketManifest) -> [PacketManifest.File] {
        var out = m.photos.flatMap { p in [p.image] + [p.depth?.map, p.depth?.confidence].compactMap { $0 } }
        let streams = [m.streams?.trajectory, m.streams?.accelerometer, m.streams?.gyroscope, m.streams?.magnetometer, m.streams?.deviceMotion, m.streams?.barometer]
        out += streams.compactMap { $0.map { PacketManifest.File(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) } }
        out += [m.lidar?.mesh].compactMap { $0 }
        out += [m.scene.map { PacketManifest.File(path: $0.path, bytes: $0.bytes, sha256: $0.sha256) }].compactMap { $0 }
        return out
    }

    /// Writes the synthetic packet and checks what packet/validate.py checks that can be checked
    /// here. For the validator itself (manual, not a test dependency):
    ///
    ///     HOUSESCAN_PACKET_OUT=/tmp/hs-swift-packet swift test --package-path ios/HouseScanKit \
    ///         --filter PacketWriterTests/syntheticPacketIsComplete
    ///     cd <t3/packet checkout>/packet && uv run python -m packet validate /tmp/hs-swift-packet
    ///
    /// With HOUSESCAN_PACKET_OUT set, the packet is written there (it must not exist or be
    /// empty) and kept.
    @Test func syntheticPacketIsComplete() throws {
        let keep = ProcessInfo.processInfo.environment["HOUSESCAN_PACKET_OUT"].map { URL(fileURLWithPath: $0) }
        let folder = keep ?? temporaryFolder("packet")
        let jpegs = temporaryFolder("packet-jpegs")
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: jpegs)
            if keep == nil { try? FileManager.default.removeItem(at: folder) }
        }
        let synthetic = try SyntheticPacket()
        let written = try synthetic.write(to: folder, jpegs: jpegs)
        #expect(written == folder)

        // The schema.
        let manifestData = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        #expect(try PacketSchema.validator().validate(manifestData) == [])

        // Every file's size and hash, and no file the manifest does not name.
        let manifest = try decodedManifest(folder)
        let named = files(manifest)
        for file in named {
            let data = try Data(contentsOf: folder.appendingPathComponent(file.path))
            #expect(data.count == file.bytes, "\(file.path)")
            #expect(PacketFiles.sha256(data) == file.sha256, "\(file.path)")
        }
        let onDisk = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
            .map { String($0.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1)) }
        #expect(Set(onDisk) == Set(named.map(\.path) + ["manifest.json"]))
        #expect(Set(named.map(\.path)).count == named.count)

        // Session.
        let s = manifest.session
        #expect(manifest.packetVersion == "1.0" && s.worldAlignment == "gravity" && s.consent == nil)
        #expect(s.capture.startedAt == "2026-09-21T14:13:20.000Z")
        #expect(s.capture.startedAtUptime == 100 && s.capture.endedAtUptime == synthetic.t(120))
        #expect(s.meterAnchor.poseInWorld == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1.5, 0, 1])
        #expect(s.meterAnchor.groundYM == -1.5)
        // The camera walks x from -1 to 1: 2 m, to Float rounding.
        #expect(abs(try #require(s.capture.distanceWalkedM) - 2) < 1e-5)

        // Photos: sorted by t, on the trajectory, depth cleaned.
        #expect(manifest.photos.map(\.id) == ["p00001", "p00002", "p00003"])
        #expect(manifest.photos.map(\.image.path) == ["photos/p00001.jpg", "photos/p00002.jpg", "photos/p00003.jpg"])
        let first = manifest.photos[0]
        #expect(first.t == synthetic.t(15))
        #expect(first.pose == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -0.75, -0.25, 2.5, 1])
        #expect(first.intrinsics == [80, 80, 48, 36])
        #expect(first.tracking?.state == "normal" && first.tracking?.reason == nil)
        #expect(first.sharpness?.method == "laplacian_variance_luma_640")
        #expect(first.depth?.map.path == "depth/p00001.f32" && first.depth?.confidence?.path == "depth/p00001.conf.u8")
        #expect(first.depth?.width == 24 && first.depth?.source == .arkitSceneDepth && manifest.photos[2].depth == nil)
        let depth = try Data(contentsOf: folder.appendingPathComponent("depth/p00001.f32"))
        let noMeasurement = [UInt8](repeating: 0, count: 8)
        #expect([UInt8](depth.prefix(8)) == noMeasurement)

        // Streams: rows, rates, trajectory values at the photo.
        let streams = try #require(manifest.streams)
        #expect(streams.trajectory?.rows == 121 && streams.trajectory?.nominalRateHz == 60)
        #expect(streams.accelerometer?.rows == 200 && streams.barometer?.rows == 2 && streams.location == nil)
        let trajectory = parseCSV(try Data(contentsOf: folder.appendingPathComponent("streams/trajectory.csv")))
        #expect(trajectory.rows[0] == ["100.0", "limited", "-1.0", "-0.25", "2.5", "0.0", "0.0", "0.0", "1.0"])
        #expect(trajectory.rows[15][0] == "100.25" && trajectory.rows[15][2] == "-0.75")
        let accelerometer = parseCSV(try Data(contentsOf: folder.appendingPathComponent("streams/accelerometer.csv")))
        #expect(accelerometer.rows[0] == ["100.0", "-9.80665", "0.0", "0.0"])

        // LiDAR: the wall mesh sits on z = 0 in the meter frame, 1.5 m below to 1 m above the meter.
        let mesh = try parsePLY(Data(contentsOf: folder.appendingPathComponent("lidar/mesh.ply")))
        let corners: [SIMD3<Float>] = [SIMD3(-3, -1.5, 0), SIMD3(3, -1.5, 0), SIMD3(3, 1, 0), SIMD3(-3, 1, 0)]
        #expect(mesh.vertices == corners)
        #expect(mesh.faces.map(\.classification) == [1, 1])
        let planes = try #require(manifest.lidar?.planes)
        #expect(PacketPose.columnMajor(planes[0].pose) == [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, -0.25, 0, 1])
        #expect(planes[1].classification == nil)

        // Marks and guidance come back as written.
        let marks = try #require(manifest.marks)
        #expect(marks.map(\.kind) == [.meter, .wallEnd, .wallEnd, .window, .gasMeter, .driveEdge])
        let window: [SIMD3<Float>] = [SIMD3(-2, -0.5, 0), SIMD3(-1.25, 0.5, 0)]
        let drive: [SIMD3<Float>] = [SIMD3(2, -1.5, 0.5), SIMD3(2, -1.5, 4)]
        #expect(marks[3].points == window)
        #expect(marks[5].points == drive)
        #expect(manifest.guidance?.map(\.outcome) == [.met, .cannotReach, .unresolved])
        #expect(manifest.scene?.schemaVersion == "1.0" && manifest.scene?.path == "scene.json")
    }

    /// Optional fields are left out, never written as null; nested keys are the schema's.
    @Test func manifestJSONShape() throws {
        let folder = temporaryFolder("packet-shape")
        let jpegs = temporaryFolder("packet-shape-jpegs")
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: jpegs)
        }
        _ = try SyntheticPacket().write(to: folder, jpegs: jpegs)
        let text = try String(contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(!text.contains("null"))
        #expect(!text.contains("\\/"))
        let json = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["packet_version", "session", "photos", "streams", "lidar", "marks", "guidance", "scene"])
        let session = try #require(json["session"] as? [String: Any])
        #expect(Set(session.keys) == ["id", "producer", "device", "capture", "world_alignment", "meter_anchor"])
        let device = try #require(session["device"] as? [String: Any])
        #expect(Set(device.keys) == ["model", "ios_version", "lidar", "scene_depth_enabled", "mesh_enabled"])
        let capture = try #require(session["capture"] as? [String: Any])
        #expect(Set(capture.keys) == ["started_at", "started_at_uptime", "ended_at_uptime", "distance_walked_m"])
        let photo = try #require((json["photos"] as? [[String: Any]])?.first)
        #expect(Set(photo.keys) == ["id", "image", "width", "height", "t", "pose", "intrinsics", "tracking", "exposure", "lens", "sharpness", "depth"])
        #expect(Set(try #require(photo["exposure"] as? [String: Any]).keys) == ["duration_s", "iso"])
        let marks = try #require(json["marks"] as? [[String: Any]])
        #expect(Set(marks[0].keys) == ["id", "kind", "points", "t", "photo_ids"])
        #expect(Set(marks[1].keys) == ["id", "kind", "points", "t", "side", "end_kind"])
        #expect((marks[3]["attrs"] as? [String: Bool]) == ["operable": true])
        let guidance = try #require(json["guidance"] as? [[String: Any]])
        #expect(Set(guidance[1].keys) == ["id", "kind", "origin", "message", "band", "span_m", "t_shown", "t_resolved", "outcome"])
        #expect(Set(guidance[2].keys) == ["id", "kind", "origin", "t_shown", "outcome"])
        let streams = try #require(json["streams"] as? [String: Any])
        #expect(Set(streams.keys) == ["trajectory", "accelerometer", "gyroscope", "magnetometer", "device_motion", "barometer"])
    }

    @Test func refusesInputsTheValidatorWouldReject() throws {
        let synthetic = try SyntheticPacket()
        let folder = temporaryFolder("packet-refuse")
        let jpegs = temporaryFolder("packet-refuse-jpegs")
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: jpegs)
        }
        var writer = try PacketWriter(folder: folder, session: synthetic.session)
        #expect(throws: PacketError.noPhotos) { try writer.finish() }

        let jpeg = jpegs.appendingPathComponent("a.jpg")
        try makeJPEG(width: 96, height: 72, at: jpeg)
        let pose = synthetic.frame.pose(synthetic.worldCamera(0))
        func photo(id: String = "p00001", t: Double = 100.5, width: Int = 96, height: Int = 72, jpeg: URL = jpeg, depth: DepthPacket? = nil) -> PacketPhoto {
            PacketPhoto(
                id: id, jpeg: jpeg, width: width, height: height, t: t, pose: pose, intrinsics: SIMD4(80, 80, 48, 36),
                tracking: .normal, sharpness: 1, depth: depth)
        }
        #expect(throws: PacketError.invalidID("p/1")) { try writer.addPhoto(photo(id: "p/1")) }
        #expect(throws: PacketError.timeBeforeStart(where: "photo p00001", t: 99, start: 100)) { try writer.addPhoto(photo(t: 99)) }
        #expect(throws: PacketError.invalidPhoto(id: "p00001", reason: "the JPEG is 96x72, not 100x75")) {
            try writer.addPhoto(PacketPhoto(
                id: "p00001", jpeg: jpeg, width: 100, height: 75, t: 100.5, pose: pose, intrinsics: SIMD4(80, 80, 48, 36),
                tracking: .normal, sharpness: 1))
        }
        let portrait = jpegs.appendingPathComponent("portrait.jpg")
        try makeJPEG(width: 72, height: 96, at: portrait)
        #expect(throws: PacketError.self) { try writer.addPhoto(photo(width: 72, height: 96, jpeg: portrait)) }
        let turned = jpegs.appendingPathComponent("turned.jpg")
        try makeJPEG(width: 96, height: 72, at: turned, orientation: 6)
        #expect(throws: PacketError.invalidPhoto(id: "p00001", reason: "EXIF orientation 6; store the unrotated sensor image")) {
            try writer.addPhoto(photo(jpeg: turned))
        }
        let square = DepthPacket(meters: [Float](repeating: 1, count: 24 * 24), width: 24, height: 24, confidence: nil, source: .arkitSceneDepth)
        #expect(throws: PacketError.self) { try writer.addPhoto(photo(depth: square)) }
        let empty = DepthPacket(meters: [Float](repeating: 0, count: 24 * 18), width: 24, height: 18, confidence: nil, source: .arkitSceneDepth)
        #expect(throws: PacketError.self) { try writer.addPhoto(photo(depth: empty)) }
        let badConfidence = DepthPacket(
            meters: [Float](repeating: 1, count: 24 * 18), width: 24, height: 18, confidence: [UInt8](repeating: 3, count: 24 * 18),
            source: .arkitSceneDepth)
        #expect(throws: PacketError.invalidDepth(id: "p00001", reason: "confidence must be 0, 1 or 2")) { try writer.addPhoto(photo(depth: badConfidence)) }
        // Nothing refused left a file behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        try writer.addPhoto(photo())
        #expect(throws: PacketError.duplicateID("p00001")) { try writer.addPhoto(photo()) }
        #expect(throws: PacketError.self) { try writer.addPhoto(photo(id: "p00002")) }  // same t

        let lonely = PacketMark.meter(id: "m1", photoIDs: ["p00009"])
        try writer.setMarks([lonely])
        #expect(throws: PacketError.invalidMark(id: "m1", reason: "photo_ids names p00009, which is not a photo in the packet")) { try writer.finish() }
        #expect(throws: PacketError.duplicateID("m1")) { try writer.setMarks([.meter(id: "m1"), .meter(id: "m1")]) }
        let early = PacketGuidanceEntry(id: "g1", kind: .walk, origin: .phone, message: nil, tShown: 101, tResolved: 100.5, outcome: .met)
        #expect(throws: PacketError.self) { try writer.setGuidance([early]) }
        let open = PacketGuidanceEntry(id: "g1", kind: .walk, origin: .phone, message: nil, tShown: 101, tResolved: nil, outcome: .skipped)
        #expect(throws: PacketError.invalidGuidance(id: "g1", reason: "outcome skipped needs t_resolved")) { try writer.setGuidance([open]) }
        #expect(throws: PacketError.self) { try writer.appendTrajectory(t: 100, tracking: .normal, pose: simd_float4x4(diagonal: SIMD4(2, 1, 1, 1))) }
        #expect(throws: PacketError.invalidScene("not a JSON object")) { try writer.setScene(Data("[1]".utf8)) }
    }

    @Test func refusesAFolderThatHoldsFiles() throws {
        let folder = temporaryFolder("packet-busy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appendingPathComponent("stale.jpg"))
        #expect(throws: PacketError.folderNotEmpty(folder.path)) { try PacketWriter(folder: folder, session: SyntheticPacket().session) }
    }

    @Test func photoIDs() {
        #expect(PacketPhoto.id(number: 1) == "p00001")
        #expect(PacketPhoto.id(number: 12345) == "p12345")
        #expect(PacketPhoto.id(number: 123456) == "p123456")
    }
}

@Suite struct PacketMarkTests {
    private let wall = SceneWall(meter: SIMD3(0, 1.5, 0), outward: SIMD3(0, 0, 1), groundY: 0)

    @Test func pointCountsPerKind() {
        let counts = Dictionary(uniqueKeysWithValues: PacketMark.Kind.allCases.map { ($0.rawValue, $0.pointCount) })
        #expect(counts == [
            "meter": 1, "wall_end": 1, "gas_meter": 1, "ac": 1,
            "door": 2, "window": 2, "garage_door": 2, "drive_edge": 2, "fence": 2,
        ])
    }

    /// Scene features become marks in the meter frame: an opening's corners from its span and
    /// heights (y is height less the meter's 1.5 m), taps moved from the world.
    @Test func sceneFeaturesBecomeMarks() throws {
        let frame = try #require(MeterFrame(wall: wall))
        let door = try PacketMark.from(.opening(kind: .door, span: 0.5 ... 1.4, bottom: 0, top: 2.25, operable: nil), id: "d", wall: wall, frame: frame)
        #expect(door.kind == .door && door.operable == nil)
        #expect(door.points == [SIMD3(0.5, -1.5, 0), SIMD3(1.4, 0.75, 0)])
        let ac = try PacketMark.from(.pointObject(kind: .ac, tap: SIMD3(-2, 0.5, 0.6), bottom: nil, top: nil), id: "a", wall: wall, frame: frame)
        #expect(ac.kind == .ac && ac.points == [SIMD3(-2, -1, 0.6)])
        let fence = try PacketMark.from(.fence(foot: [SIMD3(-1, 0, 3), SIMD3(1, 0, 3)]), id: "f", wall: wall, frame: frame)
        #expect(fence.kind == .fence && fence.points == [SIMD3(-1, -1.5, 3), SIMD3(1, -1.5, 3)])
        #expect(throws: PacketError.self) { try PacketMark.from(.driveway(edge: [SIMD3(0, 0, 1)]), id: "x", wall: wall, frame: frame) }
        let end = PacketMark.wallEnd(id: "e", side: .right, endKind: .limit, s: 2.5, wall: wall, frame: frame)
        #expect(end.points == [SIMD3(2.5, 0, 0)] && end.side == .right && end.endKind == .limit)
        #expect(PacketMark.meter(id: "m").points == [.zero])
    }

    @Test func marksAndGuidanceRoundTripThroughJSON() throws {
        let frame = try #require(MeterFrame(wall: wall))
        let marks: [PacketMark] = [
            .opening(.garageDoor, id: "g", span: -1 ... 1, bottom: 0, top: 2.2, operable: false, wall: wall, frame: frame, t: 3, photoIDs: ["p00001"]),
            .fence(id: "f", from: SIMD3(0.1, -1.5, 2), to: SIMD3(0.2, -1.5, 3)),
        ]
        let entries = [
            PacketGuidanceEntry(id: "g", kind: .gapPastEnd, origin: .server, message: "Go past the corner", band: .facing, span: -0.5 ... 0.25, tShown: 4, tResolved: 5, outcome: .superseded),
        ]
        let encoder = JSONEncoder()
        #expect(try JSONDecoder().decode([PacketMark].self, from: encoder.encode(marks)) == marks)
        #expect(try JSONDecoder().decode([PacketGuidanceEntry].self, from: encoder.encode(entries)) == entries)
    }

    /// Every guidance kind and outcome name is the spec's.
    @Test func guidanceNames() {
        #expect(PacketGuidanceEntry.Kind.allCases.map(\.rawValue) == ["walk", "tilt_to_ground", "step_back", "mark_end", "closeup", "gap_band", "gap_past_end"])
        #expect(PacketGuidanceEntry.Outcome.allCases.map(\.rawValue) == ["met", "skipped", "cannot_reach", "superseded", "unresolved"])
    }
}

@Suite struct PacketSchemaTests {
    @Test func vendoredManifestSchemaIsTheRecordedRevision() throws {
        let digest = SHA256.hash(data: try SceneSchemas.data(PacketSchema.name)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == PacketSchema.sha256, "Schemas/\(PacketSchema.name) is not the copy taken from origin/t3/packet d82a903")
    }

    @Test func vendoredManifestSchemaMatchesThePacketTree() throws {
        guard let root = SceneSchemas.repoRoot() else { return }
        let file = root.appendingPathComponent(PacketSchema.repoPath)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        #expect(try Data(contentsOf: file) == SceneSchemas.data(PacketSchema.name), "copy \(PacketSchema.repoPath) over Tests/HouseScanKitTests/Schemas/\(PacketSchema.name)")
    }

    /// The schema is not a rubber stamp: a manifest missing required fields or breaking a pattern
    /// fails.
    @Test func schemaRejectsBrokenManifests() throws {
        let v = try PacketSchema.validator()
        #expect(try v.validate(Data(#"{"packet_version": "2.0", "session": {}, "photos": []}"#.utf8)).count >= 3)
        let badPath = #"{"path": "../x.jpg", "bytes": 1, "sha256": "00"}"#
        let manifest = #"{"packet_version": "1.0", "session": {}, "photos": [], "scene": \#(badPath)}"#
        let errors = try v.validate(Data(manifest.utf8))
        #expect(errors.contains { $0.hasPrefix("$.scene.path") })
        #expect(errors.contains { $0.hasPrefix("$.scene.sha256") })
    }
}
