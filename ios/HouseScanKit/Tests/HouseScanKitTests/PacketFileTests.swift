import Foundation
@testable import HouseScanKit
import simd
import Testing

/// Splits CSV text with a header row into its header and rows (the packet's CSVs have no quoting).
func parseCSV(_ data: Data) -> (header: [String], rows: [[String]]) {
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
    let cells = lines.map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    // The text ends with a newline, so the last split is an empty line.
    return (cells.first ?? [], Array(cells.dropFirst().dropLast()))
}

/// A binary PLY in the packet's layout, read back.
struct ParsedPLY {
    var header: [String]
    var vertices: [SIMD3<Float>]
    var faces: [(count: UInt8, indices: [Int32], classification: UInt8)]
    var trailingBytes: Int
}

func parsePLY(_ data: Data) throws -> ParsedPLY {
    let marker = Data("end_header\n".utf8)
    let end = try #require(data.range(of: marker))
    let header = String(decoding: data[..<end.upperBound], as: UTF8.self).split(separator: "\n").map(String.init)
    let bytes = [UInt8](data[end.upperBound...])
    func count(_ element: String) throws -> Int {
        let line = try #require(header.first { $0.hasPrefix("element \(element) ") })
        return try #require(Int(line.split(separator: " ")[2]))
    }
    func u32(_ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) }
    }
    let nv = try count("vertex")
    let nf = try count("face")
    var offset = 0
    var vertices: [SIMD3<Float>] = []
    for _ in 0..<nv {
        vertices.append(SIMD3(Float(bitPattern: u32(offset)), Float(bitPattern: u32(offset + 4)), Float(bitPattern: u32(offset + 8))))
        offset += 12
    }
    var faces: [(count: UInt8, indices: [Int32], classification: UInt8)] = []
    for _ in 0..<nf {
        let indices = [u32(offset + 1), u32(offset + 5), u32(offset + 9)].map { Int32(bitPattern: $0) }
        faces.append((bytes[offset], indices, bytes[offset + 13]))
        offset += 14
    }
    return ParsedPLY(header: header, vertices: vertices, faces: faces, trailingBytes: bytes.count - offset)
}

@Suite struct PacketCSVTests {
    /// Column orders exactly as `STREAM_COLUMNS` in packet/validate.py.
    @Test func columnsMatchTheSpec() {
        #expect(PacketStream.trajectory.columns.joined(separator: ",") == "t,tracking,px,py,pz,qx,qy,qz,qw")
        #expect(PacketStream.accelerometer.columns.joined(separator: ",") == "t,x,y,z")
        #expect(PacketStream.gyroscope.columns.joined(separator: ",") == "t,x,y,z")
        #expect(PacketStream.magnetometer.columns.joined(separator: ",") == "t,x,y,z")
        let motion = "t,qx,qy,qz,qw,gravity_x,gravity_y,gravity_z,user_accel_x,user_accel_y,user_accel_z,rotation_rate_x,rotation_rate_y,rotation_rate_z,heading_deg"
        #expect(PacketStream.deviceMotion.columns.joined(separator: ",") == motion)
        #expect(PacketStream.barometer.columns.joined(separator: ",") == "t,pressure_kpa,relative_altitude_m")
        let paths: [String] = [
            "streams/trajectory.csv", "streams/accelerometer.csv", "streams/gyroscope.csv", "streams/magnetometer.csv",
            "streams/device_motion.csv", "streams/barometer.csv",
        ]
        #expect(PacketStream.allCases.map(\.path) == paths)
    }

