import Foundation
import HouseScanKit
import OSLog
import simd
import UIKit

/// The capture packet (packet/README.md on t3/packet, version 1.0): what Share scan hands over.
/// Everything in it is in meters, seconds of device uptime and the meter frame, except
/// scene.json, which travels inside unchanged. Nothing uploads it: photos leave the phone only
/// when the homeowner shares the scan.
extension ScanEngine {
    /// Everything the packet needs from the main actor, read in one turn so it describes one
    /// moment of the scan. The files are written from it off the main actor (`writePacket`).
    struct PacketInputs: Sendable {
        var folder: URL
        var zip: URL
        var storeDirectory: URL
        var recorder: CaptureRecorder
        /// A replay's own frames, which stand in for the live trajectory: nil live.
        var replayTrajectory: [ReplayPose]?
        var producer: PacketManifest.Producer
        var device: PacketManifest.Device
        var meterFrame: MeterFrame
        var groundWorldY: Float
        /// Keyframes and stills; `writePacket` orders them by time.
        var photos: [StoredKeyframe]
        var mesh: LiveCapture.MeshSnapshot?
        var planes: [PacketPlane]
        /// `photoIDs` hold store ids ("meter_close"); `writePacket` swaps in packet ids.
        var marks: [PacketMark]
        var guidance: [PacketGuidanceEntry]
        var scene: Data
        /// The camera's frame rate live; nil on a replay, whose rate comes from its frames.
        var trajectoryRate: Double?
        var motionStreams: Set<CaptureRecorder.Stream>
    }

    struct ReplayPose: Sendable {
        var t: Double
        var normal: Bool
        var cameraToWorld: simd_float4x4
    }

    /// Nil before there is a wall: the meter frame is built from it.
    func packetInputs(scene: Data, mesh: LiveCapture.MeshSnapshot?) -> PacketInputs? {
        guard let map = coverage else { return nil }
        let wall = map.wall
        // The wall in world meters, as scene.json's wall type describes it, for the marks.
        let sceneWall = SceneWall(meter: wall.meter, outward: wall.outward, groundY: wall.groundY, leftCorners: wall.leftCorners, rightCorners: wall.rightCorners)
        guard let frame = MeterFrame(meter: wall.meter, outward: wall.outward) else { return nil }
        let settings = liveCapture?.settings
        let info = Bundle.main.infoDictionary ?? [:]
        let version = [info["CFBundleShortVersionString"], info["CFBundleVersion"]].compactMap { $0 as? String }
        return PacketInputs(
            folder: store.packetFolder,
            zip: store.bundleURL,
            storeDirectory: store.directory,
            recorder: recorder,
            replayTrajectory: replay.map { player in
                player.frames.map { ReplayPose(t: $0.timestamp, normal: $0.trackingNormal, cameraToWorld: $0.cameraToWorld) }
            },
            producer: PacketManifest.Producer(
                kind: .app, name: info["CFBundleName"] as? String ?? "HouseScan",
                version: version.count == 2 ? "\(version[0]) (\(version[1]))" : version.first ?? "unknown",
                // No build step records the git commit; the schema makes it optional.
                commit: nil
            ),
            device: PacketManifest.Device(
                model: Self.hardwareModel(), iosVersion: UIDevice.current.systemVersion, lidar: LiveCapture.supportsDepth,
                // A replay runs no ARKit session, so neither ran.
                sceneDepthEnabled: settings?.sceneDepth ?? false, meshEnabled: settings?.mesh ?? false
            ),
            meterFrame: frame,
            groundWorldY: wall.groundY,
            photos: store.keyframes + store.stillFrames.keys.sorted().compactMap { store.stillFrames[$0] },
            mesh: mesh,
            planes: (liveCapture?.planeSnapshot() ?? []).map { plane in
                PacketPlane(
                    id: plane.id, alignment: plane.vertical ? .vertical : .horizontal, classification: plane.classification,
                    pose: frame.pose(plane.pose), extent: plane.extent
                )
            },
            marks: packetMarks(map, wall: sceneWall, frame: frame),
            guidance: guidanceLog.entries.map { Self.packetEntry($0, wall: sceneWall, frame: frame) },
            scene: scene,
            trajectoryRate: settings.map { Double($0.framesPerSecond) },
            motionStreams: motionRunsLive ? motionAvailable : []
        )
    }

    /// `utsname.machine`, such as "iPhone16,1": the hardware, never the phone's name. "arm64" in
    /// the Simulator.
    nonisolated static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Marks

