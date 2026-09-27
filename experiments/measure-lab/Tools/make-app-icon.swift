// Draws MeasureLab's placeholder app icon: a black tape-measure blade with tick marks on the
// app's tape yellow. App Store Connect rejects an upload without an icon or with transparency,
// so the PNG is opaque.
//
// Run from experiments/measure-lab:
//   swift Tools/make-app-icon.swift MeasureLab/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-app-icon.swift <output.png>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    // No alpha channel: the App Store rejects icons with transparency.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("Couldn't create a bitmap context") }

let yellow = CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)
let ink = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)

context.setFillColor(yellow)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// The blade runs corner to corner at 45°, drawn in a rotated frame centered on the icon.
context.translateBy(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
context.rotate(by: .pi / 4)
let bladeLength: CGFloat = 1180
let bladeWidth: CGFloat = 300
let blade = CGRect(x: -bladeLength / 2, y: -bladeWidth / 2, width: bladeLength, height: bladeWidth)
context.setFillColor(ink)
context.fill(blade)

// Tick marks along the top edge: a tall one every fourth tick, like inches and quarter inches.
context.setFillColor(yellow)
let spacing: CGFloat = 44
let tickWidth: CGFloat = 12
var index = 0
var x = blade.minX + spacing / 2
while x < blade.maxX {
    let height: CGFloat = index % 4 == 0 ? 150 : 80
    context.fill(CGRect(x: x - tickWidth / 2, y: blade.maxY - height, width: tickWidth, height: height))
    index += 1
    x += spacing
}

guard
    let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Couldn't prepare the PNG") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(output.path)") }
