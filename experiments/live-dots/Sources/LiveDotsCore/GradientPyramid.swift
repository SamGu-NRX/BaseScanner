import Foundation

/// Colour gradient of a keyframe image, measured at the scale of a voxel.
///
/// Level 0 is a Sobel on the 640 x 480 JPEG; each further level halves the image by 2 x 2
/// averaging first. A depth sample reads the level whose pixel is closest to one voxel (5 cm) at
/// its depth, so a 1 cm mortar joint averages away while a painted outline, a step in colour
/// wider than the pixel, keeps its full height. The magnitude is the Sobel of the strongest RGB
/// channel divided by 4, which reads a sharp step of height c (0 to 1) as c at every level.
public struct GradientPyramid: Sendable {
    public struct Level: Sendable {
        public let width: Int
        public let height: Int
        public let magnitude: [Float]
    }

    public static let levelCount = 5
    public let levels: [Level]

    public init(image: RGBImage) {
        var width = image.width, height = image.height
        var planes: [[Float]] = (0..<3).map { channel in
            (0..<(width * height)).map { Float(image.rgba[$0 * 4 + channel]) / 255 }
        }
        var levels: [Level] = []
        for level in 0..<Self.levelCount {
            levels.append(Level(width: width, height: height, magnitude: Self.sobel(planes, width: width, height: height)))
            if level < Self.levelCount - 1 {
                (planes, width, height) = Self.halve(planes, width: width, height: height)
            }
        }
        self.levels = levels
    }

    /// The level whose pixel spans about one voxel at `depth`, for an image with focal length
    /// `focal` in level-0 pixels.
    public static func level(depth: Float, focal: Float) -> Int {
        let pixelsPerVoxel = Tuning.voxelSize * focal / max(depth, 0.01)
        let level = Int(log2(max(pixelsPerVoxel, 1)).rounded())
        return min(max(level, 0), levelCount - 1)
    }

    /// Bilinear magnitude at continuous level-0 pixel coordinates (u, v).
    public func magnitude(u: Float, v: Float, level: Int) -> Float {
        let l = levels[level]
        let scale = Float(1 << level)
        let x = min(max(u / scale - 0.5, 0), Float(l.width - 1))
        let y = min(max(v / scale - 0.5, 0), Float(l.height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, l.width - 1), y1 = min(y0 + 1, l.height - 1)
        let fx = x - Float(x0), fy = y - Float(y0)
        let m = l.magnitude
        let top = m[y0 * l.width + x0] * (1 - fx) + m[y0 * l.width + x1] * fx
        let bottom = m[y1 * l.width + x0] * (1 - fx) + m[y1 * l.width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    private static func sobel(_ planes: [[Float]], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        for plane in planes {
            plane.withUnsafeBufferPointer { p in
                for y in 0..<height {
                    let ym = max(y - 1, 0) * width, y0 = y * width, yp = min(y + 1, height - 1) * width
                    for x in 0..<width {
                        let xm = max(x - 1, 0), xp = min(x + 1, width - 1)
                        let gx = (p[ym + xp] + 2 * p[y0 + xp] + p[yp + xp]) - (p[ym + xm] + 2 * p[y0 + xm] + p[yp + xm])
                        let gy = (p[yp + xm] + 2 * p[yp + x] + p[yp + xp]) - (p[ym + xm] + 2 * p[ym + x] + p[ym + xp])
                        let m = (gx * gx + gy * gy).squareRoot() / 4
                        if m > out[y0 + x] { out[y0 + x] = m }
                    }
                }
            }
        }
        return out
    }

    private static func halve(_ planes: [[Float]], width: Int, height: Int) -> ([[Float]], Int, Int) {
        let w = width / 2, h = height / 2
        let halved = planes.map { p in
            (0..<(w * h)).map { i -> Float in
                let x = (i % w) * 2, y = (i / w) * 2
                return (p[y * width + x] + p[y * width + x + 1] + p[(y + 1) * width + x] + p[(y + 1) * width + x + 1]) / 4
            }
        }
        return (halved, w, h)
    }
}
