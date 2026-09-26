// Writes a fully synthetic measure-lab-session v2 replay: a ray-traced brick wall with painted
// meters, a door and a window, filmed by a phone held in portrait. No real imagery goes in, so the
// output can be committed and redistributed; UI tests and replay decoders use it as a fixture.
//
// Run from the repository root (macOS):
//   swift ios/Tools/make-synthetic-replay.swift ios/HouseScanUITests/Fixtures/synthetic-wall
//   swift ios/Tools/make-synthetic-replay.swift --lidar ios/HouseScanUITests/Fixtures/synthetic-wall-lidar
//
// --lidar writes the replay a LiDAR phone would record of the same walk: the scene gains a wheelie
// bin in front of the wall (see `occluder`), drawn in the photos, and every keyframe gets a depth
// map in the Measure Lab v2 layout: keyframes/<id>.depth.f32 (Float32 meters, little-endian,
// row-major) and keyframes/<id>.confidence.u8 (UInt8 0 low, 1 medium, 2 high). A depth value is
// the distance along the camera's viewing axis, as in ARKit's depthMap; 0 means nothing was hit
// (sky). The depth map is the photo's view at `depthWidth` x `depthHeight`, so its intrinsics are
// the photo's scaled by depthWidth / width.
//
// Scene, in the ARKit gravity frame (meters, +y up):
//   wall on z = 0 facing +z, x in [-6, 6], height 3; sky above and beyond it.
//   ground y = 0 for z in [0, 10]: mulch strip z in [0, 0.5], grass beyond; flat color past z = 10.
//   electric meter x [-0.15, 0.15] y [1.3, 1.7]; gas meter x [-1.35, -1.05] y [0.3, 0.8];
//   door x [-3.4, -2.5] y [0, 2.05]; window x [2.0, 3.0] y [0.9, 2.0].
//   --lidar only: a bin x [1.2, 1.8] y [0, 1.1] z [0.5, 1.1].
// The last three frames tilt up at the wall above the meter and the sky, for the tilt-up step.
// Images are the unrotated landscape sensor image: camera +x is world down, so the ground appears
// on the right of each JPEG. Output is deterministic; the only "noise" comes from integer hashes.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Options

let arguments = Array(CommandLine.arguments.dropFirst())
let lidar = arguments.first == "--lidar"
guard arguments.count == (lidar ? 2 : 1) else {
    FileHandle.standardError.write(Data("usage: swift ios/Tools/make-synthetic-replay.swift [--lidar] <outputDir>\n".utf8))
    exit(2)
}
let outputPath = arguments[arguments.count - 1]

// MARK: - Small vector math (scalar Double; the script runs unoptimized, so avoid generic SIMD)

struct V3 {
    var x, y, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (a: V3, b: V3) -> V3 { V3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: V3, b: V3) -> V3 { V3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: V3, s: Double) -> V3 { V3(a.x * s, a.y * s, a.z * s) }
    func dot(_ b: V3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: V3) -> V3 { V3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var normalized: V3 { self * (1 / dot(self).squareRoot()) }
    var array: [Double] { [x, y, z] }
}

struct RGB {
    var r, g, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    static func * (c: RGB, s: Double) -> RGB { RGB(c.r * s, c.g * s, c.b * s) }
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }
}

/// Portrait camera: columns (-up, right, -forward, position), see the header.
struct Camera {
    let position: V3
    let c0: V3, c1: V3, c2: V3

    init(position: V3, forward f: V3) {
        let forward = f.normalized
        let right = forward.cross(V3(0, 1, 0)).normalized
        let up = right.cross(forward)
        self.position = position
        c0 = up * -1
        c1 = right
        c2 = forward * -1
    }

    var pose: [Double] {
        [c0.x, c0.y, c0.z, 0, c1.x, c1.y, c1.z, 0, c2.x, c2.y, c2.z, 0, position.x, position.y, position.z, 1]
    }

    /// World point to pixel (u, v); the rotation is orthonormal, so its inverse is its transpose.
    func project(_ p: V3) -> (u: Double, v: Double) {
        let d = p - position
        let x = d.dot(c0), y = d.dot(c1), z = d.dot(c2)
        return (cx + fx * x / -z, cy - fy * y / -z)
    }
}

// MARK: - Deterministic noise

