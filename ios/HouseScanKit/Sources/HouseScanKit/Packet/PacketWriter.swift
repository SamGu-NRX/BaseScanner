import Foundation
import ImageIO
import simd

/// What the session section of the manifest needs from the app, read once at session start.
public struct PacketSessionInfo: Sendable {
    /// Unique per scan; letters, digits, '_' or '-' keep it usable as a folder name.
    public var id: String
    public var producer: PacketManifest.Producer
    public var device: PacketManifest.Device
    /// Wall clock at `startedAtUptime`; written as ISO 8601 UTC.
    public var startedAt: Date?
    /// Device uptime (`ARFrame.timestamp`'s clock) at the first frame.
    public var startedAtUptime: Double
    public var meterFrame: MeterFrame
    /// World y of the ground in front of the wall at the meter, meters (`SceneWall.groundY`).
    /// Written as `ground_y_m`, the ground on the meter frame's y.
    public var groundWorldY: Float?

    public init(
        id: String, producer: PacketManifest.Producer, device: PacketManifest.Device, startedAt: Date?,
        startedAtUptime: Double, meterFrame: MeterFrame, groundWorldY: Float?
    ) {
        self.id = id
        self.producer = producer
        self.device = device
        self.startedAt = startedAt
        self.startedAtUptime = startedAtUptime
        self.meterFrame = meterFrame
        self.groundWorldY = groundWorldY
    }
}

/// One photo for the packet. The JPEG is copied in unchanged, so it must already be what the
/// packet stores: the sensor's landscape image, unrotated, EXIF orientation absent or 1, with
/// `intrinsics` in its pixels.
public struct PacketPhoto: Sendable {
    /// The manifest id and file stem; `PacketPhoto.id(number:)` gives the spec's p00001 form.
    public var id: String
    public var jpeg: URL
    public var width: Int
    public var height: Int
    /// `ARFrame.timestamp`.
    public var t: Double
    /// Camera to meter frame (`MeterFrame.pose(_:)` of `ARFrame.camera.transform`).
    public var pose: simd_float4x4
    /// [fx, fy, cx, cy] in pixels of the stored JPEG.
    public var intrinsics: SIMD4<Float>
    public var tracking: PacketTracking
    public var exposure: PacketExposure?
    public var lens: PacketLens?
    /// `PacketSharpness.laplacianVarianceLuma640` of the JPEG's luma.
    public var sharpness: Double
    public var depth: DepthPacket?

    public init(
        id: String, jpeg: URL, width: Int, height: Int, t: Double, pose: simd_float4x4, intrinsics: SIMD4<Float>,
        tracking: PacketTracking, exposure: PacketExposure? = nil, lens: PacketLens? = nil, sharpness: Double,
        depth: DepthPacket? = nil
    ) {
        self.id = id
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.t = t
        self.pose = pose
        self.intrinsics = intrinsics
        self.tracking = tracking
        self.exposure = exposure
        self.lens = lens
        self.sharpness = sharpness
        self.depth = depth
    }

    /// "p00001" for 1: the packet's photo naming, five digits.
    public static func id(number: Int) -> String {
        let digits = String(number)
        return "p" + String(repeating: "0", count: max(0, 5 - digits.count)) + digits
    }
}

/// A depth map aligned to its photo: same field of view, lower resolution, the photo's aspect to
/// 1%. Meters along the camera's -z (z-depth, as ARKit's `sceneDepth`), row by row from the top.
public struct DepthPacket: Sendable {
    public enum Source: String, Codable, Sendable {
        case arkitSceneDepth = "arkit_scene_depth"
        case arkitSmoothedSceneDepth = "arkit_smoothed_scene_depth"
        case renderedFromLaserScan = "rendered_from_laser_scan"
    }

    /// A value that is not finite or is negative is written as 0, the packet's "no measurement",
    /// as `DepthImage.init(meters:)` treats them.
    public var meters: [Float]
    public var width: Int
    public var height: Int
    /// ARConfidenceLevel per pixel: 0 low, 1 medium, 2 high.
    public var confidence: [UInt8]?
    public var source: Source

    public init(meters: [Float], width: Int, height: Int, confidence: [UInt8]?, source: Source) {
        self.meters = meters
        self.width = width
        self.height = height
        self.confidence = confidence
        self.source = source
    }
}

