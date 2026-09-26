import Foundation
import simd

/// The two strips of surface the scan must see: the wall face and the ground at its foot.
public enum SurfaceBand: String, Sendable, CaseIterable {
    case wall
    case ground
}

/// How well a cell has been seen. Only `.covered` counts as evidence.
public enum CoverageLevel: UInt8, Sendable, Equatable {
    case unseen
    /// Some row seen by a kept keyframe, but not every row from two separate positions yet.
    case seen
    /// Every sample row seen from two camera positions at least `CoverageConfig.coveringBaseline`
    /// apart (the rows may be seen by different frames).
    case covered
    /// The homeowner said they cannot get there. Never evidence.
    case skipped
}

/// Thresholds of the coverage map. Every value is a starting hypothesis, not a measured optimum;
/// the reasons for each are next to it.
public struct CoverageConfig: Sendable, Equatable {
    /// Cell width along the wall. 6 in is the research note's display guess
    /// (docs/research/t3-first-try-capture.md on t3/research): fine enough that one missed
    /// stride shows as a gap, coarse enough that the strip reads at a glance.
    public var cellWidth: Float = 0.1524
    /// Wall band height: 6.5 ft (1.9812 m). scene.schema.json defines an observed wall band as
    /// the face "from the ground up to headroom height", and 6.5 ft is the NEC 110.26 and Austin
    /// Energy §1.9.2 headroom (docs/04-prior-art-and-codes.md). It was 2.4 m, which a phone held
    /// at chest height 2.6 m out never sees (the top of its view is about 2.0 m up), so the export
    /// claimed band it had not seen. The server's own headroom value is not checked here.
    public var wallBandHeight: Float = 1.9812
    /// Ground band depth out from the wall. 1.2 m covers a unit's footprint plus its front clearance.
    public var groundBandDepth: Float = 1.2
    /// Farther than this a phone camera resolves too little of a wall to measure against it.
    public var maxDistance: Float = 6
    /// Views more oblique than this foreshorten the surface too much to measure on it.
    public var maxAngleFromNormal: Float = 65 * .pi / 180
    /// Samples within this fraction of the image edge don't count, since edges blur and distort most.
    public var imageMargin: Float = 0.03
    /// Sample rows across a band, bottom edge to top edge (wall) or wall foot to outer edge
    /// (ground). A cell is covered only when every row is, so the first and last rows sit on the
    /// band's edges: the band a covered cell claims is the band its rows saw. Three rows leave
    /// 0.99 m between wall rows and 0.6 m between ground rows unsampled; a hypothesis, not tuned.
    public var rowsPerBand = 3
    /// Two views count as separate positions only this far apart, so parallax exists between them.
    public var coveringBaseline: Float = 0.25
    /// Fog drawn ahead of what has been seen, so the homeowner sees where to go next.
    public var fogAhead: Float = 2.5

    public init() {}
}

/// Which cells of the wall and ground strips kept keyframes have seen.
///
/// Coverage marks what the camera pointed at, not what it saw. Occlusion is not modelled: a bush
/// or bin in front of the wall is counted as seen wall and ground. Nothing downstream corrects
/// this; the server takes the covered intervals as given and does not read images. On ETH3D the
/// evals lane measured 1.1 ft of a 19.3 ft wall claimed covered that no photo saw, all of it
/// occluded at the bottom.
public struct CoverageMap: Sendable {
    public private(set) var wall: WallFrame
    public let config: CoverageConfig
    /// Marked wall ends in meters of s. Nothing outside them is observed once they are set.
    public private(set) var leftEnd: Float?
    public private(set) var rightEnd: Float?
    /// Increments on every change.
    public private(set) var revision = 0

    private var cells: [SurfaceBand: [Int: Cell]] = [.wall: [:], .ground: [:]]
    /// s shift from meter moves not yet applied to skipped cells, meters (see `updateWall`).
    private var pendingShift: Float = 0
    /// Cameras of the frames `observe` recorded, oldest first, so a new wall frame can be replayed
    /// against them. Sightings recorded directly through `record` are not kept.
    public private(set) var observedCameras: [CameraFrame] = []

    private struct Cell: Sendable {
        /// Per sample row, the camera positions that saw it, pairwise at least
        /// `coveringBaseline` apart. Two are enough, so a row stops collecting at two.
        var rows: [[SIMD3<Float>]]
        var skipped = false
        var covered = false

