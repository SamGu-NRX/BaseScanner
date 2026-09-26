// Reads one wall and a list of keyframes (JSON on stdin), feeds every keyframe to the app's
// CoverageMap in order, and writes what the app would export as observed (JSON on stdout), plus
// each keyframe's sightings so the caller can attribute errors to the frames the app credited.
// Without a wall it writes only the config.
import Foundation
import HouseScanKit
import simd

struct Input: Decodable {
    struct Wall: Decodable {
        let meter: [Float]
        let outward: [Float]
        let groundY: Float
    }

    struct Keyframe: Decodable {
        let id: String
        /// Camera-to-world, 16 numbers column by column, ARKit camera axes.
        let pose: [Float]
        /// fx, fy, cx, cy in pixels of the unrotated image; (0, 0) is its top-left corner.
        let intrinsics: [Float]
        let size: [Float]
    }

    let wall: Wall?
    let leftEnd: Float?
    let rightEnd: Float?
    let keyframes: [Keyframe]?
}

struct Output: Encodable {
    struct Sighting: Encodable {
        let keyframe: String
        let band: String
        let index: Int
        let rows: [Int]
    }

    let config: [String: Float]
    let covered: [String: [[Float]]]?
    let sightings: [Sighting]?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("coverage-driver: \(message)\n".utf8))
    exit(1)
}

func vector(_ v: [Float], _ name: String) -> SIMD3<Float> {
    guard v.count == 3 else { fail("\(name) has \(v.count) numbers, expected 3") }
    return SIMD3(v[0], v[1], v[2])
}

let input: Input
do {
    input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
} catch {
    fail("bad input: \(error)")
}
let config = CoverageConfig()
let configValues: [String: Float] = [
    "cellWidth": config.cellWidth,
    "wallBandHeight": config.wallBandHeight,
    "groundBandDepth": config.groundBandDepth,
    "maxDistance": config.maxDistance,
    "maxAngleFromNormal": config.maxAngleFromNormal,
    "imageMargin": config.imageMargin,
    "rowsPerBand": Float(config.rowsPerBand),
    "coveringBaseline": config.coveringBaseline,
]
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

guard let wallInput = input.wall else {
    FileHandle.standardOutput.write(try encoder.encode(Output(config: configValues, covered: nil, sightings: nil)))
    exit(0)
}
guard let wall = WallFrame(
    meter: vector(wallInput.meter, "wall.meter"),
    outward: vector(wallInput.outward, "wall.outward"),
    groundY: wallInput.groundY
) else { fail("wall.outward has no horizontal component") }
guard let leftEnd = input.leftEnd, let rightEnd = input.rightEnd, leftEnd < rightEnd else {
    fail("leftEnd and rightEnd are required, left of right")
}

var map = CoverageMap(wall: wall, config: config)
map.setEnd(.left, at: leftEnd)
map.setEnd(.right, at: rightEnd)

var sightings: [Output.Sighting] = []
for keyframe in input.keyframes ?? [] {
    guard keyframe.intrinsics.count == 4, keyframe.size.count == 2 else { fail("\(keyframe.id): intrinsics or size malformed") }
    guard let camera = CameraFrame(
        columnMajorPose: keyframe.pose,
        intrinsics: SIMD4(keyframe.intrinsics[0], keyframe.intrinsics[1], keyframe.intrinsics[2], keyframe.intrinsics[3]),
        imageSize: SIMD2(keyframe.size[0], keyframe.size[1])
    ) else { fail("\(keyframe.id): pose is not 16 finite numbers") }
    // Sightings before observing: visibleCells does not depend on what was seen before.
    for s in map.visibleCells(from: camera) {
        sightings.append(.init(keyframe: keyframe.id, band: s.band.rawValue, index: s.index, rows: s.rows.sorted()))
    }
    map.observe(camera, trackingNormal: true)
}

let output = Output(
    config: configValues,
    covered: Dictionary(uniqueKeysWithValues: SurfaceBand.allCases.map { band in
        (band.rawValue, map.coveredIntervals(band).map { [$0.lowerBound, $0.upperBound] })
    }),
    sightings: sightings
)
FileHandle.standardOutput.write(try encoder.encode(output))
