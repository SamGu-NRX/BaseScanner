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
    /// This near band is what the coverage strip draws and what the walk's guidance asks for; how
    /// far out the ground was actually seen is `groundDepthReach` and `groundDepth(at:)`.
    public var groundBandDepth: Float = 1.2
    /// How far out from the wall ground depth is sampled: 17 ft (34 rows of 6 in), the deepest
    /// ground request the public rules make within cable reach, rounded up to a whole row.
    ///
    /// The server asks for ground out to D + r + e (server/README.md "What settles each check" on
    /// origin/t3/server), with D = 1.8333 ft, r = 10 ft for a pool (the largest clearance in
    /// rules.yaml) and e = 0.3 + 0.16 x ft at the battery's far edge, x ft along the walls from
    /// the meter. The server tries spots whose near edge is within (20 + 0.3 + 0.3 + 0.16 W) /
    /// (1 - 0.16) = 25.02 ft of the meter (solver.py `reach_limit`: the 20 ft cable maximum plus
    /// the default meter and wall errors, W = 2.5833 ft); past that the route fails whatever the
    /// ground shows. The far edge is then 27.60 ft out, e = 4.72 ft, and the pool request
    /// 16.55 ft. A larger meter or wall error, a detour round a wall object, or private rules can
    /// ask for more; `GapPlanner.isBeyondCapture` sends such a request to review.
    public var groundDepthReach: Float = 5.1816
    /// Spacing of the ground depth rows: 6 in, the cell width, so depth is sampled as densely out
    /// from the wall as the cells are along it. Depth is exported as a whole number of rows, so this
    /// is also the resolution of the reported depth; 6 in is under the position error the server
    /// assumes a few feet from the meter (0.3 ft plus 0.16 ft per foot). A hypothesis, not tuned.
    public var groundDepthSpacing: Float = 0.1524
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
    /// Two kept positions at most this far apart are one stretch of walked path: the homeowner
    /// went from one to the other, and a straight line between them is assumed. Keyframes are kept
    /// about every 0.5 m (`AutoCaptureConfig.spacingMeters`); 1 m allows one dropped frame
    /// between them while staying under two strides, too short to have walked around something.
    /// A hypothesis, not measured.
    public var walkStep: Float = 1.0
    /// Two kept positions at most this many seconds apart are one stretch of walked path; further
    /// apart, the homeowner may have gone anywhere between them. A guess, not measured: 2 s is a
    /// `walkStep` of 1 m at 0.5 m/s, a slow scanning pace. It bounds a detour on which no frame
    /// was kept (auto-capture keeps one every 0.5 m moved unless it skips them as blurry or
    /// hurried) to what 2 s of walking allows; it does not rule one out.
    public var walkGap: Double = 2
    /// A tilt-up view counts as overhead evidence only where it also shows the wall at this
    /// height, the top of the wall band, so what it shows above joins what the walk saw below
    /// without a hole between them.
    public var overheadFrom: Float = 1.9812
    /// Overhead heights are rounded down to 0.1 ft, so a view's cells merge into a few entries
    /// instead of differing in the last millimetre. It costs at most 0.1 ft of the height.
    public var overheadQuantum: Float = 0.03048
    /// Fog drawn ahead of what has been seen, so the homeowner sees where to go next.
    public var fogAhead: Float = 2.5

    public init() {}
}

/// Which cells of the wall and ground strips kept keyframes have seen.
///
/// Coverage marks what the camera pointed at, not what it saw. Occlusion is not modelled (whether
/// to is a pending team decision): a bush or bin in front of the wall is counted as seen wall and
/// ground; only the wall itself hides what lies behind it. Nothing downstream corrects
/// this; the server takes the covered intervals as given and does not read images. On ETH3D the
/// evals lane measured 1.1 ft of a 19.3 ft wall claimed covered that no photo saw, all of it
/// occluded at the bottom.
public struct CoverageMap: Sendable {
    public private(set) var wall: WallFrame
    public let config: CoverageConfig
    /// Marked wall ends in meters of s. Nothing outside them is observed once they are set, except
    /// ground past a limit end (`limitEnds`).
    public private(set) var leftEnd: Float?
    public private(set) var rightEnd: Float?
    /// Marked ends the homeowner said are real limits: no usable wall past them (a fence, a
    /// corner the walk does not follow). Ground past one still counts for clearances, so it is
    /// sampled and reported (`groundDepthSpans`); past any other end nothing is.
    public private(set) var limitEnds: Set<WalkSide> = []
    /// Increments on every change.
    public private(set) var revision = 0

