// Generates icon/AppIcon.icns. Run from the repo root:  swift icon/make_icon.swift
//
// Design: a macOS-style rounded square with a blue-indigo gradient, holding a frosted
// panel with three window tiles, the middle one selected — a tiny TabLite switcher.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, a])!
}
func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func makeContext(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawMaster() -> CGImage {
    let c = makeContext(Int(S))
    // Apple's macOS icon grid: 824 pt body centered on a 1024 canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = rr(body, 185)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgba(0x000000, 0.35))
    c.addPath(bodyPath); c.setFillColor(rgba(0x3B3FD8)); c.fillPath()
    c.restoreGState()

    // Background gradient (y is up: top is y = 924).
    c.saveGState()
    c.addPath(bodyPath); c.clip()
    let bg = CGGradient(colorsSpace: srgb, colors: [rgba(0x6FA8FF), rgba(0x4F5BF0), rgba(0x3A2FB8)] as CFArray,
                        locations: [0, 0.55, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glossy glow in the upper half.
    let glow = CGGradient(colorsSpace: srgb, colors: [rgba(0xFFFFFF, 0.28), rgba(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 900), endRadius: 520, options: [])
    c.restoreGState()

    // Thin light rim around the body.
    c.addPath(rr(body.insetBy(dx: 3, dy: 3), 182))
    c.setStrokeColor(rgba(0xFFFFFF, 0.25)); c.setLineWidth(6); c.strokePath()

    // Frosted switcher panel.
    let panel = CGRect(x: 172, y: 352, width: 680, height: 320)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgba(0x10125A, 0.35))
    c.addPath(rr(panel, 64)); c.setFillColor(rgba(0xFFFFFF, 0.20)); c.fillPath()
    c.restoreGState()
    c.addPath(rr(panel.insetBy(dx: 2, dy: 2), 62))
    c.setStrokeColor(rgba(0xFFFFFF, 0.55)); c.setLineWidth(4); c.strokePath()

    // Three window tiles; the middle one is selected.
    let tw: CGFloat = 176, th: CGFloat = 136, gap: CGFloat = 34
    let x0 = 512 - (3 * tw + 2 * gap) / 2, ty: CGFloat = 512 - th / 2
    let content: [UInt32] = [0xBFD7FF, 0xFFFFFF, 0xFFD9C2]
    for i in 0..<3 {
        let r = CGRect(x: x0 + CGFloat(i) * (tw + gap), y: ty, width: tw, height: th)
        if i == 1 {
            let sel = r.insetBy(dx: -20, dy: -20)
            c.addPath(rr(sel, 34)); c.setFillColor(rgba(0xFFFFFF, 0.35)); c.fillPath()
            c.addPath(rr(sel, 34)); c.setStrokeColor(rgba(0xFFFFFF, 0.95)); c.setLineWidth(6); c.strokePath()
        }
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: rgba(0x10125A, 0.30))
        c.addPath(rr(r, 18)); c.setFillColor(rgba(content[i])); c.fillPath()
        c.restoreGState()
        // Title bar with traffic lights.
        c.saveGState()
        c.addPath(rr(r, 18)); c.clip()
        c.setFillColor(rgba(0xECEFF6)); c.fill(CGRect(x: r.minX, y: r.maxY - 30, width: tw, height: 30))
        c.restoreGState()
        for (k, col) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            c.setFillColor(rgba(col))
            c.fillEllipse(in: CGRect(x: r.minX + 14 + CGFloat(k) * 20, y: r.maxY - 21, width: 12, height: 12))
        }
        // A few content lines.
        c.setFillColor(rgba(0x1E2350, 0.18))
        for (k, w) in [CGFloat(0.70), 0.52, 0.62].enumerated() {
            c.addPath(rr(CGRect(x: r.minX + 16, y: r.maxY - 56 - CGFloat(k) * 22, width: (tw - 32) * w, height: 10), 5))
            c.fillPath()
        }
    }
    return c.makeImage()!
}

func writePNG(_ img: CGImage, size: Int, to url: URL) {
    let c = makeContext(size)
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = drawMaster()
for base in [16, 32, 128, 256, 512] {
    writePNG(master, size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(master, size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
writePNG(master, size: 256, to: root.appendingPathComponent("icon/preview.png"))   // for the README

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("icon/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote icon/AppIcon.icns" : "iconutil failed")