    /// The meter, the marked wall ends and every marked feature, in the meter frame.
    private func packetMarks(_ map: CoverageMap, wall: SceneWall, frame: MeterFrame) -> [PacketMark] {
        var marks = [PacketMark.meter(
            id: "meter", t: markTimes[MarkKey.meter], photoIDs: store.stillFrames["meter_close"] == nil ? nil : ["meter_close"]
        )]
        for (side, s) in [(WallSide.left, map.leftEnd), (.right, map.rightEnd)] {
            guard let s else { continue }
            marks.append(.wallEnd(
                id: "wall_end_\(side.rawValue)", side: side == .left ? .left : .right,
                endKind: wallEndKinds[side] == .limit ? .limit : .unexplored, s: s, wall: wall, frame: frame, t: markTimes[MarkKey.end(side)]
            ))
        }
        for feature in state.features {
            let id = feature.id.uuidString.lowercased()
            let t = markTimes[MarkKey.feature(feature.id)]
            let points = feature.points.map { frame.point($0) }
            switch feature.kind {
            case .door, .window:
                let bottom = feature.bottom ?? 0
                marks.append(.opening(
                    feature.kind == .door ? .door : .window, id: id, span: feature.span, bottom: bottom, top: feature.top ?? bottom,
                    operable: feature.kind == .window ? feature.opens : nil, wall: wall, frame: frame, t: t
                ))
            case .gasMeter, .acUnit:
                guard let point = points.first else { continue }
                marks.append(.pointObject(feature.kind == .gasMeter ? .gasMeter : .ac, id: id, point: point, t: t))
            case .driveway, .fence:
                guard points.count == 2 else {
                    RuntimeLog.engine.error("packet: \(feature.kind.rawValue, privacy: .public) mark has \(points.count) taps, not 2; left out")
                    continue
                }
                marks.append(feature.kind == .fence
                    ? .fence(id: id, from: points[0], to: points[1], t: t)
                    : .driveEdge(id: id, from: points[0], to: points[1], t: t))
            }
        }
        return marks
    }

    /// Keys of `markTimes`.
    enum MarkKey {
        static let meter = "meter"
        static func end(_ side: WallSide) -> String { "end.\(side.rawValue)" }
        static func feature(_ id: UUID) -> String { id.uuidString }
    }

    // MARK: Guidance

    /// A logged request with its span moved from s to meter-frame x.
    private static func packetEntry(_ entry: GuidanceLog.Entry, wall: SceneWall, frame: MeterFrame) -> PacketGuidanceEntry {
        let span = entry.request.span.map { span -> ClosedRange<Float> in
            let low = frame.point(on: wall, s: span.lowerBound, height: 0, out: 0).x
            let high = frame.point(on: wall, s: span.upperBound, height: 0, out: 0).x
            return min(low, high)...max(low, high)
        }
        return PacketGuidanceEntry(
            id: entry.id, kind: entry.request.kind, origin: entry.request.origin, message: entry.request.message,
            band: entry.request.band, span: span, tShown: entry.shown, tResolved: entry.resolved, outcome: entry.outcome
        )
    }

    // MARK: Writing

