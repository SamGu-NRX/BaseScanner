import Foundation
import HouseScanKit
import OSLog
import simd

extension ScanEngine {
    /// scene.json for the current scan (contract C1).
    ///
    /// The scene frame is the AR world frame moved down so the ground at the wall is y = 0: the
    /// server reads heights (meter.pos y, pose translations) as height above that ground, and
    /// scene.json has no field for the ground's height otherwise.
    func sceneJSON() throws -> Data {
        guard let map = coverage else { throw ExportError.noWall }
        let wall = map.wall
        let drop = SIMD3<Float>(0, wall.groundY, 0)
        let sceneWall = SceneWall(meter: wall.meter - drop, outward: wall.outward, groundY: 0)

        let seen = map.seenExtent
        let low = min(map.leftEnd ?? min(seen?.lowerBound ?? -1, -1), -0.1)
        let high = max(map.rightEnd ?? max(seen?.upperBound ?? 1, 1), 0.1)

        // Tap geometry must never stop the export: SceneExport rejects negative heights, a top
        // below a bottom, ground points behind the wall and a zero-length driveway edge, and
        // taps can produce each of them once the ground or the meter anchor moves after the tap
        // (a window tapped wholly below a guessed ground, a fence foot that ends up behind the
        // refined wall line). Such marks are clamped to the nearest valid shape here, or dropped
        // when nothing valid is left, and logged.
        let features: [SceneFeature] = state.features.compactMap { feature in
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
                guard points.count == 2 else { return Self.dropped(feature, "needs two taps") }
                return .fence(foot: points.map { Self.inFront(of: sceneWall, $0) })
            case .driveway:
                guard points.count == 2 else { return Self.dropped(feature, "needs two taps") }
                let edge = points.map { Self.inFront(of: sceneWall, $0) }
                // SceneExport's own degenerate-edge tolerance is 1e-3 ft; 1 cm keeps well clear of it.
                guard simd_distance(SIMD2(edge[0].x, edge[0].z), SIMD2(edge[1].x, edge[1].z)) > 0.01 else {
                    return Self.dropped(feature, "taps coincide in plan")
                }
                return .driveway(edge: edge)
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
            baselineS: low...high,
            meterPlusMinus: groundError,
            meterPlane: meterPlaneSource,
            objectPlusMinus: groundError,
            features: features,
            coverage: SceneCoverage(
                map, leftEndMarked: wallEndKinds[.left] == .limit, rightEndMarked: wallEndKinds[.right] == .limit
            ),
            keyframes: keyframes,
            stills: store.stills
        )
        return try SceneExport.jsonData(input)
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

    private static func dropped(_ feature: MarkedFeature, _ reason: String) -> SceneFeature? {
        RuntimeLog.engine.error("export: dropped \(feature.kind.rawValue, privacy: .public) \(feature.id.uuidString, privacy: .public): \(reason, privacy: .public)")
        return nil
    }

    enum ExportError: Error, CustomStringConvertible {
        case noWall

        var description: String { "There is no wall to export yet." }
    }

    /// The server's result in the terms the screens use (meters, wall coordinates).
    func presentation(of result: PlacementResult, isSample: Bool) -> ResultPresentation {
        let meters: (Double) -> Float = { Float($0 * 0.3048) }
        let sceneWall = coverage.map { SceneWall(meter: $0.wall.meter, outward: $0.wall.outward, groundY: $0.wall.groundY) }

        var spot: BatterySpot?
        if let placed = result.spot {
            // Placed from the offset to the meter, as result.schema.json asks, so the AR box
            // follows the meter's anchor. The offset is split along the result's own `along` and
            // `outward` vectors (same scene frame as the offset), which keeps the bundled sample
            // meaningful on any wall orientation.
            let offset = placed.meterOffsetFt
            let centerS = meters(offset.x * placed.along.x + offset.y * placed.along.y)
            let centerOut = meters(offset.x * placed.outward.x + offset.y * placed.outward.y)
            let width = meters(placed.widthFt)
            let depth = meters(placed.depthFt)
            spot = BatterySpot(
                span: (centerS - width / 2)...(centerS + width / 2),
                depth: depth, height: meters(placed.heightFt),
                offsetFromWall: max(0, centerOut - depth / 2)
            )
        }

        var route: [SIMD2<Float>] = []
        if let cable = result.route {
            let height = meters(cable.heightFt)
            if let placed = result.spot {
                // Relative to the meter's plan position in the result's own frame (the spot's
                // centre minus its offset from the meter), along the result's own wall direction.
                let meterPlan = placed.center - placed.meterOffsetFt
                route = cable.polyline.map { point in
                    let d = point - meterPlan
                    return SIMD2(meters(d.x * placed.along.x + d.y * placed.along.y), height)
                }
            } else if let sceneWall {
                route = cable.polyline.map { SIMD2(sceneWall.wallCoordinates(ofPlanPointFeet: $0).s, height) }
            }
        }

        let checks = result.checks.map { check in
            CheckRow(
                id: check.id, title: check.label, outcome: Self.outcome(check.outcome), reason: check.reason,
                // An UNSURE with no cause is unexplained, so a person has to look at it.
                needsPerson: check.outcome == .unsure && (check.unsureCause.map { [.margin, .unknownAttribute, .ruleRequiresReview].contains($0) } ?? true),
                measured: check.measuredFt.map(meters), threshold: check.thresholdFt.map(meters), plusMinus: check.plusMinusFt.map(meters)
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
                // A band of wall or ground, or the far side of an end, is something another
                // walk can show; overhead and facing bands need a person with a tape.
                // Only when a gap request can actually be built from it (a band item needs its
                // span, a past_end item its side); otherwise the button would do nothing.
                capturable: gapPlanner.plan(for: item, leftEnd: coverage?.leftEnd, rightEnd: coverage?.rightEnd) != nil
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
            isSample: isSample
        )
    }

    static func outcome(_ outcome: PlacementOutcome) -> CheckOutcome {
        switch outcome {
        case .pass: .pass
        case .fail: .fail
        case .unsure: .unsure
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