func hash(_ a: Int, _ b: Int, _ seed: Int) -> Double {
    var h = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
    h ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
    h ^= UInt64(bitPattern: Int64(seed)) &* 0x1656_67B1_9E37_79F9
    h ^= h >> 31
    h = h &* 0xBF58_476D_1CE4_E5B9
    h ^= h >> 29
    return Double(h >> 11) / Double(1 << 53)
}

func valueNoise(_ x: Double, _ y: Double, _ seed: Int) -> Double {
    let x0 = x.rounded(.down), y0 = y.rounded(.down)
    let ix = Int(x0), iy = Int(y0)
    var tx = x - x0, ty = y - y0
    tx = tx * tx * (3 - 2 * tx)
    ty = ty * ty * (3 - 2 * ty)
    let a = hash(ix, iy, seed), b = hash(ix + 1, iy, seed)
    let c = hash(ix, iy + 1, seed), d = hash(ix + 1, iy + 1, seed)
    return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
}

// MARK: - Scene

let fx = 500.0, fy = 500.0, cx = 320.0, cy = 240.0
let width = 640, height = 480

let brickLength = 0.215, brickHeight = 0.065, mortar = 0.01

func wallColor(_ x: Double, _ y: Double) -> RGB {
    // Electric meter: light gray box with a dark dial.
    if x >= -0.15, x <= 0.15, y >= 1.3, y <= 1.7 {
        let dx = x, dy = y - 1.52
        if dx * dx + dy * dy <= 0.08 * 0.08 { return RGB(0.12, 0.13, 0.15) }
        return RGB(0.80, 0.81, 0.82)
    }
    if x >= -1.35, x <= -1.05, y >= 0.3, y <= 0.8 { return RGB(0.93, 0.78, 0.16) }
    if x >= -3.4, x <= -2.5, y >= 0, y <= 2.05 {
        let knob = (x + 2.6) * (x + 2.6) + (y - 1.0) * (y - 1.0) <= 0.03 * 0.03
        return knob ? RGB(0.75, 0.68, 0.40) : RGB(0.30, 0.18, 0.10)
    }
    if x >= 2.0, x <= 3.0, y >= 0.9, y <= 2.0 {
        let frame = 0.06
        let inFrame = x < 2.0 + frame || x > 3.0 - frame || y < 0.9 + frame || y > 2.0 - frame
            || abs(x - 2.5) < frame / 2
        return inFrame ? RGB(0.95, 0.95, 0.93) : RGB(0.22, 0.27, 0.32)
    }
    let rowPitch = brickHeight + mortar, colPitch = brickLength + mortar
    let row = Int((y / rowPitch).rounded(.down))
    let shifted = x + 6 + (row % 2 == 0 ? 0 : colPitch / 2)
    let col = Int((shifted / colPitch).rounded(.down))
    let ly = y - Double(row) * rowPitch
    let lx = shifted - Double(col) * colPitch
    if ly < mortar || lx < mortar { return RGB(0.70, 0.68, 0.64) }
    let tone = 0.82 + 0.3 * hash(row, col, 1)
    return RGB(0.62, 0.30, 0.22) * tone
}

func groundColor(_ x: Double, _ z: Double) -> RGB {
    if z < 0 || z > 10 { return RGB(0.45, 0.47, 0.42) }
    let n = 0.6 * valueNoise(x * 12, z * 12, 2) + 0.4 * valueNoise(x * 3, z * 3, 3)
    if z <= 0.5 { return RGB.mix(RGB(0.20, 0.13, 0.08), RGB(0.34, 0.22, 0.13), n) }
    return RGB.mix(RGB(0.25, 0.42, 0.16), RGB(0.40, 0.55, 0.24), n)
}

func skyColor(_ d: V3) -> RGB {
    RGB.mix(RGB(0.78, 0.87, 0.95), RGB(0.45, 0.65, 0.90), max(0, min(1, d.y)))
}

/// An axis-aligned box standing in the scene.
struct Box {
    let low: V3, high: V3

    /// Where the ray enters the box: its parameter and the outward normal of the face it crosses,
    /// or nil on a miss. Every camera stands outside the box.
    func entry(_ o: V3, _ d: V3) -> (t: Double, normal: V3)? {
        var near = -Double.infinity, far = Double.infinity
        var normal = V3(0, 0, 0)
        let axes = [
            (o.x, d.x, low.x, high.x, V3(1, 0, 0)),
            (o.y, d.y, low.y, high.y, V3(0, 1, 0)),
            (o.z, d.z, low.z, high.z, V3(0, 0, 1)),
        ]
        for (origin, direction, lo, hi, axis) in axes {
            if direction == 0 {
                if origin < lo || origin > hi { return nil }
                continue
            }
            // Moving toward +axis, the ray enters through the low face, whose normal is -axis.
            let (t0, t1, sign) = direction > 0
                ? ((lo - origin) / direction, (hi - origin) / direction, -1.0)
                : ((hi - origin) / direction, (lo - origin) / direction, 1.0)
            if t0 > near { near = t0; normal = axis * sign }
            far = min(far, t1)
            if near > far { return nil }
        }
        return near > 0 ? (near, normal) : nil
    }
}

