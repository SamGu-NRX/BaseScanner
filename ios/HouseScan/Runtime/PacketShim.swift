// SHIM, engine lane round 6. Stands in for HouseScanKit/Sources/HouseScanKit/Packet/ (package
// lane, t3/ios-mvf-r6pk at 3d15204) until it merges; the lead deletes this file at merge and the
// engine then compiles against the package unchanged. It declares only what the engine calls,
// with the package's names, labels and types; the implementation is a stand-in that follows the
// same rules, not a copy.
//
// Spec: packet/README.md and packet/manifest.schema.json on t3/packet (capture packet 1.0).

import CryptoKit
import Foundation
import HouseScanKit
import simd

// MARK: - Frames and poses

struct MeterFrame: Sendable, Equatable {
    let meterInWorld: simd_float4x4
    private let worldToMeter: simd_float4x4

    init(meterInWorld: simd_float4x4) {
        self.meterInWorld = meterInWorld
        worldToMeter = meterInWorld.inverse
    }

    init?(meter: SIMD3<Float>, outward: SIMD3<Float>) {
        let flat = SIMD3<Float>(outward.x, 0, outward.z)
        let length = simd_length(flat)
        guard length.isFinite, length > 1e-6 else { return nil }
        let z = flat / length
        let y = SIMD3<Float>(0, 1, 0)
        self.init(meterInWorld: simd_float4x4(SIMD4(simd_cross(y, z), 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(meter, 1)))
    }

    func pose(_ worldPose: simd_float4x4) -> simd_float4x4 {
        var m = worldToMeter * worldPose
        m.columns.0.w = 0
        m.columns.1.w = 0
        m.columns.2.w = 0
        m.columns.3.w = 1
        return m
    }

    func point(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = worldToMeter * SIMD4(world, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    func mesh(_ world: TriangleMesh) -> TriangleMesh {
        TriangleMesh(vertices: world.vertices.map(point), indices: world.indices)
    }

    func point(on wall: SceneWall, s: Float, height: Float, out: Float) -> SIMD3<Float> {
        point(wall.world(s: s, height: height, out: out))
    }
}

// MARK: - Session and photos

/// Only the nested types the engine names; the package's `PacketManifest` is the whole manifest.
enum PacketManifest {
    struct Producer: Sendable, Equatable {
        enum Kind: String, Sendable { case app, converter }
        var kind: Kind
        var name: String
        var version: String
        var commit: String?

        init(kind: Kind, name: String, version: String, commit: String? = nil) {
            self.kind = kind
            self.name = name
            self.version = version
            self.commit = commit
        }
    }

    struct Device: Sendable, Equatable {
        var model: String
        var iosVersion: String?
        var lidar: Bool
        var sceneDepthEnabled: Bool?
        var meshEnabled: Bool?
    }
}

struct PacketSessionInfo: Sendable {
    var id: String
    var producer: PacketManifest.Producer
    var device: PacketManifest.Device
    var startedAt: Date?
    var startedAtUptime: Double
    var meterFrame: MeterFrame
    /// World y of the ground at the meter; written as `ground_y_m` on the meter frame's y.
    var groundWorldY: Float?
}

enum PacketTracking: Sendable, Equatable {
    case normal
    case limited(Reason?)
    case notAvailable

    enum Reason: String, Sendable {
        case initializing, relocalizing
        case excessiveMotion = "excessive_motion"
        case insufficientFeatures = "insufficient_features"
    }

    var state: String {
        switch self {
        case .normal: "normal"
        case .limited: "limited"
        case .notAvailable: "not_available"
        }
    }
}

struct PacketExposure: Sendable, Equatable {
    var durationS: Double?
    var iso: Double?
    var offsetEV: Double?

    init(durationS: Double? = nil, iso: Double? = nil, offsetEV: Double? = nil) {
        self.durationS = durationS
        self.iso = iso
        self.offsetEV = offsetEV
    }
}

struct PacketLens: Sendable, Equatable {
    var focalLengthMM: Double?
    var fNumber: Double?
    var camera: String?

    init(focalLengthMM: Double? = nil, fNumber: Double? = nil, camera: String? = nil) {
        self.focalLengthMM = focalLengthMM
        self.fNumber = fNumber
        self.camera = camera
    }
}

struct DepthPacket: Sendable {
    enum Source: String, Sendable {
        case arkitSceneDepth = "arkit_scene_depth"
        case arkitSmoothedSceneDepth = "arkit_smoothed_scene_depth"
        case renderedFromLaserScan = "rendered_from_laser_scan"
    }

    var meters: [Float]
    var width: Int
    var height: Int
    var confidence: [UInt8]?
    var source: Source
}

struct PacketPhoto: Sendable {
    var id: String
    var jpeg: URL
    var width: Int
    var height: Int
    var t: Double
    var pose: simd_float4x4
    var intrinsics: SIMD4<Float>
    var tracking: PacketTracking
    var exposure: PacketExposure?
    var lens: PacketLens?
    var sharpness: Double
    var depth: DepthPacket?

    static func id(number: Int) -> String { String(format: "p%05d", number) }
}

// MARK: - Streams, marks, planes, guidance

enum PacketStream: String, CaseIterable, Sendable {
    case trajectory, accelerometer, gyroscope, magnetometer
    case deviceMotion = "device_motion"
    case barometer

    var columns: [String] {
        switch self {
        case .trajectory: ["t", "tracking", "px", "py", "pz", "qx", "qy", "qz", "qw"]
        case .accelerometer, .gyroscope, .magnetometer: ["t", "x", "y", "z"]
        case .deviceMotion:
            ["t", "qx", "qy", "qz", "qw", "gravity_x", "gravity_y", "gravity_z", "user_accel_x", "user_accel_y", "user_accel_z",
             "rotation_rate_x", "rotation_rate_y", "rotation_rate_z", "heading_deg"]
        case .barometer: ["t", "pressure_kpa", "relative_altitude_m"]
        }
    }

    var path: String { "streams/\(rawValue).csv" }

    static let standardGravity = 9.80665
}

struct DeviceMotionSample: Sendable, Equatable {
    var t: Double
    var attitude: SIMD4<Double>
    var gravity: SIMD3<Double>
    var userAcceleration: SIMD3<Double>
    var rotationRate: SIMD3<Double>
    var headingDegrees: Double
}

struct PacketMark: Sendable {
    enum Kind: String, Sendable {
        case meter
        case wallEnd = "wall_end"
        case gasMeter = "gas_meter"
        case ac, door, window
        case garageDoor = "garage_door"
        case driveEdge = "drive_edge"
        case fence
    }

    enum Side: String, Sendable { case left, right }
    enum EndKind: String, Sendable { case limit, unexplored }
    enum OpeningKind: Sendable { case door, window, garageDoor }

    var id: String
    var kind: Kind
    var points: [SIMD3<Float>]
    var t: Double?
    var photoIDs: [String]?
    var side: Side?
    var endKind: EndKind?
    var operable: Bool?

    static func meter(id: String, t: Double? = nil, photoIDs: [String]? = nil) -> PacketMark {
        PacketMark(id: id, kind: .meter, points: [.zero], t: t, photoIDs: photoIDs)
    }

    static func wallEnd(id: String, side: Side, endKind: EndKind, s: Float, wall: SceneWall, frame: MeterFrame, t: Double? = nil) -> PacketMark {
        let point = frame.point(on: wall, s: s, height: wall.meter.y - wall.groundY, out: 0)
        return PacketMark(id: id, kind: .wallEnd, points: [point], t: t, side: side, endKind: endKind)
    }

    static func opening(
        _ opening: OpeningKind, id: String, span: ClosedRange<Float>, bottom: Float, top: Float, operable: Bool?,
        wall: SceneWall, frame: MeterFrame, t: Double? = nil, photoIDs: [String]? = nil
    ) -> PacketMark {
        let kind: Kind = switch opening {
        case .door: .door
        case .window: .window
        case .garageDoor: .garageDoor
        }
        let corners = [frame.point(on: wall, s: span.lowerBound, height: bottom, out: 0), frame.point(on: wall, s: span.upperBound, height: top, out: 0)]
        return PacketMark(id: id, kind: kind, points: corners, t: t, photoIDs: photoIDs, operable: operable)
    }

    static func pointObject(_ kind: ScenePointObjectKind, id: String, point: SIMD3<Float>, t: Double? = nil, photoIDs: [String]? = nil) -> PacketMark {
        PacketMark(id: id, kind: kind == .gasMeter ? .gasMeter : .ac, points: [point], t: t, photoIDs: photoIDs)
    }

    static func fence(id: String, from a: SIMD3<Float>, to b: SIMD3<Float>, t: Double? = nil, photoIDs: [String]? = nil) -> PacketMark {
        PacketMark(id: id, kind: .fence, points: [a, b], t: t, photoIDs: photoIDs)
    }

    static func driveEdge(id: String, from a: SIMD3<Float>, to b: SIMD3<Float>, t: Double? = nil, photoIDs: [String]? = nil) -> PacketMark {
        PacketMark(id: id, kind: .driveEdge, points: [a, b], t: t, photoIDs: photoIDs)
    }
}

struct PacketGuidanceEntry: Sendable {
    enum Kind: String, Sendable {
        case walk
        case tiltToGround = "tilt_to_ground"
        case stepBack = "step_back"
        case markEnd = "mark_end"
        case closeup
        case gapBand = "gap_band"
        case gapPastEnd = "gap_past_end"
    }

    enum Origin: String, Sendable { case phone, server }
    enum Band: String, Sendable { case wall, ground, overhead, facing }
    enum Outcome: String, Sendable {
        case met, skipped, superseded, unresolved
        case cannotReach = "cannot_reach"
    }

    var id: String
    var kind: Kind
    var origin: Origin
    var message: String?
    var band: Band?
    var span: ClosedRange<Float>?
    var tShown: Double
    var tResolved: Double?
    var outcome: Outcome

    init(
        id: String, kind: Kind, origin: Origin, message: String?, band: Band? = nil, span: ClosedRange<Float>? = nil,
        tShown: Double, tResolved: Double?, outcome: Outcome
    ) {
        self.id = id
        self.kind = kind
        self.origin = origin
        self.message = message
        self.band = band
        self.span = span
        self.tShown = tShown
        self.tResolved = tResolved
        self.outcome = outcome
    }
}

struct PacketPlane: Sendable {
    enum Alignment: String, Sendable { case horizontal, vertical }
    enum Classification: String, Sendable { case none, wall, floor, ceiling, table, seat, window, door }

    var id: String
    var alignment: Alignment
    var classification: Classification?
    var pose: simd_float4x4
    var extent: SIMD2<Float>
}

// MARK: - Sharpness

enum PacketSharpness {
    static let method = "laplacian_variance_luma_640"

    /// Variance of the 4-neighbour Laplacian of the luma after scaling the long side to 640 px
    /// with Pillow's bilinear resampling (write.py `sharpness`).
    static func laplacianVarianceLuma640(luma: [UInt8], width: Int, height: Int) -> Double {
        var pixels = luma
        var w = width
        var h = height
        let scale = 640 / Double(max(width, height))
        if scale < 1 {
            w = Int((Double(width) * scale).rounded(.toNearestOrEven))
            h = Int((Double(height) * scale).rounded(.toNearestOrEven))
            pixels = resizeBilinear(luma, width: width, height: height, toWidth: w, height: h)
        }
        guard w >= 3, h >= 3 else { return 0 }
        var sum = 0.0
        var sumSquares = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let around: Int = Int(pixels[i - 1]) + Int(pixels[i + 1]) + Int(pixels[i - w]) + Int(pixels[i + w])
                let lap = Double(around - 4 * Int(pixels[i]))
                sum += lap
                sumSquares += lap * lap
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return max(0, sumSquares / n - mean * mean)
    }

    /// Pillow's "L" conversion of 8-bit RGBX pixels.
    static func luma(rgbx base: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * bytesPerRow + 4 * x
                out[y * width + x] = MeterPhotoChecks.luma(red: base[p], green: base[p + 1], blue: base[p + 2])
            }
        }
        return out
    }

    /// Pillow's `ImagingResample` for 8-bit images with the bilinear filter: horizontal pass,
    /// then vertical, 22-bit fixed-point weights, rounded to a byte between the passes.
    private static func resizeBilinear(_ source: [UInt8], width: Int, height: Int, toWidth outW: Int, height outH: Int) -> [UInt8] {
        let horizontal = coefficients(inSize: width, outSize: outW)
        var mid = [UInt8](repeating: 0, count: outW * height)
        for y in 0..<height {
            for x in 0..<outW {
                var acc = 1 << 21
                for (i, k) in horizontal[x].weights.enumerated() { acc += Int(source[y * width + horizontal[x].start + i]) * k }
                mid[y * outW + x] = UInt8(clamping: acc >> 22)
            }
        }
        let vertical = coefficients(inSize: height, outSize: outH)
        var out = [UInt8](repeating: 0, count: outW * outH)
        for y in 0..<outH {
            for x in 0..<outW {
                var acc = 1 << 21
                for (i, k) in vertical[y].weights.enumerated() { acc += Int(mid[(vertical[y].start + i) * outW + x]) * k }
                out[y * outW + x] = UInt8(clamping: acc >> 22)
            }
        }
        return out
    }

    private static func coefficients(inSize: Int, outSize: Int) -> [(start: Int, weights: [Int])] {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        return (0..<outSize).map { xx in
            let center = (Double(xx) + 0.5) * scale
            let start = max(Int(center - filterScale + 0.5), 0)
            let count = min(Int(center + filterScale + 0.5), inSize) - start
            let raw = (0..<count).map { x -> Double in
                let v = abs((Double(x + start) - center + 0.5) / filterScale)
                return v < 1 ? 1 - v : 0
            }
            let total = raw.reduce(0, +)
            let fixed = raw.map { Int(0.5 + (total == 0 ? $0 : $0 / total) * Double(1 << 22)) }
            return (start, fixed)
        }
    }
}

// MARK: - Writer

enum PacketError: Error, CustomStringConvertible {
    case folderNotEmpty(String)
    case invalidPhoto(id: String, reason: String)
    case invalidMesh(String)
    case timeNotIncreasing(stream: String, previous: Double, t: Double)
    case noPhotos

