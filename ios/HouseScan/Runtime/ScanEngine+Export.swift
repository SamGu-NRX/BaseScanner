import Foundation
import HouseScanKit
import OSLog
import simd

extension ScanEngine {
    /// scene.json for the current scan (contract C1), with the LiDAR mesh's measurements on
    /// phones that have one.
    ///
    /// The scene frame is the AR world frame moved down so the ground at the wall is y = 0: the
    /// server reads heights (meter.pos y, pose translations) as height above that ground, and
    /// scene.json has no field for the ground's height otherwise.
    ///
    /// Everything is placed against `geometry.wall` (`exportGeometry()`): marks are read again
    /// from their tapped world points when that is the measured chain rather than the walk's wall.
    func sceneJSON(mesh: MeshMeasurements = MeshMeasurements(), geometry: ExportGeometry) throws -> Data {
        guard let map = coverage else { throw ExportError.noWall }
        let wall = geometry.wall
        let drop = SIMD3<Float>(0, wall.groundY, 0)
        // The corners carry their pieces' sources (`markNextWall`, or the measured chain's); the
        // meter's piece, its own (`meterLineSource`, set on the map in `markMeter`, or the
        // measured piece's).
        let sceneWall = SceneWall(
            meter: wall.meter - drop, outward: wall.outward, groundY: 0, leftCorners: wall.leftCorners, rightCorners: wall.rightCorners,
            source: wall.source)

        // SceneExport rejects negative heights, a top below a bottom, ground points behind the
        // wall and a zero-length driveway edge, and taps can produce each of them once the ground
        // or the meter anchor moves after the tap (a window tapped wholly below a guessed ground,
        // a fence foot that ends up behind the refined wall line). Such marks are clamped to the
        // nearest valid shape here and logged. A driveway or fence with nothing valid left fails
        // the export instead (`ExportError.markCollapsed`): dropping it would send the ground
        // near it as seen and clear, which can pass its clearance check with the hazard unsent.
        let features: [SceneFeature] = try state.features.map { marked in
            var feature = marked
            if wall != map.wall { Self.project(&feature, onto: wall) }
            let points = feature.points.map { $0 - drop }
            switch feature.kind {
            case .door, .window:
                let heights = [feature.bottom ?? 0, feature.top ?? 0]
                let bottom = max(0, heights.min() ?? 0)
                let top = max(bottom, heights.max() ?? 0)
                if bottom != feature.bottom || top != feature.top {
                    RuntimeLog.engine.info("export: \(feature.kind.rawValue, privacy: .public) heights \(feature.bottom ?? .nan)...\(feature.top ?? .nan) clamped to \(bottom)...\(top)")
                }
                return .opening(kind: feature.kind == .door ? .door : .window, span: feature.span, bottom: bottom, top: top,
                                operable: feature.kind == .window ? feature.opens : nil)
            case .gasMeter:
                return .pointObject(kind: .gasMeter, tap: points.first ?? wall.meter - drop, bottom: nil, top: nil)
            case .acUnit:
                return .pointObject(kind: .ac, tap: points.first ?? wall.meter - drop, bottom: nil, top: nil)
            case .fence:
                return .fence(foot: try Self.groundLine(feature, points, wall: sceneWall))
            case .driveway:
                return .driveway(edge: try Self.groundLine(feature, points, wall: sceneWall))
            }
        }

        let keyframes = store.keyframes.map { stored -> SceneKeyframe in
            var pose = stored.camera.cameraToWorld
            pose.columns.3.y -= wall.groundY
            return SceneKeyframe(
                id: stored.id, cameraToWorld: pose, intrinsics: stored.camera.intrinsics,
                w: Int(stored.camera.imageSize.x), h: Int(stored.camera.imageSize.y), img: stored.fileName
            )
        }

        // A guessed ground puts the same error into every height in the scene. scene.json has no
        // field for "the ground was estimated", so the error bars say it instead.
        let groundError: Float? = groundMeasured ? nil : Self.estimatedGroundError
        let input = SceneInput(
            wall: sceneWall,
            baselineS: geometry.baselineS,
            meterPlusMinus: groundError,
            meterPlane: meterPlaneSource,
            objectPlusMinus: groundError,
            features: features,
            coverage: geometry.coverage,
            keyframes: keyframes,
            stills: store.stills,
            // Written without plus_minus_ft: the server takes its mesh error for both.
            meshFacing: mesh.facing,
            meshOverheads: mesh.overheads,
            // Unanswered exports like "Not sure": no patch, and the server reports the surface unknown.
            groundType: state.groundAnswer.flatMap(Self.sceneGroundType),
            wallPlusMinus: geometry.plusMinus,
            // A measured wall lies on its fitted line; the meter stays where it was tapped, which
            // may be on a box proud of that line.
            meterPosition: wall.meter == map.wall.meter ? nil : map.wall.meter - drop
        )
        return try SceneExport.jsonData(input)
    }

