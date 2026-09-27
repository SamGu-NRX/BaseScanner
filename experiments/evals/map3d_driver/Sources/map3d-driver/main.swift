// Feeds depth frames (JSON manifest on stdin, Float32 depth files on disk) to the app's Map3D,
// unmodified, and writes its coverage along a given wall and its measured wall chain (JSON on
// stdout).
import Foundation
import HouseScanKit
import simd

struct Input: Decodable {
    struct Wall: Decodable {
        let meter: [Float]
        let outward: [Float]
        let groundY: Float
    }

    struct Frame: Decodable {
        let id: String
        /// Camera-to-world, 16 numbers column by column, ARKit camera axes.
        let pose: [Float]
        /// fx, fy, cx, cy of the photo, (0, 0) at its top-left corner.
        let intrinsics: [Float]
        let size: [Float]
        /// Float32 meters along -z, row-major, `width` x `height`, 0 where nothing was measured.
        let depthFile: String
        let width: Int
        let height: Int
    }

    let wall: Wall
    let frames: [Frame]
}

struct Span: Encodable {
    let s: [Float]
    let out: Float?
}

struct Piece: Encodable {
    let start: [Float]
    let end: [Float]
    let outward: [Float]
    let support: Int
}

struct Output: Encodable {
    let poseInWorld: [Float]
    let wall: [Span]
    let ground: [Span]
    let facing: [Span]
    let overhead: [Span]
    let chain: [Piece]
    let meterIndex: Int?
    let pieces: [Piece]
    let allocatedBytes: Int
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("map3d-driver: \(message)\n".utf8))
    exit(1)
}

func v3(_ v: [Float]) -> SIMD3<Float> { SIMD3(v[0], v[1], v[2]) }

let input: Input
do {
    input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
} catch {
    fail("bad input: \(error)")
}
guard let wall = WallFrame(meter: v3(input.wall.meter), outward: v3(input.wall.outward), groundY: input.wall.groundY),
      let mapFrame = MapFrame(meter: v3(input.wall.meter), outward: v3(input.wall.outward), worldGroundY: input.wall.groundY)
else { fail("wall.outward has no horizontal component") }

var map = Map3D(frame: mapFrame)
for f in input.frames {
    guard let photo = CameraFrame(
        columnMajorPose: f.pose, intrinsics: SIMD4(f.intrinsics[0], f.intrinsics[1], f.intrinsics[2], f.intrinsics[3]),
        imageSize: SIMD2(f.size[0], f.size[1])
    ) else { fail("\(f.id): pose is not 16 finite numbers") }
    guard let data = FileManager.default.contents(atPath: f.depthFile), data.count == f.width * f.height * 4 else {
        fail("\(f.id): \(f.depthFile) is not \(f.width) x \(f.height) Float32 values")
    }
    let depth = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    map.integrate(DepthFrame(photo: photo, width: f.width, height: f.height, depth: depth, kind: .lidar(confidence: nil)))
}

let coverage = map.coverage(along: wall)
func pieces(_ walls: [MeasuredWall]) -> [Piece] {
    walls.map { Piece(start: [$0.start.x, $0.start.y], end: [$0.end.x, $0.end.y], outward: [$0.outward.x, $0.outward.y], support: $0.support) }
}
let chain = map.measuredWalls()
let output = Output(
    poseInWorld: map.frame.poseInWorld.columnMajor,
    wall: coverage.wall.map { Span(s: [$0.lowerBound, $0.upperBound], out: nil) },
    ground: coverage.ground.map { Span(s: [$0.span.lowerBound, $0.span.upperBound], out: $0.out) },
    facing: coverage.facing.map { Span(s: [$0.span.lowerBound, $0.span.upperBound], out: $0.out) },
    overhead: coverage.overhead.map { Span(s: [$0.span.lowerBound, $0.span.upperBound], out: $0.out) },
    chain: pieces(chain?.walls ?? []),
    meterIndex: chain?.meterIndex,
    pieces: pieces(map.wallPieces()),
    allocatedBytes: map.allocatedBytes
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try encoder.encode(output))
