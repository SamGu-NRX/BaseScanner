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

    public var band: SurfaceBand
    public var span: ClosedRange<Float>
    public var reason: Reason

    public init(band: SurfaceBand, span: ClosedRange<Float>, reason: Reason) {
        self.band = band
        self.span = span
        self.reason = reason
    }
}

public struct GapPlannerConfig: Sendable, Equatable {
    /// Look for gaps within this distance of the meter: about 20 ft, the same reach the walk uses.
    public var reach: Float = 6.1
    /// A gap narrower than 0.45 m (three 6 in cells) can't hide a battery footprint, so it is not
    /// worth a second walk.
    public var minRun: Float = 0.45
    /// A request counts as satisfied at 80 % of its cells covered, allowing a cell or two at the
    /// edges that a real camera never quite reaches.
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

    public func progress(of gap: GapPlan, _ coverage: CoverageMap) -> Double {
        coverage.coveredFraction(gap.band, in: gap.span)
    }

    public func isSatisfied(_ gap: GapPlan, _ coverage: CoverageMap) -> Bool {
        progress(of: gap, coverage) >= config.satisfiedFraction
    }

    private func distanceToMeter(_ run: ClosedRange<Float>) -> Float {
        run.contains(0) ? 0 : min(abs(run.lowerBound), abs(run.upperBound))
    }
}

extension GapPlanner {
    /// The capture request for an item of the server's missing evidence, or nil when no walk can
    /// settle it (overhead and facing bands need a person with a tape).
    ///
    /// A band item asks for its own span. A past-end item asks for the ground 2 m beyond that
    /// end: far enough to show whether the wall continues, near enough to stay one instruction.
    public func plan(for item: PlacementMissingEvidence, leftEnd: Float?, rightEnd: Float?) -> GapPlan? {
        let metersPerFoot: Float = 0.3048
        switch item.kind {
        case .band:
            guard let span = item.spanFt else { return nil }
            let band: SurfaceBand
            switch item.band {
            case .wall?: band = .wall
            case .ground?: band = .ground
            case .overhead?, .facing?, nil: return nil
            }
            let low = Float(min(span.x, span.y)) * metersPerFoot
            let high = Float(max(span.x, span.y)) * metersPerFoot
            return GapPlan(band: band, span: low...high, reason: .server)
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
