import Foundation
import simd

// Files that go into the upload bundle beside scene.json for the reconstruction worker (recon/),
// which the server's scene schema does not describe:
//
//   depth/<keyframe id>.u16       uint16 little-endian millimeters, row-major, 0 = no reading
//   depth/<keyframe id>.conf.u8   uint8 per pixel, 0 low, 1 medium, 2 high
//   depth/index.json              {"units": "mm", "frames": [{"keyframe", "file", "confidence_file",
//                                  "w", "h", "intrinsics": [fx, fy, cx, cy]}]}
//   mesh.ply                      binary little-endian PLY in the scene frame, feet
//
// Each depth frame has the camera and pose of the keyframe with the same id in scene.json; its
// intrinsics are in pixels of the depth image.

public enum BundleFileError: Error, Equatable, CustomStringConvertible {
    /// A keyframe id that can't be a file name: empty, ".", "..", or holding "/" or "\".
    case unusableKeyframeID(String)

    public var description: String {
        switch self {
        case .unusableKeyframeID(let id): "keyframe id \"\(id)\" can't name a depth file"
        }
    }
}

public enum DepthBundle {
    public static let indexName = "depth/index.json"

    public static func depthName(keyframe id: String) -> String { "depth/\(id).u16" }
    public static func confidenceName(keyframe id: String) -> String { "depth/\(id).conf.u8" }

    /// One entry of depth/index.json (keys `keyframe`, `file`, `confidence_file`, `w`, `h`,
    /// `intrinsics`).
    public struct Frame: Sendable, Equatable, Codable {
        public var keyframe: String
        public var file: String
        /// Nil when the image has no confidence; written as JSON null.
        public var confidenceFile: String?
        public var width: Int
        public var height: Int
        /// [fx, fy, cx, cy] in pixels of the depth image.
        public var intrinsics: [Double]

        public init(keyframe: String, file: String, confidenceFile: String?, width: Int, height: Int, intrinsics: [Double]) {
            self.keyframe = keyframe
            self.file = file
            self.confidenceFile = confidenceFile
            self.width = width
            self.height = height
            self.intrinsics = intrinsics
        }

        enum CodingKeys: String, CodingKey {
            case keyframe, file, intrinsics
            case confidenceFile = "confidence_file"
            case width = "w"
            case height = "h"
        }

        // Written out by hand so a missing confidence file is an explicit null, not an absent key.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(keyframe, forKey: .keyframe)
            try container.encode(file, forKey: .file)
            try container.encode(confidenceFile, forKey: .confidenceFile)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(intrinsics, forKey: .intrinsics)
        }
    }

    /// The whole of depth/index.json.
    public struct Index: Sendable, Equatable, Codable {
        public var units: String
        public var frames: [Frame]

        public init(frames: [Frame]) {
            units = "mm"
            self.frames = frames
        }
    }

    /// `image`'s millimeters as uint16 little-endian, row-major.
    public static func depthData(_ image: DepthImage) -> Data {
        var data = Data(capacity: image.millimeters.count * 2)
        for value in image.millimeters {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }

    /// `image`'s confidence, one byte per pixel; nil when it has none.
    public static func confidenceData(_ image: DepthImage) -> Data? {
        image.confidence.map { Data($0) }
    }

    /// The zip entries of one keyframe's depth and its index.json entry.
    public static func files(keyframe id: String, image: DepthImage) throws(BundleFileError) -> (entries: [ZipEntry], frame: Frame) {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else { throw .unusableKeyframeID(id) }
        var entries = [ZipEntry(name: depthName(keyframe: id), data: depthData(image))]
        let confidence = confidenceData(image).map { ZipEntry(name: confidenceName(keyframe: id), data: $0) }
        if let confidence { entries.append(confidence) }
        let i = image.intrinsics
        let frame = Frame(
            keyframe: id, file: depthName(keyframe: id), confidenceFile: confidence?.name,
            width: image.width, height: image.height, intrinsics: [i.x, i.y, i.z, i.w].map(Double.init))
        return (entries, frame)
    }

    /// depth/index.json for `frames`, keys sorted.
    public static func indexEntry(_ frames: [Frame]) throws -> ZipEntry {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ZipEntry(name: indexName, data: try encoder.encode(Index(frames: frames)))
    }
}

public enum MeshPLY {
    public static let name = "mesh.ply"

    /// `mesh` as binary little-endian PLY in scene.json's frame: world meters shifted down by
    /// `groundY` (world meters) so the ground is at y = 0, then scaled to feet, the same shift and
    /// scale the export applies to keyframe poses. The caller passes the wall's ground.
    ///
    /// Vertices are `float x y z`; faces are `list uchar uint vertex_indices`, three each.
    public static func data(_ mesh: TriangleMesh, groundY: Float) -> Data {
        let header = """
        ply
        format binary_little_endian 1.0
        comment House Scan LiDAR mesh: feet, gravity-aligned scene frame, ground at y = 0
        element vertex \(mesh.vertices.count)
        property float x
        property float y
        property float z
        element face \(mesh.triangleCount)
        property list uchar uint vertex_indices
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + mesh.vertices.count * 12 + mesh.triangleCount * 13)
        let scale = Float(SceneUnits.feetPerMeter)
        func append(_ bits: UInt32) {
            withUnsafeBytes(of: bits.littleEndian) { data.append(contentsOf: $0) }
        }
        for vertex in mesh.vertices {
            let scene = (vertex - SIMD3(0, groundY, 0)) * scale
            append(scene.x.bitPattern)
            append(scene.y.bitPattern)
            append(scene.z.bitPattern)
        }
        var index = 0
        while index + 2 < mesh.indices.count {
            data.append(3)
            append(mesh.indices[index])
            append(mesh.indices[index + 1])
            append(mesh.indices[index + 2])
            index += 3
        }
        return data
    }
}