    private var cells: [SurfaceBand: [Int: Cell]] = [.wall: [:], .ground: [:]]
    /// Per cell, per ground depth row (0 at the wall foot, then every `groundDepthSpacing` out to
    /// `groundDepthReach`), the camera positions that saw it, pairwise at least `coveringBaseline`
    /// apart, two at most. Separate from `cells` so the near ground band the strip draws keeps its
    /// meaning.
    private var depthCells: [Int: [[SIMD3<Float>]]] = [:]
    /// Per limit end, per cell past it (0 touching the end, counting away from the meter), the
    /// camera positions that saw each ground depth row on both sides of the wall's continued
    /// line: the rows in front (out = +row), then the rows behind (out = -row). Kept like
    /// `depthCells`. The cells start at the end itself, so what they report meets the ground
    /// clipped to the end exactly.
    private var pastLimitCells: [WalkSide: [Int: [[SIMD3<Float>]]]] = [:]
    /// s shift from meter moves not yet applied to skipped cells, meters (see `updateWall`).
    private var pendingShift: Float = 0
    /// Cameras of the frames `observe` recorded, oldest first, so a new wall frame can be replayed
    /// against them. Sightings recorded directly through `record` are not kept.
    public private(set) var observedCameras: [CameraFrame] = []
    /// Tilt-up views the homeowner confirmed have nothing overhead (`recordOverhead`), oldest
    /// first. What each showed is worked out against the current wall when read.
    public private(set) var overheadCameras: [CameraFrame] = []
    /// Per entry of `observedCameras`, the frame clock time it was kept at; nil when the caller
    /// gave none, and such a pose is never joined into walked path.
    private var observedTimes: [Double?] = []
    /// Indices of `observedCameras` whose pose is not joined to the one before it
    /// (`breakWalkedPath`).
    private var pathStarts: Set<Int> = []
    /// Set by `breakWalkedPath` until the next observed camera starts a new stretch.
    private var pathBroken = false

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

