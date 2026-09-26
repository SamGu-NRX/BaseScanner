import Foundation
import HouseScanKit
import simd
import Testing

// Depth read from Measure Lab replays, and the depth and mesh files written beside scene.json.
@Suite struct DepthFilesTests {
    /// One keyframe with a 4 x 2 JPEG and 2 x 2 depth: x scales by 0.5 and y by 1.
    static let frameJSON = """
    [{"id": "k1", "img": "keyframes/k1.jpg", "w": 4, "h": 2, "intrinsics": [4, 6, 2, 1],
      "pose": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1], "timestamp": 1, "tracking": "normal",
      "depth": {"file": "keyframes/k1.depth.f32", "confidenceFile": "keyframes/k1.confidence.u8", "w": 2, "h": 2}}]
    """

    static func frame() throws -> ReplayFrame {
        try #require(ReplaySession.decode(sessionJSON: ReplaySessionTests.session(keyframes: frameJSON)).frames.first)
    }

    static func float32(_ values: [Float]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// Meters become rounded millimeters; negative, NaN and over-65.535 m values become 0.
    static let meters: [Float] = [1.2346, -1, .nan, 70]

    @Test func measureLabDepthDecodesToMillimeters() throws {
        let frame = try Self.frame()
        let file = try #require(frame.depth)
        #expect(file.file == "keyframes/k1.depth.f32")
        #expect(file.confidenceFile == "keyframes/k1.confidence.u8")
        #expect(file.width == 2 && file.height == 2)
        let image = try ReplaySession.depthImage(for: frame, depth: Self.float32(Self.meters), confidence: Data([2, 1, 0, 2]))
        #expect(image.width == 2 && image.height == 2)
        #expect(image.millimeters == [1235, 0, 0, 0])
        #expect(image.confidence == [2, 1, 0, 2])
        #expect(image.intrinsics == SIMD4(2, 6, 1, 1))
    }

    @Test func wrongByteCountsAreRefused() throws {
        let frame = try Self.frame()
        #expect(throws: ReplayError.badDepth(frameID: "k1", reason: "depth has 12 bytes, expected 16 for 2 x 2 Float32")) {
            try ReplaySession.depthImage(for: frame, depth: Self.float32([1, 2, 3]), confidence: nil)
        }
        #expect(throws: ReplayError.badDepth(frameID: "k1", reason: "confidence has 3 bytes, expected 4")) {
            try ReplaySession.depthImage(for: frame, depth: Self.float32([1, 2, 3, 4]), confidence: Data([0, 1, 2]))
        }
    }

    @Test func loadsDepthFromTheSessionFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("depth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keyframes"), withIntermediateDirectories: true)
        try Self.float32([1, 2, 3, 4]).write(to: folder.appendingPathComponent("keyframes/k1.depth.f32"))
        try Data([2, 2, 1, 0]).write(to: folder.appendingPathComponent("keyframes/k1.confidence.u8"))
        let image = try #require(try ReplaySession.loadDepth(for: Self.frame(), folder: folder))
        #expect(image.millimeters == [1000, 2000, 3000, 4000])
        #expect(image.confidence == [2, 2, 1, 0])
    }

    @Test func frameWithoutDepthHasNone() throws {
        let json = Self.frameJSON.replacingOccurrences(
            of: #"{"file": "keyframes/k1.depth.f32", "confidenceFile": "keyframes/k1.confidence.u8", "w": 2, "h": 2}"#, with: "null")
        let frame = try #require(ReplaySession.decode(sessionJSON: ReplaySessionTests.session(keyframes: json)).frames.first)
        #expect(frame.depth == nil)
        #expect(try ReplaySession.loadDepth(for: frame, folder: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    // MARK: Bundle files

    static let image = DepthImage(
        width: 2, height: 2, millimeters: [0x0102, 0xFFFF, 0, 1500], confidence: [0, 1, 2, 2], intrinsics: SIMD4(200, 201, 128, 96))

    static func decodeU16(_ data: Data) -> [UInt16] {
        stride(from: 0, to: data.count, by: 2).map { UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8 }
    }

    @Test func depthBytesAreLittleEndianMillimeters() {
        let data = DepthBundle.depthData(Self.image)
        #expect([UInt8](data) == [0x02, 0x01, 0xFF, 0xFF, 0x00, 0x00, 0xDC, 0x05])
        #expect(Self.decodeU16(data) == Self.image.millimeters)
        #expect(DepthBundle.confidenceData(Self.image) == Data([0, 1, 2, 2]))
    }

    @Test func keyframeFilesAndIndexRoundTrip() throws {
        let (entries, frame) = try DepthBundle.files(keyframe: "k00001", image: Self.image)
        #expect(entries.map(\.name) == ["depth/k00001.u16", "depth/k00001.conf.u8"])
        #expect(frame == DepthBundle.Frame(
            keyframe: "k00001", file: "depth/k00001.u16", confidenceFile: "depth/k00001.conf.u8", width: 2, height: 2,
            intrinsics: [200, 201, 128, 96]))

        let bare = DepthImage(width: 1, height: 1, millimeters: [7], confidence: nil, intrinsics: SIMD4(1, 1, 0.5, 0.5))
        let (bareEntries, bareFrame) = try DepthBundle.files(keyframe: "k2", image: bare)
        #expect(bareEntries.map(\.name) == ["depth/k2.u16"])
        #expect(bareFrame.confidenceFile == nil)

        let index = try DepthBundle.indexEntry([frame, bareFrame])
        #expect(index.name == "depth/index.json")
        let text = String(decoding: index.data, as: UTF8.self)
        #expect(text.contains(#""units":"mm""#))
        #expect(text.contains(#""confidence_file":null"#))
        #expect(text.contains(#""w":2"#))
        let decoded = try JSONDecoder().decode(DepthBundle.Index.self, from: index.data)
        #expect(decoded == DepthBundle.Index(frames: [frame, bareFrame]))
    }

    @Test(arguments: ["", ".", "..", "a/b", #"a\b"#])
    func unusableKeyframeIDsAreRefused(id: String) {
        #expect(throws: BundleFileError.unusableKeyframeID(id)) { try DepthBundle.files(keyframe: id, image: Self.image) }
    }

    /// Vertices in world meters with the ground at y = 1: shifted down by 1 m and scaled to feet,
    /// (0.3048, 1.3048, 0) is (1, 1, 0) ft and (0.6096, 1, -0.3048) is (2, 0, -1) ft.
    @Test func plyIsInSceneFeetWithTheGroundAtZero() throws {
        let mesh = TriangleMesh(
            vertices: [SIMD3(0.3048, 1.3048, 0), SIMD3(0.6096, 1, -0.3048), SIMD3(0, 1, 0)], indices: [0, 1, 2, 2, 1, 0])
        let data = MeshPLY.data(mesh, groundY: 1)
        let marker = Data("end_header\n".utf8)
        let end = try #require(data.range(of: marker)).upperBound
        let header = String(decoding: data[..<end], as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(header == [
            "ply", "format binary_little_endian 1.0",
            "comment House Scan LiDAR mesh: feet, gravity-aligned scene frame, ground at y = 0",
            "element vertex 3", "property float x", "property float y", "property float z",
            "element face 2", "property list uchar uint vertex_indices", "end_header",
        ])
        let body = [UInt8](data[end...])
        #expect(body.count == 3 * 12 + 2 * 13)
        func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(body[offset + $1]) << (8 * $1) } }
        let floats = (0..<9).map { Float(bitPattern: u32($0 * 4)) }
        let expected: [Float] = [1, 1, 0, 2, 0, -1, 0, 0, 0]
        for (a, e) in zip(floats, expected) { #expect(nearlyEqual(a, e, 1e-5), "\(floats)") }
        #expect(body[36] == 3)
        #expect([u32(37), u32(41), u32(45)] == [0, 1, 2])
        #expect(body[49] == 3)
        #expect([u32(50), u32(54), u32(58)] == [2, 1, 0])
    }
}
