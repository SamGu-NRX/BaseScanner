import CoreGraphics
import Foundation
import ImageIO

/// A decoded 8-bit sRGB image, RGBA byte order, top row first.
public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "rgba must hold 4 bytes per pixel")
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public init(jpeg data: Data, path: String) throws(FixtureError) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw .undecodableImage(path: path) }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw .undecodableImage(path: path) }
        self.init(width: width, height: height, rgba: bytes)
    }
}
