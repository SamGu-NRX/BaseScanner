import Foundation

/// manifest.json of a capture packet, version 1.1: the field names and nesting of
/// packet/manifest.schema.json on t3/packet (d5439cf), vendored in the tests as
/// Schemas/manifest.schema.json. Optional fields are left out when nil, never written as null.
/// Lengths are meters, times seconds of device uptime, poses 16 numbers column by column in the
/// meter frame (`MeterFrame`).
public struct PacketManifest: Codable, Sendable, Equatable {
    public static let version = "1.1"

    public var packetVersion: String
    public var session: Session
    public var photos: [Photo]
    /// Depth recorded between photos, without an image (1.1).
    public var depthFrames: [DepthFrame]?
    public var streams: Streams?
    /// `ARPlaneAnchor`s, at the top level from 1.1.
    public var planes: [PacketPlane]?
    public var lidar: Lidar?
    public var marks: [PacketMark]?
    public var guidance: [PacketGuidanceEntry]?
    public var scene: SceneFile?
    /// Where a converted sample came from. The app never writes it.
    public var provenance: Provenance?

    enum CodingKeys: String, CodingKey {
        case packetVersion = "packet_version"
        case depthFrames = "depth_frames"
        case session, photos, streams, planes, lidar, marks, guidance, scene, provenance
    }

    /// A file in the packet: its path relative to manifest.json, size and SHA-256 (lowercase hex).
    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: Int
        public var sha256: String

        public init(path: String, bytes: Int, sha256: String) {
            self.path = path
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public struct Session: Codable, Sendable, Equatable {
        public var id: String
        public var producer: Producer
        public var device: Device
        public var capture: Capture
        /// Always "gravity".
        public var worldAlignment: String
        public var meterAnchor: MeterAnchor
        /// Absent: location and heading are not recorded.
        public var consent: Consent?

        enum CodingKeys: String, CodingKey {
            case id, producer, device, capture, consent
            case worldAlignment = "world_alignment"
            case meterAnchor = "meter_anchor"
        }
    }

    public struct Producer: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case app
            case converter
        }

        public var kind: Kind
        public var name: String
        public var version: String
        public var commit: String?

