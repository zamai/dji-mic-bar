#!/usr/bin/env swift
// Draws the app icon (the Mic Mini 2 transmitter, three-quarter view) and writes an .icns.
//   swift tools/make-icon.swift Resources/AppIcon.icns [preview.png]
import AppKit
import SwiftUI

// Coordinates are on Apple's 1024 pt icon grid, y down. The tile is the standard 824 pt squircle;
// any other outline gets shrunk onto a grey plate by macOS 26 and later.

func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v * 1.015, alpha: a) }

func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    Path(roundedRect: r, cornerRadius: radius, style: .continuous).cgPath
}

func draw(pixels px: Int) -> CGImage {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(px) / 1024
    c.translateBy(x: 0, y: CGFloat(px))
    c.scaleBy(x: scale, y: -scale)

    func fill(_ p: CGPath, _ color: CGColor) { c.addPath(p); c.setFillColor(color); c.fillPath() }
    func stroke(_ p: CGPath, _ color: CGColor, _ width: CGFloat) {
        c.addPath(p); c.setStrokeColor(color); c.setLineWidth(width); c.strokePath()
    }
    func gradient(_ p: CGPath, _ colors: [CGColor], from a: CGPoint, to b: CGPoint) {
        c.saveGState(); c.addPath(p); c.clip()
        c.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: nil)!,
                             start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
    // Shadow offsets and blurs ignore the CTM, hence the manual scaling.
    func shadowed(dy: CGFloat, blur: CGFloat, _ color: CGColor, _ body: () -> Void) {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: color)
        body()
        c.restoreGState()
    }

    let tile = squircle(CGRect(x: 100, y: 100, width: 824, height: 824), 185.4)
    gradient(tile, [gray(0.27), gray(0.075)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    c.addPath(tile); c.clip()

    let small = px <= 64          // drop fine detail, enlarge what is left
    let zoom: CGFloat = small ? 1.17 : 1.04
    c.translateBy(x: 512, y: 512); c.scaleBy(x: zoom, y: zoom); c.translateBy(x: -512, y: -512)

    let body = squircle(CGRect(x: 218, y: 220, width: 590, height: 584), 168)
    shadowed(dy: 22, blur: 50, gray(0, 0.6)) { fill(body, gray(0.7)) }
    gradient(body, [gray(0.93), gray(0.78), gray(0.56)], from: CGPoint(x: 600, y: 230), to: CGPoint(x: 790, y: 810))

    let face = squircle(CGRect(x: 226, y: 234, width: 460, height: 556), 132)
    gradient(face, [gray(0.99), gray(0.88), gray(0.79)], from: CGPoint(x: 280, y: 240), to: CGPoint(x: 620, y: 800))

    if !small {
        stroke(face, gray(0.5, 0.8), 5)
        // magnet recesses showing through the translucent front
        for r in [CGRect(x: 531, y: 284, width: 100, height: 112), CGRect(x: 281, y: 628, width: 100, height: 112)] {
            fill(squircle(r, 40), gray(0.6, 0.12))
            stroke(squircle(r, 40), gray(1, 0.4), 4)
        }
    }

    // status LED
    let led = squircle(CGRect(x: small ? 704 : 711, y: 324, width: small ? 70 : 56, height: small ? 46 : 30), 15)
    let green = CGColor(srgbRed: 0.1, green: 0.93, blue: 0.25, alpha: 1)
    shadowed(dy: 0, blur: 34, green) { fill(led, green) }

    // link and power buttons
    for r in [CGRect(x: 710, y: 416, width: 66, height: 154), CGRect(x: 710, y: 604, width: 66, height: 112)] {
        let b = squircle(r, 33)
        gradient(b, [gray(0.45), gray(0.27)], from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
        if !small { stroke(b, gray(0.2, 0.7), 4) }
    }

    // "dji", set in the system font like the menu bar glyph
    let base = NSFont.systemFont(ofSize: small ? 290 : 258, weight: .heavy)
    let font = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "dji", attributes: [
        .font: font, .kern: -8,
        .foregroundColor: NSColor(cgColor: gray(small ? 0.15 : 0.3))!,
    ]))
    let box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    c.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    c.textPosition = CGPoint(x: 452 - box.midX, y: 512 + box.midY)
    CTLineDraw(line, c)

    return c.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: make-icon.swift <out.icns> [preview.png]"); exit(2) }
let set = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
// No 16 or 32 px representations: macOS puts those on a grey plate even when the shape is right,
// and scales down cleanly from the 64 px one (32@2x) instead.
for size in [32, 128, 256, 512] {
    if size > 32 { try writePNG(draw(pixels: size), set.appendingPathComponent("icon_\(size)x\(size).png")) }
    try writePNG(draw(pixels: size * 2), set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = try Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"),
                        arguments: ["-c", "icns", set.path, "-o", args[1]])
p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
guard p.terminationStatus == 0 else { print("iconutil failed"); exit(1) }
if args.count > 2 { try writePNG(draw(pixels: 512), URL(fileURLWithPath: args[2])) }
