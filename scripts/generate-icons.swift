#!/usr/bin/env swift
// Draws every app icon and Top Shelf image from code, so the artwork can be
// tweaked and regenerated instead of hand-exported.
//
//   swift scripts/generate-icons.swift
//
// Writes into the three asset catalogs under App/ and a 1024 px marketing
// copy into AppStore/. No dependencies beyond CoreGraphics and ImageIO.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let orangeTop = rgb(0xFF9A3C)
let orangeBottom = rgb(0xE5521B)
let darkTop = rgb(0x2C2C2E)
let darkBottom = rgb(0x0B0B0C)
let white = rgb(0xFFFFFF)

// MARK: - Bitmap helpers

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func makeContext(_ width: Int, _ height: Int, opaque: Bool) -> CGContext {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

func write(_ ctx: CGContext, to relativePath: String) {
    let url = root.appendingPathComponent(relativePath)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest), "Couldn't write \(relativePath)")
    print("  \(relativePath)")
}

func writeJSON(_ object: Any, to relativePath: String) {
    let url = root.appendingPathComponent(relativePath)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

let xcodeInfo: [String: Any] = ["author": "xcode", "version": 1]

func fillVerticalGradient(_ ctx: CGContext, _ rect: CGRect, top: CGColor, bottom: CGColor) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1])!
    // CoreGraphics' origin is bottom-left, so "top" is maxY.
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: - The gauge glyph

/// Which parts of the gauge to draw, so tvOS can split it across parallax layers.
struct GaugeParts: OptionSet {
    let rawValue: Int
    static let track = GaugeParts(rawValue: 1)
    static let needle = GaugeParts(rawValue: 2)
    static let all: GaugeParts = [.track, .needle]
}

/// A 240° speedometer: faint full track, a bright arc filled to ~72%, tick
/// marks, and a needle with a hub. `center` and `radius` are in the
/// context's coordinates; everything scales from `radius`.
func drawGauge(_ ctx: CGContext, center: CGPoint, radius r: CGFloat, color: CGColor, trackAlpha: CGFloat = 0.3, parts: GaugeParts = .all) {
    let start = CGFloat.pi * (7.0 / 6.0)     // 210°, lower left
    let end = CGFloat.pi * (-1.0 / 6.0)      // -30°, lower right
    let sweep = start - end                  // 240°, drawn clockwise
    let level: CGFloat = 0.72
    let needleAngle = start - sweep * level
    let lineWidth = r * 0.17

    ctx.saveGState()
    ctx.setLineCap(.round)

    if parts.contains(.track) {
        // Faint full track.
        ctx.setStrokeColor(color.copy(alpha: trackAlpha)!)
        ctx.setLineWidth(lineWidth)
        ctx.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()

        // Filled portion.
        ctx.setStrokeColor(color)
        ctx.addArc(center: center, radius: r, startAngle: start, endAngle: needleAngle, clockwise: true)
        ctx.strokePath()

        // Tick marks inside the arc.
        ctx.setLineWidth(r * 0.045)
        let ticks = 9
        for i in 0..<ticks {
            let t = CGFloat(i) / CGFloat(ticks - 1)
            let a = start - sweep * t
            let inner = r * 0.66, outer = r * 0.76
            ctx.setStrokeColor(color.copy(alpha: t <= level + 0.001 ? 0.95 : trackAlpha + 0.1)!)
            ctx.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
            ctx.strokePath()
        }
    }

    if parts.contains(.needle) {
        // Needle: a tapered wedge from the hub towards the arc.
        let tip = CGPoint(x: center.x + cos(needleAngle) * r * 0.86, y: center.y + sin(needleAngle) * r * 0.86)
        let perpendicular = needleAngle + .pi / 2
        let baseHalf = r * 0.085
        ctx.setFillColor(color)
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: center.x + cos(perpendicular) * baseHalf, y: center.y + sin(perpendicular) * baseHalf))
        ctx.addLine(to: CGPoint(x: center.x - cos(perpendicular) * baseHalf, y: center.y - sin(perpendicular) * baseHalf))
        ctx.closePath()
        ctx.fillPath()

        // Hub.
        ctx.fillEllipse(in: CGRect(x: center.x - r * 0.15, y: center.y - r * 0.15, width: r * 0.3, height: r * 0.3))
    }
    ctx.restoreGState()
}