    /// The wall scene.json describes, the stretch of it, what was seen along it, and how well each
    /// of its pieces' lines is known.
    struct ExportGeometry: Sendable {
        var wall: WallFrame
        var baselineS: ClosedRange<Float>
        var coverage: SceneCoverage
        /// `SceneInput.wallPlusMinus`; empty takes the server's default for every piece.
        var plusMinus: [Float?]
    }

    /// Under `-coverage legacy`, the walk's tapped wall and the coverage map's sightings. Under
    /// `map3d`, the 3D map's (`Map3DCoverageSource.export`): the measured wall chain when it
    /// matches the walk, and coverage read along whichever wall is written.
    ///
    /// The 3D map is used only once some depth went into it (LiDAR, a replay's, or estimated
    /// with `-estimatedDepth on` and the model present). Without, it holds only feature points
    /// and planes and would report near-empty coverage, so the camera coverage map decides here
    /// as it does for the walk on such a phone.
    func exportGeometry() async throws -> ExportGeometry {
        guard let map = coverage else { throw ExportError.noWall }
        func camera(because reason: String) -> ExportGeometry {
            RuntimeLog.engine.info("export: camera coverage map, \(reason, privacy: .public)")
            return ExportGeometry(
                wall: map.wall, baselineS: Self.exportSpan(map),
                coverage: SceneCoverage(map, leftEndMarked: wallEndKinds[.left] == .limit, rightEndMarked: wallEndKinds[.right] == .limit),
                plusMinus: [])
        }
        guard let map3D else { return camera(because: "-coverage legacy") }
        // The snapshot is computed off the main actor, and meanwhile the meter anchor can move the
        // wall. One read along another wall than the current one is taken again; the next read
        // includes the move. Three tries, then the export fails rather than mix two walls.
        for _ in 0..<3 {
            let snapshot = await Task.detached(priority: .userInitiated) { map3D.finalSnapshot() }.value
            guard let snapshot else { throw ExportError.noMap3D }
            guard let map = coverage else { throw ExportError.noWall }
            guard snapshot.wall == map.wall else { continue }
            guard snapshot.integratedDepth else {
                return camera(because: "the 3D map integrated no depth (no LiDAR, and estimated depth off or without its model)")
            }
            let export = try Map3DCoverageSource.export(
                snapshot, tapWall: map.wall, baselineS: Self.exportSpan(map),
                leftEndMarked: wallEndKinds[.left] == .limit, rightEndMarked: wallEndKinds[.right] == .limit,
                walkedFacing: map.facingSpans(), confirmedOverhead: map.overheadSpans())
            let why = if let reason = export.tappedBecause {
                "tapped wall (\(reason)); walked facing and confirmed overhead merged in"
            } else {
                "measured wall; walked facing and confirmed overhead carried onto its meter piece"
            }
            RuntimeLog.engine.info("export: 3D map revision \(snapshot.revision), \(why, privacy: .public), \(export.wall.segments.count) pieces, s \(export.baselineS.lowerBound)...\(export.baselineS.upperBound)")
            return ExportGeometry(
                wall: export.wall, baselineS: export.baselineS, coverage: export.coverage, plusMinus: export.plusMinus)
        }
        throw ExportError.wallKeptMoving
    }

    static func sceneGroundType(_ answer: GroundAnswer) -> SceneGroundType? {
        switch answer {
        case .notSure: nil
        case .type(.lawn): .lawn
        case .type(.mulch): .mulch
        case .type(.gravel): .gravel
        case .type(.concrete): .concrete
        case .type(.drive): .drive
        case .type(.deck): .deck
        }
    }

