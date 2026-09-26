/// Maps between pixels of a landscape sensor image and points of a portrait view that shows it
/// rotated 90° clockwise, scaled to fill the view, centered and cropped.
///
/// This is how an iPhone held upright shows the back camera's `capturedImage`: the image's left
/// edge (u = 0) is at the top of the screen and its top edge (v = 0) at the right. The frozen-frame
/// view draws the image exactly this way, so a tap there maps back to the saved image's pixel.
public struct PortraitFillMapping: Sendable, Equatable {
    public let imageWidth: Double
    public let imageHeight: Double
    public let viewWidth: Double
    public let viewHeight: Double

    public init(imageWidth: Double, imageHeight: Double, viewWidth: Double, viewHeight: Double) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
    }

    /// View points per image pixel. The rotated image is imageHeight wide and imageWidth tall.
    public var scale: Double {
        max(viewWidth / imageHeight, viewHeight / imageWidth)
    }

    /// Where the rotated image's top-left corner sits in the view; negative on a cropped side.
    var offset: (x: Double, y: Double) {
        ((viewWidth - imageHeight * scale) / 2, (viewHeight - imageWidth * scale) / 2)
    }

    public func imagePixel(forViewPoint x: Double, _ y: Double) -> (u: Double, v: Double) {
        let rotatedX = (x - offset.x) / scale
        let rotatedY = (y - offset.y) / scale
        return (rotatedY, imageHeight - rotatedX)
    }

    public func viewPoint(forImagePixel u: Double, _ v: Double) -> (x: Double, y: Double) {
        (offset.x + (imageHeight - v) * scale, offset.y + u * scale)
    }
}
