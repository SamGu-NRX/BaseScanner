import Foundation

/// One targeted request for missing evidence.
public struct GapPlan: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// Ground at the foot of the wall, where a battery would stand.
        case groundNearMeter
        /// Wall face, where a battery would back onto and the cable would run.
        case wallNearMeter
        /// The server listed it.
        case server
    }

    /// What settles the request.
    public enum Need: Sendable, Equatable {
        /// The band covered over the span: `GapPlannerConfig.satisfiedFraction` of its cells for
        /// the phone's own request, all of the span as exported for a server request.
        case cells
        /// The ground seen out to this many meters from the wall over the whole span
        /// (`CoverageMap.groundDepth(at:)`).
        case groundOut(Float)
        /// The span walked past with this many meters of clearance left after the position error
        /// (`CoverageMap.walkedClearance(at:)`): the walk must pass `out` plus the error out.
        case walkOut(Float)
        /// A recorded tilt-up view over the whole span reaching this height, meters
        /// (`CoverageMap.overheadHeight(at:)`); nil when any recorded view does.
        case overhead(Float?)
    }

    /// The band the request is drawn on: facing requests on the ground, overhead on the wall.
    public var band: SurfaceBand
    public var span: ClosedRange<Float>
    public var reason: Reason
    public var need: Need

    public init(band: SurfaceBand, span: ClosedRange<Float>, reason: Reason, need: Need = .cells) {
        self.band = band
        self.span = span
        self.reason = reason
        self.need = need
    }
}

public struct GapPlannerConfig: Sendable, Equatable {
    /// Look for gaps within this distance of the meter: about 20 ft, the same reach the walk uses.
    public var reach: Float = 6.1
    /// A gap narrower than 0.45 m (three 6 in cells) can't hide a battery footprint, so it is not
    /// worth a second walk.
    public var minRun: Float = 0.45
    /// The phone's own request counts as satisfied at 80 % of its cells covered, allowing a cell
    /// or two at the edges that a real camera never quite reaches. A guess, not measured. Server
    /// requests need their whole span (`isSatisfied`).
    public var satisfiedFraction: Double = 0.8

    public init() {}
}

/// Finds the most decision-relevant missing evidence after the walk.
public struct GapPlanner: Sendable {
    public let config: GapPlannerConfig

    public init(config: GapPlannerConfig = GapPlannerConfig()) {
        self.config = config
    }

    /// The stretch the search covers: between the marked ends (or what was seen, for an end not
    /// marked), within `reach` of the meter.
    public func searchRange(_ coverage: CoverageMap) -> ClosedRange<Float>? {
        guard let seen = coverage.seenExtent else { return nil }
        let low = max(coverage.leftEnd ?? seen.lowerBound, -config.reach)
        let high = min(coverage.rightEnd ?? seen.upperBound, config.reach)
        return low < high ? low...high : nil
    }

    /// Prefers an uncovered ground run nearest the meter, since the ground under a candidate spot
    /// decides whether a battery can stand there; otherwise a wall run. Skipped cells are not
    /// asked for again.
    public func plan(_ coverage: CoverageMap) -> GapPlan? {
        guard let range = searchRange(coverage) else { return nil }
        for band in [SurfaceBand.ground, .wall] {
            let runs = missingRuns(band, in: range, coverage: coverage)
            let nearest = runs.min { distanceToMeter($0) < distanceToMeter($1) }
            if let nearest {
                return GapPlan(band: band, span: nearest, reason: band == .ground ? .groundNearMeter : .wallNearMeter)
            }
        }
        return nil
    }

    /// Runs of unseen or seen-once cells at least `minRun` long, clipped to `range`.
    public func missingRuns(_ band: SurfaceBand, in range: ClosedRange<Float>, coverage: CoverageMap) -> [ClosedRange<Float>] {
        var runs: [ClosedRange<Float>] = []
        var start: Float?
        var end: Float = 0
        for index in coverage.indices(overlapping: range) {
            let cell = coverage.cellRange(index).clamped(to: range)
            let level = coverage.level(band, index)
            if level == .unseen || level == .seen {
                if start == nil { start = cell.lowerBound }
                end = cell.upperBound
            } else if let s = start {
                runs.append(s...end)
                start = nil
            }
        }
        if let s = start { runs.append(s...end) }
        return runs.filter { $0.upperBound - $0.lowerBound >= config.minRun - 1e-4 }
    }

    /// The fraction of the request met so far: of its cells for a phone request or a reach, of
    /// its span as the exported scene will report it for a server cell request.
    public func progress(of gap: GapPlan, _ coverage: CoverageMap) -> Double {
        // A reach meets a request in feet as the export will report it (rounded down), so the
        // phone never calls a request met that the uploaded scene falls short of.
        func reaches(_ value: Float?, _ needed: Float) -> Bool {
            guard let value else { return false }
            return SceneExport.feetDown(value) >= SceneExport.round4(Double(needed) * SceneUnits.feetPerMeter)
        }
        let met: (Int) -> Bool
        switch gap.need {
        case .cells where gap.reason == .server:
            return Self.fraction(of: gap.span, coveredBy: Self.exportedSpans(gap.band, coverage))
        case .cells:
            return coverage.coveredFraction(gap.band, in: gap.span)
        case .groundOut(let out):
            met = { reaches(coverage.groundDepth(at: $0), out) }
        case .walkOut(let out):
            met = { reaches(coverage.walkedClearance(at: $0), out) }
        case .overhead(let height):
            met = { index in height.map { reaches(coverage.overheadHeight(at: index), $0) } ?? (coverage.overheadHeight(at: index) != nil) }
        }
        let cells = coverage.indices(overlapping: gap.span).filter(coverage.isWithinEnds)
        guard !cells.isEmpty else { return 0 }
        return Double(cells.filter(met).count) / Double(cells.count)
    }