    /// How the line of the meter's piece of wall was found, for scene.json's `walls[].source`.
    ///
    /// Live, `markMeter` puts the wall through the raycast's hit point, facing the normal of the
    /// plane it hit. On a detected plane (an ARPlaneAnchor, `.existingPlaneGeometry`) the normal
    /// is the anchor's and the hit point lies on the anchor's geometry, so both the line's
    /// direction and its distance from the camera are the plane's: `plane`. The tap only picks
    /// where along that line the meter is. On an estimated plane there is no anchor: ARKit fits a
    /// plane to the feature points around the tapped pixel for that one raycast, which is what an
    /// AR tap is, and the schema's `plane` means detected planes, so it is `tap`. Nothing in the
    /// walk takes a wall line from the LiDAR mesh (`MeshProbe` only measures in front of and
    /// above a line already set), so no tapped piece is `mesh`. Under `-coverage map3d` the export
    /// can write the 3D map's measured chain instead, whose pieces are `mesh` or `plane`
    /// (`exportGeometry()`).
    ///
    /// A replay's wall is `tap`: a recorded measure-lab wall runs through two tapped ground
    /// contacts (its `contacts`), and a wall assumed from the trajectory was never measured at
    /// all, which no source describes; replays run only in tests and demos.
    var meterLineSource: WallLineSource {
        replay == nil ? Self.lineSource(of: meterPlaneSource) : .tap
    }

    /// The source of a wall line put through a live vertical-plane raycast's hit, facing the hit
    /// plane's normal (`meterLineSource` has the reasons).
    static func lineSource(of plane: MeterPlaneSource) -> WallLineSource {
        switch plane {
        case .detectedPlane: .plane
        case .estimatedPlane: .tap
        }
    }

    /// The stretch of wall the scene describes, meters of s: between the marked ends, or out to
    /// what was seen (at least 1 m) on a side without one, always containing the meter.
    nonisolated static func exportSpan(_ map: CoverageMap) -> ClosedRange<Float> {
        let seen = map.seenExtent
        let low = min(map.leftEnd ?? min(seen?.lowerBound ?? -1, -1), -0.1)
        let high = max(map.rightEnd ?? max(seen?.upperBound ?? 1, 1), 0.1)
        return low...high
    }

    /// What the LiDAR mesh measured over the exported stretch: the gap from the wall out to
    /// whatever faces it, and the clear height under anything overhead, each per stretch of s in
    /// meters. Empty without a mesh.
    struct MeshMeasurements: Sendable {
        var facing: [ObservedSpan] = []
        var overheads: [ObservedSpan] = []
    }

    /// Measures a world-space mesh (meters) against the wall (world meters) over `span`, the
    /// exported stretch of s.
    nonisolated static func measure(_ mesh: TriangleMesh, wall: WallFrame, over span: ClosedRange<Float>) -> MeshMeasurements {
        MeshMeasurements(facing: mesh.facingSpans(wall: wall, over: span), overheads: mesh.overheadSpans(wall: wall, over: span))
    }

    /// Error of the chest-height ground guess (camera height minus 1.4 m), meters. Phones held
    /// for scanning sit roughly 1.1 to 1.7 m up, so ±0.3 m. A hypothesis; no measured spread exists.
    static let estimatedGroundError: Float = 0.3

    /// A ground point on or behind the wall line moved to 1 mm in front of it, keeping its s. The
    /// millimetre keeps float round-off from turning an on-the-line point into a negative depth.
    private static func inFront(of wall: SceneWall, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let c = wall.wallCoordinates(of: point)
        return c.out >= 0.001 ? point : wall.world(s: c.s, height: c.height, out: 0.001)
    }

    /// The two ground points of a driveway edge or a fence foot, each moved in front of the wall.
    /// Throws `markCollapsed` when they are not two points 1 cm apart in plan: a wall line refined
    /// past both taps puts them on one point. SceneExport's own degenerate-edge tolerance is
    /// 1e-3 ft; 1 cm keeps well clear of it.
    private static func groundLine(_ feature: MarkedFeature, _ points: [SIMD3<Float>], wall: SceneWall) throws(ExportError) -> [SIMD3<Float>] {
        let line = points.map { inFront(of: wall, $0) }
        guard line.count == 2, simd_distance(SIMD2(line[0].x, line[0].z), SIMD2(line[1].x, line[1].z)) > 0.01 else {
            RuntimeLog.engine.error("export: \(feature.kind.rawValue, privacy: .public) \(feature.id.uuidString, privacy: .public) has \(points.count) taps that don't make a line; asking for it to be marked again")
            throw .markCollapsed(feature.kind)
        }
        return line
    }