/// Writes a capture packet 1.0 folder (packet/README.md on t3/packet): photos, depth and the mesh
/// go to disk as they are added; streams are held as CSV text; `finish()` writes the streams,
/// scene.json's entry and manifest.json with every file's size and SHA-256.
///
/// Each input is checked against the rules packet/validate.py applies to it, and refused with a
/// `PacketError` naming the field, so a finished packet validates. Nothing here sends the packet
/// anywhere: photos leave the phone only when the homeowner shares the folder.
public struct PacketWriter: Sendable {
    public let folder: URL
    public let session: PacketSessionInfo
    private var photos: [PacketManifest.Photo] = []
    private var streams: [PacketStream: PacketCSV] = [:]
    private var nominalRates: [PacketStream: Double] = [:]
    private var trajectoryPositions: [SIMD3<Float>] = []
    private var mesh: PacketManifest.File?
    private var planes: [PacketPlane]?
    private var marks: [PacketMark]?
    private var guidance: [PacketGuidanceEntry]?
    private var scene: PacketManifest.SceneFile?

    /// Creates `folder` (and its parents). Refuses a folder that already holds files, so a stale
    /// packet's photos never end up in a new one; the caller removes it first.
    public init(folder: URL, session: PacketSessionInfo) throws {
        guard Self.isValidID(session.id) else { throw PacketError.invalidID(session.id) }
        guard session.startedAtUptime.isFinite, session.startedAtUptime >= 0 else {
            throw PacketError.invalidTime(where: "session.capture.started_at_uptime", t: session.startedAtUptime)
        }
        if let ground = session.groundWorldY, !ground.isFinite { throw PacketError.nonFiniteValue(where: "session.meter_anchor.ground_y_m") }
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path), !(try fm.contentsOfDirectory(atPath: folder.path)).isEmpty {
            throw PacketError.folderNotEmpty(folder.path)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        self.session = session
    }

    // MARK: Photos

    /// Copies the JPEG to photos/<id>.jpg and, with depth, writes depth/<id>.f32 and
    /// depth/<id>.conf.u8. Photos may be added in any order; the manifest lists them by `t`.
    public mutating func addPhoto(_ photo: PacketPhoto) throws {
        let id = photo.id
        guard Self.isValidID(id) else { throw PacketError.invalidID(id) }
        guard !photos.contains(where: { $0.id == id }) else { throw PacketError.duplicateID(id) }
        try checkTime(photo.t, "photo \(id)")
        if photos.contains(where: { $0.t == photo.t }) {
            throw PacketError.invalidPhoto(id: id, reason: "another photo has the same t \(photo.t)")
        }
        guard PacketPose.isRigid(photo.pose) else { throw PacketError.notRigid("photo \(id)") }
        guard photo.sharpness.isFinite, photo.sharpness >= 0 else {
            throw PacketError.invalidPhoto(id: id, reason: "sharpness \(photo.sharpness) must be finite and >= 0")
        }
        if let problem = Self.intrinsicsProblem(photo.intrinsics, width: photo.width, height: photo.height) {
            throw PacketError.invalidPhoto(id: id, reason: problem)
        }
        if let problem = Self.jpegProblem(photo.jpeg, width: photo.width, height: photo.height) {
            throw PacketError.invalidPhoto(id: id, reason: problem)
        }
        if let exposure = photo.exposure, let problem = Self.exposureProblem(exposure) {
            throw PacketError.invalidPhoto(id: id, reason: problem)
        }
        if let lens = photo.lens, let problem = Self.lensProblem(lens) {
            throw PacketError.invalidPhoto(id: id, reason: problem)
        }
        // Depth is checked before anything is written, so a refused photo leaves no files.
        let depth = try photo.depth.map { depth throws(PacketError) in try Self.checkedDepth(depth, photo: photo) }
        let image = try PacketFiles.copy(photo.jpeg, to: "photos/\(id).jpg", in: folder)
        var entry = PacketManifest.Photo(
            id: id, image: image, width: photo.width, height: photo.height, t: photo.t,
            pose: PacketPose.columnMajor(photo.pose),
            intrinsics: [photo.intrinsics.x, photo.intrinsics.y, photo.intrinsics.z, photo.intrinsics.w].map(PacketNumber.double),
            tracking: photo.tracking.manifest, exposure: photo.exposure, lens: photo.lens,
            sharpness: .init(method: PacketSharpness.method, value: photo.sharpness), depth: nil)
        if let depth {
            let map = try PacketFiles.write(PacketFiles.depthData(meters: depth.meters), to: "depth/\(id).f32", in: folder)
            let confidence = try depth.confidence.map { try PacketFiles.write(Data($0), to: "depth/\(id).conf.u8", in: folder) }
            entry.depth = .init(map: map, confidence: confidence, width: depth.width, height: depth.height, source: depth.source)
        }
        photos.append(entry)
    }