    /// A server request is met only over its whole span: the server settles it only when observed
    /// entries cover all of it (server/README.md, "What settles each check"). The phone's own
    /// cell request is met at `satisfiedFraction`: it is this planner's guess at what the server
    /// will want, not a span the server named, and the upload it leads to asks for exactly what
    /// is still missing, so holding the homeowner there for the last edge cell buys nothing.
    public func isSatisfied(_ gap: GapPlan, _ coverage: CoverageMap) -> Bool {
        let progress = progress(of: gap, coverage)
        return gap.need == .cells && gap.reason != .server ? progress >= config.satisfiedFraction : progress >= 1
    }

    /// Whether a tilt-up view settles an overhead request once the homeowner says nothing is
    /// overhead: recorded with the views already kept, it meets the request over the whole span.
    /// False for any other request. The engine asks the overhead question only when this holds,
    /// so the answer "nothing overhead" always closes the request.
    public func overheadViewSettles(_ gap: GapPlan, _ coverage: CoverageMap, camera: CameraFrame) -> Bool {
        guard case .overhead = gap.need else { return false }
        var trial = coverage
        guard !trial.recordOverhead(camera, trackingNormal: true).isEmpty else { return false }
        return isSatisfied(gap, trial)
    }

    /// The stretches scene.json will list as observed in `band`, meters (`SceneCoverage`): the
    /// wall band's covered runs, and every ground entry whatever its depth.
    static func exportedSpans(_ band: SurfaceBand, _ coverage: CoverageMap) -> [ClosedRange<Float>] {
        switch band {
        case .wall: coverage.coveredIntervals(.wall)
        case .ground: coverage.groundDepthSpans().map(\.span)
        }
    }

    /// The fraction of `span` that `spans` cover, measured the way the server reads the uploaded
    /// scene: both in feet at the export's four decimals, joined where they touch within 1e-9 ft
    /// (server/scene.py `missing` on origin/t3/server). Rounding the request as well absorbs the
    /// Float round trip of its feet through meters.
    static func fraction(of span: ClosedRange<Float>, coveredBy spans: [ClosedRange<Float>]) -> Double {
        let feet = { (meters: Float) in SceneExport.round4(Double(meters) * SceneUnits.feetPerMeter) }
        let low = feet(span.lowerBound)
        let high = feet(span.upperBound)
        guard high > low else { return 0 }
        let eps = 1e-9
        var cursor = low
        var missing = 0.0
        for (a, b) in spans.map({ (feet($0.lowerBound), feet($0.upperBound)) }).sorted(by: { $0 < $1 }) {
            if b <= cursor + eps { continue }
            if a >= high - eps { break }
            if a > cursor + eps { missing += min(a, high) - cursor }
            cursor = max(cursor, b)
        }
        if cursor < high - eps { missing += high - cursor }
        return max(0, 1 - missing / (high - low))
    }

    private func distanceToMeter(_ run: ClosedRange<Float>) -> Float {
        run.contains(0) ? 0 : min(abs(run.lowerBound), abs(run.upperBound))
    }
}

extension GapPlanner {
    /// The capture request for an item of the server's missing evidence, or nil when no capture
    /// can settle it.
    ///
    /// A band item asks for its own span, and for its `out_ft` when it has one: ground seen that
    /// far out, a walk past the span that far out (facing), a tilt-up view reaching that high
    /// (overhead). A facing item without `out_ft` asks for a measurement of what faces the wall,
    /// which a walk can't give, so it has no request. A past-end item asks for the ground 2 m
    /// beyond that end: far enough to show whether the wall continues, near enough to stay one
    /// instruction.
    public func plan(for item: PlacementMissingEvidence, leftEnd: Float?, rightEnd: Float?) -> GapPlan? {
        let metersPerFoot: Float = 0.3048
        switch item.kind {
        case .band:
            guard let span = item.spanFt else { return nil }
            let out = item.outFt.map { Float($0) * metersPerFoot }
            let band: SurfaceBand
            let need: GapPlan.Need
            switch item.band {
            case .wall?: (band, need) = (.wall, .cells)
            case .ground?: (band, need) = (.ground, out.map(GapPlan.Need.groundOut) ?? .cells)
            case .facing?:
                guard let out else { return nil }
                (band, need) = (.ground, .walkOut(out))
            case .overhead?: (band, need) = (.wall, .overhead(out))
            case nil: return nil
            }
            let low = Float(min(span.x, span.y)) * metersPerFoot
            let high = Float(max(span.x, span.y)) * metersPerFoot
            return GapPlan(band: band, span: low...high, reason: .server, need: need)
        case .pastEnd:
            guard let side = item.side else { return nil }
            switch side {
            case .left:
                let end = leftEnd ?? 0
                return GapPlan(band: .ground, span: (end - 2)...end, reason: .server)
            case .right:
                let end = rightEnd ?? 0
                return GapPlan(band: .ground, span: end...(end + 2), reason: .server)
            }
        }
    }
}
