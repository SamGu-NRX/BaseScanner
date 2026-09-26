import Foundation

// The close-up retake checks that the close-up eval found to work without knowing where the true
// number is: whole-photo focus and the top candidate's size. A port of retake.py and the helpers it
// uses from quality.py (experiments/meter-closeup/src/meter_eval/ on t3/meter-closeup at 944cbe1).
// Glare, framing and hand shake have no check because the eval found no signal the phone can
// compute for them (README, question 2).

/// A grayscale photo of 0-255 values, row-major. Float, as the eval resizes in PIL's 32-bit float
/// mode.
public struct MeterGrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height, "MeterGrayImage: \(pixels.count) values for \(width)x\(height)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The luma of 8-bit RGBX pixels (4 bytes each, the fourth ignored). `bytesPerRow` may exceed
    /// `4 * width` (row padding).
    public init(rgbx base: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) {
        precondition(bytesPerRow >= 4 * width && base.count >= bytesPerRow * (height - 1) + 4 * width, "MeterGrayImage: \(base.count) bytes for \(width)x\(height) at \(bytesPerRow) per row")
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let p = row + 4 * x
                out[y * width + x] = Float(MeterPhotoChecks.luma(red: base[p], green: base[p + 1], blue: base[p + 2]))
            }
        }
        self.init(width: width, height: height, pixels: out)
    }
}

/// What the homeowner is shown after a close-up that passed the focus check.
public struct MeterChoices: Sendable, Equatable {
    /// Barcode-confirmed first, at most three (`MeterNumberRanking.choices`).
    public var candidates: [MeterTextCandidate]
    /// The top-scoring candidate's line is at most `MeterPhotoChecks.minTopLinePixels` tall.
    public var numberTooSmall: Bool
}

public enum MeterPhotoChecks {
    /// Retake as out of focus at or below this whole-photo sharpness (grey levels squared).
    /// From the eval's results/sweep.md (blur, whole-photo sharpness at up to 1024 px, 95%
    /// column): AUC 0.96, and it sent back none of the 75 real photos that read, whose lowest
    /// score was 58.7, so no real photo was near it. Measured on Commons JPEGs, not this app's
    /// camera path: the README asks for a field test on the app's own captures before trusting it,
    /// because sharpening and noise reduction move sharpness values.
    public static let minSharpness = 6.63
    /// "Number too small" at or below this height of the top candidate's line, in photo pixels.
    /// From results/sweep.md (scale, top-candidate line height, 95% column): AUC 0.86, sending
    /// back 2 of 75 real photos that read. Also untested on this app's camera path (README, "Field
    /// test before trusting the thresholds").
    public static let minTopLinePixels = 33.9
    /// Sharpness is measured with the long side shrunk to this, so it does not depend on
    /// resolution above it.
    public static let sharpnessLongSide = 1024

    /// 8-bit luma L = 0.299 R + 0.587 G + 0.114 B, rounded in fixed point as PIL's "L" conversion
    /// does.
    public static func luma(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        // Separate typed terms: Swift 6.2 (CI's Xcode 26.6) times out type-checking the sum as
        // one expression.
        let r: Int = Int(red) * 19595
        let g: Int = Int(green) * 38470
        let b: Int = Int(blue) * 7471
        let sum: Int = r + g + b + 0x8000
        return UInt8(sum >> 16)
    }

    /// Laplacian variance of the photo shrunk to a 1024 px long side; smaller photos as they are.
    ///
    /// Takes the stored pixels, before any EXIF turn or flip: the 4-neighbour Laplacian is the same
    /// under quarter turns and flips, and the resize treats each axis on its own, so orienting first
    /// changes only float rounding.
    public static func wholePhotoSharpness(_ image: MeterGrayImage) -> Double {
        laplacianVariance(downscaled(image, longSide: sharpnessLongSide))
    }

    public static func isOutOfFocus(sharpness: Double) -> Bool {
        sharpness <= minSharpness
    }

    /// The choices for a photo that passed the focus check, or nil when nothing was read (retake).
    /// The size check uses the highest-scoring candidate, as the eval measured it, even when a
    /// barcode-confirmed one is listed first.
    public static func choices(from candidates: [MeterTextCandidate], photoHeight: Int) -> MeterChoices? {
        guard let top = MeterNumberRanking.ranked(candidates).first else { return nil }
        return MeterChoices(
            candidates: MeterNumberRanking.choices(candidates),
            numberTooSmall: top.box.height * Double(photoHeight) <= minTopLinePixels
        )
    }