    @Test func timeMustStrictlyIncreaseAndValuesBeFinite() throws {
        var csv = PacketCSV(.barometer)
        try csv.append(t: 10.5, values: [101.3, 0])
        #expect(throws: PacketError.timeNotIncreasing(stream: "barometer", previous: 10.5, t: 10.5)) {
            try csv.append(t: 10.5, values: [101.3, 0])
        }
        #expect(throws: PacketError.timeNotIncreasing(stream: "barometer", previous: 10.5, t: 10.25)) {
            try csv.append(t: 10.25, values: [101.3, 0])
        }
        #expect(throws: PacketError.self) { try csv.append(t: 11, values: [.nan, 0]) }
        #expect(throws: PacketError.self) { try csv.append(t: .infinity, values: [101.3, 0]) }
        #expect(throws: PacketError.self) { try csv.append(t: -1, values: [101.3, 0]) }
        try csv.append(t: 10.500001, values: [101.25, -0.125])
        #expect(csv.rows == 2)
        #expect(String(decoding: csv.data, as: UTF8.self) == "t,pressure_kpa,relative_altitude_m\n10.5,101.3,0.0\n10.500001,101.25,-0.125\n")
    }

    /// Every value comes back exactly: Swift's shortest round-trip decimals, which Python's
    /// float() reads to the same Double.
    @Test func valuesRoundTrip() throws {
        var csv = PacketCSV(.gyroscope)
        let rows: [(Double, SIMD3<Double>)] = [(12345.678901234, SIMD3(0.1, -1e-7, 3.141592653589793)), (12345.6789123, SIMD3(1e20, 0, -0.0))]
        for (t, v) in rows { try csv.append(t: t, values: [v.x, v.y, v.z]) }
        let parsed = parseCSV(csv.data)
        #expect(parsed.header == ["t", "x", "y", "z"])
        #expect(parsed.rows.count == 2)
        for (row, (t, v)) in zip(parsed.rows, rows) {
            let written: [Double] = [t, v.x, v.y, v.z]
            let read: [Double] = row.compactMap { Double($0) }
            #expect(read == written)
        }
    }
}

@Suite struct PacketPLYTests {
    private let mesh = TriangleMesh(
        vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-0.5, -1.25, 0.75)],
        indices: [0, 1, 2, 0, 2, 3])

    @Test func headerIsExactlyTheSpecs() throws {
        let data = try PacketFiles.meshPLY(mesh, classification: [1, 7])
        let parsed = try parsePLY(data)
        #expect(parsed.header == [
            "ply", "format binary_little_endian 1.0", "comment House Scan LiDAR mesh: meter frame, meters",
            "element vertex 4", "property float x", "property float y", "property float z",
            "element face 2", "property list uchar int vertex_indices", "property uchar classification", "end_header",
        ])
    }

    @Test func roundTrip() throws {
        let parsed = try parsePLY(PacketFiles.meshPLY(mesh, classification: [1, 7]))
        #expect(parsed.vertices == mesh.vertices)
        let counts: [UInt8] = [3, 3]
        let indices: [[Int32]] = [[0, 1, 2], [0, 2, 3]]
        #expect(parsed.faces.map(\.count) == counts)
        #expect(parsed.faces.map(\.indices) == indices)
        let classes: [UInt8] = [1, 7]
        #expect(parsed.faces.map(\.classification) == classes)
        #expect(parsed.trailingBytes == 0)
    }

    @Test func refusesBadClassification() {
        #expect(throws: PacketError.invalidMesh("1 classifications for 2 triangles")) { try PacketFiles.meshPLY(mesh, classification: [1]) }
        #expect(throws: PacketError.self) { try PacketFiles.meshPLY(mesh, classification: [1, 8]) }
        let empty = TriangleMesh(vertices: [], indices: [])
        #expect(throws: Never.self) { try PacketFiles.meshPLY(empty, classification: []) }
    }
}

@Suite struct PacketDepthFileTests {
    @Test func float32LittleEndianRoundTrip() {
        let meters: [Float] = [0, 1.5, 0.001, 12.25, .greatestFiniteMagnitude]
        let data = PacketFiles.depthData(meters: meters)
        #expect(data.count == 20)
        // 1.5 is 0x3FC00000: little-endian bytes 00 00 C0 3F.
        #expect([UInt8](data[4..<8]) == [0x00, 0x00, 0xC0, 0x3F])
        let back: [Float] = stride(from: 0, to: data.count, by: 4).map { (i: Int) -> Float in
            var bits: UInt32 = 0
            for k in 0..<4 { bits |= UInt32(data[i + k]) << UInt32(8 * k) }
            return Float(bitPattern: bits)
        }
        #expect(back == meters)
    }