        init(rowCount: Int) {
            rows = Array(repeating: [], count: rowCount)
        }

        var isSeen: Bool { rows.contains { !$0.isEmpty } }

        var level: CoverageLevel {
            if covered { return .covered }
            if skipped { return .skipped }
            return isSeen ? .seen : .unseen
        }
    }

    public struct Delta: Sendable, Equatable {
        public var newlySeen = 0
        public var newlyCovered = 0
        public var changed: Bool { newlySeen + newlyCovered > 0 }
    }

    public init(wall: WallFrame, config: CoverageConfig = CoverageConfig()) {
        self.wall = wall
        self.config = config
    }

    // MARK: Cells

    public func cellIndex(forS s: Float) -> Int { Int((s / config.cellWidth).rounded(.down)) }

    public func cellRange(_ index: Int) -> ClosedRange<Float> {
        let start = Float(index) * config.cellWidth
        return start...(start + config.cellWidth)
    }

    public func level(_ band: SurfaceBand, _ index: Int) -> CoverageLevel {
        cells[band]?[index]?.level ?? .unseen
    }

    /// Indices of every cell overlapping `range` by more than a thousandth of a cell.
    ///
    /// Ranges built from cell edges (gap spans, seen extents) sit within Float rounding of a
    /// boundary: `Float(i) * width / width` can floor to i - 1, and the next cell's start can land
    /// an ulp below this cell's end. Without the tolerance, 9 of the 121 cells within 9 m of the
    /// meter picked up a neighbour, which could read a gap's 3 of 4 cells covered as 4 of 5 (80 %).
    public func indices(overlapping range: ClosedRange<Float>) -> ClosedRange<Int> {
        let tolerance = config.cellWidth * 1e-3
        let first = cellIndex(forS: range.lowerBound + tolerance)
        let last = cellIndex(forS: range.upperBound - tolerance)
        return first...max(first, last)
    }

    /// The s range allowed by the marked ends; unbounded sides are nil.
    private func allows(_ index: Int) -> Bool {
        let range = cellRange(index)
        if let leftEnd, range.upperBound <= leftEnd { return false }
        if let rightEnd, range.lowerBound >= rightEnd { return false }
        return true
    }

    // MARK: Observing

    /// Records a kept keyframe. Returns nothing new unless tracking was normal for it: frames with
    /// limited tracking have poses that can be off by more than a cell.
    @discardableResult
    public mutating func observe(_ camera: CameraFrame, trackingNormal: Bool) -> Delta {
        guard trackingNormal else { return Delta() }
        observedCameras.append(camera)
        return record(visibleCells(from: camera), from: camera.position)
    }

    /// Every cell a frame sees at least one row of, before the marked ends clip anything that
    /// isn't allowed.
    public func visibleCells(from camera: CameraFrame) -> [Sighting] {
        var seen: [Sighting] = []
        for band in SurfaceBand.allCases {
            for index in candidateIndices(for: camera) {
                let rows = visibleRows(band, index, from: camera)
                if !rows.isEmpty { seen.append(Sighting(band: band, index: index, rows: rows)) }
            }
        }
        return seen
    }

    public struct Sighting: Sendable, Hashable {
        public var band: SurfaceBand
        public var index: Int
        /// The sample rows of the cell the frame saw, 0 at the band's bottom (or the wall foot).
        public var rows: Set<Int>
    }

    /// Records cells a kept keyframe with normal tracking saw from `position`: the part of
    /// `observe` after visibility, for planners that precompute what each frame sees.
    @discardableResult
    public mutating func record(_ sightings: [Sighting], from position: SIMD3<Float>) -> Delta {
        var delta = Delta()
        for sighting in sightings where allows(sighting.index) {
            var cell = cells[sighting.band]?[sighting.index] ?? Cell(rowCount: config.rowsPerBand)
            let wasSeen = cell.isSeen
            var added = false
            for row in sighting.rows where cell.rows.indices.contains(row) {
                let positions = cell.rows[row]
                // A repeated or nearby frame adds no parallax, so it adds nothing.
                guard positions.count < 2,
                      positions.allSatisfy({ simd_distance($0, position) >= config.coveringBaseline }) else { continue }
                cell.rows[row].append(position)
                added = true
            }
            guard added else { continue }
            if !wasSeen { delta.newlySeen += 1 }
            if !cell.covered, cell.rows.allSatisfy({ $0.count >= 2 }) {
                cell.covered = true
                delta.newlyCovered += 1
            }
            cells[sighting.band, default: [:]][sighting.index] = cell
        }
        if delta.changed { revision += 1 }
        return delta
    }

