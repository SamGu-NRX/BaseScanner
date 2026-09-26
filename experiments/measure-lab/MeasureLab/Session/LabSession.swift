import ARKit
import MeasureGeometry
import Observation
import UIKit

/// One measuring session: the tool state machine, everything recorded so far, and the
/// session.json writer.
///
/// `CaptureController` resolves each tap to a saved frame, a pixel and a ray (plus a ground
/// raycast when the tool needs one) and hands it to `handle(_:)`. All geometry decisions happen
/// here through the MeasureGeometry package, so every accept and refuse is logged in one place.
@MainActor
@Observable
final class LabSession {
    /// Tracking must stay `.normal` this long before a tap counts (research note, acceptance gates).
    static let trackingStableSeconds = 1.0
    /// Ground taps flatter than this are kept but flagged (research note, acceptance gates).
    static let minimumGroundLookDown = 30.0
    /// Live taps compare ARKit's display transform with the app's portrait mapping. The two should
    /// agree to rounding; 2 px is an arbitrary alarm level, not a measured one.
    static let displayMappingTolerance = 2.0

    let wallGates = WallGates()
    let triangulationGates = TriangulationGates()
    let recorder = KeyframeRecorder()
    let lidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let meshReconstructionSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    private(set) var manifest: SessionManifest
    private(set) var folder: URL?
    private(set) var storageError: String?

    private(set) var tool: Tool = .ground
    private(set) var wallStep: WallStep = .firstContact
    private(set) var twoViewFirst: TwoViewFirst?
    private(set) var lastEvent: LabEvent?

    private(set) var trackingState: TrackingState = .notAvailable
    private(set) var isTrackingStable = false
    private(set) var isInterrupted = false
    private(set) var failure: SessionFailure?
    private(set) var horizontalPlaneCount = 0
    private(set) var verticalPlaneCount = 0

    private var horizontalPlanes: Set<UUID> = []
    private var verticalPlanes: Set<UUID> = []
    private var walls: [String: Wall] = [:]
    /// The session closed by `startNewSession`, kept so a keyframe that was mid-write at the
    /// switch still lands in its own session.json.
    private var closedSession: (manifest: SessionManifest, folder: URL)?
    private var stabilityTask: Task<Void, Never>?
    private var keyframesSinceSave = 0
    private var eventCount = 0

    enum WallStep: Equatable {
        case firstContact
        case secondContact(pointID: String, position: SIMD3<Double>)
        /// The wall exists; further taps are optional validation contacts.
        case validate(wallID: String)
    }

    struct TwoViewFirst {
        let tapID: String
        let keyframeID: String
        let ray: Ray
    }

    /// Pure: nothing touches disk until `start()`, so SwiftUI can re-create the owning view freely.
    init() {
        manifest = Self.makeManifest(sceneDepth: false, recorder: recorder)
    }

    /// Opens the first session folder. Later calls do nothing.
    func start() {
        guard folder == nil, storageError == nil else { return }
        manifest = Self.makeManifest(sceneDepth: false, recorder: recorder)
        openFolder(startRecorder: true)
    }

    // MARK: - Session lifecycle

    var sceneDepthEnabled: Bool {
        manifest.session.sceneDepthEnabled
    }

    /// Scene depth is fixed per session, so it can change only before the first tap.
    var canChangeSceneDepth: Bool {
        lidarAvailable && manifest.taps.isEmpty
    }

    /// Saves and closes the current session and opens an empty one in a new folder. The caller
    /// stops the recorder first and starts it on the returned destination once the AR map resets.
    func startNewSession(sceneDepth: Bool) -> KeyframeRecorder.Destination? {
        save()
        if let folder { closedSession = (manifest, folder) }
        manifest = Self.makeManifest(sceneDepth: sceneDepth && lidarAvailable, recorder: recorder)
        walls = [:]
        wallStep = .firstContact
        twoViewFirst = nil
        lastEvent = nil
        keyframesSinceSave = 0
        return openFolder(startRecorder: false)
    }