    /// Writes the packet folder, zips it to `inputs.zip` and removes the folder. Returns the zip
    /// and a one-line summary for the log. Off the main actor: it copies every photo and hashes
    /// every file.
    ///
    /// A photo, a trajectory row or a section the writer refuses is left out and logged, so one
    /// bad input doesn't cost the homeowner the whole packet; the writer's checks are the
    /// validator's, so what is written validates.
    nonisolated static func writePacket(_ inputs: PacketInputs) throws -> (url: URL, summary: String) {
        let frame = inputs.meterFrame
        let trajectory = trajectoryRows(inputs)
        guard let started = trajectory.rows.first?.t, let ended = trajectory.rows.last?.t, ended > started else {
            throw PacketBuildError.noTrajectory
        }

        try? FileManager.default.removeItem(at: inputs.folder)
        var writer = try PacketWriter(folder: inputs.folder, session: PacketSessionInfo(
            id: trajectory.sessionID, producer: inputs.producer, device: inputs.device, startedAt: trajectory.startedAt,
            startedAtUptime: started, meterFrame: frame, groundWorldY: inputs.groundWorldY
        ))

        // Photos in time order, one per source frame, inside the capture.
        var packetID: [String: String] = [:]
        var last: (t: Double, id: String)?
        var added = 0
        var withDepth = 0
        for stored in inputs.photos.sorted(by: { $0.t < $1.t }) {
            if let last, last.t == stored.t {
                // The same frame kept twice (a close-up that was also a walk frame, or a view kept
                // again for the overhead answer): one photo.
                packetID[stored.id] = last.id
                continue
            }
            guard (started...ended).contains(stored.t), let sharpness = stored.sharpness else {
                RuntimeLog.engine.error("packet: \(stored.id, privacy: .public) at t=\(stored.t) left out: outside the capture \(started)...\(ended) or no sharpness")
                continue
            }
            let id = PacketPhoto.id(number: added + 1)
            do {
                let depth = stored.depth.flatMap { KeyframeStore.loadDepth($0, in: inputs.storeDirectory) }.flatMap(Self.measured)
                try writer.addPhoto(Self.photo(stored, id: id, sharpness: sharpness, depth: depth, inputs: inputs))
                packetID[stored.id] = id
                last = (stored.t, id)
                added += 1
                if depth != nil { withDepth += 1 }
            } catch {
                RuntimeLog.engine.error("packet: \(stored.id, privacy: .public) left out: \(String(describing: error), privacy: .public)")
            }
        }

        var skippedRows = 0
        try writer.setNominalRate(trajectory.rate, for: .trajectory)
        for row in trajectory.rows {
            do { try writer.appendTrajectory(t: row.t, tracking: row.tracking, pose: frame.pose(row.cameraToWorld)) } catch { skippedRows += 1 }
        }
        skippedRows += writeMotion(inputs, window: started...ended, into: &writer)
        if skippedRows > 0 { RuntimeLog.engine.error("packet: \(skippedRows) stream rows refused and left out") }

        if let mesh = inputs.mesh {
            do { try writer.setMesh(frame.mesh(mesh.mesh), classification: mesh.classification) } catch { Self.logLeftOut("mesh", error) }
        }
        if !inputs.planes.isEmpty {
            do { try writer.setPlanes(inputs.planes) } catch { Self.logLeftOut("planes", error) }
        }
        let clamp = { (t: Double) in min(max(t, started), ended) }
        do {
            try writer.setMarks(inputs.marks.map { mark in
                var mark = mark
                let ids = (mark.photoIDs ?? []).compactMap { packetID[$0] }
                mark.photoIDs = ids.isEmpty ? nil : ids
                mark.t = mark.t.map(clamp)
                return mark
            })
        } catch { Self.logLeftOut("marks", error) }
        do {
            try writer.setGuidance(inputs.guidance.map { entry in
                var entry = entry
                entry.tShown = clamp(entry.tShown)
                entry.tResolved = entry.tResolved.map { max(clamp($0), entry.tShown) }
                return entry
            })
        } catch { Self.logLeftOut("guidance", error) }
        try writer.setScene(inputs.scene)
        let folder = try writer.finish()
        try KeyframeStore.zipPacket(folder, to: inputs.zip)
        let summary = "\(added) photos (\(withDepth) with depth), \(trajectory.rows.count) trajectory rows over \(String(format: "%.1f", ended - started)) s, "
            + "\(inputs.motionStreams.count) motion streams, \(inputs.mesh == nil ? "no mesh" : "mesh"), \(inputs.planes.count) planes, "
            + "\(inputs.marks.count) marks, \(inputs.guidance.count) guidance entries"
        return (inputs.zip, summary)
    }

    private struct Trajectory {
        var sessionID: String
        var startedAt: Date?
        /// Nominal rate, Hz.
        var rate: Double
        var rows: [(t: Double, tracking: PacketTracking, cameraToWorld: simd_float4x4)]
    }

    /// The camera path, world frame: every recorded ARFrame live, or one row per replay frame.
    /// Its first and last times are the capture's window.
    private nonisolated static func trajectoryRows(_ inputs: PacketInputs) -> Trajectory {
        if let poses = inputs.replayTrajectory {
            var rows: [(t: Double, tracking: PacketTracking, cameraToWorld: simd_float4x4)] = []
            for pose in poses.sorted(by: { $0.t < $1.t }) where pose.t > (rows.last?.t ?? -.infinity) {
                rows.append((pose.t, pose.normal ? .normal : .limited(nil), pose.cameraToWorld))
            }
            // The recording's own rate. It has no wall-clock start.
            let span = (rows.last?.t ?? 0) - (rows.first?.t ?? 0)
            let rate = rows.count > 1 && span > 0 ? Double(rows.count - 1) / span : 1
            return Trajectory(sessionID: UUID().uuidString, startedAt: nil, rate: rate, rows: rows)
        }
        let snapshot = inputs.recorder.flush()
        let rows = inputs.recorder.rows(.trajectory).map { row in
            let pose = simd_float4x4(
                SIMD4(Float(row[3]), Float(row[4]), Float(row[5]), Float(row[6])),
                SIMD4(Float(row[7]), Float(row[8]), Float(row[9]), Float(row[10])),
                SIMD4(Float(row[11]), Float(row[12]), Float(row[13]), Float(row[14])),
                SIMD4(Float(row[15]), Float(row[16]), Float(row[17]), Float(row[18]))
            )
            return (t: row[0], tracking: TrackingCode(state: Int(row[1]), reason: Int(row[2])).packetTracking, cameraToWorld: pose)
        }
        return Trajectory(sessionID: snapshot.sessionID, startedAt: snapshot.startedAt, rate: inputs.trajectoryRate ?? 60, rows: rows)
    }

