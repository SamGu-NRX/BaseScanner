import CoreGraphics
import CoreText
import Foundation
import HouseScanKit
import ImageIO
import UniformTypeIdentifiers

/// The practice meter's picture, drawn in code: a gray socket-meter box with a glass dome, the
/// made-up maker and the fake number (`PracticeMeter.printedLines`). The camera view draws it on
/// the wall at the tap (`PracticeMeterOverlay`), and a practice close-up stores a photo of it on a
/// sided wall (`closeUpJPEG`), which the meter-number reader then reads.
///
/// Only Core Graphics, Core Text and ImageIO, with fonts both iOS and macOS ship, so the same
/// drawing renders on either.
enum SampleMeterArt {
    /// Width over height of the drawn box, as `PracticeMeter.plateSize`.
    static let aspect = CGFloat(PracticeMeter.plateSize.x / PracticeMeter.plateSize.y)

    /// The box alone on a clear background, upright, for the camera view. 600 px wide: sharp at
    /// the size the close-up holds it on screen, about half the screen's width.
    static let face: CGImage? = {
        let width = 600
        let height = Int((CGFloat(width) / aspect).rounded())
        guard let context = uprightContext(width: width, height: height, opaque: false) else { return nil }
        drawMeter(in: context, rect: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }()

    /// A close-up photo of the sample on a sided wall, as the camera stores one: the landscape
    /// sensor image of `width` by `height` pixels, unrotated, whose upright view is it turned 90°
    /// clockwise (`ImageWork.uprightThumbnail`, and the reader's EXIF `.right`). The practice
    /// close-up passes the live frame's size, so the stored photo's pixels still match the
    /// frame's intrinsics. Nil when a context can't be made.
    static func closeUpJPEG(width: Int, height: Int) -> Data? {
        // Upright, the photo is portrait: the sensor's height across, its width down.
        let uprightWidth = height
        let uprightHeight = width
        guard width > 0, height > 0, let upright = uprightContext(width: uprightWidth, height: uprightHeight, opaque: true) else { return nil }
        let size = CGSize(width: uprightWidth, height: uprightHeight)
        drawWall(in: upright, size: size)
        // The box fills 78% of the photo's height, as a close-up held at the gate's distance does.
        let boxHeight = size.height * 0.78
        let box = CGRect(x: (size.width - boxHeight * aspect) / 2, y: size.height * 0.47 - boxHeight / 2, width: boxHeight * aspect, height: boxHeight)
        drawConduit(in: upright, below: box, size: size)
        upright.saveGState()
        upright.setShadow(offset: CGSize(width: 0, height: box.height * 0.02), blur: box.height * 0.05, color: CGColor(gray: 0, alpha: 0.35))
        upright.addPath(boxPath(box))
        upright.setFillColor(gray: 0.6, alpha: 1)
        upright.fillPath()
        upright.restoreGState()
        drawMeter(in: upright, rect: box)
        guard let image = upright.makeImage(),
              let sensor = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        // Turned 90° counterclockwise: the inverse of `ImageWork.rotatedClockwise`, so turning the
        // stored image clockwise gives the upright photo back.
        sensor.translateBy(x: CGFloat(width), y: 0)
        sensor.rotate(by: .pi / 2)
        sensor.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let stored = sensor.makeImage() else { return nil }
        return jpeg(stored)
    }

    // MARK: Drawing

    /// An sRGB context whose user space runs y down from the top left, as the layout below is
    /// written, with Core Text set to draw upright glyphs in it.
    private static func uprightContext(width: Int, height: Int, opaque: Bool) -> CGContext? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        return context
    }

    private static func boxPath(_ box: CGRect) -> CGPath {
        CGPath(roundedRect: box, cornerWidth: box.width * 0.08, cornerHeight: box.width * 0.08, transform: nil)
    }

    /// Beige lap siding: a board every 4.5% of the height, each with a shadow line at its lower
    /// edge.
    private static func drawWall(in context: CGContext, size: CGSize) {
        context.setFillColor(red: 0.86, green: 0.83, blue: 0.77, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let board = size.height * 0.045
        var y = board
        while y < size.height {
            context.setFillColor(red: 0.74, green: 0.71, blue: 0.65, alpha: 1)
            context.fill(CGRect(x: 0, y: y - board * 0.08, width: size.width, height: board * 0.08))
            context.setFillColor(red: 0.91, green: 0.89, blue: 0.84, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: size.width, height: board * 0.06))
            y += board
        }
    }

