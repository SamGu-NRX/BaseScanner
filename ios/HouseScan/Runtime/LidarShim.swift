import Foundation
import HouseScanKit
import simd

// LIDAR SHIM: DELETE THIS FILE AT MERGE.
//
// Stand-ins for the HouseScanKit types and functions the package lane is building in round 5, so
// the engine compiles and runs against the shared interface before they land. The engine calls
// only the names below. After deleting the file, three call sites change:
// - `CoverageMap.isHidden(_:_:)` (ScanEngine.swift, `cellState` and `hiddenBands`) becomes
//   `level(band, index) == .hidden`, and `ScanEngine.cell(_:)` gains `case .hidden: .hidden`.
// - `SceneExport.jsonData(_:facing:overheads:)` (ScanEngine+Export.swift) becomes whatever the
//   package's export takes for mesh measurements.
// - The `LidarBundle` encoders and decoders (KeyframeStore.swift, ReplayPlayer.swift) become the
//   package's.
// Everything here is a placeholder: depth is ignored by coverage, no cell is ever hidden, and the
// mesh measurements are empty. Only the bundle encoders produce real bytes.

/// Shared interface: one depth map, row-major, in landscape sensor orientation like the photo.
struct DepthImage: Sendable {
    var width: Int
    var height: Int
    /// 0 means no reading.
    var millimeters: [UInt16]
    /// 0 low, 1 medium, 2 high.
    var confidence: [UInt8]?
    /// fx, fy, cx, cy in pixels of this depth image.
    var intrinsics: SIMD4<Float>
}

extension CoverageMap {
    /// Shim: the package's `observe` takes `depth` and counts a sample only where depth confirms
    /// it. This one ignores depth.
    @discardableResult
    mutating func observe(_ camera: CameraFrame, trackingNormal: Bool, time: Double? = nil, depth: DepthImage?) -> Delta {
        observe(camera, trackingNormal: trackingNormal, time: time)
    }

    /// Shim: the package's `CoverageLevel` gains `.hidden`. Until then no cell is hidden.
    func isHidden(_ band: SurfaceBand, _ index: Int) -> Bool { false }
}

/// Shared interface: a triangle mesh in world meters.
struct TriangleMesh: Sendable {
    var vertices: [SIMD3<Float>]
    /// Three per triangle.
    var indices: [UInt32]
}

/// Shim: the package's function measures the gap from the wall out to the mesh over `span`.
func facingDepth(_ mesh: TriangleMesh, wall: WallFrame, over span: ClosedRange<Float>) -> [ObservedSpan] { [] }

/// Shim: the package's function measures the clear height under the mesh over `span`.
func overheadClearance(_ mesh: TriangleMesh, wall: WallFrame, over span: ClosedRange<Float>) -> [ObservedSpan] { [] }

extension SceneExport {
    /// Shim: the package's export writes `facing` (depth_ft) and `overheads` (clearance_ft)
    /// entries from mesh measurements. This one drops them.
    static func jsonData(_ input: SceneInput, facing: [ObservedSpan], overheads: [ObservedSpan]) throws -> Data {
        try jsonData(input)
    }
}

/// Shim for the package's encoders and decoders of the files beside scene.json.
enum LidarBundle {
    /// One entry of depth/index.json.
    struct DepthEntry: Codable, Sendable, Equatable {
        var keyframe: String
        /// Path inside the bundle (a guess the package settles: relative to the bundle root, like
        /// scene.json's `img`).
        var file: String
        var confidenceFile: String?
        var w: Int
        var h: Int
        var intrinsics: [Float]

        enum CodingKeys: String, CodingKey {
            case keyframe, file, w, h, intrinsics
            case confidenceFile = "confidence_file"
        }
    }

    private struct DepthIndex: Codable {
        var units: String
        var frames: [DepthEntry]
    }

    enum DecodeError: Error, CustomStringConvertible {
        case wrongUnits(String)
        case wrongSize(file: String, expected: Int, actual: Int)

        var description: String {
            switch self {
            case .wrongUnits(let units): "depth/index.json has units \"\(units)\", expected \"mm\""
            case .wrongSize(let file, let expected, let actual): "\(file) has \(actual) bytes, expected \(expected)"
            }
        }
    }

    static func millimetersData(_ image: DepthImage) -> Data {
        var data = Data(capacity: image.millimeters.count * 2)
        for value in image.millimeters { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func confidenceData(_ image: DepthImage) -> Data? {
        image.confidence.map { Data($0) }
    }

    static func depthIndex(_ frames: [DepthEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(DepthIndex(units: "mm", frames: frames))
    }

    static func decodeDepthIndex(_ data: Data) throws -> [DepthEntry] {
        let index = try JSONDecoder().decode(DepthIndex.self, from: data)
        guard index.units == "mm" else { throw DecodeError.wrongUnits(index.units) }
        return index.frames
    }

    static func depthImage(_ entry: DepthEntry, millimeters: Data, confidence: Data?) throws -> DepthImage {
        let count = entry.w * entry.h
        guard millimeters.count == count * 2 else { throw DecodeError.wrongSize(file: entry.file, expected: count * 2, actual: millimeters.count) }
        if let confidence, confidence.count != count {
            throw DecodeError.wrongSize(file: entry.confidenceFile ?? "", expected: count, actual: confidence.count)
        }
        let values = millimeters.withUnsafeBytes { raw in
            (0..<count).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)) }
        }
        let i = entry.intrinsics
        return DepthImage(
            width: entry.w, height: entry.h, millimeters: values, confidence: confidence.map { [UInt8]($0) },
            intrinsics: i.count == 4 ? SIMD4(i[0], i[1], i[2], i[3]) : .zero
        )
    }

    /// binary_little_endian 1.0 PLY: float x y z per vertex, uchar-counted uint indices per face.
    static func ply(_ mesh: TriangleMesh) -> Data {
        let faces = mesh.indices.count / 3
        let header = """
        ply
        format binary_little_endian 1.0
        element vertex \(mesh.vertices.count)
        property float x
        property float y
        property float z
        element face \(faces)
        property list uchar uint vertex_indices
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + mesh.vertices.count * 12 + faces * 13)
        for v in mesh.vertices {
            for c in [v.x, v.y, v.z] { withUnsafeBytes(of: c.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        }
        for face in 0..<faces {
            data.append(3)
            for k in 0..<3 { withUnsafeBytes(of: mesh.indices[face * 3 + k].littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }
}
