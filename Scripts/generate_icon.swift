#!/usr/bin/env swift
//
// generate_icon.swift: Render the Lincoln app icon procedurally.
//
// Produces every size in Lincoln/Assets.xcassets/AppIcon.appiconset (artwork
// filling the standard 824/1024 squircle body on Apple's icon grid, with the
// usual drop shadow, so it sits at the same size as every other Dock icon),
// docs/icon.png (1024 px, full-bleed for the web) and, when the bino.io site
// checkout is present, its copy of the icon.
//
// Usage: xcrun swift Scripts/generate_icon.swift [preview.png]

import AppKit
import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = repoRoot.appendingPathComponent("Lincoln/Assets.xcassets/AppIcon.appiconset")
let docsIconURL = repoRoot.appendingPathComponent("docs/icon.png")
let siteIconURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads/homelab/web/bino.io/lincoln/icon.png")

// Accent #5E5CE6 (indigo), unique on the bino.io card grid.
func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func render(size s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    // Full-bleed squircle (Apple's ~22.37% corner ratio).
    let bounds = CGRect(x: 0, y: 0, width: s, height: s)
    let squircle = NSBezierPath(roundedRect: bounds, xRadius: s * 0.2237, yRadius: s * 0.2237)
    squircle.addClip()

    // Night sky gradient.
    NSGradient(colors: [color(0x6D6BF0), color(0x4B49C9), color(0x2B2A7A)])!
        .draw(in: bounds, angle: -90)

    // Ground / roadbed.
    let groundTop = s * 0.30
    ctx.setFillColor(color(0x1B1B3A).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: groundTop))

    // Portal wall: a broad arch with a stone face.
    let archCenter = CGPoint(x: s * 0.5, y: s * 0.52)
    let outerRadius = s * 0.30
    let outer = CGMutablePath()
    outer.move(to: CGPoint(x: archCenter.x - outerRadius, y: groundTop))
    outer.addLine(to: CGPoint(x: archCenter.x - outerRadius, y: archCenter.y))
    outer.addArc(center: archCenter, radius: outerRadius, startAngle: .pi, endAngle: 0, clockwise: true)
    outer.addLine(to: CGPoint(x: archCenter.x + outerRadius, y: groundTop))
    outer.closeSubpath()
    ctx.addPath(outer)
    ctx.setFillColor(color(0xF5F4FF).cgColor)
    ctx.fillPath()

    // Tunnel opening: dark bore with a bright light at the far end.
    let innerRadius = s * 0.225
    let opening = CGMutablePath()
    opening.move(to: CGPoint(x: archCenter.x - innerRadius, y: groundTop))
    opening.addLine(to: CGPoint(x: archCenter.x - innerRadius, y: archCenter.y))
    opening.addArc(center: archCenter, radius: innerRadius, startAngle: .pi, endAngle: 0, clockwise: true)
    opening.addLine(to: CGPoint(x: archCenter.x + innerRadius, y: groundTop))
    opening.closeSubpath()
    ctx.saveGState()
    ctx.addPath(opening)
    ctx.clip()
    ctx.setFillColor(color(0x0B0B1F).cgColor)
    ctx.fill(bounds)
    let lightCenter = CGPoint(x: archCenter.x, y: groundTop + s * 0.10)
    let lightGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0xFFFBE6).cgColor, color(0xFFD65C, alpha: 0.85).cgColor, color(0x5E5CE6, alpha: 0.0).cgColor] as CFArray,
        locations: [0, 0.35, 1]
    )!
    ctx.drawRadialGradient(lightGradient, startCenter: lightCenter, startRadius: 0, endCenter: lightCenter, endRadius: innerRadius * 0.95, options: [])

    // Road with perspective: lane line converging on the light.
    ctx.setFillColor(color(0x2A2A4E).cgColor)
    let road = CGMutablePath()
    road.move(to: CGPoint(x: archCenter.x - innerRadius, y: 0))
    road.addLine(to: CGPoint(x: archCenter.x + innerRadius, y: 0))
    road.addLine(to: CGPoint(x: lightCenter.x + s * 0.02, y: lightCenter.y))
    road.addLine(to: CGPoint(x: lightCenter.x - s * 0.02, y: lightCenter.y))
    road.closeSubpath()
    ctx.addPath(road)
    ctx.fillPath()
    ctx.setStrokeColor(color(0xFFD65C).cgColor)
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.setLineDash(phase: 0, lengths: [s * 0.05, s * 0.035])
    ctx.move(to: CGPoint(x: archCenter.x, y: 0))
    ctx.addLine(to: CGPoint(x: archCenter.x, y: lightCenter.y - s * 0.02))
    ctx.strokePath()
    ctx.restoreGState()

    // Road continues out of the portal across the foreground.
    ctx.setFillColor(color(0x2A2A4E).cgColor)
    let apron = CGMutablePath()
    apron.move(to: CGPoint(x: s * 0.12, y: 0))
    apron.addLine(to: CGPoint(x: s * 0.88, y: 0))
    apron.addLine(to: CGPoint(x: archCenter.x + innerRadius, y: groundTop))
    apron.addLine(to: CGPoint(x: archCenter.x - innerRadius, y: groundTop))
    apron.closeSubpath()
    ctx.addPath(apron)
    ctx.fillPath()
    ctx.setStrokeColor(color(0xFFD65C).cgColor)
    ctx.setLineWidth(max(1, s * 0.016))
    ctx.setLineDash(phase: 0, lengths: [s * 0.07, s * 0.045])
    ctx.move(to: CGPoint(x: archCenter.x, y: 0))
    ctx.addLine(to: CGPoint(x: archCenter.x, y: groundTop))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Keystone highlight on the arch.
    ctx.setFillColor(color(0xC9C7FF).cgColor)
    let keystone = CGMutablePath()
    keystone.move(to: CGPoint(x: archCenter.x - s * 0.045, y: archCenter.y + innerRadius - s * 0.005))
    keystone.addLine(to: CGPoint(x: archCenter.x + s * 0.045, y: archCenter.y + innerRadius - s * 0.005))
    keystone.addLine(to: CGPoint(x: archCenter.x + s * 0.06, y: archCenter.y + outerRadius + s * 0.002))
    keystone.addLine(to: CGPoint(x: archCenter.x - s * 0.06, y: archCenter.y + outerRadius + s * 0.002))
    keystone.closeSubpath()
    ctx.addPath(keystone)
    ctx.fillPath()

    // Subtle inner hairline on the squircle edge.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: s * 0.004, dy: s * 0.004), cornerWidth: s * 0.2237, cornerHeight: s * 0.2237, transform: nil))
    ctx.strokePath()

    image.unlockFocus()
    return image
}