/// The live-graph motif from the app's hero card, as a soft line along the bottom.
func drawGraphLine(_ ctx: CGContext, in rect: CGRect, color: CGColor, lineWidth: CGFloat) {
    let values: [CGFloat] = [0.10, 0.22, 0.46, 0.62, 0.58, 0.70, 0.66, 0.78, 0.74, 0.82, 0.77, 0.86, 0.80]
    let points = values.enumerated().map { i, v in
        CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1), y: rect.minY + rect.height * v)
    }
    let path = CGMutablePath()
    path.move(to: points[0])
    for i in 1..<points.count {
        let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
        path.addQuadCurve(to: mid, control: points[i - 1])
    }
    path.addLine(to: points[points.count - 1])

    // Area under the line.
    let area = path.mutableCopy()!
    area.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    area.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    area.closeSubpath()
    ctx.saveGState()
    ctx.addPath(area)
    ctx.setFillColor(color.copy(alpha: color.alpha * 0.35)!)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Square icon artwork

enum Style { case light, dark, tinted }

/// Full-bleed square artwork, as iOS wants it (the system applies the mask).
func drawSquareIcon(_ ctx: CGContext, size s: CGFloat, style: Style) {
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let glyph: CGColor
    switch style {
    case .light:
        fillVerticalGradient(ctx, rect, top: orangeTop, bottom: orangeBottom)
        glyph = white
    case .dark:
        fillVerticalGradient(ctx, rect, top: darkTop, bottom: darkBottom)
        glyph = rgb(0xFF8A2A)
    case .tinted:
        // Grayscale on black; the system tints it.
        ctx.setFillColor(rgb(0x000000))
        ctx.fill(rect)
        glyph = white
    }
    drawGraphLine(ctx, in: CGRect(x: 0, y: 0, width: s, height: s * 0.26), color: glyph.copy(alpha: 0.22)!, lineWidth: s * 0.012)
    drawGauge(ctx, center: CGPoint(x: s / 2, y: s * 0.47), radius: s * 0.3, color: glyph, trackAlpha: style == .light ? 0.32 : 0.25)
}

// MARK: - iOS

