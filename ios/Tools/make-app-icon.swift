// Renders the House Scan app icon: a 1024x1024 opaque PNG.
//
// Run from the repo root:
//   swift ios/Tools/make-app-icon.swift ios/HouseScan/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// The icon is generated from code so it can be reviewed in a diff and regenerated after a change.
//
// Layout uses a top-left origin (y grows downward) on a 1024-point canvas. iOS masks the corners,
// so the art is full-bleed with every important shape inside the central ~80%.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-app-icon.swift <output.png>\n".utf8))
    exit(64)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// noneSkipLast: RGB with an unused fourth byte, so the PNG has no alpha channel.
// App Store Connect rejects icons that carry alpha.
guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: srgb,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    fatalError("could not create a \(size)x\(size) RGB bitmap context")
}

ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// Palette
let nightTop: UInt32 = 0x0B1B3A
let nightBottom: UInt32 = 0x13305F
let wallColor: UInt32 = 0xF3EFE6
let batteryBlue: UInt32 = 0x1F66F2
let meterGrey: UInt32 = 0x8A93A3

// Geometry
let eaveY: CGFloat = 500       // where the gable meets the vertical walls
let ridgeY: CGFloat = 372      // top of the gable
let groundY: CGFloat = 860     // foot of the wall
let wallLeft: CGFloat = 196
let wallRight: CGFloat = 828
let battery = CGRect(x: 520, y: 562, width: 200, height: 272)
let meterCenter = CGPoint(x: 348, y: 666)
let meterRadius: CGFloat = 66

// 1. Night sky
let sky = CGGradient(colorsSpace: srgb, colors: [rgb(nightTop), rgb(nightBottom)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])

// The house art spans roughly y 322...891; shift it up so it sits on the canvas's optical centre.
ctx.translateBy(x: 0, y: -84)

// 2. Wall: rectangle plus a low gable, seen straight on
let wall = CGMutablePath()
wall.move(to: CGPoint(x: wallLeft, y: groundY))
wall.addLine(to: CGPoint(x: wallLeft, y: eaveY))
wall.addLine(to: CGPoint(x: 512, y: ridgeY))
wall.addLine(to: CGPoint(x: wallRight, y: eaveY))
wall.addLine(to: CGPoint(x: wallRight, y: groundY))
wall.closeSubpath()
ctx.addPath(wall)
ctx.setFillColor(rgb(wallColor))
ctx.fillPath()

