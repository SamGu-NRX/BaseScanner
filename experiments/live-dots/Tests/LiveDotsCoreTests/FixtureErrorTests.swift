import Foundation
import simd
import Testing
@testable import LiveDotsCore

/// A broken fixture must say which file and which counts, not fail somewhere downstream.
struct FixtureErrorTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-dots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("keyframes"), withIntermediateDirectories: true)
        let session = """
        {"format": "measure-lab-session", "formatVersion": 2, "keyframes": [
          {"id": "k00001", "img": "keyframes/k00001.jpg", "w": 640, "h": 480, "intrinsics": [500, 500, 320, 240],
           "pose": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,1.5,2.6,1], "timestamp": 100,
           "depth": {"file": "keyframes/k00001.depth.f32", "confidenceFile": "keyframes/k00001.confidence.u8", "w": 4, "h": 2}}
        ]}
        """
        try Data(session.utf8).write(to: folder.appendingPathComponent("session.json"))
    }

    private func write(_ name: String, bytes: Int) throws {
        try Data(count: bytes).write(to: folder.appendingPathComponent("keyframes/\(name)"))
    }

    @Test func `a missing depth file names its path`() throws {
        let replay = try Replay.load(folder: folder)
        let error = #expect(throws: FixtureError.self) { try replay.depth(for: replay.keyframes[0]) }
        let message = try #require(error).description
        #expect(message.contains("keyframes/k00001.depth.f32"))
    }

    @Test func `a short depth file names its path and both byte counts`() throws {
        try write("k00001.depth.f32", bytes: 10)
        try write("k00001.confidence.u8", bytes: 8)
        let replay = try Replay.load(folder: folder)
        let error = #expect(throws: FixtureError.self) { try replay.depth(for: replay.keyframes[0]) }
        let message = try #require(error).description
        #expect(message.contains("k00001.depth.f32") && message.contains("10 bytes") && message.contains("expected 32") && message.contains("4 x 2"))
    }

    @Test func `a wrong confidence size names its path and both byte counts`() throws {
        try write("k00001.depth.f32", bytes: 32)
        try write("k00001.confidence.u8", bytes: 5)
        let replay = try Replay.load(folder: folder)
        let error = #expect(throws: FixtureError.self) { try replay.depth(for: replay.keyframes[0]) }
        let message = try #require(error).description
        #expect(message.contains("k00001.confidence.u8") && message.contains("5 bytes") && message.contains("expected 8"))
    }

    @Test func `a correct depth file decodes little-endian metres with intrinsics scaled to its size`() throws {
        var bytes = Data()
        for value: Float in [0, 1.5, 2, 2.5, 3, 3.5, 4, 6.5] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }
        try bytes.write(to: folder.appendingPathComponent("keyframes/k00001.depth.f32"))
        try Data([0, 1, 2, 2, 2, 2, 1, 0]).write(to: folder.appendingPathComponent("keyframes/k00001.confidence.u8"))
        let replay = try Replay.load(folder: folder)
        let depth = try replay.depth(for: replay.keyframes[0])
        #expect(depth.meters == [0, 1.5, 2, 2.5, 3, 3.5, 4, 6.5])
        #expect(depth.confidence[1] == 1)
        let expected = SIMD4<Float>(500 * 4 / 640, 500 * 2 / 480, 320 * 4 / 640, 240 * 2 / 480)
        #expect(simd_distance(depth.intrinsics, expected) < 1e-5)
    }

    @Test func `the wrong format version is refused`() throws {
        let url = folder.appendingPathComponent("session.json")
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"formatVersion\": 2", with: "\"formatVersion\": 3")
        try Data(text.utf8).write(to: url)
        #expect(throws: FixtureError.unsupportedVersion(path: url.path, found: 3)) { try Replay.load(folder: folder) }
    }
}