print("iOS")
let iosSet = "App/CFSpeed/Assets.xcassets/AppIcon.appiconset"
for (style, name) in [(Style.light, "AppIcon.png"), (.dark, "AppIcon-Dark.png"), (.tinted, "AppIcon-Tinted.png")] {
    let ctx = makeContext(1024, 1024, opaque: true)
    drawSquareIcon(ctx, size: 1024, style: style)
    write(ctx, to: "\(iosSet)/\(name)")
    if style == .light { write(ctx, to: "AppStore/icon-1024.png") }
}
writeJSON([
    "images": [
        ["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
        ["appearances": [["appearance": "luminosity", "value": "dark"]], "filename": "AppIcon-Dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
        ["appearances": [["appearance": "luminosity", "value": "tinted"]], "filename": "AppIcon-Tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
    ],
    "info": xcodeInfo,
], to: "\(iosSet)/Contents.json")
writeJSON(["info": xcodeInfo], to: "App/CFSpeed/Assets.xcassets/Contents.json")

// MARK: - macOS

/// macOS icons carry their own shape: an 824 pt rounded square centred on a
/// 1024 canvas with a soft drop shadow, per Apple's icon grid.
func drawMacIcon(_ ctx: CGContext, size s: CGFloat) {
    let scale = s / 1024
    let inset = 100 * scale
    let body = CGRect(x: inset, y: inset + 6 * scale, width: s - inset * 2, height: s - inset * 2)
    let shape = CGPath(roundedRect: body, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: rgb(0x000000, 0.3))
    ctx.addPath(shape)
    ctx.setFillColor(orangeBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    fillVerticalGradient(ctx, body, top: orangeTop, bottom: orangeBottom)
    drawGraphLine(ctx, in: CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.26), color: white.copy(alpha: 0.22)!, lineWidth: max(1, body.width * 0.012))
    drawGauge(ctx, center: CGPoint(x: body.midX, y: body.minY + body.height * 0.47), radius: body.width * 0.3, color: white, trackAlpha: 0.32)
    ctx.restoreGState()
}

print("macOS")
let macSet = "App/CFSpeed-macOS/Assets.xcassets/AppIcon.appiconset"
var macImages: [[String: Any]] = []
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = point * scale
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        let ctx = makeContext(px, px, opaque: false)
        drawMacIcon(ctx, size: CGFloat(px))
        write(ctx, to: "\(macSet)/\(name)")
        macImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(point)x\(point)"])
    }
}
writeJSON(["images": macImages, "info": xcodeInfo], to: "\(macSet)/Contents.json")
writeJSON(["info": xcodeInfo], to: "App/CFSpeed-macOS/Assets.xcassets/Contents.json")

// MARK: - tvOS

print("tvOS")
let tvAssets = "App/CFSpeed-tvOS/Assets.xcassets"
let brand = "\(tvAssets)/AppIcon.brandassets"

/// tvOS icons are 5:3 parallax stacks. Back: gradient. Middle: graph line and
/// gauge track. Front: needle, which moves the most when focused.
enum TVLayer: String, CaseIterable { case Front, Middle, Back }

func drawTVLayer(_ ctx: CGContext, width w: CGFloat, height h: CGFloat, layer: TVLayer) {
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    let center = CGPoint(x: w / 2, y: h * 0.46)
    let radius = h * 0.3
    switch layer {
    case .Back:
        fillVerticalGradient(ctx, rect, top: orangeTop, bottom: orangeBottom)
    case .Middle:
        drawGraphLine(ctx, in: CGRect(x: 0, y: 0, width: w, height: h * 0.28), color: white.copy(alpha: 0.24)!, lineWidth: h * 0.012)
        drawGauge(ctx, center: center, radius: radius, color: white, trackAlpha: 0.32, parts: .track)
    case .Front:
        drawGauge(ctx, center: center, radius: radius, color: white, parts: .needle)
    }
}

func makeImageStack(name: String, pointSize: (Int, Int), scales: [Int]) {
    let stack = "\(brand)/\(name).imagestack"
    writeJSON(["info": xcodeInfo, "layers": TVLayer.allCases.map { ["filename": "\($0.rawValue).imagestacklayer"] }], to: "\(stack)/Contents.json")
    for layer in TVLayer.allCases {
        let layerDir = "\(stack)/\(layer.rawValue).imagestacklayer"
        writeJSON(["info": xcodeInfo], to: "\(layerDir)/Contents.json")
        var images: [[String: Any]] = []
        for scale in scales {
            let w = pointSize.0 * scale, h = pointSize.1 * scale
            let file = "\(layer.rawValue.lowercased())\(scale == 2 ? "@2x" : "").png"
            let ctx = makeContext(w, h, opaque: layer == .Back)
            drawTVLayer(ctx, width: CGFloat(w), height: CGFloat(h), layer: layer)
            write(ctx, to: "\(layerDir)/Content.imageset/\(file)")
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        }
        writeJSON(["images": images, "info": xcodeInfo], to: "\(layerDir)/Content.imageset/Contents.json")
    }
}

makeImageStack(name: "App Icon", pointSize: (400, 240), scales: [1, 2])
makeImageStack(name: "App Icon - App Store", pointSize: (1280, 768), scales: [1])

/// Top Shelf: the gauge on the left over a wide graph line, on the same gradient.
func drawTopShelf(_ ctx: CGContext, width w: CGFloat, height h: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    fillVerticalGradient(ctx, rect, top: orangeTop, bottom: orangeBottom)
    drawGraphLine(ctx, in: CGRect(x: 0, y: 0, width: w, height: h * 0.34), color: white.copy(alpha: 0.2)!, lineWidth: h * 0.008)
    drawGauge(ctx, center: CGPoint(x: w * 0.5, y: h * 0.48), radius: h * 0.28, color: white, trackAlpha: 0.32)
}

for (name, role, size) in [("Top Shelf Image", "top-shelf-image", (1920, 720)), ("Top Shelf Image Wide", "top-shelf-image-wide", (2320, 720))] {
    _ = role
    let set = "\(brand)/\(name).imageset"
    var images: [[String: Any]] = []
    for scale in [1, 2] {
        let file = "topshelf\(name.hasSuffix("Wide") ? "-wide" : "")\(scale == 2 ? "@2x" : "").png"
        let ctx = makeContext(size.0 * scale, size.1 * scale, opaque: true)
        drawTopShelf(ctx, width: CGFloat(size.0 * scale), height: CGFloat(size.1 * scale))
        write(ctx, to: "\(set)/\(file)")
        images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
    }
    writeJSON(["images": images, "info": xcodeInfo], to: "\(set)/Contents.json")
}

writeJSON([
    "assets": [
        ["filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
        ["filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
        ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
        ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
    ],
    "info": xcodeInfo,
], to: "\(brand)/Contents.json")
writeJSON(["info": xcodeInfo], to: "\(tvAssets)/Contents.json")

print("Done.")