/// The app icon on Apple's macOS icon grid: the artwork fills an 824×824
/// squircle centred in the 1024×1024 canvas (80.47%), lifted slightly to make
/// room for the standard soft drop shadow beneath it.
func renderAppIcon(size s: CGFloat) -> NSImage {
    let artwork = render(size: s)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let bodySize = s * 0.8046875
    let margin = (s - bodySize) / 2
    let yOffset = s * 0.006
    let rect = CGRect(x: margin, y: margin + yOffset, width: bodySize, height: bodySize)
    let radius = bodySize * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 1. Standard macOS drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -max(0.5, s * 0.012)),
                  blur: max(1.0, s * 0.025),
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Artwork filling the squircle body.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()

    // 3. Subtle inner stroke highlight.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineWidth(max(0.5, s * 0.001))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.strokePath()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixelSize: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

if CommandLine.arguments.count > 1 {
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    try writePNG(render(size: 1024), pixelSize: 1024, to: out)
    print("Wrote preview \(out.path)")
    exit(0)
}

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for (points, scale) in sizes {
    let pixels = points * scale
    let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try writePNG(renderAppIcon(size: CGFloat(pixels)), pixelSize: pixels, to: iconsetURL.appendingPathComponent(filename))
    images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconsetURL.appendingPathComponent("Contents.json"))
print("Wrote \(sizes.count) icons to \(iconsetURL.path)")

try writePNG(render(size: 1024), pixelSize: 1024, to: docsIconURL)
print("Wrote \(docsIconURL.path)")

if FileManager.default.fileExists(atPath: siteIconURL.deletingLastPathComponent().deletingLastPathComponent().path) {
    try writePNG(render(size: 1024), pixelSize: 1024, to: siteIconURL)
    print("Wrote \(siteIconURL.path)")
}
