import Foundation

/// A small 8-bit grayscale image, row-major, one byte per pixel.
public struct LumaImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height, "LumaImage: \(pixels.count) bytes for \(width)x\(height)")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Samples every `step`-th pixel of every `step`-th row of a larger plane, for example the Y
    /// plane of a camera buffer. `bytesPerRow` may exceed `width` (row padding).
    public init(sampling base: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, step: Int) {
        precondition(step > 0 && width >= step && height >= step, "LumaImage: step \(step) for \(width)x\(height)")
        let outWidth = width / step
        let outHeight = height / step
        var out = [UInt8](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            let row = y * step * bytesPerRow
            for x in 0..<outWidth {
                out[y * outWidth + x] = base[row + x * step]
            }
        }
        self.init(width: outWidth, height: outHeight, pixels: out)
    }
}

/// Exposure and sharpness of one frame, from a downsampled luma image.
public struct FrameQuality: Sendable, Equatable {
    /// Variance of the 4-neighbour Laplacian. Higher is sharper; only comparable between frames of
    /// the same size and scene, which is why auto-capture compares it with recent frames.
    public var sharpness: Double
    /// Mean luma, 0...255.
    public var meanLuma: Double
    /// Fraction of pixels at 250 or above: blown highlights and glare.
    public var clippedFraction: Double

    public init(sharpness: Double, meanLuma: Double, clippedFraction: Double) {
        self.sharpness = sharpness
        self.meanLuma = meanLuma
        self.clippedFraction = clippedFraction
    }

    public init(_ image: LumaImage) {
        let w = image.width
        let h = image.height
        let p = image.pixels
        var sum = 0.0
        var clipped = 0
        for value in p {
            sum += Double(value)
            if value >= 250 { clipped += 1 }
        }
        var lapSum = 0.0
        var lapSquares = 0.0
        var count = 0.0
        if w >= 3 && h >= 3 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let lap = Double(p[i - 1]) + Double(p[i + 1]) + Double(p[i - w]) + Double(p[i + w]) - 4 * Double(p[i])
                    lapSum += lap
                    lapSquares += lap * lap
                    count += 1
                }
            }
        }
        let mean = count > 0 ? lapSum / count : 0
        sharpness = count > 0 ? lapSquares / count - mean * mean : 0
        meanLuma = sum / Double(p.count)
        clippedFraction = Double(clipped) / Double(p.count)
    }
}