    @Test func sha256IsLowercaseHex() {
        // FIPS 180-2's "abc" test vector.
        #expect(PacketFiles.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

/// A synthetic luma pattern the reference values below were computed on:
/// (x² + 3y² + 5xy + 7x + 11y) mod 256.
func packetLumaPattern(width: Int, height: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let square: Int = x * x + 3 * y * y
            let linear: Int = 5 * x * y + 7 * x + 11 * y
            out[y * width + x] = UInt8((square + linear) % 256)
        }
    }
    return out
}

@Suite struct PacketSharpnessTests {
    /// Interior pixels of [[0,0,0,0],[0,10,0,0],[0,0,0,0]]: Laplacians -40 and 10, mean -15,
    /// variance ((-25)² + 25²) / 2 = 625.
    @Test func handComputedCase() {
        let luma: [UInt8] = [0, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0]
        #expect(PacketSharpness.laplacianVarianceLuma640(luma: luma, width: 4, height: 3) == 625)
        #expect(PacketSharpness.laplacianVarianceLuma640(luma: [1, 2, 3, 4], width: 2, height: 2) == 0)
    }

    /// Values from `sharpness` in packet/write.py (t3/packet d82a903, Pillow 12.3.0, numpy 2.5.3)
    /// on `packetLumaPattern`, run as `Image.fromarray(pattern, "L")`. Sizes cover no resize, a
    /// shrink on both axes, width only (641 x 10 -> 640 x 10), portrait, and 1280 x 9, whose
    /// 4.5-row height rounds half to even to 4.
    @Test(arguments: [
        (9, 7, 50502.84408163265),
        (800, 600, 18388.9229653887),
        (1920, 1440, 4170.471720473048),
        (700, 333, 24881.58272866055),
        (641, 10, 58340.66444966639),
        (1280, 9, 5875.926181813268),
        (480, 1000, 12358.077326545086),
    ])
    func matchesTheReference(width: Int, height: Int, expected: Double) {
        let value = PacketSharpness.laplacianVarianceLuma640(luma: packetLumaPattern(width: width, height: height), width: width, height: height)
        #expect(abs(value - expected) <= 1e-9 * expected, "\(width)x\(height): \(value), reference \(expected)")
    }

    /// Pillow's "L" conversion of an 8 x 6 RGB image, and write.py's score of it (561.0833...).
    @Test func lumaFromRGBXMatchesPillow() {
        var rgbx: [UInt8] = []
        for y in 0..<6 {
            for x in 0..<8 {
                rgbx += [UInt8((x * 31 + y * 7) % 256), UInt8((x * 5 + y * 43) % 256), UInt8((x * y * 17) % 256), 255]
            }
        }
        let luma = rgbx.withUnsafeBytes { PacketSharpness.luma(rgbx: $0, width: 8, height: 6, bytesPerRow: 32) }
        let pillow: [UInt8] = [
            0, 12, 24, 37, 49, 61, 73, 85, 27, 41, 56, 70, 84, 98, 112, 126, 55, 71, 87, 103, 119, 135, 151, 167,
            82, 100, 118, 136, 154, 172, 161, 179, 109, 129, 149, 169, 160, 180, 200, 220, 137, 159, 180, 202, 195, 217, 239, 232,
        ]
        #expect(luma == pillow)
        #expect(abs(PacketSharpness.laplacianVarianceLuma640(luma: luma, width: 8, height: 6) - 561.0833333333334) < 1e-9)
    }

    /// The 8-bit path rounds each pass to a byte; a flat image stays flat and exact.
    @Test func flatImageResizesFlat() {
        let flat = [UInt8](repeating: 77, count: 1000 * 700)
        let small = PacketSharpness.resizedBilinear8(flat, width: 1000, height: 700, toWidth: 640, toHeight: 448)
        #expect(small.count == 640 * 448 && small.allSatisfy { $0 == 77 })
    }
}