    enum ExportError: Error, CustomStringConvertible {
        case noWall
        /// Under `-coverage map3d` there is a wall but no 3D map: `setWall` starts both.
        case noMap3D
        /// The wall moved during each of three reads of the 3D map.
        case wallKeptMoving
        /// A driveway or fence whose taps no longer make a line. The homeowner has to mark it
        /// again; `UploadFailure.packaging(_:)` says so.
        case markCollapsed(FeatureKind)

        var description: String {
            switch self {
            case .noWall: "There is no wall to export yet."
            case .noMap3D: "The 3D map was never started for this wall."
            case .wallKeptMoving: "The wall moved while the 3D map was read, three times running."
            case .markCollapsed(let kind): "The \(kind.rawValue) mark's taps don't make a line."
            }
        }
    }

    /// The server's result in the terms the screens use (meters, wall coordinates), along the
    /// wall scene.json described (`exportedWall`), which under `-coverage map3d` can be the
    /// measured chain rather than the walk's.
    func presentation(of result: PlacementResult, isSample: Bool) -> ResultPresentation {
        let meters: (Double) -> Float = { Float($0 * 0.3048) }
        let placedWall = exportedWall ?? coverage?.wall
        let sceneWall = placedWall.map {
            SceneWall(meter: $0.meter, outward: $0.outward, groundY: $0.groundY, leftCorners: $0.leftCorners, rightCorners: $0.rightCorners)
        }

        var spot: BatterySpot?
        if let placed = result.spot {
            // Placed by its `span_ft`, its stretch in s along the wall chain, which the screens
            // turn into world points piece by piece (`WallGeometry.world(s:)`), so a spot round a
            // corner lands on the right piece and still moves with the meter's anchor. The meter
            // offset split along the spot's own `along` gave s only on the meter's piece: past a
            // corner it measured along the other piece's direction and drew the spot on the
            // meter's wall. Both s and the depth below are frame-free, so the bundled sample (in
            // its own frame) still means the same on any wall.
            let low = meters(min(placed.spanFt.x, placed.spanFt.y))
            let high = meters(max(placed.spanFt.x, placed.spanFt.y))
            let depth = meters(placed.depthFt)
            // How far the footprint's centre stands out from its back edge (back-left and
            // back-right corners come first), along the spot's own outward: the gap to the wall
            // is what exceeds half the depth. The server puts the back on the wall line. Decoding
            // refuses a footprint without exactly four corners.
            let d = placed.center - (placed.footprint[0] + placed.footprint[1]) / 2
            let centerOut = meters(d.x * placed.outward.x + d.y * placed.outward.y)
            spot = BatterySpot(
                span: low...high,
                depth: depth, height: meters(placed.heightFt),
                offsetFromWall: max(0, centerOut - depth / 2)
            )
        }

        var route: [SIMD2<Float>] = []
        if let cable = result.route {
            let height = meters(cable.heightFt)
            // Each point as an offset from the meter: the result's meter is the spot's centre
            // minus its offset from the meter. The answer to this scan is in the scene's plan
            // frame (the AR world's x and z in feet, scene.json's frame; result.schema.json's
            // meter_offset_ft is "in the scene frame's axes"), so the offsets are put on the
            // current wall chain by `chainS`, which follows the route round corners and adds a
            // vertex at each so the drawn line bends there. Offsets rather than the points
            // themselves keep the route on the meter's anchor as it moves, like the spot's s.
            // The bundled sample is in a frame of its own, unrelated to this wall, so its route
            // is measured along the sample spot's own direction, as before.
            if isSample {
                if let placed = result.spot {
                    let meterPlan = placed.center - placed.meterOffsetFt
                    route = cable.polyline.map { point in
                        let d = point - meterPlan
                        return SIMD2(meters(d.x * placed.along.x + d.y * placed.along.y), height)
                    }
                }
            } else if let sceneWall {
                // A route comes with a spot (result.schema.json); without one, the meter as it is now.
                let meterNow = SIMD2(Double(sceneWall.meter.x), Double(sceneWall.meter.z)) * SceneUnits.feetPerMeter
                let meterPlan = result.spot.map { $0.center - $0.meterOffsetFt } ?? meterNow
                route = sceneWall.chainS(ofPlanOffsetsFeet: cable.polyline.map { $0 - meterPlan }).map { SIMD2($0, height) }
            }
        }

        let checks = result.checks.map { check in
            CheckRow(
                id: check.id, title: check.label, outcome: Self.outcome(check.outcome), reason: check.reason,
                // An UNSURE with no cause is unexplained, so a person has to look at it.
                needsPerson: check.outcome == .unsure && (check.unsureCause.map { [.margin, .unknownAttribute, .ruleRequiresReview].contains($0) } ?? true),
                measured: check.measuredFt.map(meters), threshold: check.thresholdFt.map(meters), plusMinus: check.plusMinusFt.map(meters),
                comparison: check.comparison.map(Self.comparison)
            )
        }

        let depth = spot?.depth ?? 0.3
        // A run's start_ft is a range of battery LEFT edges, so the wall it describes reaches one
        // battery width past its last start. Only the spot carries the width; without a spot the
        // zone is drawn over the starts alone, which understates it.
        let width = spot.map { $0.span.upperBound - $0.span.lowerBound } ?? 0
        let clearances = result.sweep.enumerated().map { index, run in
            let first = meters(min(run.startFt.x, run.startFt.y))
            let last = meters(max(run.startFt.x, run.startFt.y))
            return ClearanceZone(
                id: "sweep-\(index)",
                label: (run.failing + run.unsure).joined(separator: ", "),
                outcome: Self.outcome(run.outcome),
                span: first...(last + width),
                depth: depth
            )
        }

        let missing = result.missingEvidence.enumerated().map { index, item in
            MissingEvidence(
                id: "missing-\(index)", text: item.message,
                // Only when a gap request can be built from it: a band item needs its span (and
                // a facing item its out_ft, which a walk can reach), a past_end item its side.
                // Otherwise the button would do nothing. A request the homeowner already skipped
                // or answered with something overhead stays with the installer.
                capturable: gapPlanner.plan(for: walkRequest(item), leftEnd: coverage?.leftEnd, rightEnd: coverage?.rightEnd, limitEnds: coverage?.limitEnds ?? [])
                    .map { !skippedGaps.contains($0) } ?? false
            )
        }

        var unseen: WallSide?
        if let pastEnd = result.missingEvidence.first(where: { $0.kind == .pastEnd })?.side {
            unseen = pastEnd == .left ? .left : .right
        } else if result.ends.left.kind == .unexplored, result.ends.left.beyondReach != true {
            // An end beyond cable reach can't hold the battery whatever lies past it.
            unseen = .left
        } else if result.ends.right.kind == .unexplored, result.ends.right.beyondReach != true {
            unseen = .right
        }

        return ResultPresentation(
            decision: Self.decision(result.decision),
            summary: result.summary,
            policyApproved: result.policy.autoApprove,
            spot: spot,
            cableRoute: route,
            cableLength: result.route.map { meters($0.lengthFt) },
            checks: checks,
            clearances: clearances,
            missing: missing,
            unseenSide: unseen,
            isSample: isSample,
            wall: resultWall()
        )
    }

    /// The answer's wall (`exportedWall`, or the walk's) as the result screens draw it, with the
    /// marked ends carried onto it from the walk's wall.
    func resultWall() -> WallGeometry? {
        guard let walk = coverage?.wall else { return nil }
        let wall = exportedWall ?? walk
        return Self.geometry(
            wall, leftEnd: coverage?.leftEnd.map { walk.s($0, along: wall) }, rightEnd: coverage?.rightEnd.map { walk.s($0, along: wall) })
    }

    static func outcome(_ outcome: PlacementOutcome) -> CheckOutcome {
        switch outcome {
        case .pass: .pass
        case .fail: .fail
        case .unsure: .unsure
        }
    }

    static func comparison(_ comparison: PlacementComparison) -> RuleComparison {
        switch comparison {
        case .atLeast: .atLeast
        case .atMost: .atMost
        }
    }

    static func decision(_ decision: PlacementDecision) -> ResultPresentation.Decision {
        switch decision {
        case .pass: .pass
        case .manualReview: .manualReview
        case .reject: .reject
        }
    }
}
