import Testing
@testable import MeasureGeometry

struct PortraitFillMappingTests {
    @Test func `uncropped view maps corners to rotated image corners`() throws {
        // A 2000 × 1000 image rotated is 1000 × 2000, exactly twice a 500 × 1000 view.
        let mapping = try #require(PortraitFillMapping(imageWidth: 2000, imageHeight: 1000, viewWidth: 500, viewHeight: 1000))
        #expect(mapping.scale == 0.5)
        // Top-left of the view is the image's bottom-left corner.
        #expect(mapping.imagePixel(forViewPoint: 0, 0) == (u: 0, v: 1000))
        // Bottom-right of the view is the image's top-right corner.
        #expect(mapping.imagePixel(forViewPoint: 500, 1000) == (u: 2000, v: 0))
        // (100, 300) is rotated (200, 600): u = 600, v = 1000 − 200.
        #expect(mapping.imagePixel(forViewPoint: 100, 300) == (u: 600, v: 800))
        #expect(mapping.viewPoint(forImagePixel: 600, 800) == (x: 100, y: 300))
    }

    @Test func `cropped view keeps the center and crops the sides`() throws {
        // 1920 × 1440 sensor image in a 390 × 844 pt view: height fills at 844 / 1920 pt per px,
        // so the rotated image is 633 pt wide and 121.5 pt is cropped from each side.
        let mapping = try #require(PortraitFillMapping(imageWidth: 1920, imageHeight: 1440, viewWidth: 390, viewHeight: 844))
        #expect(isClose(mapping.scale, 844.0 / 1920))
        #expect(isClose(mapping.offset.x, -121.5))
        #expect(isClose(mapping.offset.y, 0))
        let center = mapping.imagePixel(forViewPoint: 195, 422)
        #expect(isClose(center.u, 960))
        #expect(isClose(center.v, 720))
        // The view's left edge is 121.5 pt into the rotated image: v = 1440 − 121.5 / scale.
        let left = mapping.imagePixel(forViewPoint: 0, 422)
        #expect(isClose(left.v, 1440 - 121.5 * 1920 / 844))
    }

    @Test(arguments: [
        (0.0, 1440.0, 390.0, 844.0),
        (1920.0, 0.0, 390.0, 844.0),
        (1920.0, 1440.0, 0.0, 844.0),
        (1920.0, 1440.0, 390.0, 0.0),
        (-1.0, 1440.0, 390.0, 844.0),
        (1920.0, -1.0, 390.0, 844.0),
        (1920.0, 1440.0, -1.0, 844.0),
        (1920.0, 1440.0, 390.0, -1.0),
        (Double.nan, 1440.0, 390.0, 844.0),
        (1920.0, Double.infinity, 390.0, 844.0),
        (1920.0, 1440.0, -Double.infinity, 844.0),
        (1920.0, 1440.0, 390.0, Double.nan),
        (Double.leastNonzeroMagnitude, 1440.0, 390.0, 844.0),
    ])
    func `rejects dimensions that cannot produce a finite mapping`(imageWidth: Double, imageHeight: Double, viewWidth: Double, viewHeight: Double) {
        #expect(PortraitFillMapping(imageWidth: imageWidth, imageHeight: imageHeight, viewWidth: viewWidth, viewHeight: viewHeight) == nil)
    }

    @Test(arguments: [(0.0, 0.0), (1920.0, 1440.0), (123.4, 987.6)])
    func `view points and image pixels round-trip`(u: Double, v: Double) throws {
        let mapping = try #require(PortraitFillMapping(imageWidth: 1920, imageHeight: 1440, viewWidth: 402, viewHeight: 874))
        let point = mapping.viewPoint(forImagePixel: u, v)
        let back = mapping.imagePixel(forViewPoint: point.x, point.y)
        #expect(isClose(back.u, u))
        #expect(isClose(back.v, v))
    }
}
