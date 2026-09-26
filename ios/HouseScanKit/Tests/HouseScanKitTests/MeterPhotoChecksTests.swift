import Foundation
import HouseScanKit
import Testing

// Cases from the close-up eval's tests/test_retake.py (t3/meter-closeup at 944cbe1), including its
// pinned value for the resize, plus small cases worked out by hand.

/// Alternating 0/200 pixels: every interior Laplacian is +-800, far above any threshold.
private func checkerboard(width: Int, height: Int) -> MeterGrayImage {
    MeterGrayImage(width: width, height: height, pixels: (0..<(width * height)).map { Float(($0 % width + $0 / width) % 2 * 200) })
}

/// test_retake.py's sine_rows: 128 + 100 sin(2 pi x / period) in every row.
private func sineRows(period: Int, width: Int, height: Int) -> MeterGrayImage {
    let row = (0..<width).map { Float(128 + 100 * sin(2 * Double.pi * Double($0) / Double(period))) }
    return MeterGrayImage(width: width, height: height, pixels: Array((0..<height).map { _ in row }.joined()))
}

private func candidates(lineHeight: Double) -> [MeterTextCandidate] {
    MeterNumberRanking.candidates(
        lines: [MeterTextLine(text: "12345678", box: MeterBox(x: 0.25, y: 0.3, width: 0.5, height: lineHeight))],
        barcodePayloads: []
    )
}

private func relativeError(_ value: Double, _ reference: Double) -> Double {
    abs(value - reference) / abs(reference)
}

@Suite struct MeterPhotoChecksTests {
    @Test func lumaRoundsAsPIL() {
        #expect(MeterPhotoChecks.luma(red: 255, green: 255, blue: 255) == 255)
        #expect(MeterPhotoChecks.luma(red: 255, green: 0, blue: 0) == 76)
        #expect(MeterPhotoChecks.luma(red: 0, green: 255, blue: 0) == 150)
        #expect(MeterPhotoChecks.luma(red: 0, green: 0, blue: 255) == 29)
    }

    @Test func lumaFromPaddedRGBXRows() {
        let bytes: [UInt8] = [255, 0, 0, 9, 0, 255, 0, 9, 7, 7, 7, 7]
        let image = bytes.withUnsafeBytes { MeterGrayImage(rgbx: $0, width: 2, height: 1, bytesPerRow: 12) }
        #expect(image.pixels == [76, 150])
    }

    @Test func laplacianVarianceOfACheckerboard() {
        // 4 x 4: the 2 x 2 interior Laplacians are +800, -800, -800, +800; mean 0.
        #expect(MeterPhotoChecks.laplacianVariance(checkerboard(width: 4, height: 4)) == 640_000)
        #expect(MeterPhotoChecks.laplacianVariance(checkerboard(width: 2, height: 4)) == 0)
    }

    @Test func bilinearShrinkMatchesPillowsWeights() {
        // Halving 4 px: support 2, centers 1 and 3. Triangle weights 0.75, 0.75, 0.25 over pixels
        // 0-2 and 0.25, 0.75, 0.75 over pixels 1-3, each divided by 1.75: 3/7, 3/7, 1/7 and
        // 1/7, 3/7, 3/7. On 0, 7, 14, 21 that gives 3 + 2 = 5 and 1 + 6 + 9 = 16.
        let image = MeterGrayImage(width: 4, height: 1, pixels: [0, 7, 14, 21])
        let out = MeterPhotoChecks.resizedBilinear(image, width: 2, height: 1)
        #expect(out.width == 2 && out.height == 1)
        #expect(abs(out.pixels[0] - 5) < 1e-5 && abs(out.pixels[1] - 16) < 1e-5)
    }

    @Test func sharpnessLeavesSmallPhotosAtTheirSize() {
        // Below 1024 px nothing is resized. For a sine of amplitude A and period P the Laplacian
        // variance is (2(cos(2 pi / P) - 1))^2 A^2 / 2, about 115.9 at P = 16.
        let sharpness = MeterPhotoChecks.wholePhotoSharpness(sineRows(period: 16, width: 1024, height: 768))
        #expect(relativeError(sharpness, 115.9) < 0.01)
    }

    @Test func sharpnessAfterHalvingMatchesTheEvalsPinnedValue() {
        // test_retake.py pins 112.68 (PIL bilinear on a float image, rel 1e-3) for 32 px stripes
        // halved to 16 px ones; the antialiasing softens them a little under 115.9.
        let sharpness = MeterPhotoChecks.wholePhotoSharpness(sineRows(period: 32, width: 2048, height: 1536))
        #expect(relativeError(sharpness, 112.68) < 1e-3)
    }

    @Test func downscaleRoundsHalfToEvenAndNeverEnlarges() {
        // 2050 x 5 at scale 1024/2050: 5 x 0.4995... = 2.497 rounds to 2.
        let wide = MeterPhotoChecks.downscaled(MeterGrayImage(width: 2050, height: 5, pixels: .init(repeating: 1, count: 10250)), longSide: 1024)
        #expect(wide.width == 1024 && wide.height == 2)
        let small = checkerboard(width: 20, height: 10)
        #expect(MeterPhotoChecks.downscaled(small, longSide: 1024) == small)
    }

    @Test func sharpnessDoesNotDependOnOrientation() {
        // A quarter turn swaps the axes; the value must match the unturned photo's.
        var state: UInt64 = 42
        let width = 1500
        let height = 900
        let pixels = (0..<(width * height)).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(state >> 56)
        }
        let image = MeterGrayImage(width: width, height: height, pixels: pixels)
        var turned = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { turned[x * height + (height - 1 - y)] = pixels[y * width + x] }
        }
        let a = MeterPhotoChecks.wholePhotoSharpness(image)
        let b = MeterPhotoChecks.wholePhotoSharpness(MeterGrayImage(width: height, height: width, pixels: turned))
        #expect(relativeError(b, a) < 1e-5)
    }

    @Test func sharpPhotoPassesAndFlatPhotoIsOutOfFocus() {
        #expect(!MeterPhotoChecks.isOutOfFocus(sharpness: MeterPhotoChecks.wholePhotoSharpness(checkerboard(width: 200, height: 100))))
        let flat = MeterGrayImage(width: 200, height: 100, pixels: .init(repeating: 128, count: 20000))
        #expect(MeterPhotoChecks.isOutOfFocus(sharpness: MeterPhotoChecks.wholePhotoSharpness(flat)))
        #expect(MeterPhotoChecks.isOutOfFocus(sharpness: 6.63))
        #expect(!MeterPhotoChecks.isOutOfFocus(sharpness: 6.64))
    }

    @Test func noCandidateMeansNoChoices() {
        #expect(MeterPhotoChecks.choices(from: [], photoHeight: 100) == nil)
    }

    @Test func topCandidateBelowTheThresholdIsTooSmall() throws {
        // 100 px tall photo: 33 px is under the 33.9 px threshold; 35 px is over it; 40 px passes.
        let small = try #require(MeterPhotoChecks.choices(from: candidates(lineHeight: 0.33), photoHeight: 100))
        #expect(small.numberTooSmall && small.candidates.map(\.core) == ["12345678"])
        #expect(MeterPhotoChecks.choices(from: candidates(lineHeight: 0.35), photoHeight: 100)?.numberTooSmall == false)
        #expect(MeterPhotoChecks.choices(from: candidates(lineHeight: 0.4), photoHeight: 100)?.numberTooSmall == false)
    }
}