/// --lidar only: a wheelie bin 0.6 m wide, 0.6 m deep and 1.1 m tall, 0.5 m out from the wall,
/// spanning x 1.2 to 1.8 m (4 to 6 ft right of the meter, clear of the window). From the walk it
/// hides the wall behind it up to about 1 m and the mulch at its foot.
let occluder: Box? = lidar ? Box(low: V3(1.2, 0, 0.5), high: V3(1.8, 1.1, 1.1)) : nil

func binColor(_ box: Box, _ p: V3, _ normal: V3) -> RGB {
    // The top face and an 8 cm band under it are the lid.
    let lid = normal.y > 0 || p.y > box.high.y - 0.08
    let base = lid ? RGB(0.10, 0.16, 0.12) : RGB(0.16, 0.26, 0.20)
    // Light from above and in front: top brightest, sides darker than the front.
    return base * (normal.y > 0 ? 1.25 : normal.z > 0 ? 1.0 : 0.75)
}

/// The nearest surface along the ray: its ray parameter (infinity for sky) and color.
func trace(_ o: V3, _ d: V3) -> (t: Double, color: RGB) {
    var best = Double.infinity
    var color = skyColor(d)
    if d.z < 0 {
        let t = -o.z / d.z
        let p = o + d * t
        if t > 0, p.x >= -6, p.x <= 6, p.y >= 0, p.y <= 3 {
            best = t
            color = wallColor(p.x, p.y)
        }
    }
    if d.y < 0 {
        let t = -o.y / d.y
        if t > 0, t < best {
            best = t
            let p = o + d * t
            color = groundColor(p.x, p.z)
        }
    }
    if let box = occluder, let hit = box.entry(o, d), hit.t < best {
        best = hit.t
        color = binColor(box, o + d * hit.t, hit.normal)
    }
    return (best, color)
}

func render(_ cam: Camera) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    let offsets = [0.25, 0.75]
    for v in 0..<height {
        for u in 0..<width {
            var r = 0.0, g = 0.0, b = 0.0
            for oy in offsets {
                for ox in offsets {
                    let dx = (Double(u) + ox - cx) / fx
                    let dy = -(Double(v) + oy - cy) / fy
                    let d = (cam.c0 * dx + cam.c1 * dy - cam.c2).normalized
                    let c = trace(cam.position, d).color
                    r += c.r; g += c.g; b += c.b
                }
            }
            let i = (v * width + u) * 4
            pixels[i] = UInt8(max(0, min(255, (r / 4 * 255).rounded())))
            pixels[i + 1] = UInt8(max(0, min(255, (g / 4 * 255).rounded())))
            pixels[i + 2] = UInt8(max(0, min(255, (b / 4 * 255).rounded())))
        }
    }
    return pixels
}

/// ARKit's depth map size. The 41 maps take 8 MB on disk but zlib, which git stores objects
/// with, packs them about 14 to 1 (measured on this fixture), because noise-free depth of flat
/// surfaces is smooth; confidence packs about 400 to 1.
let depthWidth = 256, depthHeight = 192

/// One ray per depth pixel, through its center, with no noise: the value is the exact distance
/// along the viewing axis to the surface the photo shows there.
///
/// Confidence by distance is a guess at LiDAR behaviour, not measured: high to 3 m, medium to 5 m,
/// low beyond, and low with depth 0 where the ray hits nothing.
func renderDepth(_ cam: Camera) -> (meters: [Float], confidence: [UInt8]) {
    let scale = Double(width) / Double(depthWidth)
    var meters = [Float](repeating: 0, count: depthWidth * depthHeight)
    var confidence = [UInt8](repeating: 0, count: depthWidth * depthHeight)
    for v in 0..<depthHeight {
        for u in 0..<depthWidth {
            let dx = ((Double(u) + 0.5) * scale - cx) / fx
            let dy = -((Double(v) + 0.5) * scale - cy) / fy
            // Unnormalized, one unit along the viewing axis per unit of t, so t is the depth.
            let t = trace(cam.position, cam.c0 * dx + cam.c1 * dy - cam.c2).t
            guard t.isFinite else { continue }
            let i = v * depthWidth + u
            meters[i] = Float(t)
            confidence[i] = t <= 3 ? 2 : t <= 5 ? 1 : 0
        }
    }
    return (meters, confidence)
}