    /// A cell's s range. Each edge is computed from its own index, so neighbouring cells share a
    /// bit-identical edge: exported spans of neighbouring cells then meet exactly, where
    /// `start + width` could leave an ulp between them that the server (which joins spans only
    /// within 1e-9 ft) would read as an unobserved sliver.
    public func cellRange(_ index: Int) -> ClosedRange<Float> {
        (Float(index) * config.cellWidth)...(Float(index + 1) * config.cellWidth)
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

    /// Whether any of a cell lies between the marked ends. Cells beyond them are never observed;
    /// ground past a limit end is kept apart (`groundDepthPastLimit`).
    public func isWithinEnds(_ index: Int) -> Bool { allows(index) }

    /// The s range allowed by the marked ends; unbounded sides are nil.
    private func allows(_ index: Int) -> Bool {
        let range = cellRange(index)
        if let leftEnd, range.upperBound <= leftEnd { return false }
        if let rightEnd, range.lowerBound >= rightEnd { return false }
        return true
    }

    // MARK: Observing

    /// Records a kept keyframe kept at `time` seconds on the frame clock. Returns nothing new
    /// unless tracking was normal for it: frames with limited tracking have poses that can be off
    /// by more than a cell, and such a frame also breaks the walked path (`breakWalkedPath`).
    /// Without a `time` the pose still counts for the bands, but never for walked path.
    @discardableResult
    public mutating func observe(_ camera: CameraFrame, trackingNormal: Bool, time: Double? = nil) -> Delta {
        guard trackingNormal else {
            breakWalkedPath()
            return Delta()
        }
        if pathBroken {
            pathStarts.insert(observedCameras.count)
            pathBroken = false
        }
        observedCameras.append(camera)
        observedTimes.append(time)
        let depthChanged = recordDepth(from: camera)
        let pastChanged = recordPastLimits(from: camera)
        let delta = record(visibleCells(from: camera), from: camera.position)
        // One change, one increment: `record` has counted it when the bands changed too.
        if depthChanged || pastChanged, !delta.changed { revision += 1 }
        return delta
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
        let offsets = rowOffsets(band)
        return sampledRows(index, from: camera, rows: rows, onWallFace: band == .wall) { s, row in
            band == .wall ? wall.world(s: s, height: offsets[row]) : wall.world(s: s, height: 0, out: offsets[row])
        }
    }

    /// The rows of a cell whose samples, a quarter and three quarters along it, are all in view:
    /// in front of the camera, inside the image margin, within `maxDistance`, and seen within
    /// `maxAngleFromNormal` of the surface's normal: the outward of the cell's piece of wall for
    /// the wall face, up for the ground.
    private func sampledRows(
        _ index: Int, from camera: CameraFrame, rows: [Int], onWallFace: Bool,
        point: (_ s: Float, _ row: Int) -> SIMD3<Float>
    ) -> Set<Int> {
        let range = cellRange(index)
        let width = range.upperBound - range.lowerBound
        let middle = range.lowerBound + width / 2
        // Behind the plane of the cell's piece of wall the wall itself hides both bands. Occlusion
        // is otherwise not modelled, and the ground row at the wall's foot would pass from there.
        guard wall.out(of: camera.position, pieceAtS: middle) > 0 else { return [] }
        let normal = onWallFace ? wall.segment(atS: middle).outward : WallFrame.up
        let alongs = [range.lowerBound + width * 0.25, range.lowerBound + width * 0.75]
        let cosLimit = cos(config.maxAngleFromNormal)
        func sees(_ point: SIMD3<Float>) -> Bool {
            let toCamera = camera.position - point
            let distance = simd_length(toCamera)
            guard distance <= config.maxDistance, distance > 0 else { return false }
            guard simd_dot(toCamera / distance, normal) >= cosLimit else { return false }
            guard let pixel = camera.pixel(of: point) else { return false }
            return camera.contains(pixel: pixel, margin: config.imageMargin)
        }
        return Set(rows.filter { row in alongs.allSatisfy { sees(point($0, row)) } })
    }

    // MARK: Ground depth

    /// Distance out from the wall of each ground depth row: 0, then every `groundDepthSpacing`
    /// up to `groundDepthReach`.
    public var groundDepthRows: [Float] {
        let count = Int((config.groundDepthReach / config.groundDepthSpacing + 1e-3).rounded(.down))
        return (0...max(1, count)).map { Float($0) * config.groundDepthSpacing }
    }

    /// The ground depth rows of a cell a frame sees, by the same rules as the bands' rows.
    public func visibleDepthRows(_ index: Int, from camera: CameraFrame) -> Set<Int> {
        let rows = groundDepthRows
        return sampledRows(index, from: camera, rows: Array(rows.indices), onWallFace: false) { s, row in
            wall.world(s: s, height: 0, out: rows[row])
        }
    }

    /// Adds a kept frame's view of the ground depth rows; true when any row gained a position.
    @discardableResult
    private mutating func recordDepth(from camera: CameraFrame) -> Bool {
        let rowCount = groundDepthRows.count
        var changed = false
        for index in candidateIndices(for: camera) {
            let seen = visibleDepthRows(index, from: camera)
            guard !seen.isEmpty else { continue }
            var rows = depthCells[index] ?? Array(repeating: [], count: rowCount)
            for row in seen where rows[row].count < 2
                && rows[row].allSatisfy({ simd_distance($0, camera.position) >= config.coveringBaseline }) {
                rows[row].append(camera.position)
                changed = true
            }
            depthCells[index] = rows
        }
        return changed
    }

    /// How far out from the wall the ground of a cell was seen, meters: the farthest depth row
    /// such that every row from the wall foot out to it was seen from two positions at least
    /// `coveringBaseline` apart (occlusion is not modelled; see the type's comment). Nil when
    /// not even the first row past the foot is, or the cell lies beyond a marked end.
    public func groundDepth(at index: Int) -> Float? {
        guard allows(index), let rows = depthCells[index] else { return nil }
        let covered = rows.prefix { $0.count >= 2 }.count
        guard covered >= 2 else { return nil }
        return groundDepthRows[covered - 1]
    }

    /// Stretches of ground and how far out each was seen (`groundDepth(at:)`, and past a limit
    /// end `groundDepthPastLimit`), merged where neighbouring cells reached the same depth.
    /// Every depth is a whole number of rows, so equal depths merge exactly and none is rounded up.
    public func groundDepthSpans() -> [ObservedSpan] {
        let inside = ObservedSpan.merge(depthCells.keys.sorted().compactMap { index in
            groundDepth(at: index).map { ObservedSpan(span: cellRange(index), out: $0) }
        }, touching: config.cellWidth * 0.01).map(clippedToEnds)
        let past = pastLimitCells.flatMap { side, cells in
            cells.keys.compactMap { cell -> ObservedSpan? in
                guard let end = end(side), let depth = groundDepthPastLimit(side, cell) else { return nil }
                return ObservedSpan(span: pastCellRange(side, cell, end: end), out: depth)
            }
        }
        let all = (inside + past).sorted { $0.span.lowerBound < $1.span.lowerBound }
        return ObservedSpan.merge(all, touching: config.cellWidth * 0.01)
    }

    // MARK: Ground past a limit end

    /// How far out the ground of a cell past a limit end was seen, meters: the farthest depth row
    /// such that every row out to it, on both sides of the wall's continued line, was seen from
    /// two positions at least `coveringBaseline` apart. The server reads ground past a limit end
    /// as covering both sides of that line (server/README.md "Ends and corners" on
    /// origin/t3/server), so one side seen is not enough. Cell 0 touches the end. Nil when the
    /// end on `side` is not a limit or not even the first row past the line is seen both ways.
    public func groundDepthPastLimit(_ side: WalkSide, _ cell: Int) -> Float? {
        guard limitEnds.contains(side), let rows = pastLimitCells[side]?[cell] else { return nil }
        let count = groundDepthRows.count
        let front = rows[0..<count].prefix { $0.count >= 2 }.count
        let behind = rows[count...].prefix { $0.count >= 2 }.count
        let covered = min(front, behind)
        guard covered >= 2 else { return nil }
        return groundDepthRows[covered - 1]
    }

    private func end(_ side: WalkSide) -> Float? { side == .left ? leftEnd : rightEnd }

    /// The s range of the `cell`th cell past `end`, counting away from the meter.
    private func pastCellRange(_ side: WalkSide, _ cell: Int, end: Float) -> ClosedRange<Float> {
        let near = end + side.sign * Float(cell) * config.cellWidth
        let far = end + side.sign * Float(cell + 1) * config.cellWidth
        return min(near, far)...max(near, far)
    }

    /// The piece of wall a limit end is on. Past the end the server continues this piece's line
    /// straight (the chain the export sends stops at the end), so past cells use it too. A
    /// corner's own s belongs to the piece on its left, which is the chain's last piece for a
    /// right end there; a left end there starts the piece on its right.
    private func endPiece(_ side: WalkSide, end: Float) -> WallSegment {
        wall.segment(atS: side == .left ? end.nextUp : end)
    }

    /// Adds a kept frame's view of the ground past each limit end; true when any row gained a
    /// position.
    ///
    /// Samples are placed and seen like the ground depth rows (`sampledRows`), on the end
    /// piece's line continued. The camera must stand in front of the wall. A sample behind the
    /// continued line counts only when the sight line to it crosses that line past the end: one
    /// crossing short of the end runs through the house. Nothing else hides anything: the
    /// house's other walls are not modelled (at an inside corner, where the next wall comes
    /// forward, ground past the end is counted though it is indoors), and neither is anything
    /// standing on the ground (see the type's comment).
    @discardableResult
    private mutating func recordPastLimits(from camera: CameraFrame) -> Bool {
        guard wall.wallPoint(camera.position).out > 0 else { return false }
        var changed = false
        for side in limitEnds {
            guard let end = end(side) else { continue }
            let piece = endPiece(side, end: end)
            let origin = wall.origin
            let eye = piece.coordinates(ofOffset: camera.position - origin)
            guard eye.out > 0 else { continue }
            // Cells whose s lies within `maxDistance` of the camera's along the end's piece.
            let beyond = (eye.s - end) * side.sign
            let last = Int(((beyond + config.maxDistance) / config.cellWidth).rounded(.down))
            let first = max(0, Int(((beyond - config.maxDistance) / config.cellWidth).rounded(.down)))
            guard last >= first else { continue }
            let depths = groundDepthRows
            let cosLimit = cos(config.maxAngleFromNormal)
            func point(_ s: Float, _ out: Float) -> SIMD3<Float> {
                origin + piece.anchor + piece.along * (s - piece.anchorS) + piece.outward * out
            }
            func sees(_ s: Float, _ out: Float) -> Bool {
                if out < 0 {
                    // Where the sight line crosses the continued line (out = 0).
                    let crossing = eye.s + (s - eye.s) * eye.out / (eye.out - out)
                    guard (crossing - end) * side.sign >= 0 else { return false }
                }
                let target = point(s, out)
                let toCamera = camera.position - target
                let distance = simd_length(toCamera)
                guard distance <= config.maxDistance, distance > 0,
                      simd_dot(toCamera / distance, WallFrame.up) >= cosLimit,
                      let pixel = camera.pixel(of: target) else { return false }
                return camera.contains(pixel: pixel, margin: config.imageMargin)
            }
            for cell in first...last {
                let range = pastCellRange(side, cell, end: end)
                let width = range.upperBound - range.lowerBound
                let alongs = [range.lowerBound + width * 0.25, range.lowerBound + width * 0.75]
                var rows = pastLimitCells[side]?[cell] ?? Array(repeating: [], count: 2 * depths.count)
                var added = false
                for row in rows.indices {
                    let out = row < depths.count ? depths[row] : -depths[row - depths.count]
                    guard rows[row].count < 2,
                          rows[row].allSatisfy({ simd_distance($0, camera.position) >= config.coveringBaseline }),
                          alongs.allSatisfy({ sees($0, out) }) else { continue }
                    rows[row].append(camera.position)
                    added = true
                }
                if added {
                    pastLimitCells[side, default: [:]][cell] = rows
                    changed = true
                }
            }
        }
        return changed
    }

    /// Rebuilds the ground past the limit ends from `observedCameras`, after an end moved or
    /// became or stopped being a limit.
    private mutating func replayPastLimits() {
        pastLimitCells = [:]
        guard !limitEnds.isEmpty else { return }
        for camera in observedCameras { recordPastLimits(from: camera) }
    }

    // MARK: Facing space

    /// The server's default position error for something placed in AR, meters, at `s` meters
    /// along the wall from the meter: 0.3 ft plus 0.16 ft per foot (server/README.md, "Writing
    /// a scene" and "What settles each check", on origin/t3/server at e0ee8d3). The 0.16 per foot
    /// is the server's measured ARKit drift; in meters it is 0.16 m per meter.
    public static func positionError(atS s: Float) -> Float {
        0.3 * 0.3048 + 0.16 * abs(s)
    }

    /// How far out from the wall a cell is known clear because the homeowner walked past it,
    /// meters. A step is the straight line between consecutive kept positions with normal
    /// tracking, with no `breakWalkedPath` between them, both in front of the wall, at most
    /// `walkStep` apart and kept at most `walkGap` seconds apart; it shows the space
    /// between the wall and itself clear, out to its end nearer the wall. The cell is clear out
    /// to the largest distance d such that steps reaching at least d cover it along the wall.
    /// That distance less `positionError` at the cell's edge farther from the meter is the
    /// clearance, which the contract takes as exact ("for a walked path, the distance from the
    /// wall less your position error"). Nil when no steps cover the cell, nothing is left after
    /// the error, or the cell lies beyond a marked end.
    ///
    /// Only the phone's path is known, so this is the space between the wall and the phone; the
    /// homeowner's body is behind it, farther out. Something low the phone passed over (a bush
    /// under chest height) is not seen; occlusion is not modelled here either.
    public func walkedClearance(at index: Int) -> Float? {
        walkedClearance(at: index, steps: walkedSteps())
    }

    private func walkedClearance(at index: Int, steps: [WalkedStep]) -> Float? {
        guard allows(index) else { return nil }
        let cell = cellRange(index)
        let tolerance: Float = 1e-5
        let over = steps.filter { $0.low < cell.upperBound - tolerance && $0.high > cell.lowerBound + tolerance }
        // Deepest first: the first depth whose steps join up across the cell is the answer.
        for depth in Set(over.map(\.nearest)).sorted(by: >) {
            var reached = cell.lowerBound
            for step in over.filter({ $0.nearest >= depth }).sorted(by: { $0.low < $1.low }) where step.low <= reached + tolerance {
                reached = max(reached, step.high)
            }
            guard reached >= cell.upperBound - tolerance else { continue }
            let clear = depth - Self.positionError(atS: max(abs(cell.lowerBound), abs(cell.upperBound)))
            return clear > 0 ? clear : nil
        }
        return nil
    }

    /// Stretches known clear in front of the wall from the walked path (`walkedClearance(at:)`),
    /// neighbours of equal clearance merged. The error grows by 0.08 ft a cell, so this is
    /// nearly one span per walked cell (80 for a walk 6 m either side of the meter).
    public func facingSpans() -> [ObservedSpan] {
        let steps = walkedSteps()
        guard let low = steps.map(\.low).min(), let high = steps.map(\.high).max(), low < high else { return [] }
        let items = indices(overlapping: low...high).compactMap { index in
            walkedClearance(at: index, steps: steps).map { ObservedSpan(span: cellRange(index), out: $0) }
        }
        return ObservedSpan.merge(items, touching: config.cellWidth * 0.01).map(clippedToEnds)
    }

    private struct WalkedStep {
        var low: Float
        var high: Float
        /// Distance from the wall of the step's end nearer to it.
        var nearest: Float
    }

    /// The homeowner's path is not continuous from the last kept pose to the next one (tracking
    /// was lost, or the capture paused): walked-path facing does not join the poses on either
    /// side. A straight line across an outage or a detour would claim space no one walked past.
    public mutating func breakWalkedPath() {
        pathBroken = true
    }

    private func walkedSteps() -> [WalkedStep] {
        observedCameras.indices.dropFirst().compactMap { index in
            guard !pathStarts.contains(index),
                  let t0 = observedTimes[index - 1], let t1 = observedTimes[index], abs(t1 - t0) <= config.walkGap else { return nil }
            let first = observedCameras[index - 1]
            let second = observedCameras[index]
            guard simd_distance(first.position, second.position) <= config.walkStep else { return nil }
            let a = wall.wallPoint(first.position)
            let b = wall.wallPoint(second.position)
            guard a.out > 0, b.out > 0 else { return nil }
            return WalkedStep(low: min(a.s, b.s), high: max(a.s, b.s), nearest: min(a.out, b.out))
        }
    }

    // MARK: Overhead

    /// What a view tilted up at the wall shows: per cell along the wall, the height on the wall's
    /// plane the view reached, rounded down to `overheadQuantum`, neighbours of equal height
    /// merged. A pure function of the camera, the wall and the marked ends; it records nothing.
    ///
    /// A cell counts when both its samples (a quarter and three quarters along it) are in view at
    /// `overheadFrom`; its height is the highest point above that still in view at both, where
    /// in view means in front of the camera, inside the image margin and within `maxDistance`.
    /// The view of a plane is convex, so everything between the two heights is in view too.
    /// Unlike the bands there is no limit on obliqueness: nothing is measured on this part of the
    /// wall, the homeowner only judges whether anything is overhead. Empty when the camera is
    /// behind the wall or does not show the wall at `overheadFrom`.
    ///
    /// The camera sees the wall's plane, not what is on it: it can't tell open sky above a
    /// one-storey eave from the wall. So a reach is evidence only once the homeowner has said
    /// nothing is overhead (`recordOverhead`).
    public func overheadReach(from camera: CameraFrame) -> [ObservedSpan] {
        guard wall.wallPoint(camera.position).out > 0 else { return [] }
        func inView(_ s: Float, _ height: Float) -> Bool {
            let point = wall.world(s: s, height: height)
            guard simd_distance(point, camera.position) <= config.maxDistance, let pixel = camera.pixel(of: point) else { return false }
            return camera.contains(pixel: pixel, margin: config.imageMargin)
        }
        func reach(_ s: Float) -> Float? {
            guard inView(s, config.overheadFrom) else { return nil }
            var low = config.overheadFrom
            var high = config.overheadFrom + config.maxDistance
            // Bisection to under a millimetre; `low` stays in view throughout.
            for _ in 0..<14 {
                let middle = (low + high) / 2
                if inView(s, middle) { low = middle } else { high = middle }
            }
            return low
        }
        let items = candidateIndices(for: camera).compactMap { index -> ObservedSpan? in
            let range = cellRange(index)
            let width = range.upperBound - range.lowerBound
            guard let a = reach(range.lowerBound + width * 0.25), let b = reach(range.lowerBound + width * 0.75) else { return nil }
            let height = (min(a, b) / config.overheadQuantum).rounded(.down) * config.overheadQuantum
            return ObservedSpan(span: range, out: height)
        }
        return ObservedSpan.merge(items, touching: config.cellWidth * 0.01).map(clippedToEnds)
    }

    /// Keeps a tilt-up view as overhead evidence. Call it only after the homeowner answered that
    /// nothing is overhead there (ScanActions.answerOverhead(clear: true)): the camera cannot
    /// tell a clear view from an eave. Returns what the view showed (`overheadReach`); nothing
    /// is kept when tracking was not normal or the view showed no wall at `overheadFrom`.
    @discardableResult
    public mutating func recordOverhead(_ camera: CameraFrame, trackingNormal: Bool) -> [ObservedSpan] {
        guard trackingNormal else { return [] }
        let reach = overheadReach(from: camera)
        guard !reach.isEmpty else { return [] }
        overheadCameras.append(camera)
        revision += 1
        return reach
    }

    /// Height seen clear above a cell, meters: the highest any recorded tilt-up view reached
    /// there. Nil when none reached it.
    public func overheadHeight(at index: Int) -> Float? {
        guard allows(index) else { return nil }
        let middle = (cellRange(index).lowerBound + cellRange(index).upperBound) / 2
        return overheadCameras.compactMap { camera in
            overheadReach(from: camera).first { $0.span.contains(middle) }?.out
        }.max()
    }

    /// Stretches seen clear overhead, each with the height seen (`overheadHeight(at:)`), for
    /// scene.json's overhead band.
    public func overheadSpans() -> [ObservedSpan] {
        var best: [Int: Float] = [:]
        for camera in overheadCameras {
            for item in overheadReach(from: camera) {
                for index in indices(overlapping: item.span) where allows(index) {
                    best[index] = max(best[index] ?? item.out, item.out)
                }
            }
        }
        let items = best.keys.sorted().compactMap { index in best[index].map { ObservedSpan(span: cellRange(index), out: $0) } }
        return ObservedSpan.merge(items, touching: config.cellWidth * 0.01).map(clippedToEnds)
    }

    /// A span trimmed to the marked ends. Cells overlapping an end keep only the allowed part.
    private func clippedToEnds(_ observed: ObservedSpan) -> ObservedSpan {
        var span = observed.span
        if let leftEnd { span = max(span.lowerBound, leftEnd)...max(span.upperBound, leftEnd) }
        if let rightEnd { span = min(span.lowerBound, rightEnd)...min(span.upperBound, rightEnd) }
        return ObservedSpan(span: span, out: observed.out)
    }

    /// Whether a frame sees any row of the cell.
    public func isVisible(_ band: SurfaceBand, _ index: Int, from camera: CameraFrame) -> Bool {
        !visibleRows(band, index, from: camera).isEmpty
    }

    // MARK: Homeowner input

    /// Marks the wall's end on `side` at `s`. The end is unexplored until `setEndIsLimit` says
    /// otherwise, also when it was a limit before it moved.
    public mutating func setEnd(_ side: WalkSide, at s: Float) {
        switch side {
        case .left: leftEnd = s
        case .right: rightEnd = s
        }
        if limitEnds.remove(side) != nil { replayPastLimits() }
        revision += 1
    }

    /// Says whether the marked end on `side` is a real limit (scene.json's `limit`) or not
    /// (`unexplored`). Only past a limit is ground reported. Does nothing when no end is marked
    /// on that side: a limit is a property of a marked end.
    public mutating func setEndIsLimit(_ side: WalkSide, _ isLimit: Bool) {
        guard end(side) != nil, limitEnds.contains(side) != isLimit else { return }
        if isLimit { limitEnds.insert(side) } else { limitEnds.remove(side) }
        replayPastLimits()
        revision += 1
    }

    /// Forgets a marked end, for example to walk past it when the server asks what lies beyond.
    public mutating func clearEnd(_ side: WalkSide) {
        switch side {
        case .left: leftEnd = nil
        case .right: rightEnd = nil
        }
        if limitEnds.remove(side) != nil { replayPastLimits() }
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
    /// Corners the walk followed move like the ends, so they keep their place in the world: pass
    /// `frame` with the corners it had (a copy of `wall` with a new meter or ground).
    /// Assumes the wall's direction is unchanged.
    public mutating func updateWall(_ frame: WallFrame) {
        guard frame != wall else { return }
        let delta = simd_dot(wall.meter - frame.meter, frame.along)
        var frame = frame
        frame.shiftCorners(by: delta)
        wall = frame
        leftEnd = leftEnd.map { $0 + delta }
        rightEnd = rightEnd.map { $0 + delta }
        pendingShift += delta
        let whole = Int((pendingShift / config.cellWidth).rounded())
        pendingShift -= Float(whole) * config.cellWidth
        replayObservedCameras(shiftingSkippedBy: whole)
    }

    /// How far from the marked end on its side (or, with none marked, the far edge of what was
    /// seen) a corner may lie: 3 m. A guess, not measured: the homeowner marked the end at the
    /// corner, and AR taps near the walk are off by well under a meter, so a corner farther
    /// away means the marked wall is some other wall.
    public static let maxCornerFromEnd: Float = 3

    /// Follows the wall round a corner on `side`, to the wall the homeowner marked at `point`
    /// facing `outward` (toward the homeowner). The corner is where the two walls' lines meet on
    /// the ground (`WallFrame.corner(on:meeting:outward:)`). The end on that side is cleared, so
    /// the walk goes on along the new wall, and every kept camera is replayed against the new
    /// chain: cells past the corner were measured on the old wall's line. Changes nothing when
    /// it throws.
    @discardableResult
    public mutating func turnCorner(_ side: WalkSide, meeting point: SIMD3<Float>, outward: SIMD3<Float>) throws(CornerRefusal) -> WallCorner {
        let corner = try wall.corner(on: side, meeting: point, outward: outward)
        let seenEdge = seenExtent.map { side == .left ? $0.lowerBound : $0.upperBound }
        let reference = (side == .left ? leftEnd : rightEnd) ?? seenEdge ?? 0
        guard abs(corner.s - reference) <= Self.maxCornerFromEnd else { throw .implausible(s: corner.s) }
        wall.turn(side, at: corner)
        switch side {
        case .left: leftEnd = nil
        case .right: rightEnd = nil
        }
        limitEnds.remove(side)
        replayObservedCameras(shiftingSkippedBy: 0)
        return corner
    }

    /// Rebuilds seen and covered cells by replaying `observedCameras` against the current wall,
    /// keeping skipped cells, moved by `whole` cells.
    private mutating func replayObservedCameras(shiftingSkippedBy whole: Int) {
        var skipped: [SurfaceBand: [Int: Cell]] = [.wall: [:], .ground: [:]]
        for (band, bandCells) in cells {
            for (index, cell) in bandCells where cell.skipped {
                var kept = Cell(rowCount: config.rowsPerBand)
                kept.skipped = true
                skipped[band, default: [:]][index + whole] = kept
            }
        }
        cells = skipped
        depthCells = [:]
        for camera in observedCameras {
            recordDepth(from: camera)
            record(visibleCells(from: camera), from: camera.position)
        }
        replayPastLimits()
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

/// A stretch of wall (s, meters) and how far the view of it reached, meters: out from the wall
/// for ground and facing, up from the ground for overhead. It is scene.json's `coverage.observed`
/// entry before conversion to feet (`span_ft`, `out_ft`), and like `out_ft` it is a distance the
/// capture is sure of, never rounded up.
public struct ObservedSpan: Sendable, Equatable {
    public var span: ClosedRange<Float>
    public var out: Float

    public init(span: ClosedRange<Float>, out: Float) {
        self.span = span
        self.out = out
    }

    /// Joins neighbours (in s order) that touch within `touching` and reach exactly as far.
    static func merge(_ sorted: [ObservedSpan], touching: Float) -> [ObservedSpan] {
        var runs: [ObservedSpan] = []
        for item in sorted {
            if let last = runs.last, last.out == item.out, abs(last.span.upperBound - item.span.lowerBound) < touching {
                runs[runs.count - 1].span = last.span.lowerBound...item.span.upperBound
            } else {
                runs.append(item)
            }
        }
        return runs
    }
}

public enum WalkSide: String, Sendable, CaseIterable {
    case left
    case right

    /// -1 for left, +1 for right: the sign of s on this side of the meter.
    public var sign: Float { self == .left ? -1 : 1 }
    public var opposite: WalkSide { self == .left ? .right : .left }
}
