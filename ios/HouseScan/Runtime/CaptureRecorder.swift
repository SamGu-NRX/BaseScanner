import CoreMotion
import Foundation
import HouseScanKit
import OSLog
import simd
import Synchronization

/// The packet's sensor streams, written to disk as they arrive: the camera trajectory at every
/// ARFrame (from the AR delegate queue) and Core Motion's samples (from `MotionSource`'s queue).
/// Nothing here runs on the main actor or holds an ARFrame; each sample is copied into a fixed
/// row of Doubles and appended to one raw file per stream, in 64 KB writes.
///
/// Poses stay in ARKit's world frame on disk: the meter anchor, which defines the packet's frame,
/// is set after capture starts, and can move until the packet is written. Packaging reads the
/// rows back (`rows(_:)`) and converts them then, so samples from before the meter was marked are
/// kept too.
///
/// One recorder is one packet session, in one world frame. `restart` starts a new session in the
/// same folder when the world frame is thrown away (a failed relocalization).
final class CaptureRecorder: Sendable {
    /// The raw streams. Each row starts with `t`, seconds of device uptime.
    enum Stream: Int, CaseIterable, Sendable {
        /// t, tracking state code, tracking reason code, then camera-to-world as 16 floats,
        /// column by column (`TrackingCode`).
        case trajectory
        /// t, x, y, z in g.
        case accelerometer
        /// t, x, y, z in rad/s.
        case gyroscope
        /// t, x, y, z in µT, uncalibrated.
        case magnetometer
        /// t, quaternion x y z w, gravity x y z (g), user acceleration x y z (g), rotation rate
        /// x y z (rad/s), heading in degrees (negative: none).
        case deviceMotion
        /// t, pressure in kPa, relative altitude in m.
        case barometer

        var width: Int {
            switch self {
            case .trajectory: 19
            case .accelerometer, .gyroscope, .magnetometer: 4
            case .deviceMotion: 15
            case .barometer: 3
            }
        }

        var fileName: String { "\(self).f64" }
    }

    /// What a session looked like when packaging flushed it.
    struct Snapshot: Sendable {
        var sessionID: String
        /// Wall clock at the first trajectory row, from that row's uptime.
        var startedAt: Date?
        var firstUptime: Double?
        var lastUptime: Double?
    }

    private struct State {
        var sessionID = UUID().uuidString
        var recording = true
        /// Rows older than this are from a world frame `restart` discarded; ARKit can deliver a
        /// few after the reset.
        var since: Double = 0
        var startedAt: Date?
        var firstUptime: Double?
        var lastUptime: Double?
        var buffers: [Data] = Array(repeating: Data(), count: Stream.allCases.count)
        var lastT: [Double] = Array(repeating: -.infinity, count: Stream.allCases.count)
        var failed = false
    }

    let directory: URL
    private let state = Mutex(State())
    /// 64 KB: about 450 trajectory rows (7 s at 60 Hz) or 2000 accelerometer rows per write.
    private static let flushBytes = 1 << 16

    init(directory: URL) {
        self.directory = directory
        Self.truncate(directory)
    }

    /// A new session in a new world frame: the files start empty, and rows timed before now are
    /// dropped.
    func restart() {
        state.withLock { state in
            state = State()
            state.since = ProcessInfo.processInfo.systemUptime
            Self.truncate(directory)
        }
    }

    /// Off while no capture is under way (the result screens): rows are dropped.
    func setRecording(_ on: Bool) {
        state.withLock { $0.recording = on }
    }

    func recordPose(t: Double, tracking: TrackingCode, cameraToWorld m: simd_float4x4) {
        let columns = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        let pose = columns.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
        append(.trajectory, [t, Double(tracking.state), Double(tracking.reason)] + pose)
    }

    /// Appends one row. A row not later than the stream's last one is dropped: every stream's `t`
    /// strictly increases.
    func append(_ stream: Stream, _ row: [Double]) {
        precondition(row.count == stream.width, "\(stream) row has \(row.count) values, expected \(stream.width)")
        let t = row[0]
        state.withLock { state in
            guard state.recording, !state.failed, t >= state.since, t > state.lastT[stream.rawValue] else { return }
            state.lastT[stream.rawValue] = t
            if stream == .trajectory {
                if state.firstUptime == nil {
                    state.firstUptime = t
                    // The same instant on the wall clock: the frame is `now - t` seconds old.
                    state.startedAt = Date(timeIntervalSinceNow: t - ProcessInfo.processInfo.systemUptime)
                }
                state.lastUptime = t
            }
            row.withUnsafeBufferPointer { values in
                for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { state.buffers[stream.rawValue].append(contentsOf: $0) } }
            }
            if state.buffers[stream.rawValue].count >= Self.flushBytes {
                write(stream, &state)
            }
        }
    }

    /// Writes every buffered row and returns the session as it stands.
    func flush() -> Snapshot {
        state.withLock { state in
            for stream in Stream.allCases { write(stream, &state) }
            return Snapshot(sessionID: state.sessionID, startedAt: state.startedAt, firstUptime: state.firstUptime, lastUptime: state.lastUptime)
        }
    }

    /// Every row written for `stream`, after `flush`. Call off the main actor.
    func rows(_ stream: Stream) -> [[Double]] {
        guard let data = try? Data(contentsOf: directory.appending(path: stream.fileName)) else { return [] }
        let values = data.withUnsafeBytes { raw in
            (0..<(raw.count / 8)).map { Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self))) }
        }
        return stride(from: 0, to: values.count - stream.width + 1, by: stream.width).map { Array(values[$0..<($0 + stream.width)]) }
    }

    /// A failed write stops the recorder rather than leave a stream with a hole in it; packaging
    /// then writes what reached the disk before the failure.
    private func write(_ stream: Stream, _ state: inout State) {
        let buffer = state.buffers[stream.rawValue]
        guard !buffer.isEmpty else { return }
        state.buffers[stream.rawValue] = Data()
        let url = directory.appending(path: stream.fileName)
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: buffer)
        } catch {
            state.failed = true
            RuntimeLog.capture.error("stream \(String(describing: stream), privacy: .public) not recorded from here on: \(String(describing: error), privacy: .public)")
        }
    }

    private static func truncate(_ directory: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        for stream in Stream.allCases {
            files.createFile(atPath: directory.appending(path: stream.fileName).path, contents: Data())
        }
    }
}