func writeJPEG(_ pixels: [UInt8], to url: URL, quality: Double) throws {
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    guard let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ), let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

// MARK: - Camera path

struct Shot { let camera: Camera; let time: Double }

let meter = V3(0, 1.5, 0)
let pitch = 20.0 * Double.pi / 180
let walkForward = V3(0, -sin(pitch), -cos(pitch))
var shots: [Shot] = []
var time = 100.0

// a) Close-up on the meter, with up to 1 cm of hashed hand jitter.
for i in 0..<5 {
    let j = V3(hash(i, 0, 7) - 0.5, hash(i, 1, 7) - 0.5, hash(i, 2, 7) - 0.5) * 0.0115
    let position = V3(0, 1.5, 1.0) + j
    shots.append(Shot(camera: Camera(position: position, forward: meter - position), time: time))
    time += 0.2
}
time += 0.3
// b) Step back to z = 2.6, still aimed at the meter.
for z in [1.8, 2.6] {
    let position = V3(0, 1.5, z)
    shots.append(Shot(camera: Camera(position: position, forward: meter - position), time: time))
    time += 0.5
}
time += 0.05
// c) Walk left, then d) walk right, pitched 20 degrees down; the turnaround frame appears once.
let walkXs = (0...10).map { -0.5 * Double($0) } + (1...20).map { -5 + 0.5 * Double($0) }
for x in walkXs {
    shots.append(Shot(camera: Camera(position: V3(x, 1.5, 2.6), forward: walkForward), time: time))
    time += 0.55
}
// e) Back beside the meter (the walk back isn't filmed; 5 s keeps it at a walking pace), then tilt
// up at the upper wall and the sky above it for the tilt-up step: 22, 26 and 30 degrees up. At 22
// degrees about 60% of the view is still brick, so the frame is as sharp as the walk's.
time += 5
for degrees in [22.0, 26.0, 30.0] {
    let up = degrees * Double.pi / 180
    shots.append(Shot(camera: Camera(position: V3(0.2, 1.5, 2.6), forward: V3(0, sin(up), -cos(up))), time: time))
    time += 0.5
}

// MARK: - Output

let out = URL(fileURLWithPath: outputPath, isDirectory: true)
let keyframesDir = out.appendingPathComponent("keyframes", isDirectory: true)
let fm = FileManager.default
if fm.fileExists(atPath: keyframesDir.path) {
    for name in try fm.contentsOfDirectory(atPath: keyframesDir.path)
    where [".jpg", ".depth.f32", ".confidence.u8"].contains(where: name.hasSuffix) {
        try fm.removeItem(at: keyframesDir.appendingPathComponent(name))
    }
}
try fm.createDirectory(at: keyframesDir, withIntermediateDirectories: true)

/// Writes the keyframe's depth and confidence maps and returns its `depth` entry.
func writeDepth(_ cam: Camera, id: String) throws -> [String: Any] {
    let (meters, confidence) = renderDepth(cam)
    var bytes = Data(capacity: meters.count * 4)
    for value in meters {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
    }
    let file = "keyframes/\(id).depth.f32", confidenceFile = "keyframes/\(id).confidence.u8"
    try bytes.write(to: out.appendingPathComponent(file))
    try Data(confidence).write(to: out.appendingPathComponent(confidenceFile))
    return ["file": file, "confidenceFile": confidenceFile, "w": depthWidth, "h": depthHeight]
}

let jpegQuality = 0.5
var keyframes: [[String: Any]] = []
for (index, shot) in shots.enumerated() {
    let id = String(format: "k%05d", index + 1)
    let img = "keyframes/\(id).jpg"
    try writeJPEG(render(shot.camera), to: out.appendingPathComponent(img), quality: jpegQuality)
    keyframes.append([
        "id": id, "img": img, "w": width, "h": height,
        "intrinsics": [fx, fy, cx, cy], "pose": shot.camera.pose,
        "timestamp": (shot.time * 1000).rounded() / 1000,
        "tracking": "normal", "reason": "motion",
        "depth": lidar ? try writeDepth(shot.camera, id: id) : NSNull(),
    ])
}