    /// How many cells this frame would show a row of for the first time, if kept. A cell whose
    /// lower rows are seen still counts when the frame is the first to see its top row, or it
    /// could never become covered.
    public func newlySeenCount(from camera: CameraFrame) -> Int {
        var count = 0
        for band in SurfaceBand.allCases {
            for index in candidateIndices(for: camera) {
                let cell = cells[band]?[index]
                let unseenRows = (0..<config.rowsPerBand).filter { cell?.rows[$0].isEmpty ?? true }
                guard !unseenRows.isEmpty else { continue }
                if !visibleRows(band, index, from: camera, among: unseenRows).isEmpty { count += 1 }
            }
        }
        return count
    }

    private func candidateIndices(for camera: CameraFrame) -> [Int] {
        let s = wall.wallPoint(camera.position).s
        return indices(overlapping: (s - config.maxDistance)...(s + config.maxDistance)).filter(allows)
    }

    /// Height (wall) or distance out (ground) of each sample row, evenly from edge to edge.
    public func rowOffsets(_ band: SurfaceBand) -> [Float] {
        let extent = band == .wall ? config.wallBandHeight : config.groundBandDepth
        let count = max(2, config.rowsPerBand)
        return (0..<count).map { extent * Float($0) / Float(count - 1) }
    }

    /// The rows of a cell a frame sees: a row counts when both of its samples, a quarter and
    /// three quarters along the cell, are in view.
    public func visibleRows(_ band: SurfaceBand, _ index: Int, from camera: CameraFrame) -> Set<Int> {
        visibleRows(band, index, from: camera, among: Array(0..<config.rowsPerBand))
    }

    private func visibleRows(_ band: SurfaceBand, _ index: Int, from camera: CameraFrame, among rows: [Int]) -> Set<Int> {
        // Behind the wall's plane the wall itself hides both bands. Occlusion is otherwise not
        // modelled, and the ground row at the wall's foot would pass from there.
        guard wall.wallPoint(camera.position).out > 0 else { return [] }
        let range = cellRange(index)
        let width = range.upperBound - range.lowerBound
        let alongs = [range.lowerBound + width * 0.25, range.lowerBound + width * 0.75]
        let offsets = rowOffsets(band)
        let normal = band == .wall ? wall.outward : WallFrame.up
        let cosLimit = cos(config.maxAngleFromNormal)
        func sees(_ point: SIMD3<Float>) -> Bool {
            let toCamera = camera.position - point
            let distance = simd_length(toCamera)
            guard distance <= config.maxDistance, distance > 0 else { return false }
            guard simd_dot(toCamera / distance, normal) >= cosLimit else { return false }
            guard let pixel = camera.pixel(of: point) else { return false }
            return camera.contains(pixel: pixel, margin: config.imageMargin)
        }
        return Set(rows.filter { row in
            alongs.allSatisfy { s in
                sees(band == .wall ? wall.world(s: s, height: offsets[row]) : wall.world(s: s, height: 0, out: offsets[row]))
            }
        })
    }

    /// Whether a frame sees any row of the cell.
    public func isVisible(_ band: SurfaceBand, _ index: Int, from camera: CameraFrame) -> Bool {
        !visibleRows(band, index, from: camera).isEmpty
    }

    // MARK: Homeowner input

    public mutating func setEnd(_ side: WalkSide, at s: Float) {
        switch side {
        case .left: leftEnd = s
        case .right: rightEnd = s
        }
        revision += 1
    }

    /// Forgets a marked end, for example to walk past it when the server asks what lies beyond.
    public mutating func clearEnd(_ side: WalkSide) {
        switch side {
        case .left: leftEnd = nil
        case .right: rightEnd = nil
        }
        revision += 1
    }

    /// Marks the not-yet-covered cells of `range` as skipped ("I can't get there").
    public mutating func markSkipped(_ band: SurfaceBand, _ range: ClosedRange<Float>) {
        for index in indices(overlapping: range) where allows(index) {
            var cell = cells[band]?[index] ?? Cell(rowCount: config.rowsPerBand)
            guard !cell.covered else { continue }
            cell.skipped = true
            cells[band, default: [:]][index] = cell
        }
        revision += 1
    }

