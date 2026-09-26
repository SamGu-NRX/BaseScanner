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
    /// Seen by at least one kept keyframe, not yet from two separate positions.
    case seen
    /// Seen from two camera positions at least `CoverageConfig.coveringBaseline` apart.
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
    /// Wall band height. 2.4 m covers a battery unit plus the cable route above it.
    public var wallBandHeight: Float = 2.4
    /// Ground band depth out from the wall. 1.2 m covers a unit's footprint plus its front clearance.
    public var groundBandDepth: Float = 1.2
    /// Farther than this a phone camera resolves too little of a wall to measure against it.
    public var maxDistance: Float = 6
    /// Views more oblique than this foreshorten the surface too much to measure on it.
    public var maxAngleFromNormal: Float = 65 * .pi / 180
    /// Samples within this fraction of the image edge don't count, since edges blur and distort most.
    public var imageMargin: Float = 0.03
    /// Share of a cell's samples that must pass for the cell to count as seen ("most of it").
    public var minSampleFraction: Float = 0.6
    /// Two views count as separate positions only this far apart, so parallax exists between them.
    public var coveringBaseline: Float = 0.25
    /// Fog drawn ahead of what has been seen, so the homeowner sees where to go next.
    public var fogAhead: Float = 2.5

    public init() {}
}

/// Which cells of the wall and ground strips kept keyframes have seen.
///
/// Coverage is guidance, not proof: occlusion is not modelled, so a cell behind a bush still
/// counts as seen when the bush is in the way. The server re-checks what matters from the images.
public struct CoverageMap: Sendable {
    public private(set) var wall: WallFrame
    public let config: CoverageConfig
    /// Marked wall ends in meters of s. Nothing outside them is observed once they are set.
    public private(set) var leftEnd: Float?
    public private(set) var rightEnd: Float?
    /// Increments on every change.
    public private(set) var revision = 0

    private var cells: [SurfaceBand: [Int: Cell]] = [.wall: [:], .ground: [:]]

    private struct Cell: Sendable {
        var positions: [SIMD3<Float>] = []
        var skipped = false
        var covered = false

        var level: CoverageLevel {
            if covered { return .covered }
            if skipped { return .skipped }
            return positions.isEmpty ? .unseen : .seen
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

    /// Indices of every cell overlapping `range`.
    public func indices(overlapping range: ClosedRange<Float>) -> ClosedRange<Int> {
        let first = cellIndex(forS: range.lowerBound)
        var last = cellIndex(forS: range.upperBound)
        if cellRange(last).lowerBound >= range.upperBound, last > first { last -= 1 }
        return first...last
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
        var delta = Delta()
        for band in SurfaceBand.allCases {
            for index in candidateIndices(for: camera) where isVisible(band, index, from: camera) {
                var cell = cells[band]?[index] ?? Cell()
                let wasSeen = !cell.positions.isEmpty
                let isNewPosition = cell.positions.allSatisfy { simd_distance($0, camera.position) >= config.coveringBaseline }
                guard isNewPosition else { continue }
                cell.positions.append(camera.position)
                if !wasSeen { delta.newlySeen += 1 }
                if cell.positions.count >= 2, !cell.covered {
                    cell.covered = true
                    delta.newlyCovered += 1
                }
                cells[band, default: [:]][index] = cell
            }
        }
        if delta.changed { revision += 1 }
        return delta
    }

    /// How many cells this frame would see for the first time, if kept.
    public func newlySeenCount(from camera: CameraFrame) -> Int {
        var count = 0
        for band in SurfaceBand.allCases {
            for index in candidateIndices(for: camera) where (cells[band]?[index]?.positions.isEmpty ?? true) {
                if isVisible(band, index, from: camera) { count += 1 }
            }
        }
        return count
    }

    private func candidateIndices(for camera: CameraFrame) -> [Int] {
        let s = wall.wallPoint(camera.position).s
        return indices(overlapping: (s - config.maxDistance)...(s + config.maxDistance)).filter(allows)
    }

    /// Sample points of a cell: two positions along it times three heights (or depths).
    private func samples(_ band: SurfaceBand, _ index: Int) -> [(point: SIMD3<Float>, normal: SIMD3<Float>)] {
        let range = cellRange(index)
        let width = range.upperBound - range.lowerBound
        let alongs = [range.lowerBound + width * 0.25, range.lowerBound + width * 0.75]
        let fractions: [Float] = [1.0 / 6, 0.5, 5.0 / 6]
        var points: [(SIMD3<Float>, SIMD3<Float>)] = []
        for s in alongs {
            for f in fractions {
                switch band {
                case .wall: points.append((wall.world(s: s, height: f * config.wallBandHeight), wall.outward))
                case .ground: points.append((wall.world(s: s, height: 0, out: f * config.groundBandDepth), WallFrame.up))
                }
            }
        }
        return points
    }

    public func isVisible(_ band: SurfaceBand, _ index: Int, from camera: CameraFrame) -> Bool {
        let all = samples(band, index)
        let cosLimit = cos(config.maxAngleFromNormal)
        let passing = all.filter { sample in
            let toCamera = camera.position - sample.point
            let distance = simd_length(toCamera)
            guard distance <= config.maxDistance, distance > 0 else { return false }
            guard simd_dot(toCamera / distance, sample.normal) >= cosLimit else { return false }
            guard let pixel = camera.pixel(of: sample.point) else { return false }
            return camera.contains(pixel: pixel, margin: config.imageMargin)
        }.count
        return Float(passing) >= config.minSampleFraction * Float(all.count)
    }

    // MARK: Homeowner input

    public mutating func setEnd(_ side: WalkSide, at s: Float) {
        switch side {
        case .left: leftEnd = s
        case .right: rightEnd = s
        }
        revision += 1
    }

    /// Marks the not-yet-covered cells of `range` as skipped ("I can't get there").
    public mutating func markSkipped(_ band: SurfaceBand, _ range: ClosedRange<Float>) {
        for index in indices(overlapping: range) where allows(index) {
            var cell = cells[band]?[index] ?? Cell()
            guard !cell.covered else { continue }
            cell.skipped = true
            cells[band, default: [:]][index] = cell
        }
        revision += 1
    }

    /// Moves the map to a new wall frame (after the meter anchor is refined). Cells keep their
    /// s positions; camera positions keep their world positions.
    public mutating func updateWall(_ frame: WallFrame) {
        wall = frame
    }

    // MARK: Reading

    /// s extent of seen or covered cells, or nil when nothing has been seen.
    public var seenExtent: ClosedRange<Float>? {
        let seen = cells.values.flatMap { $0.filter { !$0.value.positions.isEmpty }.keys }
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