    private static func makeManifest(sceneDepth: Bool, recorder: KeyframeRecorder) -> SessionManifest {
        let now = Date.now
        let idFormatter = DateFormatter()
        idFormatter.locale = Locale(identifier: "en_US_POSIX")
        idFormatter.timeZone = .gmt
        idFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let spacing = recorder.spacing
        let wallGates = WallGates()
        let triangulationGates = TriangulationGates()
        let info = SessionInfo(
            // The random suffix keeps two sessions started in the same second in separate folders.
            id: idFormatter.string(from: now) + "-" + String(format: "%04x", UInt16.random(in: .min ... .max)),
            startedAt: now.ISO8601Format(),
            startedAtUptime: ProcessInfo.processInfo.systemUptime,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            deviceModel: deviceModelIdentifier(),
            systemVersion: UIDevice.current.systemVersion,
            lidarAvailable: ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            meshReconstructionSupported: ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh),
            sceneDepthEnabled: sceneDepth
        )
        let gates = GateValues(
            trackingStableSeconds: trackingStableSeconds,
            minimumGroundLookDown: minimumGroundLookDown,
            minimumContactSeparation: wallGates.minimumContactSeparation,
            maximumAngleFromWallNormal: wallGates.maximumAngleFromNormal,
            wallValidationTolerance: wallGates.validationTolerance,
            minimumCameraOffsetFromWall: wallGates.minimumCameraOffset,
            minimumRayAngle: triangulationGates.minimumRayAngle,
            maximumRayGap: triangulationGates.maximumGap,
            keyframeSpacingMeters: spacing.meters,
            keyframeSpacingDegrees: spacing.degrees
        )
        return SessionManifest(session: info, gates: gates)
    }

    @discardableResult
    private func openFolder(startRecorder: Bool) -> KeyframeRecorder.Destination? {
        do {
            let folder = try SessionStore.makeFolder(id: manifest.session.id)
            self.folder = folder
            storageError = nil
            let destination = KeyframeRecorder.Destination(sessionID: manifest.session.id, folder: folder)
            if startRecorder { recorder.start(destination) }
            save()
            return destination
        } catch {
            folder = nil
            storageError = "Couldn't create a folder for this session: \(error.localizedDescription)"
            return nil
        }
    }

    /// Writes session.json and returns the folder to archive. Called right before zipping so the
    /// manifest lists every keyframe saved so far.
    func prepareExport() -> URL? {
        save()
        return folder
    }

    func save() {
        guard let folder else { return }
        do {
            try SessionStore.write(manifest, to: folder)
            keyframesSinceSave = 0
        } catch {
            storageError = "Couldn't save session.json: \(error.localizedDescription)"
        }
    }

    // MARK: - ARKit state

    func trackingChanged(to state: TrackingState, at time: Double) {
        guard state != trackingState else { return }
        trackingState = state
        manifest.tracking.append(TrackingRecord(time: time, state: state.manifestName))
        stabilityTask?.cancel()
        isTrackingStable = false
        guard state == .normal else { return }
        stabilityTask = Task {
            try? await Task.sleep(for: .seconds(Self.trackingStableSeconds))
            guard !Task.isCancelled, trackingState == .normal else { return }
            isTrackingStable = true
        }
    }

    func planesAdded(_ planes: [DetectedPlane]) {
        for plane in planes {
            switch plane.orientation {
            case .horizontal: horizontalPlanes.insert(plane.id)
            case .vertical: verticalPlanes.insert(plane.id)
            }
        }
        horizontalPlaneCount = horizontalPlanes.count
        verticalPlaneCount = verticalPlanes.count
    }

    func planesRemoved(_ planes: [DetectedPlane]) {
        for plane in planes {
            switch plane.orientation {
            case .horizontal: horizontalPlanes.remove(plane.id)
            case .vertical: verticalPlanes.remove(plane.id)
            }
        }
        horizontalPlaneCount = horizontalPlanes.count
        verticalPlaneCount = verticalPlanes.count
    }

    func interruptionChanged(isInterrupted: Bool) {
        self.isInterrupted = isInterrupted
        if isInterrupted {
            isTrackingStable = false
            save()
        }
    }

    func sessionFailed(_ failure: SessionFailure) {
        self.failure = failure
        save()
    }

    /// Called when a new ARSession run resets tracking: plane counts start from zero, and taps wait
    /// until the new map reports normal tracking for the full stability time.
    func arSessionRestarted() {
        stabilityTask?.cancel()
        trackingState = .notAvailable
        isTrackingStable = false
        horizontalPlanes = []
        verticalPlanes = []
        horizontalPlaneCount = 0
        verticalPlaneCount = 0
    }

    func keyframeSaved(_ saved: KeyframeRecorder.Saved) {
        if saved.sessionID != manifest.session.id, var closed = closedSession, saved.sessionID == closed.manifest.session.id {
            closed.manifest.keyframes.append(saved.record)
            closedSession = closed
            try? SessionStore.write(closed.manifest, to: closed.folder)
            return
        }
        guard saved.sessionID == manifest.session.id else { return }
        manifest.keyframes.append(saved.record)
        keyframesSinceSave += 1
        // Keep session.json close to the images on disk without re-encoding it every frame.
        if keyframesSinceSave >= 20 { save() }
    }

    func recorderFailed(_ error: RecorderError) {
        if error == .frameFromPreviousMap {
            refuseUnresolvedTap(reason: "frameFromPreviousMap", message: error.message)
        } else {
            storageError = error.message
        }
    }

    // MARK: - Tools

    func select(_ tool: Tool) {
        self.tool = tool
    }

    /// Why a tap would be refused right now, or nil when it would be accepted.
    var markBlocker: String? {
        if isInterrupted { return "Camera paused" }
        if trackingState != .normal { return trackingState.instruction }
        if !isTrackingStable { return "Hold steady for a moment" }
        if tool == .wallPoint, activeWall == nil { return "Make a wall first" }
        return nil
    }

    var activeWall: (id: String, wall: Wall)? {
        guard let id = manifest.walls.last?.id, let wall = walls[id] else { return nil }
        return (id, wall)
    }

    var instruction: String {
        switch tool {
        case .ground:
            return "Aim the ring at the ground, then Mark."
        case .wall:
            switch wallStep {
            case .firstContact:
                return "Aim where the wall meets the ground at one end, then Mark."
            case .secondContact:
                return "Walk at least 2 m (6 ft 7 in) along the wall. Mark its base again."
            case .validate(let id):
                return "\(id) is set. To check it, mark a third point on its base."
            }
        case .wallPoint:
            guard let wall = activeWall else { return "Make a wall with the Wall tool first." }
            return "Aim at a point on \(wall.id), then Mark."
        case .twoView:
            if twoViewFirst == nil {
                return "Freeze a frame and tap a feature, or aim the ring at it and Mark."
            }
            return "Step about 1 m sideways, then mark the same feature again."
        }
    }

    /// The label for the tool's secondary action, or nil when there is none.
    var restartTitle: String? {
        switch tool {
        case .wall where wallStep != .firstContact: "New wall"
        case .twoView where twoViewFirst != nil: "Start over"
        default: nil
        }
    }

    func restartTool() {
        switch tool {
        case .wall: wallStep = .firstContact
        case .twoView: twoViewFirst = nil
        case .ground, .wallPoint: break
        }
    }

    private var stepName: String {
        switch tool {
        case .ground, .wallPoint: "single"
        case .wall:
            switch wallStep {
            case .firstContact: "firstContact"
            case .secondContact: "secondContact"
            case .validate: "validationContact"
            }
        case .twoView: twoViewFirst == nil ? "firstView" : "secondView"
        }
    }

    /// Logs a tap that never reached a frame, for example while tracking is limited.
    func refuseUnresolvedTap(reason: String, message: String) {
        _ = logRefusal(tap: nil, reason: reason, message: message, values: [:])
        announce(.refused, "Not measured", [message])
        save()
    }

    func handle(_ input: TapInput) {
        guard input.snapshot.sessionID == manifest.session.id else { return }
        var tap = TapRecord(
            id: "T\(manifest.taps.count + 1)",
            time: input.snapshot.timestamp,
            tool: tool.rawValue,
            step: stepName,
            keyframe: input.snapshot.keyframeID,
            frozen: input.frozen,
            pixel: [input.pixel.u, input.pixel.v],
            rayOrigin: input.ray.origin,
            rayDirection: input.ray.direction,
            displayMappingCheck: input.displayMappingCheck
        )
        switch tool {
        case .ground: handleGround(input, tap: &tap)
        case .wall: handleWall(input, tap: &tap)
        case .wallPoint: handleWallPoint(input, tap: &tap)
        case .twoView: handleTwoView(input, tap: &tap)
        }
        manifest.taps.append(tap)
        if let check = input.displayMappingCheck, check > Self.displayMappingTolerance, var event = lastEvent {
            // Frozen-frame taps rely on this mapping; say so on the spot rather than only in the log.
            event = LabEvent(id: event.id, tone: .warning, title: event.title, lines: event.lines + [
                "Screen mapping is off by \(check.formatted(.number.precision(.fractionLength(1)))) px; frozen taps may miss",
            ])
            lastEvent = event
        }
        save()
    }

    private func handleGround(_ input: TapInput, tap: inout TapRecord) {
        guard let point = makeGroundPoint(input, tap: &tap) else { return }
        announce(point.flags.isEmpty ? .accepted : .warning, "\(point.id) on the ground", describe(point))
    }

    private func handleWall(_ input: TapInput, tap: inout TapRecord) {
        switch wallStep {
        case .firstContact:
            guard let point = makeGroundPoint(input, tap: &tap) else { return }
            wallStep = .secondContact(pointID: point.id, position: point.position)
            announce(point.flags.isEmpty ? .accepted : .warning, "First contact \(point.id)", describe(point))

        case .secondContact(let firstID, let firstPosition):
            guard let point = makeGroundPoint(input, tap: &tap) else { return }
            let wall: Wall
            do {
                wall = try Wall(
                    contact1: firstPosition, contact2: point.position, cameraPosition: input.ray.origin, gates: wallGates
                )
            } catch {
                let (reason, message, values) = Self.explain(error)
                tap.refusal = logRefusal(tap: tap.id, reason: reason, message: message, values: values)
                announce(.refused, "No wall from \(firstID) and \(point.id)", [message])
                return
            }
            let id = "W\(manifest.walls.count + 1)"
            walls[id] = wall
            manifest.walls.append(WallRecord(
                id: id,
                contacts: [firstID, point.id],
                start: wall.start,
                end: wall.end,
                direction: wall.direction,
                normal: wall.normal,
                length: wall.length,
                cameraPosition: input.ray.origin,
                validations: []
            ))
            wallStep = .validate(wallID: id)
            announce(.accepted, "\(id) set", ["\(Format.length(wall.length)) between \(firstID) and \(point.id)"])

        case .validate(let wallID):
            guard let wall = walls[wallID], let index = manifest.walls.firstIndex(where: { $0.id == wallID }) else { return }
            guard let point = makeGroundPoint(input, tap: &tap) else { return }
            let check = wall.validate(contact: point.position, gates: wallGates)
            manifest.walls[index].validations.append(WallRecord.Validation(
                point: point.id, residual: check.residual, tolerance: check.tolerance, passes: check.passes
            ))
            let summary = "\(point.id) is \(Format.inches(check.residual)) off \(wallID) (limit \(Format.inches(check.tolerance)))"
            announce(check.passes ? .accepted : .warning, check.passes ? "\(wallID) checks out" : "\(wallID) failed its check", [summary])
        }
    }

    private func handleWallPoint(_ input: TapInput, tap: inout TapRecord) {
        guard let (wallID, wall) = activeWall else {
            let message = "There is no wall yet. Make one with the Wall tool."
            tap.refusal = logRefusal(tap: tap.id, reason: "noWall", message: message, values: [:])
            announce(.refused, "Not measured", [message])
            return
        }
        let hit: WallHit
        do {
            hit = try wall.intersect(input.ray, gates: wallGates)
        } catch {
            let (reason, message, values) = Self.explain(error)
            tap.refusal = logRefusal(tap: tap.id, reason: reason, message: message, values: values)
            announce(.refused, "Not on \(wallID)", [message])
            return
        }
        let point = addPoint(
            kind: .wall,
            position: hit.point,
            taps: [tap.id],
            onWall: PointRecord.OnWall(wall: wallID, range: hit.range, angleFromNormal: hit.angleFromNormal),
            flags: hit.withinContacts ? [] : ["outsideWallContacts"]
        )
        tap.point = point.id
        announce(point.flags.isEmpty ? .accepted : .warning, "\(point.id) on \(wallID)", describe(point))
    }

    private func handleTwoView(_ input: TapInput, tap: inout TapRecord) {
        guard let first = twoViewFirst else {
            twoViewFirst = TwoViewFirst(tapID: tap.id, keyframeID: input.snapshot.keyframeID, ray: input.ray)
            announce(.accepted, "First view saved", ["Step about 1 m sideways and mark the same feature."])
            return
        }
        guard first.keyframeID != input.snapshot.keyframeID else {
            let message = "Both taps are on the same frame. Step sideways, freeze a new frame, then tap the feature."
            tap.refusal = logRefusal(tap: tap.id, reason: "sameFrame", message: message, values: [:])
            announce(.refused, "Need a second view", [message])
            return
        }
        let result: Triangulation
        do {
            result = try Triangulation(first.ray, input.ray, gates: triangulationGates)
        } catch {
            let (reason, message, values) = Self.explain(error)
            tap.refusal = logRefusal(tap: tap.id, reason: reason, message: message, values: values)
            // A small angle can be fixed from the first view; a miss means the taps disagree.
            if case .rayAngleTooSmall = error {} else { twoViewFirst = nil }
            announce(.refused, "Not triangulated", [message])
            return
        }
        twoViewFirst = nil
        let point = addPoint(
            kind: .twoView,
            position: result.point,
            taps: [first.tapID, tap.id],
            twoView: PointRecord.TwoView(
                firstTap: first.tapID,
                secondTap: tap.id,
                rayAngle: result.rayAngle,
                gap: result.gap,
                baseline: result.baseline,
                t1: result.t1,
                t2: result.t2
            ),
            flags: []
        )
        tap.point = point.id
        announce(.accepted, "\(point.id) from two views", describe(point))
    }

    /// Adds a ground point from the tap's raycast, or logs why there is none.
    private func makeGroundPoint(_ input: TapInput, tap: inout TapRecord) -> PointRecord? {
        guard let hit = input.ground else {
            let message = "ARKit found no ground along that ray. Aim at ground it has mapped, or move closer."
            tap.refusal = logRefusal(tap: tap.id, reason: "noGround", message: message, values: [:])
            announce(.refused, "No ground there", [message])
            return nil
        }
        let lookDown = input.ray.lookDownDegrees
        var flags: [String] = []
        switch hit.surface {
        case .detectedPlane: break
        case .extendedPlane: flags.append("extendedPlane")
        case .estimatedPlane: flags.append("estimatedPlane")
        }
        if lookDown < Self.minimumGroundLookDown { flags.append("shallowLookDown") }
        let point = addPoint(
            kind: .ground,
            position: hit.point,
            taps: [tap.id],
            ground: PointRecord.Ground(surface: hit.surface.rawValue, planeAnchor: hit.planeAnchor, lookDown: lookDown),
            flags: flags
        )
        tap.point = point.id
        return point
    }

    private func addPoint(
        kind: PointRecord.Kind,
        position: SIMD3<Double>,
        taps: [String],
        ground: PointRecord.Ground? = nil,
        onWall: PointRecord.OnWall? = nil,
        twoView: PointRecord.TwoView? = nil,
        flags: [String]
    ) -> PointRecord {
        let coordinates = activeWall.map { active in
            PointRecord.WallCoordinates(
                wall: active.id,
                along: active.wall.along(position),
                heightAboveGround: active.wall.heightAboveGround(position),
                offset: active.wall.offset(of: position),
                withinContacts: active.wall.containsAlong(active.wall.along(position))
            )
        }
        let point = PointRecord(
            id: "P\(manifest.points.count + 1)",
            kind: kind,
            position: position,
            taps: taps,
            ground: ground,
            onWall: onWall,
            twoView: twoView,
            wallCoordinates: coordinates,
            flags: flags
        )
        manifest.points.append(point)
        return point
    }

    // MARK: - Measurements

    enum MeasureTarget: Hashable {
        case point(String)
        case wall(String)

        var id: String {
            switch self {
            case .point(let id), .wall(let id): id
            }
        }
    }

    func wall(id: String) -> Wall? {
        walls[id]
    }

    func point(id: String) -> PointRecord? {
        manifest.points.first { $0.id == id }
    }

    func values(from pointID: String, to target: MeasureTarget, referenceWall: String?) -> [MeasuredQuantity: Double] {
        guard let from = point(id: pointID) else { return [:] }
        switch target {
        case .point(let id):
            guard let to = point(id: id) else { return [:] }
            return measuredValues(from: from.position, to: .point(to.position), referenceWall: referenceWall.flatMap(wall(id:)))
        case .wall(let id):
            guard let wall = wall(id: id) else { return [:] }
            return measuredValues(from: from.position, to: .wall(wall))
        }
    }

    func addMeasurement(
        from pointID: String,
        to target: MeasureTarget,
        referenceWall: String?,
        compared quantity: MeasuredQuantity,
        tape: TapeReading?
    ) {
        let values = values(from: pointID, to: target, referenceWall: referenceWall)
        guard let measured = values[quantity] else { return }
        let comparison = tape.map { TapeComparison(measured: measured, tape: $0.meters) }
        let id = "M\(manifest.measurements.count + 1)"
        manifest.measurements.append(MeasurementRecord(
            id: id,
            time: ProcessInfo.processInfo.systemUptime,
            from: pointID,
            to: target.id,
            referenceWall: values[.alongWall] == nil ? nil : referenceWall,
            values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }),
            compared: quantity.rawValue,
            tape: tape.map { MeasurementRecord.Tape(feet: $0.feet, inches: $0.inches, meters: $0.meters) },
            errorMeters: comparison?.error,
            errorInches: comparison?.errorInches
        ))
        save()
        var lines = ["\(quantity.title): \(Format.length(measured))"]
        if let comparison {
            lines.append("Tape \(Format.length(comparison.tape)) · error \(Format.signedInches(comparison.error))")
        }
        announce(.accepted, "\(id) saved", lines)
    }

    // MARK: - Log helpers

    private func logRefusal(tap: String?, reason: String, message: String, values: [String: Double]) -> String {
        let id = "R\(manifest.refusals.count + 1)"
        manifest.refusals.append(RefusalRecord(
            id: id,
            time: ProcessInfo.processInfo.systemUptime,
            tool: tool.rawValue,
            tap: tap,
            reason: reason,
            message: message,
            values: values
        ))
        return id
    }

    private func announce(_ tone: LabEvent.Tone, _ title: String, _ lines: [String]) {
        eventCount += 1
        lastEvent = LabEvent(id: eventCount, tone: tone, title: title, lines: lines)
    }

    private func describe(_ point: PointRecord) -> [String] {
        var lines: [String] = []
        if let ground = point.ground {
            lines.append("\(Format.degrees(ground.lookDown)) look-down · \(GroundHit.Surface(rawValue: ground.surface)?.label ?? ground.surface)")
        }
        if let onWall = point.onWall {
            lines.append("\(Format.length(onWall.range)) away · \(Format.degrees(onWall.angleFromNormal)) from straight on")
        }
        if let twoView = point.twoView {
            lines.append("Rays \(Format.degrees(twoView.rayAngle)) apart, missing by \(Format.inches(twoView.gap)) · \(Format.length(twoView.baseline)) step")
        }
        if let coordinates = point.wallCoordinates {
            lines.append("\(Format.length(coordinates.along)) along \(coordinates.wall) · \(Format.length(coordinates.heightAboveGround)) up · \(Format.length(coordinates.offset)) out")
        }
        let warnings = point.flags.compactMap(Self.flagWarning)
        lines.append(contentsOf: warnings)
        return lines
    }

    private static func flagWarning(_ flag: String) -> String? {
        switch flag {
        case "estimatedPlane": "Estimated surface, not a found plane"
        case "extendedPlane": "Past the edge of the found plane"
        case "shallowLookDown": "Looking down less than 30°; tap from closer"
        case "outsideWallContacts": "Beyond the wall's two contacts"
        default: nil
        }
    }

    private static func explain(_ error: WallError) -> (String, String, [String: Double]) {
        switch error {
        case .contactsTooClose(let separation, let minimum):
            ("contactsTooClose",
             "The contacts are \(Format.length(separation)) apart; at least \(Format.length(minimum)) is needed. Mark the second one farther along.",
             ["separation": separation, "minimum": minimum])
        case .cameraInWallPlane(let offset, let minimum):
            ("cameraInWallPlane",
             "You're standing in line with the wall, so its front side is unclear. Step out in front of it and mark the second contact again.",
             ["offset": offset, "minimum": minimum])
        }
    }

    private static func explain(_ error: WallHitError) -> (String, String, [String: Double]) {
        switch error {
        case .grazing(let angle, let maximum):
            ("grazingRay",
             "That ray meets the wall \(Format.degrees(angle)) from straight on; the limit is \(Format.degrees(maximum)). Stand more in front of the point.",
             ["angleFromNormal": angle, "maximum": maximum])
        case .behindCamera(let t):
            ("wallBehindCamera",
             "The wall plane is behind the camera along that ray. Face the wall and try again.",
             ["t": t])
        }
    }

    private static func explain(_ error: TriangulationError) -> (String, String, [String: Double]) {
        switch error {
        case .rayAngleTooSmall(let angle, let minimum):
            ("rayAngleTooSmall",
             "The two views are \(Format.degrees(angle)) apart; at least \(Format.degrees(minimum)) is needed. Step farther sideways and mark it again.",
             ["rayAngle": angle, "minimum": minimum])
        case .behindCamera(let t1, let t2):
            ("raysMeetBehindCamera",
             "The rays meet behind the camera, so the taps aren't on the same feature. Start over.",
             ["t1": t1, "t2": t2])
        case .raysMiss(let gap, let maximum):
            ("raysMiss",
             "The rays pass \(Format.inches(gap)) apart (limit \(Format.inches(maximum))), so the taps may be on different features. Start over.",
             ["gap": gap, "maximum": maximum])
        }
    }
}

struct LabEvent: Identifiable, Equatable {
    enum Tone: Equatable {
        case accepted
        /// Accepted, but a flag or failed check applies.
        case warning
        case refused
    }

    let id: Int
    let tone: Tone
    let title: String
    let lines: [String]
}

extension GroundHit.Surface {
    var label: String {
        switch self {
        case .detectedPlane: "found plane"
        case .extendedPlane: "extended plane"
        case .estimatedPlane: "estimated surface"
        }
    }
}

extension MeasuredQuantity {
    var title: String {
        switch self {
        case .straight: "Straight line"
        case .horizontal: "Horizontal"
        case .vertical: "Height difference"
        case .alongWall: "Along the wall"
        case .gapToWall: "Gap to the wall"
        case .heightAboveGround: "Height above ground"
        }
    }
}

/// The hardware model, for example "iPhone15,4", so results can be grouped by phone.
private func deviceModelIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}
