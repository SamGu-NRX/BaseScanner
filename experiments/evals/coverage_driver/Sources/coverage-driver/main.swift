// Reads one wall and a list of keyframes (JSON on stdin), feeds every keyframe to the app's
// CoverageMap in order, and writes what the app would export as observed (JSON on stdout), plus
// each keyframe's sightings so the caller can attribute errors to the frames the app credited.
// Without a wall it writes only the config.
//
// Options for occlusion (README section 7b), modelled here so HouseScanKit stays unedited:
// - `variant.coveringBaseline` and `variant.rowsPerBand` set the app's own CoverageConfig fields.
// - `hidden` removes rows from a keyframe's sightings before the app's `record`: a depth test that
//   `sees` (CoverageMap.swift lines 241-248) would make, computed by the caller.
// - `variant.minAngleDeg` feeds the same sightings to `DiverseCoverage`, a copy of `record`
//   (lines 171-195) whose acceptance predicate (lines 180-181) also demands that two views'
//   directions to the row's centre differ by that angle. Its answer is `diverseCovered`; at 0
//   degrees it must equal the app's `covered`.
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

    struct Variant: Decodable {
        let coveringBaseline: Float?
        let rowsPerBand: Int?
        let minAngleDeg: Float?
    }

    struct Hidden: Decodable {
        let keyframe: String
        let band: String
        let index: Int
        let rows: [Int]
    }

    let wall: Wall?
    let variant: Variant?
    let hidden: [Hidden]?
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
    let diverseCovered: [String: [[Float]]]?
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
var config = CoverageConfig()
if let b = input.variant?.coveringBaseline { config.coveringBaseline = b }
if let rows = input.variant?.rowsPerBand { config.rowsPerBand = rows }
let minAngle = (input.variant?.minAngleDeg ?? 0) * .pi / 180
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
    FileHandle.standardOutput.write(try encoder.encode(Output(config: configValues, covered: nil, diverseCovered: nil, sightings: nil)))
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

var hiddenRows: [String: [String: Set<Int>]] = [:]
for h in input.hidden ?? [] {
    hiddenRows[h.keyframe, default: [:]]["\(h.band):\(h.index)", default: []].formUnion(h.rows)
}
var diverse = DiverseCoverage(map: map, minAngle: minAngle, leftEnd: leftEnd, rightEnd: rightEnd)

var sightings: [Output.Sighting] = []
for keyframe in input.keyframes ?? [] {
    guard keyframe.intrinsics.count == 4, keyframe.size.count == 2 else { fail("\(keyframe.id): intrinsics or size malformed") }
    guard let camera = CameraFrame(
        columnMajorPose: keyframe.pose,
        intrinsics: SIMD4(keyframe.intrinsics[0], keyframe.intrinsics[1], keyframe.intrinsics[2], keyframe.intrinsics[3]),
        imageSize: SIMD2(keyframe.size[0], keyframe.size[1])
    ) else { fail("\(keyframe.id): pose is not 16 finite numbers") }
    // Sightings before recording: visibleCells does not depend on what was seen before.
    var seen: [CoverageMap.Sighting] = []
    for var s in map.visibleCells(from: camera) {
        sightings.append(.init(keyframe: keyframe.id, band: s.band.rawValue, index: s.index, rows: s.rows.sorted()))
        s.rows.subtract(hiddenRows[keyframe.id]?["\(s.band.rawValue):\(s.index)"] ?? [])
        if !s.rows.isEmpty { seen.append(s) }
    }
    // What observe(_:trackingNormal: true) does (CoverageMap.swift lines 143-146), with the
    // sightings possibly thinned by `hidden`.
    map.record(seen, from: camera.position)
    diverse.record(seen, from: camera.position)
}

let output = Output(
    config: configValues,
    covered: Dictionary(uniqueKeysWithValues: SurfaceBand.allCases.map { band in
        (band.rawValue, map.coveredIntervals(band).map { [$0.lowerBound, $0.upperBound] })
    }),
    diverseCovered: Dictionary(uniqueKeysWithValues: SurfaceBand.allCases.map { band in
        (band.rawValue, diverse.coveredIntervals(band).map { [$0.lowerBound, $0.upperBound] })
    }),
    sightings: sightings
)
FileHandle.standardOutput.write(try encoder.encode(output))

/// A copy of CoverageMap.record whose acceptance predicate also demands angle diversity: a view
/// joins a row only if it is `coveringBaseline` from every view already held (the app's rule) and
/// its direction to the row's centre differs from theirs by at least `minAngle`.
struct DiverseCoverage {
    let map: CoverageMap
    let minAngle: Float
    let leftEnd: Float
    let rightEnd: Float
    private var rows: [String: [[SIMD3<Float>]]] = [:]
    private var covered: [SurfaceBand: Set<Int>] = [.wall: [], .ground: []]

    init(map: CoverageMap, minAngle: Float, leftEnd: Float, rightEnd: Float) {
        self.map = map
        self.minAngle = minAngle
        self.leftEnd = leftEnd
        self.rightEnd = rightEnd
    }

    private func allows(_ index: Int) -> Bool {
        let range = map.cellRange(index)
        return range.upperBound > leftEnd && range.lowerBound < rightEnd
    }

    private func rowCentre(_ band: SurfaceBand, _ index: Int, _ row: Int) -> SIMD3<Float> {
        let range = map.cellRange(index)
        let s = (range.lowerBound + range.upperBound) / 2
        let offset = map.rowOffsets(band)[row]
        return band == .wall ? map.wall.world(s: s, height: offset) : map.wall.world(s: s, height: 0, out: offset)
    }

    private func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b)))))
    }

    mutating func record(_ sightings: [CoverageMap.Sighting], from position: SIMD3<Float>) {
        let rowCount = map.config.rowsPerBand
        for sighting in sightings where allows(sighting.index) {
            let key = "\(sighting.band.rawValue):\(sighting.index)"
            var cell = rows[key] ?? Array(repeating: [], count: rowCount)
            for row in sighting.rows where cell.indices.contains(row) {
                let centre = rowCentre(sighting.band, sighting.index, row)
                let held = cell[row]
                guard held.count < 2, held.allSatisfy({
                    simd_distance($0, position) >= map.config.coveringBaseline
                        && angle($0 - centre, position - centre) >= minAngle
                }) else { continue }
                cell[row].append(position)
            }
            rows[key] = cell
            if cell.allSatisfy({ $0.count >= 2 }) { covered[sighting.band]?.insert(sighting.index) }
        }
    }

    /// Covered cells merged into stretches and clipped to the marked ends, as coveredIntervals does.
    func coveredIntervals(_ band: SurfaceBand) -> [ClosedRange<Float>] {
        var runs: [ClosedRange<Float>] = []
        var last: Int?
        for index in (covered[band] ?? []).sorted() {
            let range = map.cellRange(index)
            if let l = last, l == index - 1, let run = runs.last {
                runs[runs.count - 1] = run.lowerBound...range.upperBound
            } else {
                runs.append(range)
            }
            last = index
        }
        if let first = runs.first { runs[0] = max(first.lowerBound, leftEnd)...first.upperBound }
        if let end = runs.last { runs[runs.count - 1] = end.lowerBound...min(end.upperBound, rightEnd) }
        return runs
    }
}
