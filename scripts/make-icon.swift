#!/usr/bin/env swift
//
// Render one square PNG of the app icon at a given pixel size.
// Usage: swift make-icon.swift <size> <out.png>
//
// Original artwork (no third-party logos): a usage-gauge ring on a warm
// coral/terracotta squircle. The mark itself is original — only the palette is
// chosen to sit near the Claude brand color; a color alone carries no logo.
//
import AppKit

guard CommandLine.arguments.count == 3,
      let px = Double(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <size> <out.png>\n".utf8))
    exit(1)
}
let size = CGFloat(px)
let outPath = CommandLine.arguments[2]

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

cg.clear(CGRect(x: 0, y: 0, width: size, height: size))

// Rounded-square ("squircle"-ish) body with transparent margin, per macOS icons.
let margin = size * 0.09
let body = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius = body.width * 0.2237
let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Indigo gradient fill.
cg.saveGState()
cg.addPath(squircle)
cg.clip()
let grad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(srgbRed: 0.91, green: 0.53, blue: 0.38, alpha: 1).cgColor,
             NSColor(srgbRed: 0.74, green: 0.36, blue: 0.24, alpha: 1).cgColor] as CFArray,
    locations: [0, 1])!
cg.drawLinearGradient(grad,
                      start: CGPoint(x: margin, y: size - margin),
                      end: CGPoint(x: size - margin, y: margin),
                      options: [])
cg.restoreGState()

// Usage-gauge ring: faint full track + a bright ~72% value arc.
let center = CGPoint(x: size / 2, y: size / 2)
let ring = body.width * 0.30
let lw = body.width * 0.115
cg.setLineCap(.round)
cg.setLineWidth(lw)

cg.setStrokeColor(NSColor(white: 1, alpha: 0.22).cgColor)
cg.addArc(center: center, radius: ring, startAngle: 0, endAngle: .pi * 2, clockwise: false)
cg.strokePath()

let start = CGFloat.pi / 2                       // top
let end = start - 0.72 * (.pi * 2)               // clockwise ~72%
cg.setStrokeColor(NSColor.white.cgColor)
cg.addArc(center: center, radius: ring, startAngle: start, endAngle: end, clockwise: true)
cg.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("error: PNG encode failed\n".utf8))
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