    var description: String {
        switch self {
        case .folderNotEmpty(let path): "packet folder \(path) already holds files; remove it first"
        case .invalidPhoto(let id, let reason): "photo \(id): \(reason)"
        case .invalidMesh(let reason): "lidar.mesh: \(reason)"
        case .timeNotIncreasing(let stream, let previous, let t): "streams.\(stream): time goes from \(previous) to \(t)"
        case .noPhotos: "a packet needs at least one photo"
        }
    }
}

struct PacketWriter: Sendable {
    let folder: URL
    let session: PacketSessionInfo
    private var photos: [(t: Double, entry: [String: any Sendable])] = []
    private var streams: [PacketStream: (text: String, rows: Int, lastT: Double)] = [:]
    private var rates: [PacketStream: Double] = [:]
    private var positions: [SIMD3<Float>] = []
    private var mesh: [String: any Sendable]?
    private var planes: [PacketPlane]?
    private var marks: [PacketMark]?
    private var guidance: [PacketGuidanceEntry]?
    private var scene: [String: any Sendable]?

    init(folder: URL, session: PacketSessionInfo) throws {
        let files = FileManager.default
        if files.fileExists(atPath: folder.path), !(try files.contentsOfDirectory(atPath: folder.path)).isEmpty {
            throw PacketError.folderNotEmpty(folder.path)
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        self.session = session
    }

    mutating func addPhoto(_ photo: PacketPhoto) throws {
        if photos.contains(where: { $0.t == photo.t }) { throw PacketError.invalidPhoto(id: photo.id, reason: "another photo has the same t") }
        try FileManager.default.createDirectory(at: folder.appending(path: "photos"), withIntermediateDirectories: true)
        let imagePath = "photos/\(photo.id).jpg"
        try FileManager.default.copyItem(at: photo.jpeg, to: folder.appending(path: imagePath))
        var entry: [String: any Sendable] = [
            "id": photo.id, "image": try fileRef(imagePath), "width": photo.width, "height": photo.height, "t": photo.t,
            "pose": Self.columnMajor(photo.pose), "intrinsics": [photo.intrinsics.x, photo.intrinsics.y, photo.intrinsics.z, photo.intrinsics.w].map(Self.num),
            "tracking": ["state": photo.tracking.state, "reason": Self.reason(photo.tracking)] as [String: any Sendable],
            "sharpness": ["method": PacketSharpness.method, "value": photo.sharpness] as [String: any Sendable],
        ]
        if let e = photo.exposure { entry["exposure"] = Self.compact(["duration_s": e.durationS, "iso": e.iso, "offset_ev": e.offsetEV]) }
        if let l = photo.lens { entry["lens"] = Self.compact(["focal_length_mm": l.focalLengthMM, "f_number": l.fNumber, "camera": l.camera]) }
        if let depth = photo.depth {
            var map = Data(capacity: depth.meters.count * 4)
            for value in depth.meters {
                let clean: Float = value.isFinite && value > 0 ? value : 0
                withUnsafeBytes(of: clean.bitPattern.littleEndian) { map.append(contentsOf: $0) }
            }
            var d: [String: any Sendable] = ["map": try write(map, to: "depth/\(photo.id).f32"), "width": depth.width, "height": depth.height, "source": depth.source.rawValue]
            if let confidence = depth.confidence { d["confidence"] = try write(Data(confidence), to: "depth/\(photo.id).conf.u8") }
            entry["depth"] = d
        }
        photos.append((photo.t, entry))
    }

    mutating func appendTrajectory(t: Double, tracking: PacketTracking, pose: simd_float4x4) throws {
        let p = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let rotation = simd_double3x3(
            SIMD3<Double>(Double(pose.columns.0.x), Double(pose.columns.0.y), Double(pose.columns.0.z)),
            SIMD3<Double>(Double(pose.columns.1.x), Double(pose.columns.1.y), Double(pose.columns.1.z)),
            SIMD3<Double>(Double(pose.columns.2.x), Double(pose.columns.2.y), Double(pose.columns.2.z))
        )
        var q = simd_quatd(rotation).vector
        q /= simd_length(q)
        if q.w < 0 { q = -q }
        let position = [p.x, p.y, p.z].map(\.description)
        let quaternion = [q.x, q.y, q.z, q.w].map { Float($0).description }
        try append(.trajectory, t, [tracking.state] + position + quaternion)
        positions.append(p)
    }

    mutating func appendAccelerometer(t: Double, g: SIMD3<Double>) throws {
        let a = g * PacketStream.standardGravity
        try append(.accelerometer, t, [a.x, a.y, a.z].map(\.description))
    }

    mutating func appendGyroscope(t: Double, radiansPerSecond r: SIMD3<Double>) throws {
        try append(.gyroscope, t, [r.x, r.y, r.z].map(\.description))
    }

    mutating func appendMagnetometer(t: Double, microtesla m: SIMD3<Double>) throws {
        try append(.magnetometer, t, [m.x, m.y, m.z].map(\.description))
    }

    mutating func appendDeviceMotion(_ s: DeviceMotionSample) throws {
        let values: [Double] = [
            s.attitude.x, s.attitude.y, s.attitude.z, s.attitude.w, s.gravity.x, s.gravity.y, s.gravity.z,
            s.userAcceleration.x, s.userAcceleration.y, s.userAcceleration.z, s.rotationRate.x, s.rotationRate.y, s.rotationRate.z, s.headingDegrees,
        ]
        try append(.deviceMotion, s.t, values.map(\.description))
    }

    mutating func appendBarometer(t: Double, pressureKPa: Double, relativeAltitudeM: Double) throws {
        try append(.barometer, t, [pressureKPa.description, relativeAltitudeM.description])
    }

    mutating func setNominalRate(_ hz: Double, for stream: PacketStream) throws {
        rates[stream] = hz
    }

    mutating func setMesh(_ mesh: TriangleMesh, classification: [UInt8]) throws {
        guard classification.count == mesh.triangleCount else { throw PacketError.invalidMesh("\(classification.count) classes for \(mesh.triangleCount) triangles") }
        let header = "ply\nformat binary_little_endian 1.0\nelement vertex \(mesh.vertices.count)\nproperty float x\nproperty float y\nproperty float z\n"
            + "element face \(mesh.triangleCount)\nproperty list uchar int vertex_indices\nproperty uchar classification\nend_header\n"
        var data = Data(header.utf8)
        for v in mesh.vertices {
            for c in [v.x, v.y, v.z] { withUnsafeBytes(of: c.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        }
        for face in 0..<mesh.triangleCount {
            data.append(3)
            for k in 0..<3 { withUnsafeBytes(of: Int32(mesh.indices[face * 3 + k]).littleEndian) { data.append(contentsOf: $0) } }
            data.append(classification[face])
        }
        self.mesh = try write(data, to: "lidar/mesh.ply")
    }

    mutating func setPlanes(_ planes: [PacketPlane]) throws { self.planes = planes }
    mutating func setMarks(_ marks: [PacketMark]) throws { self.marks = marks }
    mutating func setGuidance(_ entries: [PacketGuidanceEntry]) throws { guidance = entries }

    mutating func setScene(_ json: Data) throws {
        var ref = try write(json, to: "scene.json")
        if let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let version = object["schema_version"] as? String {
            ref["schema_version"] = version
        }
        scene = ref
    }

    @discardableResult
    func finish() throws -> URL {
        guard !photos.isEmpty else { throw PacketError.noPhotos }
        var streamRefs: [String: any Sendable] = [:]
        for stream in PacketStream.allCases {
            guard let csv = streams[stream], csv.rows > 0 else { continue }
            var ref = try write(Data(csv.text.utf8), to: stream.path)
            ref["rows"] = csv.rows
            if let rate = rates[stream] { ref["nominal_rate_hz"] = rate }
            streamRefs[stream.rawValue] = ref
        }
        var times = photos.map(\.t) + (marks ?? []).compactMap(\.t)
        times += (guidance ?? []).flatMap { [$0.tShown] + [$0.tResolved].compactMap { $0 } }
        if let last = streams[.trajectory]?.lastT { times.append(last) }
        var capture: [String: any Sendable] = ["started_at_uptime": session.startedAtUptime, "ended_at_uptime": times.max() ?? session.startedAtUptime]
        if let date = session.startedAt {
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            format.timeZone = .gmt
            capture["started_at"] = format.string(from: date)
        }
        if streams[.trajectory] != nil { capture["distance_walked_m"] = Self.horizontalDistance(positions) }
        let p = session.producer
        let d = session.device
        var anchor: [String: any Sendable] = ["pose_in_world": Self.columnMajor(session.meterFrame.meterInWorld)]
        anchor["ground_y_m"] = session.groundWorldY.map { Self.num($0 - session.meterFrame.meterInWorld.columns.3.y) }
        let sessionObject: [String: any Sendable] = [
            "id": session.id,
            "producer": Self.compact(["kind": p.kind.rawValue, "name": p.name, "version": p.version, "commit": p.commit]),
            "device": Self.compact(["model": d.model, "ios_version": d.iosVersion, "lidar": d.lidar, "scene_depth_enabled": d.sceneDepthEnabled, "mesh_enabled": d.meshEnabled]),
            "capture": capture, "world_alignment": "gravity", "meter_anchor": anchor,
        ]
        var manifest: [String: any Sendable] = ["packet_version": "1.0", "session": sessionObject, "photos": photos.sorted { $0.t < $1.t }.map(\.entry)]
        if !streamRefs.isEmpty { manifest["streams"] = streamRefs }
        var lidar: [String: any Sendable] = [:]
        if let mesh { lidar["mesh"] = mesh }
        if let planes { lidar["planes"] = planes.map(Self.planeObject) }
        if !lidar.isEmpty { manifest["lidar"] = lidar }
        if let marks { manifest["marks"] = marks.map(Self.markObject) }
        if let guidance { manifest["guidance"] = guidance.map(Self.guidanceObject) }
        if let scene { manifest["scene"] = scene }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder.appending(path: "manifest.json"), options: .atomic)
        return folder
    }

    // MARK: Internals

    private static func planeObject(_ plane: PacketPlane) -> [String: any Sendable] {
        compact([
            "id": plane.id, "alignment": plane.alignment.rawValue, "classification": plane.classification?.rawValue,
            "pose": columnMajor(plane.pose), "extent_m": [num(plane.extent.x), num(plane.extent.y)],
        ])
    }

    private static func markObject(_ m: PacketMark) -> [String: any Sendable] {
        let points: [[Double]] = m.points.map { [num($0.x), num($0.y), num($0.z)] }
        let attrs: [String: any Sendable]? = m.operable.map { ["operable": $0] }
        return compact([
            "id": m.id, "kind": m.kind.rawValue, "points": points, "t": m.t, "photo_ids": m.photoIDs,
            "side": m.side?.rawValue, "end_kind": m.endKind?.rawValue, "attrs": attrs,
        ])
    }

    private static func guidanceObject(_ g: PacketGuidanceEntry) -> [String: any Sendable] {
        let span: [Double]? = g.span.map { [num($0.lowerBound), num($0.upperBound)] }
        return compact([
            "id": g.id, "kind": g.kind.rawValue, "origin": g.origin.rawValue, "message": g.message, "band": g.band?.rawValue,
            "span_m": span, "t_shown": g.tShown, "t_resolved": g.tResolved, "outcome": g.outcome.rawValue,
        ])
    }

    private mutating func append(_ stream: PacketStream, _ t: Double, _ fields: [String]) throws {
        var csv = streams[stream] ?? (stream.columns.joined(separator: ",") + "\n", 0, -.infinity)
        guard t > csv.lastT else { throw PacketError.timeNotIncreasing(stream: stream.rawValue, previous: csv.lastT, t: t) }
        csv.text += ([t.description] + fields).joined(separator: ",") + "\n"
        csv.rows += 1
        csv.lastT = t
        streams[stream] = csv
    }

    private func write(_ data: Data, to path: String) throws -> [String: any Sendable] {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return ["path": path, "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }

    private func fileRef(_ path: String) throws -> [String: any Sendable] {
        let handle = try FileHandle(forReadingFrom: folder.appending(path: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += chunk.count
        }
        return ["path": path, "bytes": bytes, "sha256": hasher.finalize().map { String(format: "%02x", $0) }.joined()]
    }

    /// Leaves out the keys whose value is nil, as the package's encoder does.
    private static func compact(_ values: [String: (any Sendable)?]) -> [String: any Sendable] {
        values.compactMapValues { $0 }
    }

    private static func reason(_ tracking: PacketTracking) -> any Sendable {
        if case .limited(let reason?) = tracking { return reason.rawValue }
        return NSNull()
    }

    private static func num(_ value: Float) -> Double { Double(value.description) ?? Double(value) }

    private static func columnMajor(_ m: simd_float4x4) -> [Double] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }.map(num)
    }

    private static func horizontalDistance(_ positions: [SIMD3<Float>]) -> Double {
        zip(positions, positions.dropFirst()).reduce(0) { total, pair in
            let dx = Double(pair.1.x) - Double(pair.0.x)
            let dz = Double(pair.1.z) - Double(pair.0.z)
            return total + (dx * dx + dz * dz).squareRoot()
        }
    }
}