let p1 = V3(-4, 0, 0), p2 = V3(4, 0, 0)
let wallCamera = V3(0, 1.5, 2.6)
let contactLookDown = atan2(1.5, 2.6) * 180 / Double.pi
func groundPoint(_ id: String, _ p: V3) -> [String: Any] {
    [
        "id": id, "kind": "ground", "position": p.array, "taps": [String](),
        "ground": ["surface": "detectedPlane", "planeAnchor": NSNull(), "lookDown": contactLookDown] as [String: Any],
        "onWall": NSNull(), "twoView": NSNull(), "wallCoordinates": NSNull(),
        "flags": [String](), "wallWarnings": [String](),
    ]
}
let meterPoint: [String: Any] = [
    "id": "p3", "kind": "wall", "position": meter.array, "taps": [String](),
    "ground": NSNull(),
    "onWall": ["wall": "w1", "range": 1.0, "angleFromNormal": 0.0] as [String: Any],
    "twoView": NSNull(),
    "wallCoordinates": [
        "wall": "w1", "along": 4.0, "heightAboveGround": 1.5, "offset": 0.0, "withinContacts": true,
    ] as [String: Any],
    "flags": [String](), "wallWarnings": [String](),
]

let manifest: [String: Any] = [
    "format": "measure-lab-session",
    "formatVersion": 2,
    "units": [
        "length": "meters", "angle": "degrees",
        "time": "seconds of device uptime, the clock of ARFrame.timestamp",
        "image": "pixels of the saved JPEG",
    ],
    "conventions": [
        "world": "ARKit world frame with worldAlignment .gravity: right-handed, y up (away from gravity), origin and heading fixed where the session started",
        "camera": "ARKit camera frame: +x right and +y up in the unrotated sensor image, the camera looks along -z",
        "pose": "camera-to-world 4x4 matrix, 16 numbers column by column (simd_float4x4 layout)",
        "intrinsics": "[fx, fy, cx, cy] in pixels of the saved, unrotated landscape JPEG",
        "pixel": "[u, v] continuous image coordinates: (0, 0) is the top-left corner of the JPEG, v grows down",
        "ray": "origin is the camera position; direction is a unit vector through the tapped pixel",
    ],
    "session": [
        "id": lidar ? "synthetic-wall-lidar" : "synthetic-wall",
        "startedAt": "2026-01-01T00:00:00Z", "startedAtUptime": 100.0,
        "appVersion": "make-synthetic-replay", "deviceModel": "synthetic", "systemVersion": "synthetic",
        "lidarAvailable": lidar, "meshReconstructionSupported": lidar, "sceneDepthEnabled": lidar,
    ] as [String: Any],
    // Same keys and values as the Measure Lab defaults recorded in real sessions.
    "gates": [
        "trackingStableSeconds": 1.0, "minimumGroundLookDown": 30.0, "minimumContactSeparation": 2.0,
        "maximumAngleFromWallNormal": 60.0, "wallValidationTolerance": 0.0508,
        "minimumCameraOffsetFromWall": 0.1, "minimumRayAngle": 15.0, "maximumRayGap": 0.0508,
        "keyframeSpacingMeters": 0.5, "keyframeSpacingDegrees": 15.0,
    ],
    "keyframes": keyframes,
    "taps": [Any](),
    "points": [groundPoint("p1", p1), groundPoint("p2", p2), meterPoint],
    "walls": [[
        "id": "w1", "contacts": ["p1", "p2"], "start": p1.array, "end": p2.array,
        "direction": [1.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "length": 8.0,
        "cameraPosition": wallCamera.array, "validations": [Any](), "warnings": [String](),
    ] as [String: Any]],
    "measurements": [Any](),
    "refusals": [Any](),
    "tracking": [["time": 100.0, "state": "normal"] as [String: Any]],
    "provenance": [
        "generator": "ios/Tools/make-synthetic-replay.swift",
        "note": lidar
            ? "synthetic scene with a bin in front of the wall, no real imagery; depth rendered from the scene"
            : "synthetic scene, no real imagery",
    ],
]

let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try (json + Data("\n".utf8)).write(to: out.appendingPathComponent("session.json"))

let check = shots[0].camera.project(meter)
print("wrote \(shots.count) keyframes to \(out.path)")
print(String(format: "meter center in k00001 projects to (%.2f, %.2f), expected (320, 240)", check.u, check.v))