    // MARK: Streams

    /// One trajectory row per ARFrame: `pose` is camera to meter frame.
    public mutating func appendTrajectory(t: Double, tracking: PacketTracking, pose: simd_float4x4) throws {
        guard PacketPose.isRigid(pose) else { throw PacketError.notRigid("streams.trajectory at t = \(t)") }
        let p = PacketPose.translation(pose)
        let q = PacketPose.quaternion(PacketPose.rotation(pose))
        let fields = [tracking.state] + [p.x, p.y, p.z].map(PacketNumber.csv) + [q.x, q.y, q.z, q.w].map { PacketNumber.csv(Float($0)) }
        try append(.trajectory) { (csv: inout PacketCSV) throws(PacketError) in try csv.append(t: t, fields) }
        trajectoryPositions.append(p)
    }

    /// `CMAccelerometerData.acceleration`, in g as Core Motion reports it; written in m/s².
    public mutating func appendAccelerometer(t: Double, g: SIMD3<Double>) throws {
        let a = g * PacketStream.standardGravity
        try append(.accelerometer) { (csv: inout PacketCSV) throws(PacketError) in try csv.append(t: t, values: [a.x, a.y, a.z]) }
    }

    /// `CMGyroData.rotationRate`, rad/s.
    public mutating func appendGyroscope(t: Double, radiansPerSecond r: SIMD3<Double>) throws {
        try append(.gyroscope) { (csv: inout PacketCSV) throws(PacketError) in try csv.append(t: t, values: [r.x, r.y, r.z]) }
    }

    /// `CMMagnetometerData.magneticField`, microtesla, uncalibrated.
    public mutating func appendMagnetometer(t: Double, microtesla m: SIMD3<Double>) throws {
        try append(.magnetometer) { (csv: inout PacketCSV) throws(PacketError) in try csv.append(t: t, values: [m.x, m.y, m.z]) }
    }

    public mutating func appendDeviceMotion(_ s: DeviceMotionSample) throws {
        let values: [Double] = [
            s.attitude.x, s.attitude.y, s.attitude.z, s.attitude.w,
            s.gravity.x, s.gravity.y, s.gravity.z,
            s.userAcceleration.x, s.userAcceleration.y, s.userAcceleration.z,
            s.rotationRate.x, s.rotationRate.y, s.rotationRate.z, s.headingDegrees,
        ]
        try append(.deviceMotion) { (csv: inout PacketCSV) throws(PacketError) in try csv.append(t: s.t, values: values) }
    }

    /// `CMAltitudeData`: pressure in kPa, relative altitude in meters.
    public mutating func appendBarometer(t: Double, pressureKPa: Double, relativeAltitudeM: Double) throws {
        try append(.barometer) { (csv: inout PacketCSV) throws(PacketError) in try csv.append(t: t, values: [pressureKPa, relativeAltitudeM]) }
    }

    /// The stream's `nominal_rate_hz`, the rate the sensor was asked for (60 for ARKit frames, the
    /// Core Motion update interval's inverse). Left out of the manifest when never set.
    public mutating func setNominalRate(_ hz: Double, for stream: PacketStream) throws {
        guard hz.isFinite, hz > 0 else { throw PacketError.nonFiniteValue(where: "streams.\(stream.rawValue).nominal_rate_hz \(hz)") }
        nominalRates[stream] = hz
    }

    private mutating func append(_ stream: PacketStream, _ body: (inout PacketCSV) throws(PacketError) -> Void) throws(PacketError) {
        var csv = streams[stream] ?? PacketCSV(stream)
        try body(&csv)
        streams[stream] = csv
    }

    // MARK: LiDAR, marks, guidance, scene

    /// Writes lidar/mesh.ply. `mesh` must be in the meter frame (`MeterFrame.mesh(_:)`), with one
    /// ARMeshClassification raw value per triangle.
    public mutating func setMesh(_ mesh: TriangleMesh, classification: [UInt8]) throws {
        let data = try PacketFiles.meshPLY(mesh, classification: classification)
        self.mesh = try PacketFiles.write(data, to: "lidar/mesh.ply", in: folder)
    }

    public mutating func setPlanes(_ planes: [PacketPlane]) throws {
        try Self.checkUnique(planes.map(\.id))
        for plane in planes {
            if let problem = plane.problem() { throw PacketError.invalidPlane(id: plane.id, reason: problem) }
        }
        self.planes = planes
    }

