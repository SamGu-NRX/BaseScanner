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
        /// The ground seen out to this many meters from the wall over the whole span as exported
        /// (`CoverageMap.groundDepthSpans()`).
        case groundOut(Float)
        /// The whole span, as exported, walked past with this many meters of clearance left after
        /// the position error (`CoverageMap.facingSpans()`): the walk must pass `out` plus the
        /// error out.
        case walkOut(Float)
        /// Recorded tilt-up views over the whole span as exported reaching this height, meters
        /// (`CoverageMap.overheadSpans()`); nil when any recorded view does.
        case overhead(Float?)
        /// The wall face seen at least this high, meters, over the whole span as exported
        /// (`CoverageMap.wallSeenSpans()`). The server's wall requests carry the height just above
        /// the one its check needs, so meeting it is exceeding that.
        case wallUp(Float)
    }

    /// The band the request is drawn on: facing requests on the ground, overhead on the wall.
    public var band: SurfaceBand
    public var span: ClosedRange<Float>
    public var reason: Reason
    public var need: Need
    /// The request's `out_ft` exactly as the server sent it, for a request built by
    /// `plan(for:leftEnd:rightEnd:)`. A reach is met against this, not against `need`'s meters:
    /// the server asks for values strictly above its rule (4.833334 ft for 4.833333), and the trip
    /// through Float meters and back can land a hair below what it asked. Nil for a request built
    /// in meters, whose reach is then compared in feet exactly as converted.
    public var requestedOutFt: Double?
    /// The request's `span_ft` exactly as the server sent it, low end first, for a band request
    /// built by `plan(for:leftEnd:rightEnd:)`. Progress measures the export against this rather
    /// than `span`, whose ends went through Float meters and could come back inside the request.
    /// Nil for a request built in meters, whose span is then read at the export's four decimals.
    public var requestedSpanFt: ClosedRange<Double>?

    public init(
        band: SurfaceBand, span: ClosedRange<Float>, reason: Reason, need: Need = .cells,
        requestedOutFt: Double? = nil, requestedSpanFt: ClosedRange<Double>? = nil
    ) {
        self.band = band
        self.span = span
        self.reason = reason
        self.need = need
        self.requestedOutFt = requestedOutFt
        self.requestedSpanFt = requestedSpanFt
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
    /// The deepest ground the coverage map samples, meters. Must match the map's
    /// `CoverageConfig.groundDepthReach`: a ground request past it can never be met.
    public var groundDepthReach: Float = CoverageConfig().groundDepthReach
    /// The highest wall row the coverage map samples, meters. Must match the map's
    /// `CoverageConfig.wallCaptureHeight`: a wall request above it can never be met.
    public var wallCaptureHeight: Float = CoverageConfig().wallCaptureHeight

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
    /// asked for again. A wall run means the walking band (`CoverageConfig.wallWalkHeight`).
    ///
    /// It asks for nothing above the walking band. The server's answer to the first upload names
    /// the wall above it where a check needs that, over the stretch the check reads and to the
    /// height it needs (a wall request with `out_ft`, `GapPlan.Need.wallUp`), and the engine
    /// raises it at once as the next view (`ScanEngine.automaticGapQueue`). A request from here
    /// would have to guess both the stretch and the height (7.5 ft where the public rules need
    /// just over 6.5), and when the guess missed the spot the server chose, the homeowner would
    /// be asked for the wall twice.
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

    /// Runs of cells neither covered nor skipped (unseen, seen but not covered, or hidden) at
    /// least `minRun` long, clipped to `range`.
    public func missingRuns(_ band: SurfaceBand, in range: ClosedRange<Float>, coverage: CoverageMap) -> [ClosedRange<Float>] {
        var runs: [ClosedRange<Float>] = []
        var start: Float?
        var end: Float = 0
        for index in coverage.indices(overlapping: range) {
            let cell = coverage.cellRange(index).clamped(to: range)
            let level = coverage.level(band, index)
            if level != .covered && level != .skipped {
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

    /// The fraction of the request met so far: of its cells for a phone cell request; for a
    /// server request or a reach, of its whole span as the exported scene will report it, so a
    /// request reaching past a marked end or past what was seen stays open like it does on the
    /// server.
    public func progress(of gap: GapPlan, _ coverage: CoverageMap) -> Double {
        // A reach meets a request in feet as the export will report it (rounded down), against
        // the requirement as asked: rounding the requirement too could round it down, and then
        // 4.8333 ft met a 4.833334 ft request the uploaded scene falls short of.
        func reaching(_ spans: [ObservedSpan], _ needed: Float?) -> [ClosedRange<Float>] {
            spans.filter { item in
                guard let needed else { return true }
                return SceneExport.feetDown(item.out) >= gap.requestedOutFt ?? Double(needed) * SceneUnits.feetPerMeter
            }.map(\.span)
        }
        let spans: [ClosedRange<Float>]
        switch gap.need {
        case .cells where gap.reason == .server: spans = Self.exportedSpans(gap.band, coverage)
        case .cells: return coverage.coveredFraction(gap.band, in: gap.span)
        case .groundOut(let out): spans = reaching(Self.exported(coverage.groundDepthSpans()), out)
        case .walkOut(let out): spans = reaching(Self.exported(coverage.facingSpans()), out)
        case .overhead(let height): spans = reaching(Self.exported(coverage.overheadSpans()), height)
        case .wallUp(let height): spans = reaching(Self.exported(coverage.wallSeenSpans()), height)
        }
        let feet = { (meters: Float) in SceneExport.round4(Double(meters) * SceneUnits.feetPerMeter) }
        let requested = gap.requestedSpanFt ?? feet(gap.span.lowerBound)...feet(gap.span.upperBound)
        return Self.fraction(of: requested, coveredBy: spans)
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

    /// The stretches scene.json will list as observed in `band`, meters (`SceneCoverage`): every
    /// wall or ground entry, whatever its height or depth.
    static func exportedSpans(_ band: SurfaceBand, _ coverage: CoverageMap) -> [ClosedRange<Float>] {
        switch band {
        case .wall: exported(coverage.wallSeenSpans()).map(\.span)
        case .ground: exported(coverage.groundDepthSpans()).map(\.span)
        }
    }

    /// A band's entries as the export writes them: joined or dropped to fit the schema's entry
    /// limit (`ObservedSpan.coarsened`), which only ever reports less.
    static func exported(_ spans: [ObservedSpan]) -> [ObservedSpan] {
        ObservedSpan.coarsened(spans, toAtMost: SceneExport.bandBudget)
    }

    /// The fraction of `requested` (feet) that `spans` (meters) cover, measured the way the server
    /// reads the uploaded scene: the spans in feet as the export writes them, each end rounded
    /// inward (`SceneExport.spanInward`), and gaps under the server's COVERAGE_TOLERANCE_FT
    /// (0.01 ft, server/scene.py `missing` at t3/server 930e8e5) read as rounding, not unseen.
    static func fraction(of requested: ClosedRange<Double>, coveredBy spans: [ClosedRange<Float>]) -> Double {
        let low = requested.lowerBound
        let high = requested.upperBound
        guard high > low else { return 0 }
        let eps = 1e-9
        let tolerance = 0.01
        var cursor = low
        var missing = 0.0
        let written = spans.compactMap { SceneExport.spanInward($0) }.map { ($0[0], $0[1]) }
        for (a, b) in written.sorted(by: { $0 < $1 }) {
            if b <= cursor + eps { continue }
            if a >= high - eps { break }
            if a > cursor + eps, min(a, high) - cursor >= tolerance { missing += min(a, high) - cursor }
            cursor = max(cursor, b)
        }
        if cursor < high - eps, high - cursor >= tolerance { missing += high - cursor }
        return max(0, 1 - missing / (high - low))
    }

    private func distanceToMeter(_ run: ClosedRange<Float>) -> Float {
        run.contains(0) ? 0 : min(abs(run.lowerBound), abs(run.upperBound))
    }
}

extension GapPlanner {
    /// Whether a server request asks for more than the phone can capture: ground seen farther
    /// out than the coverage map samples (`GapPlannerConfig.groundDepthReach`), or wall seen
    /// higher than its top wall row (`GapPlannerConfig.wallCaptureHeight`), so no walk could ever
    /// meet it. It has no capture request (`plan(for:leftEnd:rightEnd:)` is nil) and goes to
    /// review instead of a capture loop the homeowner can't finish.
    public func isBeyondCapture(_ item: PlacementMissingEvidence) -> Bool {
        guard item.kind == .band, let out = item.outFt else { return false }
        switch item.band {
        case .ground?: return out > SceneExport.feetDown(config.groundDepthReach)
        case .wall?: return out > SceneExport.feetDown(config.wallCaptureHeight)
        case .facing?, .overhead?, .unknown?, nil: return false
        }
    }

    /// Whether a band item's span reaches past a marked end where the coverage map records
    /// nothing, so no capture can meet it (issue #35): past any end for the wall, facing and
    /// overhead bands, and past an unexplored end for the ground. Ground past an end in
    /// `limitEnds` is recorded (`CoverageMap.groundDepthSpans`), and the server asks for it there.
    /// A span within the server's COVERAGE_TOLERANCE_FT (0.01 ft) of an end reaches it, not past.
    public func reachesPastEnd(_ item: PlacementMissingEvidence, leftEnd: Float?, rightEnd: Float?, limitEnds: Set<WalkSide>) -> Bool {
        guard item.kind == .band, let span = item.spanFt else { return false }
        let tolerance = 0.01
        let feet = { (meters: Float) in Double(meters) * SceneUnits.feetPerMeter }
        var past: [WalkSide] = []
        if let leftEnd, min(span.x, span.y) < feet(leftEnd) - tolerance { past.append(.left) }
        if let rightEnd, max(span.x, span.y) > feet(rightEnd) + tolerance { past.append(.right) }
        return past.contains { !(item.band == .ground && limitEnds.contains($0)) }
    }

    /// The capture request for an item of the server's missing evidence, or nil when no capture
    /// can settle it (including `isBeyondCapture` and `reachesPastEnd`).
    ///
    /// A band item asks for its own span, and for its `out_ft` when it has one: ground seen that
    /// far out, a walk past the span that far out (facing), a tilt-up view reaching that high
    /// (overhead), the wall seen that high up (wall). A facing item without `out_ft` asks for a measurement of what faces the wall,
    /// which a walk can't give, so it has no request. A past-end item asks for the ground 2 m
    /// beyond that end: far enough to show whether the wall continues, near enough to stay one
    /// instruction. An item of a kind or band this app doesn't know has no request.
    public func plan(
        for item: PlacementMissingEvidence, leftEnd: Float?, rightEnd: Float?, limitEnds: Set<WalkSide> = []
    ) -> GapPlan? {
        let metersPerFoot: Float = 0.3048
        switch item.kind {
        case .band:
            guard let span = item.spanFt, !isBeyondCapture(item),
                  !reachesPastEnd(item, leftEnd: leftEnd, rightEnd: rightEnd, limitEnds: limitEnds) else { return nil }
            let out = item.outFt.map { Float($0) * metersPerFoot }
            let band: SurfaceBand
            let need: GapPlan.Need
            switch item.band {
            case .wall?: (band, need) = (.wall, out.map(GapPlan.Need.wallUp) ?? .cells)
            case .ground?: (band, need) = (.ground, out.map(GapPlan.Need.groundOut) ?? .cells)
            case .facing?:
                guard let out else { return nil }
                (band, need) = (.ground, .walkOut(out))
            case .overhead?: (band, need) = (.wall, .overhead(out))
            case .unknown?, nil: return nil
            }
            let low = Float(min(span.x, span.y)) * metersPerFoot
            let high = Float(max(span.x, span.y)) * metersPerFoot
            return GapPlan(
                band: band, span: low...high, reason: .server, need: need,
                requestedOutFt: item.outFt, requestedSpanFt: min(span.x, span.y)...max(span.x, span.y))
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
        case .unknown:
            return nil
        }
    }

    /// Where the end a past_end request cleared goes once the request is met without the end
    /// marked again: past the stretch the request showed, at its far edge (never back inside
    /// `clearedAt`), so the wall runs on over ground that was seen and a next past_end request
    /// asks for the 2 m after it. Left without an end, the next request would be planned from
    /// the meter (issue #35).
    public func endAfterPastEnd(_ plan: GapPlan, side: WalkSide, clearedAt old: Float) -> Float {
        side == .left ? min(plan.span.lowerBound, old) : max(plan.span.upperBound, old)
    }

    /// The items of the server's missing evidence still to ask for without a tap, in order, with
    /// their requests, at most `limit` of them: each one a capture can settle whose request asks
    /// for no view already raised in this pass (`asked`), skipped, or earlier in the list
    /// (`GapPlan.asksForSameView(as:)`). A request the homeowner couldn't get to is in both, so
    /// the answer that follows moves on to the next item rather than raising it again (issue #39).
    public func serverRequests(
        in missing: [PlacementMissingEvidence], leftEnd: Float?, rightEnd: Float?, limitEnds: Set<WalkSide>,
        asked: [GapPlan], skipped: [GapPlan], limit: Int
    ) -> [(item: PlacementMissingEvidence, plan: GapPlan)] {
        var requests: [(item: PlacementMissingEvidence, plan: GapPlan)] = []
        for item in missing where requests.count < limit {
            guard let plan = self.plan(for: item, leftEnd: leftEnd, rightEnd: rightEnd, limitEnds: limitEnds) else { continue }
            let seen = asked + skipped + requests.map { $0.plan }
            guard !seen.contains(where: { plan.asksForSameView(as: $0) }) else { continue }
            requests.append((item, plan))
        }
        return requests
    }

    /// The first of `serverRequests`: the next item to ask for without a tap. Nil when none is left.
    public func nextServerRequest(
        in missing: [PlacementMissingEvidence], leftEnd: Float?, rightEnd: Float?, limitEnds: Set<WalkSide>,
        asked: [GapPlan], skipped: [GapPlan]
    ) -> (item: PlacementMissingEvidence, plan: GapPlan)? {
        serverRequests(in: missing, leftEnd: leftEnd, rightEnd: rightEnd, limitEnds: limitEnds, asked: asked, skipped: skipped, limit: 1).first
    }
}

extension GapPlan {
    /// How far a request's span or reach may move and still ask for the same view: 0.1 ft
    /// (0.03 m), meters. Numerical jitter from the server working the request out again is a few
    /// hundredths of a foot; a guess, not measured.
    public static let sameViewTolerance: Float = 0.03048

    /// Whether this request asks for no view beyond `other`'s, allowing for the server working it
    /// out again from the next upload: the same band and kind of need, a reach no more than
    /// `sameViewTolerance` past the other's, and a span inside the other's give or take the same
    /// tolerance. After "I can't get there" the skipped stretch goes to review and the spot or its
    /// error margins can move, so the same view comes back as, say, 2.41...7.9 ft instead of
    /// 2.4...7.9 ft. A request that asks for more is a new view, even when it mostly overlaps: a
    /// span of 2...9 ft after 2...8 ft, or ground out to 5.10 ft after 4.83 ft (issue #39). A met
    /// past_end request moves its end on 2 m, so the next one asks for new ground and is a
    /// different view.
    public func asksForSameView(as other: GapPlan) -> Bool {
        let tolerance = Self.sameViewTolerance
        guard band == other.band, need.asksNoMore(than: other.need, within: tolerance) else { return false }
        return span.lowerBound >= other.span.lowerBound - tolerance && span.upperBound <= other.span.upperBound + tolerance
    }
}

extension GapPlan.Need {
    /// The same kind of need, with any reach no more than `tolerance` meters past the other's. An
    /// overhead need without a height (any recorded view) asks no more than one with a height.
    func asksNoMore(than other: GapPlan.Need, within tolerance: Float) -> Bool {
        switch (self, other) {
        case (.cells, .cells):
            return true
        case let (.groundOut(a), .groundOut(b)), let (.walkOut(a), .walkOut(b)), let (.wallUp(a), .wallUp(b)):
            return a <= b + tolerance
        case let (.overhead(a), .overhead(b)):
            guard let a else { return true }
            guard let b else { return false }
            return a <= b + tolerance
        default:
            return false
        }
    }
}