    private nonisolated static func photo(_ stored: StoredKeyframe, id: String, sharpness: Double, depth: DepthPacket?, inputs: PacketInputs) -> PacketPhoto {
        // Intrinsics belong to the stored image; a JPEG of another size than the camera reported
        // scales them with it.
        let scale = SIMD2(Float(stored.width), Float(stored.height)) / stored.camera.imageSize
        let k = stored.camera.intrinsics
        return PacketPhoto(
            id: id, jpeg: inputs.storeDirectory.appending(path: "\(stored.id).jpg"), width: stored.width, height: stored.height,
            t: stored.t, pose: inputs.meterFrame.pose(stored.camera.cameraToWorld),
            intrinsics: SIMD4(k.x * scale.x, k.y * scale.y, k.z * scale.x, k.w * scale.y),
            tracking: TrackingCode(stored.tracking).packetTracking,
            exposure: stored.exposure.map { PacketExposure(durationS: $0.durationS, iso: $0.iso, offsetEV: $0.offsetEV) },
            // ARKit's frames come from the back wide camera; a replay says nothing about its lens.
            lens: stored.exposure.map { PacketLens(focalLengthMM: $0.focalLengthMM, fNumber: $0.fNumber, camera: "wide") },
            sharpness: sharpness, depth: depth
        )
    }

    /// Nil for a depth map with under 1% of pixels measured, which the validator calls empty: the
    /// photo goes in without it.
    private nonisolated static func measured(_ depth: DepthPacket) -> DepthPacket? {
        let count = depth.meters.reduce(0) { $0 + ($1.isFinite && $1 > 0 ? 1 : 0) }
        return Double(count) >= 0.01 * Double(depth.meters.count) ? depth : nil
    }

    /// Core Motion's streams, rows inside the capture only. Returns how many rows were refused.
    private nonisolated static func writeMotion(_ inputs: PacketInputs, window: ClosedRange<Double>, into writer: inout PacketWriter) -> Int {
        var refused = 0
        for stream in CaptureRecorder.Stream.allCases where stream != .trajectory && inputs.motionStreams.contains(stream) {
            let rows = inputs.recorder.rows(stream).filter { window.contains($0[0]) }
            guard !rows.isEmpty else { continue }
            let packetStream: PacketStream = switch stream {
            case .trajectory: .trajectory
            case .accelerometer: .accelerometer
            case .gyroscope: .gyroscope
            case .magnetometer: .magnetometer
            case .deviceMotion: .deviceMotion
            case .barometer: .barometer
            }
            // CMAltimeter sets its own rate (about 1 Hz), so the barometer claims none.
            if stream != .barometer { try? writer.setNominalRate(MotionSource.rate, for: packetStream) }
            for r in rows {
                do {
                    switch stream {
                    case .accelerometer: try writer.appendAccelerometer(t: r[0], g: SIMD3(r[1], r[2], r[3]))
                    case .gyroscope: try writer.appendGyroscope(t: r[0], radiansPerSecond: SIMD3(r[1], r[2], r[3]))
                    case .magnetometer: try writer.appendMagnetometer(t: r[0], microtesla: SIMD3(r[1], r[2], r[3]))
                    case .deviceMotion:
                        try writer.appendDeviceMotion(DeviceMotionSample(
                            t: r[0], attitude: SIMD4(r[1], r[2], r[3], r[4]), gravity: SIMD3(r[5], r[6], r[7]),
                            userAcceleration: SIMD3(r[8], r[9], r[10]), rotationRate: SIMD3(r[11], r[12], r[13]), headingDegrees: r[14]
                        ))
                    case .barometer: try writer.appendBarometer(t: r[0], pressureKPa: r[1], relativeAltitudeM: r[2])
                    case .trajectory: break
                    }
                } catch {
                    refused += 1
                }
            }
        }
        return refused
    }

    private nonisolated static func logLeftOut(_ section: String, _ error: any Error) {
        RuntimeLog.engine.error("packet: \(section, privacy: .public) left out: \(String(describing: error), privacy: .public)")
    }

    enum PacketBuildError: Error, CustomStringConvertible {
        case noTrajectory

        var description: String {
            switch self {
            case .noTrajectory: "no trajectory was recorded, so the capture has no time span"
            }
        }
    }
}
