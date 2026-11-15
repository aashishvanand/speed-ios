// Centres a captured Mac window on a 2880 x 1800 canvas (an App Store Mac
// screenshot size) with the app's orange gradient behind it.
//
//   swift scripts/frame-mac-screenshot.swift <window.png> <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let window = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("usage: frame-mac-screenshot.swift <window.png> <out.png>")
}

let width = 2880, height = 1800
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let colors = [CGColor(srgbRed: 1, green: 0.604, blue: 0.235, alpha: 1), CGColor(srgbRed: 0.898, green: 0.322, blue: 0.106, alpha: 1)]
let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])

// Fit the window (its shadow included) inside 92% of the canvas height.
let scale = min(1, CGFloat(height) * 0.92 / CGFloat(window.height), CGFloat(width) * 0.92 / CGFloat(window.width))
let w = CGFloat(window.width) * scale, h = CGFloat(window.height) * scale
ctx.interpolationQuality = .high
ctx.draw(window, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
