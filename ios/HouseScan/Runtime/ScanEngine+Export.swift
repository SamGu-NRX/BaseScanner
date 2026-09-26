import Foundation
import HouseScanKit
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

        let features: [SceneFeature] = state.features.map { feature in
            let points = feature.points.map { $0 - drop }
            switch feature.kind {
            case .door:
                return .opening(kind: .door, span: feature.span, bottom: feature.bottom ?? 0, top: feature.top ?? 0, operable: nil)
            case .window:
                return .opening(kind: .window, span: feature.span, bottom: feature.bottom ?? 0, top: feature.top ?? 0, operable: feature.opens)
            case .gasMeter:
                return .pointObject(kind: .gasMeter, tap: points.first ?? wall.meter - drop, bottom: nil, top: nil)
            case .acUnit:
                return .pointObject(kind: .ac, tap: points.first ?? wall.meter - drop, bottom: nil, top: nil)
            case .fence:
                return .fence(foot: points)
            case .driveway:
                return .driveway(edge: points)
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

        let input = SceneInput(
            wall: sceneWall,
            baselineS: low...high,
            features: features,
            coverage: SceneCoverage(
                leftEndMarked: wallEndKinds[.left] == .limit,
                rightEndMarked: wallEndKinds[.right] == .limit,
                wall: map.coveredIntervals(.wall),
                ground: map.coveredIntervals(.ground),
                groundOut: map.config.groundBandDepth
            ),
            keyframes: keyframes,
            stills: store.stills
        )
        return try SceneExport.jsonData(input)
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
                needsPerson: check.outcome == .unsure && [.margin, .unknownAttribute, .ruleRequiresReview].contains(check.unsureCause),
                measured: check.measuredFt.map(meters), threshold: check.thresholdFt.map(meters), plusMinus: check.plusMinusFt.map(meters)
            )
        }

        let depth = spot?.depth ?? 0.3
        let clearances = result.sweep.enumerated().map { index, run in
            ClearanceZone(
                id: "sweep-\(index)",
                label: (run.failing + run.unsure).joined(separator: ", "),
                outcome: Self.outcome(run.outcome),
                span: meters(run.startFt.x)...max(meters(run.startFt.x), meters(run.startFt.y)),
                depth: depth
            )
        }

        let missing = result.missingEvidence.enumerated().map { index, item in
            MissingEvidence(
                id: "missing-\(index)", text: item.message,
                // A band of wall or ground, or the far side of an end, is something another
                // walk can show; overhead and facing bands need a person with a tape.
                capturable: item.kind == .pastEnd || item.band == .wall || item.band == .ground
            )
        }

        var unseen: WallSide?
        if let pastEnd = result.missingEvidence.first(where: { $0.kind == .pastEnd })?.side {
            unseen = pastEnd == .left ? .left : .right
        } else if result.ends.left.kind == .unexplored {
            unseen = .left
        } else if result.ends.right.kind == .unexplored {
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
