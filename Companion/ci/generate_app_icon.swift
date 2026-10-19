import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.dropFirst().first
    ?? "ios/HermesCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!
context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.035, 0.055, 0.09, 1])!)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

let spark = CGMutablePath()
spark.move(to: CGPoint(x: 512, y: 790))
spark.addCurve(to: CGPoint(x: 790, y: 512), control1: CGPoint(x: 545, y: 600), control2: CGPoint(x: 600, y: 545))
spark.addCurve(to: CGPoint(x: 512, y: 234), control1: CGPoint(x: 600, y: 479), control2: CGPoint(x: 545, y: 424))
spark.addCurve(to: CGPoint(x: 234, y: 512), control1: CGPoint(x: 479, y: 424), control2: CGPoint(x: 424, y: 479))
spark.addCurve(to: CGPoint(x: 512, y: 790), control1: CGPoint(x: 424, y: 545), control2: CGPoint(x: 479, y: 600))
spark.closeSubpath()
context.saveGState()
context.addPath(spark)
context.clip()
let colors = [
    CGColor(colorSpace: colorSpace, components: [0.53, 0.74, 1, 1])!,
    CGColor(colorSpace: colorSpace, components: [0.20, 0.43, 0.98, 1])!
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 780), end: CGPoint(x: 710, y: 240), options: [])
context.restoreGState()
context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.53, 0.74, 1, 1])!)
context.fillEllipse(in: CGRect(x: 740, y: 742, width: 44, height: 44))

let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write icon") }