    /// Population variance of the 4-neighbour Laplacian [[0,1,0],[1,-4,1],[0,1,0]] over interior
    /// pixels; 0 for images under 3 px on a side.
    public static func laplacianVariance(_ image: MeterGrayImage) -> Double {
        let w = image.width
        let h = image.height
        guard w >= 3, h >= 3 else { return 0 }
        let count = Double((w - 2) * (h - 2))
        return image.pixels.withUnsafeBufferPointer { g in
            func laplacian(_ x: Int, _ y: Int) -> Double {
                let i = y * w + x
                return Double(g[i - w]) + Double(g[i + w]) + Double(g[i - 1]) + Double(g[i + 1]) - 4 * Double(g[i])
            }
            var sum = 0.0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) { sum += laplacian(x, y) }
            }
            let mean = sum / count
            var squares = 0.0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let d = laplacian(x, y) - mean
                    squares += d * d
                }
            }
            return squares / count
        }
    }

    /// Shrinks so the long side is `longSide` pixels; never enlarges. The new size rounds half to
    /// even, as Python's `round` does.
    public static func downscaled(_ image: MeterGrayImage, longSide: Int) -> MeterGrayImage {
        let scale = Double(longSide) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }
        return resizedBilinear(
            image,
            width: Int((Double(image.width) * scale).rounded(.toNearestOrEven)),
            height: Int((Double(image.height) * scale).rounded(.toNearestOrEven))
        )
    }

    /// PIL's `Image.resize(size, BILINEAR)` on a float image: a triangle filter widened by the
    /// shrink factor (so it antialiases), weights normalized per output pixel, the horizontal pass
    /// first, each pass summing in Double and storing Float.
    public static func resizedBilinear(_ image: MeterGrayImage, width: Int, height: Int) -> MeterGrayImage {
        precondition(width > 0 && height > 0, "resizedBilinear: \(width)x\(height)")
        var current = image
        if width != current.width {
            let taps = bilinearTaps(inSize: current.width, outSize: width)
            let source = current
            var out = [Float](repeating: 0, count: width * source.height)
            source.pixels.withUnsafeBufferPointer { g in
                for y in 0..<source.height {
                    let row = y * source.width
                    for (x, tap) in taps.enumerated() {
                        var sum = 0.0
                        for (k, weight) in tap.weights.enumerated() { sum += Double(g[row + tap.start + k]) * weight }
                        out[y * width + x] = Float(sum)
                    }
                }
            }
            current = MeterGrayImage(width: width, height: source.height, pixels: out)
        }
        if height != current.height {
            let taps = bilinearTaps(inSize: current.height, outSize: height)
            let source = current
            var out = [Float](repeating: 0, count: source.width * height)
            source.pixels.withUnsafeBufferPointer { g in
                for (y, tap) in taps.enumerated() {
                    for x in 0..<source.width {
                        var sum = 0.0
                        for (k, weight) in tap.weights.enumerated() { sum += Double(g[(tap.start + k) * source.width + x]) * weight }
                        out[y * source.width + x] = Float(sum)
                    }
                }
            }
            current = MeterGrayImage(width: source.width, height: height, pixels: out)
        }
        return current
    }

    /// Each output pixel's first input pixel and normalized weights: Pillow's `precompute_coeffs`
    /// (libImaging/Resample.c) for the bilinear filter, whose support is 1.
    static func bilinearTaps(inSize: Int, outSize: Int) -> [(start: Int, weights: [Double])] {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = filterScale
        let inverse = 1 / filterScale
        return (0..<outSize).map { out in
            let center = (Double(out) + 0.5) * scale
            // C's (int) cast truncates toward zero; the clamp to 0 makes that the same as floor.
            let start = max(Int(center - support + 0.5), 0)
            let end = min(Int(center + support + 0.5), inSize)
            let raw = (start..<end).map { max(0, 1 - abs((Double($0) - center + 0.5) * inverse)) }
            let total = raw.reduce(0, +)
            return (start, total == 0 ? raw : raw.map { $0 / total })
        }
    }
}
