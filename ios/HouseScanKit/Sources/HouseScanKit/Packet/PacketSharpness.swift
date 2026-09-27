import Foundation

/// The packet's photo sharpness, method "laplacian_variance_luma_640": a port of `sharpness` in
/// packet/write.py (t3/packet d82a903), so the phone's scores equal the reference's on the same
/// luma. The variance of the 4-neighbour Laplacian of the 8-bit luma after the long side is scaled
/// to 640 px with Pillow's BILINEAR resize; smaller images are used as they are.
///
/// `MeterPhotoChecks` has a Pillow resize too, but for 32-bit float images: write.py resizes the
/// 8-bit "L" image, and Pillow's 8-bit path uses fixed-point weights and rounds every pass to a
/// byte, so its values differ. This is that 8-bit path (libImaging/Resample.c,
/// `ImagingResampleHorizontal_8bpc` and `normalize_coeffs_8bpc`).
///
/// The one step not reproduced is JPEG decoding: write.py's luma comes from Pillow's libjpeg
/// decode, the phone's from ImageIO, and the two can differ by a grey level here and there. The
/// method is exact on the same luma. On the same JPEG the scores differ by decoder noise: 0.03%
/// on the tests' synthetic 96 × 72 JPEG decoded by macOS ImageIO; no phone photo has been
/// compared.
public enum PacketSharpness {
    public static let method = "laplacian_variance_luma_640"
    public static let longSide = 640

    /// The score of an 8-bit luma image, row-major with no padding. 0 for an image under 3 px on a
    /// side (no interior pixel; the reference returns NaN, which JSON can't hold).
    public static func laplacianVarianceLuma640(luma: [UInt8], width: Int, height: Int) -> Double {
        precondition(width > 0 && height > 0 && luma.count == width * height, "sharpness: \(luma.count) values for \(width)x\(height)")
        let scale = Double(longSide) / Double(max(width, height))
        guard scale < 1 else { return laplacianVariance(luma, width: width, height: height) }
        // Python's round(): half to even.
        let w = Int((Double(width) * scale).rounded(.toNearestOrEven))
        let h = Int((Double(height) * scale).rounded(.toNearestOrEven))
        let small = resizedBilinear8(luma, width: width, height: height, toWidth: w, toHeight: h)
        return laplacianVariance(small, width: w, height: h)
    }

    /// Pillow's "L" conversion of 8-bit RGBX pixels (4 bytes each, the fourth ignored), the input
    /// write.py's `image.convert("L")` gives the score. `bytesPerRow` may exceed `4 * width`.
    public static func luma(rgbx base: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        precondition(bytesPerRow >= 4 * width && base.count >= bytesPerRow * (height - 1) + 4 * width, "luma: \(base.count) bytes for \(width)x\(height) at \(bytesPerRow) per row")
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let p = row + 4 * x
                out[y * width + x] = MeterPhotoChecks.luma(red: base[p], green: base[p + 1], blue: base[p + 2])
            }
        }
        return out
    }

    /// Population variance of [[0,1,0],[1,-4,1],[0,1,0]] over the interior pixels, summed in
    /// Double as numpy's float64 does.
    static func laplacianVariance(_ g: [UInt8], width w: Int, height h: Int) -> Double {
        guard w >= 3, h >= 3 else { return 0 }
        let count = Double((w - 2) * (h - 2))
        return g.withUnsafeBufferPointer { g in
            func laplacian(_ i: Int) -> Double {
                let neighbours: Int = Int(g[i - w]) + Int(g[i + w]) + Int(g[i - 1]) + Int(g[i + 1])
                return Double(neighbours - 4 * Int(g[i]))
            }
            var sum = 0.0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) { sum += laplacian(y * w + x) }
            }
            let mean = sum / count
            var squares = 0.0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let d = laplacian(y * w + x) - mean
                    squares += d * d
                }
            }
            return squares / count
        }
    }

    /// Pillow's fixed-point precision for 8-bit resampling: 32 - 8 - 2 bits.
    static let precisionBits = 22

    /// Pillow's `Image.resize(size, BILINEAR)` on an "L" image: the horizontal pass first, each
    /// pass with integer weights round(w * 2^22), a half added, shifted down and clamped to a
    /// byte.
    static func resizedBilinear8(_ image: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8] {
        var current = image
        var currentWidth = width
        if toWidth != width {
            let taps = fixedPointTaps(inSize: width, outSize: toWidth)
            var out = [UInt8](repeating: 0, count: toWidth * height)
            current.withUnsafeBufferPointer { g in
                for y in 0..<height {
                    let row = y * width
                    for (x, tap) in taps.enumerated() {
                        var sum = 1 << (precisionBits - 1)
                        for (k, weight) in tap.weights.enumerated() { sum += Int(g[row + tap.start + k]) * weight }
                        out[y * toWidth + x] = clip8(sum)
                    }
                }
            }
            current = out
            currentWidth = toWidth
        }
        if toHeight != height {
            let taps = fixedPointTaps(inSize: height, outSize: toHeight)
            var out = [UInt8](repeating: 0, count: currentWidth * toHeight)
            current.withUnsafeBufferPointer { g in
                for (y, tap) in taps.enumerated() {
                    for x in 0..<currentWidth {
                        var sum = 1 << (precisionBits - 1)
                        for (k, weight) in tap.weights.enumerated() { sum += Int(g[(tap.start + k) * currentWidth + x]) * weight }
                        out[y * currentWidth + x] = clip8(sum)
                    }
                }
            }
            current = out
        }
        return current
    }

    /// `MeterPhotoChecks.bilinearTaps` (Pillow's `precompute_coeffs`) with each weight made an
    /// integer as `normalize_coeffs_8bpc` does: C's (int) of 0.5 + w * 2^22, weights being >= 0.
    static func fixedPointTaps(inSize: Int, outSize: Int) -> [(start: Int, weights: [Int])] {
        let one = Double(1 << precisionBits)
        return MeterPhotoChecks.bilinearTaps(inSize: inSize, outSize: outSize).map { tap in
            (tap.start, tap.weights.map { Int(0.5 + $0 * one) })
        }
    }

    /// Pillow's `clip8`: the sum shifted down by the precision (an arithmetic shift, so floor),
    /// clamped to 0...255.
    static func clip8(_ sum: Int) -> UInt8 {
        UInt8(clamping: sum >> precisionBits)
    }
}