    /// Marks' `photo_ids` must name photos in the packet by the time of `finish()`.
    public mutating func setMarks(_ marks: [PacketMark]) throws {
        try Self.checkUnique(marks.map(\.id))
        for mark in marks {
            if let problem = mark.problem() { throw PacketError.invalidMark(id: mark.id, reason: problem) }
            if let t = mark.t { try checkTime(t, "mark \(mark.id)") }
        }
        self.marks = marks
    }

    public mutating func setGuidance(_ entries: [PacketGuidanceEntry]) throws {
        try Self.checkUnique(entries.map(\.id))
        for entry in entries {
            try checkTime(entry.tShown, "guidance \(entry.id)")
            if let problem = entry.problem() { throw PacketError.invalidGuidance(id: entry.id, reason: problem) }
        }
        guidance = entries
    }

    /// Writes scene.json exactly as given (`SceneExport.jsonData`), noting its schema_version.
    public mutating func setScene(_ json: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw PacketError.invalidScene("not a JSON object")
        }
        let version = object["schema_version"] as? String
        let file = try PacketFiles.write(json, to: "scene.json", in: folder)
        scene = .init(path: file.path, bytes: file.bytes, sha256: file.sha256, schemaVersion: version)
    }

    // MARK: Finish

    /// The manifest of everything added so far. `ended_at_uptime` is the latest time the packet
    /// holds (the last trajectory row, photo, mark or guidance time), and `distance_walked_m` the
    /// trajectory's horizontal length.
    public func manifest() throws -> PacketManifest {
        guard !photos.isEmpty else { throw PacketError.noPhotos }
        let photoIDs = Set(photos.map(\.id))
        for mark in marks ?? [] {
            if let missing = mark.photoIDs?.first(where: { !photoIDs.contains($0) }) {
                throw PacketError.invalidMark(id: mark.id, reason: "photo_ids names \(missing), which is not a photo in the packet")
            }
        }
        var times = photos.map(\.t) + (marks ?? []).compactMap(\.t)
        times += (guidance ?? []).flatMap { [$0.tShown] + [$0.tResolved].compactMap { $0 } }
        if let last = streams[.trajectory]?.lastT { times.append(last) }
        let start = session.startedAtUptime
        guard let end = times.max(), end > start else {
            throw PacketError.invalidSession("nothing in the packet is later than started_at_uptime \(start)")
        }

        var streamRefs = PacketManifest.Streams()
        for stream in PacketStream.allCases {
            guard let csv = streams[stream], csv.rows > 0 else { continue }
            let data = csv.data
            streamRefs[stream] = .init(
                path: stream.path, bytes: data.count, sha256: PacketFiles.sha256(data), rows: csv.rows,
                nominalRateHz: nominalRates[stream])
        }
        let anchorY = session.meterFrame.meterInWorld.columns.3.y
        let lidar = mesh == nil && planes == nil ? nil : PacketManifest.Lidar(mesh: mesh, planes: planes)
        return PacketManifest(
            packetVersion: PacketManifest.version,
            session: .init(
                id: session.id, producer: session.producer, device: session.device,
                capture: .init(
                    startedAt: session.startedAt.map(Self.iso8601), startedAtUptime: start, endedAtUptime: end,
                    distanceWalkedM: streams[.trajectory] == nil ? nil : PacketPose.horizontalDistance(trajectoryPositions)),
                worldAlignment: "gravity",
                meterAnchor: .init(
                    poseInWorld: PacketPose.columnMajor(session.meterFrame.meterInWorld),
                    groundYM: session.groundWorldY.map { PacketNumber.double($0 - anchorY) }),
                consent: nil),
            photos: photos.sorted { $0.t < $1.t },
            streams: streamRefs == PacketManifest.Streams() ? nil : streamRefs,
            lidar: lidar, marks: marks, guidance: guidance, scene: scene, provenance: nil)
    }

    /// Writes the stream CSVs and manifest.json and returns the packet folder.
    @discardableResult
    public func finish() throws -> URL {
        let manifest = try manifest()
        for stream in PacketStream.allCases {
            guard let csv = streams[stream], csv.rows > 0 else { continue }
            _ = try PacketFiles.write(csv.data, to: stream.path, in: folder)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        return folder
    }

    // MARK: Checks

    /// The schema's photo id pattern, ^[A-Za-z0-9_-]+$, which also keeps ids safe as file stems.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    private static func checkUnique(_ ids: [String]) throws(PacketError) {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted { throw .duplicateID(id) }
    }

    private func checkTime(_ t: Double, _ place: String) throws(PacketError) {
        guard t.isFinite, t >= 0 else { throw .invalidTime(where: place, t: t) }
        guard t >= session.startedAtUptime else { throw .timeBeforeStart(where: place, t: t, start: session.startedAtUptime) }
    }

    /// validate.py's `intrinsics_problems`: landscape, principal point inside, square pixels to
    /// 5%, horizontal field of view 20 to 150 degrees.
    static func intrinsicsProblem(_ k: SIMD4<Float>, width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return "size \(width)x\(height) is empty" }
        guard width > height else { return "\(width)x\(height) is not landscape; store the unrotated sensor image" }
        guard k.x > 0, k.y > 0, k.x.isFinite, k.y.isFinite else { return "focal lengths \(k.x), \(k.y) must be positive" }
        guard k.z > 0, k.z < Float(width), k.w > 0, k.w < Float(height) else { return "principal point (\(k.z), \(k.w)) is outside the image" }
        guard abs(k.x / k.y - 1) <= 0.05 else { return "fx/fy = \(k.x / k.y); the intrinsics may belong to a rotated image" }
        let fov = 2 * atan(Double(width) / (2 * Double(k.x))) * 180 / .pi
        guard (20...150).contains(fov) else { return "horizontal field of view \(fov) degrees does not fit a \(width) px image" }
        return nil
    }

    /// The stored JPEG must be the size the manifest says and unrotated.
    static func jpegProblem(_ url: URL, width: Int, height: Int) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return "\(url.lastPathComponent) cannot be read as an image" }
        guard type == "public.jpeg" else { return "\(url.lastPathComponent) is \(type), not JPEG" }
        let w = properties[kCGImagePropertyPixelWidth] as? Int
        let h = properties[kCGImagePropertyPixelHeight] as? Int
        guard w == width, h == height else { return "the JPEG is \(w ?? 0)x\(h ?? 0), not \(width)x\(height)" }
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            return "EXIF orientation \(orientation); store the unrotated sensor image"
        }
        return nil
    }

    static func exposureProblem(_ e: PacketExposure) -> String? {
        if let d = e.durationS, !(d > 0 && d.isFinite) { return "exposure duration \(d) must be positive" }
        if let iso = e.iso, !(iso > 0 && iso.isFinite) { return "ISO \(iso) must be positive" }
        if let offset = e.offsetEV, !offset.isFinite { return "exposure offset must be finite" }
        return nil
    }

    static func lensProblem(_ lens: PacketLens) -> String? {
        if let f = lens.focalLengthMM, !(f > 0 && f.isFinite) { return "focal length \(f) mm must be positive" }
        if let n = lens.fNumber, !(n > 0 && n.isFinite) { return "f-number \(n) must be positive" }
        return nil
    }

    /// validate.py's `depth_problems`, with non-finite and negative values made 0.
    static func checkedDepth(_ depth: DepthPacket, photo: PacketPhoto) throws(PacketError) -> DepthPacket {
        let id = photo.id
        let (w, h) = (depth.width, depth.height)
        guard w > 0, h > 0, depth.meters.count == w * h else {
            throw .invalidDepth(id: id, reason: "\(depth.meters.count) values for \(w)x\(h)")
        }
        guard w <= photo.width, h <= photo.height else {
            throw .invalidDepth(id: id, reason: "\(w)x\(h) is larger than the \(photo.width)x\(photo.height) photo")
        }
        let aspect = (Double(w) / Double(h)) / (Double(photo.width) / Double(photo.height))
        guard abs(aspect - 1) <= 0.01 else {
            throw .invalidDepth(id: id, reason: "\(w)x\(h) does not have the \(photo.width)x\(photo.height) photo's aspect")
        }
        if let confidence = depth.confidence {
            guard confidence.count == w * h else { throw .invalidDepth(id: id, reason: "\(confidence.count) confidence values for \(w)x\(h)") }
            guard confidence.allSatisfy({ $0 <= 2 }) else { throw .invalidDepth(id: id, reason: "confidence must be 0, 1 or 2") }
        }
        var cleaned = depth
        cleaned.meters = depth.meters.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        // The validator calls a map with under 1% of pixels measured empty.
        let measured = cleaned.meters.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        guard Double(measured) >= 0.01 * Double(w * h) else {
            throw .invalidDepth(id: id, reason: "\(measured) of \(w * h) pixels measured; under 1% is empty, leave the depth out")
        }
        return cleaned
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
