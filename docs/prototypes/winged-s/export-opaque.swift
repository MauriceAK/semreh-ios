import Foundation
import CoreGraphics
import ImageIO

// Convert the SVG renderer's PNG to an explicit RGB PNG (no alpha channel).
guard CommandLine.arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: 1024, height: 1024,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fatalError("Expected input PNG and output PNG paths") }
let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
context.setFillColor(CGColor(red: 247/255, green: 243/255, blue: 234/255, alpha: 1))
context.fill(rect)
context.draw(image, in: rect)
guard let output = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL,
        "public.png" as CFString, 1, nil) else { fatalError("PNG encoding failed") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("PNG write failed") }