    /// The conduit that feeds the meter, from under the box to the bottom of the photo.
    private static func drawConduit(in context: CGContext, below box: CGRect, size: CGSize) {
        let pipe = CGRect(x: box.midX - box.width * 0.07, y: box.maxY - box.height * 0.05, width: box.width * 0.14, height: size.height - box.maxY + box.height * 0.05)
        context.setFillColor(gray: 0.55, alpha: 1)
        context.fill(pipe)
        context.setFillColor(gray: 0.68, alpha: 1)
        context.fill(CGRect(x: pipe.minX + pipe.width * 0.2, y: pipe.minY, width: pipe.width * 0.18, height: pipe.height))
    }

    /// The meter box filling `rect` (2:3), in an upright context.
    static func drawMeter(in context: CGContext, rect box: CGRect) {
        let w = box.width
        let h = box.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * w, y: box.minY + y * h) }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // Box: brushed gray, lighter at the top, with a dark edge and a pale inner bevel.
        context.saveGState()
        context.addPath(boxPath(box))
        context.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.80, alpha: 1), CGColor(gray: 0.62, alpha: 1)] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: point(0.5, 0), end: point(0.5, 1), options: [])
        }
        context.restoreGState()
        context.addPath(boxPath(box.insetBy(dx: w * 0.03, dy: w * 0.03)))
        context.setStrokeColor(gray: 1, alpha: 0.35)
        context.setLineWidth(w * 0.008)
        context.strokePath()
        context.addPath(boxPath(box.insetBy(dx: w * 0.006, dy: w * 0.006)))
        context.setStrokeColor(gray: 0.38, alpha: 1)
        context.setLineWidth(w * 0.012)
        context.strokePath()
        for (x, y) in [(0.09, 0.06), (0.91, 0.06), (0.09, 0.94), (0.91, 0.94)] {
            let center = point(x, y)
            let r = w * 0.025
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            context.setStrokeColor(gray: 0.3, alpha: 1)
            context.setLineWidth(r * 0.35)
            context.strokeLineSegments(between: [CGPoint(x: center.x - r * 0.6, y: center.y), CGPoint(x: center.x + r * 0.6, y: center.y)])
        }

        // Glass dome on a metal collar.
        let dome = point(0.5, 0.36)
        let collar = w * 0.44
        let glass = w * 0.40
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fillEllipse(in: CGRect(x: dome.x - collar, y: dome.y - collar, width: 2 * collar, height: 2 * collar))
        context.saveGState()
        context.addEllipse(in: CGRect(x: dome.x - glass, y: dome.y - glass, width: 2 * glass, height: 2 * glass))
        context.clip()
        if let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.99, alpha: 1), CGColor(gray: 0.86, alpha: 1)] as CFArray, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: dome.x - glass * 0.3, y: dome.y - glass * 0.35), startRadius: 0, endCenter: dome, endRadius: glass, options: [])
        }
        context.restoreGState()

        // The face: maker, practice warning, display and ratings.
        let lines = PracticeMeter.printedLines
        drawText(lines[0], font: "HelveticaNeue-Bold", size: w * 0.07, color: CGColor(gray: 0.12, alpha: 1), centeredAt: point(0.5, 0.228), in: context)
        drawText(lines[1], font: "HelveticaNeue-Bold", size: w * 0.045, color: CGColor(srgbRed: 0.78, green: 0.30, blue: 0.05, alpha: 1), centeredAt: point(0.5, 0.27), in: context)
        let display = CGRect(x: box.minX + w * 0.25, y: box.minY + h * 0.3, width: w * 0.5, height: h * 0.07)
        context.setFillColor(red: 0.16, green: 0.20, blue: 0.18, alpha: 1)
        context.fill(display)
        drawText(lines[2], font: "Menlo-Bold", size: w * 0.055, color: CGColor(srgbRed: 0.62, green: 0.93, blue: 0.70, alpha: 1), centeredAt: CGPoint(x: display.midX, y: display.midY), in: context)
        drawText(lines[3], font: "HelveticaNeue", size: w * 0.045, color: CGColor(gray: 0.25, alpha: 1), centeredAt: point(0.5, 0.435), in: context)

        // The number on its own white label under the dome, as utilities stick it on.
        let label = CGRect(x: box.minX + w * 0.05, y: box.minY + h * 0.74, width: w * 0.9, height: h * 0.13)
        context.addPath(CGPath(roundedRect: label, cornerWidth: w * 0.02, cornerHeight: w * 0.02, transform: nil))
        context.setFillColor(gray: 0.98, alpha: 1)
        context.fillPath()
        drawText(lines[4], font: "Menlo-Bold", size: w * 0.115, color: CGColor(gray: 0.08, alpha: 1), centeredAt: CGPoint(x: label.midX, y: label.midY), in: context)
    }

    /// One line centered on `center`, its baseline placed so the line's ink box is centered.
    private static func drawText(_ text: String, font name: String, size: CGFloat, color: CGColor, centeredAt center: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        context.textPosition = CGPoint(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        CTLineDraw(line, context)
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