/// Tracking state and limited reason as numbers for a raw trajectory row.
struct TrackingCode: Sendable, Equatable {
    /// 0 normal, 1 limited, 2 not available.
    var state: Int
    /// 0 none or unknown, 1 initializing, 2 relocalizing, 3 excessive motion, 4 insufficient
    /// features.
    var reason: Int

    init(_ tracking: TrackingQuality) {
        switch tracking {
        case .normal: (state, reason) = (0, 0)
        case .notAvailable: (state, reason) = (2, 0)
        case .limited(let why):
            state = 1
            reason = switch why {
            case .initializing: 1
            case .relocalizing: 2
            case .excessiveMotion: 3
            case .insufficientFeatures: 4
            case .unknown: 0
            }
        }
    }

    init(state: Int, reason: Int) {
        self.state = state
        self.reason = reason
    }

    var packetTracking: PacketTracking {
        let why: PacketTracking.Reason? = switch reason {
        case 1: .initializing
        case 2: .relocalizing
        case 3: .excessiveMotion
        case 4: .insufficientFeatures
        default: nil
        }
        return switch state {
        case 0: .normal
        case 1: .limited(why)
        default: .notAvailable
        }
    }
}

/// Core Motion for the packet: accelerometer, gyroscope, magnetometer and device motion at
/// `rate`, and the barometer at whatever rate CMAltimeter delivers. Samples go straight to the
/// recorder from a private queue. Location and heading are not recorded (no consent prompt this
/// round), so device motion runs in an arbitrary-yaw frame and its heading is Core Motion's
/// negative "none".
@MainActor
final class MotionSource {
    /// 100 Hz, the packet's nominal rate for the four Core Motion streams. A choice, not
    /// measured: ADVIO's iPhone IMU runs at 100 Hz, and it is well under Core Motion's limit.
    nonisolated static let rate: Double = 100

    private let manager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.housescanning.housescan.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private(set) var isRunning = false

    /// Which streams this phone has; the packet lists only streams with rows.
    var available: Set<CaptureRecorder.Stream> {
        var streams: Set<CaptureRecorder.Stream> = []
        if manager.isAccelerometerAvailable { streams.insert(.accelerometer) }
        if manager.isGyroAvailable { streams.insert(.gyroscope) }
        if manager.isMagnetometerAvailable { streams.insert(.magnetometer) }
        if manager.isDeviceMotionAvailable { streams.insert(.deviceMotion) }
        if CMAltimeter.isRelativeAltitudeAvailable() { streams.insert(.barometer) }
        return streams
    }

    func start(into recorder: CaptureRecorder) {
        guard !isRunning else { return }
        isRunning = true
        Self.startUpdates(manager, altimeter, queue: queue, recorder: recorder, interval: 1 / Self.rate)
        RuntimeLog.capture.info("motion recording on: \(self.available.map { "\($0)" }.sorted().joined(separator: ", "), privacy: .public)")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopMagnetometerUpdates()
        manager.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        RuntimeLog.capture.info("motion recording off")
    }

    /// Nonisolated so the handlers are not main-actor closures: Core Motion calls them on `queue`.
    private nonisolated static func startUpdates(_ manager: CMMotionManager, _ altimeter: CMAltimeter, queue: OperationQueue, recorder: CaptureRecorder, interval: Double) {
        // Raw, as Core Motion reports it: the packet writer converts g to m/s².
        if manager.isAccelerometerAvailable {
            manager.accelerometerUpdateInterval = interval
            manager.startAccelerometerUpdates(to: queue) { data, _ in
                guard let data else { return }
                let a = data.acceleration
                recorder.append(.accelerometer, [data.timestamp, a.x, a.y, a.z])
            }
        }
        if manager.isGyroAvailable {
            manager.gyroUpdateInterval = interval
            manager.startGyroUpdates(to: queue) { data, _ in
                guard let data else { return }
                let r = data.rotationRate
                recorder.append(.gyroscope, [data.timestamp, r.x, r.y, r.z])
            }
        }
        if manager.isMagnetometerAvailable {
            manager.magnetometerUpdateInterval = interval
            manager.startMagnetometerUpdates(to: queue) { data, _ in
                guard let data else { return }
                let m = data.magneticField
                recorder.append(.magnetometer, [data.timestamp, m.x, m.y, m.z])
            }
        }
        if manager.isDeviceMotionAvailable {
            manager.deviceMotionUpdateInterval = interval
            manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { motion, _ in
                guard let motion else { return }
                let q = motion.attitude.quaternion
                let g = motion.gravity
                let a = motion.userAcceleration
                let r = motion.rotationRate
                recorder.append(.deviceMotion, [motion.timestamp, q.x, q.y, q.z, q.w, g.x, g.y, g.z, a.x, a.y, a.z, r.x, r.y, r.z, motion.heading])
            }
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: queue) { data, _ in
                guard let data else { return }
                recorder.append(.barometer, [data.timestamp, data.pressure.doubleValue, data.relativeAltitude.doubleValue])
            }
        }
    }
}