    /// Moves the map to a new wall frame (after the meter anchor is refined or the ground is
    /// measured) and recomputes what every observed camera saw against it.
    ///
    /// Shifting cells is not enough: a cell records which heights a camera saw, and a corrected
    /// ground or wall plane moves the sample rows to heights no frame may have looked at. With a
    /// ground 0.3 m too high, shifted cells claimed wall and ground that were only ever sampled in
    /// the air. So seen and covered cells are rebuilt by replaying `observedCameras`; marked ends
    /// move exactly (s is measured from the meter, so moving it by d along the wall moves every
    /// end by -d), and skipped cells move by whole cells, the remainder (under half a cell,
    /// 7.6 cm, below tap error) waiting for later moves. The replay clips to the current ends, so
    /// cells beyond an end seen before it was marked are gone until a new frame sees them.
    /// Assumes the wall's direction is unchanged.
    public mutating func updateWall(_ frame: WallFrame) {
        guard frame != wall else { return }
        let delta = simd_dot(wall.meter - frame.meter, frame.along)
        wall = frame
        leftEnd = leftEnd.map { $0 + delta }
        rightEnd = rightEnd.map { $0 + delta }
        pendingShift += delta
        let whole = Int((pendingShift / config.cellWidth).rounded())
        pendingShift -= Float(whole) * config.cellWidth
        var skipped: [SurfaceBand: [Int: Cell]] = [.wall: [:], .ground: [:]]
        for (band, bandCells) in cells {
            for (index, cell) in bandCells where cell.skipped {
                var kept = Cell(rowCount: config.rowsPerBand)
                kept.skipped = true
                skipped[band, default: [:]][index + whole] = kept
            }
        }
        cells = skipped
        for camera in observedCameras {
            record(visibleCells(from: camera), from: camera.position)
        }
        revision += 1
    }

    // MARK: Reading

    /// s extent of seen or covered cells, or nil when nothing has been seen.
    public var seenExtent: ClosedRange<Float>? {
        let seen = cells.values.flatMap { $0.filter { $0.value.isSeen }.keys }
        guard let low = seen.min(), let high = seen.max() else { return nil }
        return cellRange(low).lowerBound...cellRange(high).upperBound
    }

    /// Range worth drawing: seen cells plus fog ahead, clipped to the marked ends. Before anything
    /// is seen, the fog around the meter.
    public var visibleRange: ClosedRange<Float> {
        let seen = seenExtent ?? 0...0
        var low = seen.lowerBound - config.fogAhead
        var high = seen.upperBound + config.fogAhead
        if let leftEnd { low = max(low, leftEnd) }
        if let rightEnd { high = min(high, rightEnd) }
        return low...max(low, high)
    }

    /// Covered stretches of a band, merged, in meters of s. Only covered cells count: a cell seen
    /// from one position has no parallax behind it.
    public func coveredIntervals(_ band: SurfaceBand) -> [ClosedRange<Float>] {
        let indices = (cells[band] ?? [:]).filter { $0.value.covered && allows($0.key) }.keys.sorted()
        var runs: [ClosedRange<Float>] = []
        for index in indices {
            let range = cellRange(index)
            if let last = runs.last, abs(last.upperBound - range.lowerBound) < config.cellWidth * 0.01 {
                runs[runs.count - 1] = last.lowerBound...range.upperBound
            } else {
                runs.append(range)
            }
        }
        if let leftEnd, let first = runs.first { runs[0] = max(first.lowerBound, leftEnd)...first.upperBound }
        if let rightEnd, let last = runs.last { runs[runs.count - 1] = last.lowerBound...min(last.upperBound, rightEnd) }
        return runs
    }

    /// Fraction of cells over `range` in `band` that are covered.
    public func coveredFraction(_ band: SurfaceBand, in range: ClosedRange<Float>) -> Double {
        let all = indices(overlapping: range).filter(allows)
        guard !all.isEmpty else { return 0 }
        return Double(all.filter { level(band, $0) == .covered }.count) / Double(all.count)
    }

    /// Total covered cells over both bands.
    public var coveredCount: Int {
        cells.values.reduce(0) { $0 + $1.values.filter(\.covered).count }
    }
}

public enum WalkSide: String, Sendable, CaseIterable {
    case left
    case right

    /// -1 for left, +1 for right: the sign of s on this side of the meter.
    public var sign: Float { self == .left ? -1 : 1 }
    public var opposite: WalkSide { self == .left ? .right : .left }
}
