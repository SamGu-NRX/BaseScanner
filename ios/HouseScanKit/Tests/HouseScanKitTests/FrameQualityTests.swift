import HouseScanKit
import Testing

@Suite struct FrameQualityTests {
    static func image(_ width: Int, _ height: Int, _ value: (Int, Int) -> UInt8) -> LumaImage {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { pixels.append(value(x, y)) }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    static let checkerboard = image(8, 8) { x, y in (x + y) % 2 == 0 ? 255 : 0 }

    @Test func constantImage() {
        let quality = FrameQuality(Self.image(8, 8) { _, _ in 7 })
        #expect(quality.sharpness == 0)
        #expect(quality.meanLuma == 7)
        #expect(quality.clippedFraction == 0)
    }

    @Test func whiteImageIsFullyClipped() {
        let quality = FrameQuality(Self.image(5, 4) { _, _ in 255 })
        #expect(quality.sharpness == 0)
        #expect(quality.meanLuma == 255)
        #expect(quality.clippedFraction == 1)
    }

    @Test func checkerboardHasTheWorkedOutLaplacianVariance() {
        // Every interior pixel of a 0/255 checkerboard has four opposite neighbours: the Laplacian
        // is -4 * 255 = -1020 on white and +1020 on black, 18 of each over the 6 x 6 interior.
        // Mean 0, variance 1020^2 = 1_040_400. Half the pixels are 255: mean luma 127.5, clipped 0.5.
        let quality = FrameQuality(Self.checkerboard)
        #expect(quality.sharpness == 1_040_400)
        #expect(quality.meanLuma == 127.5)
        #expect(quality.clippedFraction == 0.5)
    }

    @Test func blurLowersSharpness() {
        // 3 x 3 box blur with clamped edges.
        let source = Self.checkerboard
        let blurred = Self.image(8, 8) { x, y in
            var sum = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    let sx = min(7, max(0, x + dx))
                    let sy = min(7, max(0, y + dy))
                    sum += Int(source.pixels[sy * 8 + sx])
                }
            }
            return UInt8(sum / 9)
        }
        #expect(FrameQuality(source).sharpness > FrameQuality(blurred).sharpness)
    }

    @Test func tinyImageHasNoSharpness() {
        let quality = FrameQuality(Self.image(2, 2) { x, _ in x == 0 ? 0 : 200 })
        #expect(quality.sharpness == 0)
        #expect(quality.meanLuma == 100)
    }

    @Test func samplingSkipsRowPadding() {
        // A 6 x 4 plane stored 8 bytes per row: byte = row * 16 + column, padding columns 6 and 7 = 0xFF.
        // Step 2 keeps columns 0, 2, 4 of rows 0 and 2: 0, 2, 4 and 32, 34, 36.
        var bytes: [UInt8] = []
        for row in 0..<4 {
            for column in 0..<8 { bytes.append(column < 6 ? UInt8(row * 16 + column) : 0xFF) }
        }
        let sampled = bytes.withUnsafeBytes { LumaImage(sampling: $0, width: 6, height: 4, bytesPerRow: 8, step: 2) }
        #expect(sampled.width == 3)
        #expect(sampled.height == 2)
        #expect(sampled.pixels == [0, 2, 4, 32, 34, 36])
    }
}