        public init(kind: Kind, name: String, version: String, commit: String? = nil) {
            self.kind = kind
            self.name = name
            self.version = version
            self.commit = commit
        }
    }

    public struct Device: Codable, Sendable, Equatable {
        /// Hardware identifier such as "iPhone16,1" (`utsname.machine`), never the phone's name.
        public var model: String
        public var iosVersion: String?
        /// The device supports `.sceneDepth`.
        public var lidar: Bool
        public var sceneDepthEnabled: Bool?
        public var meshEnabled: Bool?
        /// The session's `sceneReconstruction` included `.meshWithClassification` (1.1). The writer
        /// refuses a mesh while this is nil, and a mesh with any face classified while it is false:
        /// with classification off every class is 0, which a reader could not otherwise tell from
        /// ARKit's own "none".
        public var meshClassificationEnabled: Bool?

        public init(
            model: String, iosVersion: String?, lidar: Bool, sceneDepthEnabled: Bool?, meshEnabled: Bool?,
            meshClassificationEnabled: Bool?
        ) {
            self.model = model
            self.iosVersion = iosVersion
            self.lidar = lidar
            self.sceneDepthEnabled = sceneDepthEnabled
            self.meshEnabled = meshEnabled
            self.meshClassificationEnabled = meshClassificationEnabled
        }

        enum CodingKeys: String, CodingKey {
            case model, lidar
            case iosVersion = "ios_version"
            case sceneDepthEnabled = "scene_depth_enabled"
            case meshEnabled = "mesh_enabled"
            case meshClassificationEnabled = "mesh_classification_enabled"
        }
    }

    public struct Capture: Codable, Sendable, Equatable {
        /// ISO 8601 UTC wall clock at `startedAtUptime`.
        public var startedAt: String?
        public var startedAtUptime: Double
        public var endedAtUptime: Double
        public var distanceWalkedM: Double?

        enum CodingKeys: String, CodingKey {
            case startedAt = "started_at"
            case startedAtUptime = "started_at_uptime"
            case endedAtUptime = "ended_at_uptime"
            case distanceWalkedM = "distance_walked_m"
        }
    }

    public struct MeterAnchor: Codable, Sendable, Equatable {
        /// Meter frame to world, 16 numbers column by column.
        public var poseInWorld: [Double]
        /// The ground at the meter on the meter frame's y (negative).
        public var groundYM: Double?

        enum CodingKeys: String, CodingKey {
            case poseInWorld = "pose_in_world"
            case groundYM = "ground_y_m"
        }
    }

    public struct Consent: Codable, Sendable, Equatable {
        public var location: Bool?
    }

    public struct Photo: Codable, Sendable, Equatable {
        public var id: String
        public var image: File
        public var width: Int
        public var height: Int
        public var t: Double
        /// Camera to meter frame.
        public var pose: [Double]
        /// [fx, fy, cx, cy] in pixels of the stored JPEG.
        public var intrinsics: [Double]
        public var tracking: Tracking?
        public var exposure: PacketExposure?
        public var lens: PacketLens?
        public var sharpness: Sharpness?
        public var depth: Depth?
    }

    public struct Tracking: Codable, Sendable, Equatable {
        /// "normal", "limited" or "not_available".
        public var state: String
        /// A limited state's reason; absent when ARKit gave none this format names.
        public var reason: String?
    }

    public struct Sharpness: Codable, Sendable, Equatable {
        public var method: String
        public var value: Double
    }

    public struct Depth: Codable, Sendable, Equatable {
        public var map: File
        public var confidence: File?
        /// Float32 meters, one standard deviation per pixel (1.1).
        public var sigma: File?
        public var width: Int
        public var height: Int
        public var source: DepthPacket.Source?
    }

    /// Depth recorded between photos (1.1): the depth fields of `Depth` with the camera that took
    /// it, and intrinsics in pixels of the depth map itself.
    public struct DepthFrame: Codable, Sendable, Equatable {
        public var id: String
        public var t: Double
        /// Camera to meter frame.
        public var pose: [Double]
        /// [fx, fy, cx, cy] in pixels of the depth map.
        public var intrinsics: [Double]
        public var tracking: Tracking?
        public var map: File
        public var confidence: File?
        public var sigma: File?
        public var width: Int
        public var height: Int
        public var source: DepthPacket.Source?
    }

    /// A stream's CSV file.
    public struct Stream: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: Int
        public var sha256: String
        public var rows: Int
        public var nominalRateHz: Double?

        enum CodingKeys: String, CodingKey {
            case path, bytes, sha256, rows
            case nominalRateHz = "nominal_rate_hz"
        }
    }

    public struct Streams: Codable, Sendable, Equatable {
        public var trajectory: Stream?
        public var accelerometer: Stream?
        public var gyroscope: Stream?
        public var magnetometer: Stream?
        public var deviceMotion: Stream?
        public var barometer: Stream?
        /// Not recorded by the app this round; here so a reader of any 1.0 packet decodes it.
        public var location: Stream?
        public var heading: Stream?

        enum CodingKeys: String, CodingKey {
            case trajectory, accelerometer, gyroscope, magnetometer, barometer, location, heading
            case deviceMotion = "device_motion"
        }

        subscript(stream: PacketStream) -> Stream? {
            get {
                switch stream {
                case .trajectory: trajectory
                case .accelerometer: accelerometer
                case .gyroscope: gyroscope
                case .magnetometer: magnetometer
                case .deviceMotion: deviceMotion
                case .barometer: barometer
                }
            }
            set {
                switch stream {
                case .trajectory: trajectory = newValue
                case .accelerometer: accelerometer = newValue
                case .gyroscope: gyroscope = newValue
                case .magnetometer: magnetometer = newValue
                case .deviceMotion: deviceMotion = newValue
                case .barometer: barometer = newValue
                }
            }
        }
    }

    public struct Lidar: Codable, Sendable, Equatable {
        public var mesh: File?
        /// Where 1.0 put planes. Decoded so a 1.0 packet reads; the writer puts planes at the top
        /// level and leaves this out, since a packet may not use both.
        public var planes: [PacketPlane]?
    }

    public struct SceneFile: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: Int
        public var sha256: String
        public var schemaVersion: String?

        enum CodingKeys: String, CodingKey {
            case path, bytes, sha256
            case schemaVersion = "schema_version"
        }
    }

    public struct Provenance: Codable, Sendable, Equatable {
        public var dataset: String?
        public var license: String?
        public var source: String?
        public var notes: [String]?
    }
}

/// `ARCamera.exposureDuration` and `exposureOffset`, and ISO from a still's metadata. Each is
/// optional; `durationS` and `iso` must be positive.
public struct PacketExposure: Codable, Sendable, Equatable {
    public var durationS: Double?
    public var iso: Double?
    public var offsetEV: Double?

    public init(durationS: Double? = nil, iso: Double? = nil, offsetEV: Double? = nil) {
        self.durationS = durationS
        self.iso = iso
        self.offsetEV = offsetEV
    }

    enum CodingKeys: String, CodingKey {
        case iso
        case durationS = "duration_s"
        case offsetEV = "offset_ev"
    }
}

/// From a still's EXIF. `camera` is "wide", "ultra_wide" or "telephoto".
public struct PacketLens: Codable, Sendable, Equatable {
    public var focalLengthMM: Double?
    public var fNumber: Double?
    public var camera: String?

    public init(focalLengthMM: Double? = nil, fNumber: Double? = nil, camera: String? = nil) {
        self.focalLengthMM = focalLengthMM
        self.fNumber = fNumber
        self.camera = camera
    }

    enum CodingKeys: String, CodingKey {
        case camera
        case focalLengthMM = "focal_length_mm"
        case fNumber = "f_number"
    }
}