// Faint top-to-bottom shade so the wall reads as a lit surface, not a flat cutout.
ctx.saveGState()
ctx.addPath(wall)
ctx.clip()
let wallShade = CGGradient(
    colorsSpace: srgb,
    colors: [rgb(0xFFFFFF, 0), rgb(0x0B1B3A, 0.04)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(wallShade, start: CGPoint(x: 0, y: ridgeY), end: CGPoint(x: 0, y: groundY), options: [])
ctx.restoreGState()

// 3. Roof edge: a bold chevron floating just above the gable, overhanging the walls
let roofGap: CGFloat = 34
let overhang: CGFloat = 52
let slope = (eaveY - ridgeY) / (512 - wallLeft)
let roof = CGMutablePath()
roof.move(to: CGPoint(x: wallLeft - overhang, y: eaveY - roofGap + overhang * slope))
roof.addLine(to: CGPoint(x: 512, y: ridgeY - roofGap))
roof.addLine(to: CGPoint(x: wallRight + overhang, y: eaveY - roofGap + overhang * slope))
ctx.addPath(roof)
ctx.setStrokeColor(rgb(wallColor))
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// 4. Glow behind the battery, clipped to the wall so it reads as light falling on it
ctx.saveGState()
ctx.addPath(wall)
ctx.clip()
let glow = CGGradient(
    colorsSpace: srgb,
    colors: [rgb(0x4A86FF, 0.26), rgb(0x4A86FF, 0.08), rgb(0x4A86FF, 0)] as CFArray,
    locations: [0, 0.55, 1]
)!
let batteryCenter = CGPoint(x: battery.midX, y: battery.midY)
ctx.drawRadialGradient(glow, startCenter: batteryCenter, startRadius: 0, endCenter: batteryCenter, endRadius: 230, options: [])
ctx.restoreGState()

// 5. Cable from the meter into the battery's side
let cable = CGMutablePath()
cable.move(to: CGPoint(x: meterCenter.x + meterRadius, y: meterCenter.y))
cable.addLine(to: CGPoint(x: battery.minX, y: meterCenter.y))
ctx.addPath(cable)
ctx.setStrokeColor(rgb(meterGrey))
ctx.setLineWidth(14)
ctx.setLineCap(.butt)
ctx.strokePath()

// 6. Electric meter: grey ring with a pale face and a dark index mark
ctx.setFillColor(rgb(0xDDE1E7))
ctx.fillEllipse(in: CGRect(x: meterCenter.x - meterRadius, y: meterCenter.y - meterRadius, width: meterRadius * 2, height: meterRadius * 2))
let ringWidth: CGFloat = 20
let ringInset = ringWidth / 2
ctx.setStrokeColor(rgb(meterGrey))
ctx.setLineWidth(ringWidth)
ctx.strokeEllipse(in: CGRect(
    x: meterCenter.x - meterRadius + ringInset,
    y: meterCenter.y - meterRadius + ringInset,
    width: (meterRadius - ringInset) * 2,
    height: (meterRadius - ringInset) * 2
))
ctx.setStrokeColor(rgb(0x4B5566))
ctx.setLineWidth(9)
ctx.setLineCap(.round)
ctx.move(to: meterCenter)
ctx.addLine(to: CGPoint(x: meterCenter.x + 18, y: meterCenter.y - 18))
ctx.strokePath()

// 7. Contact shadow grounding the battery on the wall
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x0B1B3A, 0.18))
let bodyPath = CGPath(roundedRect: battery, cornerWidth: 34, cornerHeight: 34, transform: nil)
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(batteryBlue))
ctx.fillPath()
ctx.restoreGState()

// 8. Battery body: subtle vertical gradient plus a thin lighter edge
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let body = CGGradient(colorsSpace: srgb, colors: [rgb(0x2E74FF), rgb(0x1A56D6)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: battery.minY), end: CGPoint(x: 0, y: battery.maxY), options: [])
ctx.restoreGState()

let edgeWidth: CGFloat = 7
let edgeRect = battery.insetBy(dx: edgeWidth / 2, dy: edgeWidth / 2)
ctx.addPath(CGPath(roundedRect: edgeRect, cornerWidth: 34 - edgeWidth / 2, cornerHeight: 34 - edgeWidth / 2, transform: nil))
ctx.setStrokeColor(rgb(0x8DB4FF))
ctx.setLineWidth(edgeWidth)
ctx.strokePath()

// 9. Lightning bolt, centred on the battery
let boltPoints: [CGPoint] = [
    CGPoint(x: 22, y: -96),
    CGPoint(x: -55, y: 13),
    CGPoint(x: -7, y: 13),
    CGPoint(x: -22, y: 96),
    CGPoint(x: 55, y: -15),
    CGPoint(x: 7, y: -15),
]
let bolt = CGMutablePath()
bolt.addLines(between: boltPoints.map { CGPoint(x: batteryCenter.x + $0.x, y: batteryCenter.y + $0.y) })
bolt.closeSubpath()
ctx.addPath(bolt)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(8)
ctx.setLineJoin(.round)
ctx.drawPath(using: .fillStroke)

// 10. Ground line, wider than the wall
ctx.setStrokeColor(rgb(wallColor, 0.55))
ctx.setLineWidth(10)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 132, y: groundY + 26))
ctx.addLine(to: CGPoint(x: 892, y: groundY + 26))
ctx.strokePath()

// Write
guard let image = ctx.makeImage() else { fatalError("could not snapshot the bitmap context") }
try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("could not open \(outputURL.path) for writing")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write PNG to \(outputURL.path)") }
print("wrote \(outputURL.path)")
