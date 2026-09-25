#!/usr/bin/env xcrun swift
//
//  generate_concepts.swift
//  SnapShelf icon design — stage 1 concept renderer.
//
//  Renders three app-icon concepts as hand-drawn vector-style geometry
//  (rounded rects, gradients, superellipse "squircle" mask, soft shadow,
//  glass highlight). No SF Symbols, no text, no stock images — every
//  glyph is original geometry built from CGPath primitives.
//
//  Run with: xcrun swift design/icon/generate_concepts.swift
//  (the bare `swift` on PATH in this environment points at a broken
//  swiftly toolchain shim — `xcrun swift` resolves to Xcode 27's real
//  Swift 6.4 toolchain and works.)
//

import Foundation
import CoreGraphics
import AppKit

// MARK: - Paths

let scriptURL = URL(fileURLWithPath: #filePath)
let iconDir = scriptURL.deletingLastPathComponent()
let conceptsDir = iconDir.appendingPathComponent("concepts")

// MARK: - Color helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

func white(_ alpha: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: alpha) }
func black(_ alpha: CGFloat) -> CGColor { CGColor(red: 0, green: 0, blue: 0, alpha: alpha) }

func hexString(_ hex: UInt32) -> String { String(format: "#%06X", hex & 0xFFFFFF) }

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// MARK: - Appearance

enum Appearance: String, CaseIterable {
    case light  // "Default"
    case dark
    case tinted
}

// MARK: - Context / image plumbing

func makeContext(size: Int) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create CGContext") }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

@discardableResult
func savePNG(_ image: CGImage, to url: URL) -> URL {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(url.path)")
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
    print("wrote \(url.path)")
    return url
}

func saveText(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Non-atomic: an atomic write (temp file + swap) trips the sandbox's
    // "Operation not permitted" even though this directory is writable.
    do {
        try text.write(to: url, atomically: false, encoding: .utf8)
        print("wrote \(url.path)")
    } catch {
        print("FAILED to write \(url.path): \(error)")
    }
}

func resize(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = makeContext(size: size)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// MARK: - Geometry helpers

/// Apple's macOS "squircle" continuous-corner shape, approximated as a
/// superellipse. Exponent ~4.5-5 reads very close to the system mask.
func superellipsePath(center: CGPoint, radius: CGFloat, exponent: CGFloat = 4.8, steps: Int = 360) -> CGPath {
    let path = CGMutablePath()
    for i in 0...steps {
        let t = (CGFloat(i) / CGFloat(steps)) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = pow(abs(ct), 2.0 / exponent) * (ct < 0 ? -1 : 1) * radius
        let y = pow(abs(st), 2.0 / exponent) * (st < 0 ? -1 : 1) * radius
        let pt = CGPoint(x: center.x + x, y: center.y + y)
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    return path
}

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A card silhouette with three rounded corners and the top-right corner
/// replaced by a diagonal cut, like a dog-eared photo. Assumes a
/// top-left-origin, y-down coordinate space.
func foldedCornerCardPath(rect: CGRect, radius: CGFloat, foldSize: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = rect
    path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX - foldSize, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY + foldSize))
    path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
    path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - radius), radius: radius)
    path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
    path.closeSubpath()
    return path
}

/// The small triangular flap cut from `foldedCornerCardPath`'s top-right corner.
func foldFlapPath(rect: CGRect, foldSize: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = rect
    path.move(to: CGPoint(x: r.maxX - foldSize, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    path.addLine(to: CGPoint(x: r.maxX, y: r.minY + foldSize))
    path.closeSubpath()
    return path
}

func drawLinearGradient(ctx: CGContext, path: CGPath?, colors: [CGColor], locations: [CGFloat], start: CGPoint, end: CGPoint) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations) else { return }
    ctx.saveGState()
    if let path = path {
        ctx.addPath(path)
        ctx.clip()
    }
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

/// Draws one L-shaped selection/viewfinder bracket. Assumes a top-left
/// origin, y-down coordinate system (the flat-draw functions flip to this).
func bracketPath(corner: Corner, canvas: CGRect, margin: CGFloat, armLength: CGFloat) -> CGPath {
    let path = CGMutablePath()
    switch corner {
    case .topLeft:
        let p = CGPoint(x: canvas.minX + margin, y: canvas.minY + margin)
        path.move(to: CGPoint(x: p.x, y: p.y + armLength))
        path.addLine(to: p)
        path.addLine(to: CGPoint(x: p.x + armLength, y: p.y))
    case .topRight:
        let p = CGPoint(x: canvas.maxX - margin, y: canvas.minY + margin)
        path.move(to: CGPoint(x: p.x - armLength, y: p.y))
        path.addLine(to: p)
        path.addLine(to: CGPoint(x: p.x, y: p.y + armLength))
    case .bottomLeft:
        let p = CGPoint(x: canvas.minX + margin, y: canvas.maxY - margin)
        path.move(to: CGPoint(x: p.x, y: p.y - armLength))
        path.addLine(to: p)
        path.addLine(to: CGPoint(x: p.x + armLength, y: p.y))
    case .bottomRight:
        let p = CGPoint(x: canvas.maxX - margin, y: canvas.maxY - margin)
        path.move(to: CGPoint(x: p.x - armLength, y: p.y))
        path.addLine(to: p)
        path.addLine(to: CGPoint(x: p.x, y: p.y - armLength))
    }
    return path
}

func strokeBracket(ctx: CGContext, corner: Corner, canvas: CGRect, margin: CGFloat, armLength: CGFloat, width: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(bracketPath(corner: corner, canvas: canvas, margin: margin, armLength: armLength))
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Canvas constant

let CANVAS: CGFloat = 1024

/// Runs `draw` in a top-left-origin, y-down coordinate space over the
/// full 1024x1024 canvas (no mask, no shadow — that's applied later by
/// the compositor, matching how Icon Composer wants flat full-bleed
/// layers with system effects added on top).
func flatCanvas(_ draw: (CGContext, CGRect) -> Void) -> CGImage {
    let ctx = makeContext(size: Int(CANVAS))
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CANVAS)
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx, CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS))
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: - Compositor: flat square art -> masked, shadowed, glass-highlighted preview mockup

func compositePreview(flat: CGImage, exponent: CGFloat = 4.8) -> CGImage {
    let ctx = makeContext(size: Int(CANVAS))
    let scale: CGFloat = 0.90 // inset so the drop shadow has room within the 1024 frame
    let radius = (CANVAS * scale) / 2
    let center = CGPoint(x: CANVAS / 2, y: CANVAS / 2)
    let squircle = superellipsePath(center: center, radius: radius, exponent: exponent)

    // 1. Drop shadow cast by the icon silhouette.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: black(0.38))
    ctx.addPath(squircle)
    ctx.setFillColor(black(1))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Clip to squircle, draw flat art scaled into the inset square.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let inset = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.draw(flat, in: inset)
    ctx.restoreGState()

    // 3. Glass highlight: soft light sweep across the top third.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let hiColors = [white(0.32), white(0.0)]
    let hiGradient = CGGradient(colorsSpace: cs, colors: hiColors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hiGradient, start: CGPoint(x: center.x, y: center.y - radius), end: CGPoint(x: center.x, y: center.y - radius * 0.15), options: [])
    // thin edge stroke for definition against light/dark comparison backdrops
    ctx.addPath(squircle)
    ctx.setStrokeColor(white(0.14))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - SVG helpers (hand-written, clean, for Icon Composer layer import)

func svgHeader() -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">"
}

func svgFooter() -> String { "</svg>" }

/// Converts any CGPath (lines, quad curves, cubic curves — e.g. from
/// addArc) into an SVG path `d` attribute string.
func svgPathData(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { elementPtr in
        let element = elementPtr.pointee
        switch element.type {
        case .moveToPoint:
            let p = element.points[0]
            d += "M \(p.x) \(p.y) "
        case .addLineToPoint:
            let p = element.points[0]
            d += "L \(p.x) \(p.y) "
        case .addQuadCurveToPoint:
            let c = element.points[0], p = element.points[1]
            d += "Q \(c.x) \(c.y) \(p.x) \(p.y) "
        case .addCurveToPoint:
            let c1 = element.points[0], c2 = element.points[1], p = element.points[2]
            d += "C \(c1.x) \(c1.y) \(c2.x) \(c2.y) \(p.x) \(p.y) "
        case .closeSubpath:
            d += "Z "
        @unknown default:
            break
        }
    }
    return d
}

// MARK: ======================================================================
// MARK: Concept 1 — Stacked Cards ("Shelf Stack")
// MARK: ======================================================================

enum StackedCards {
    static let bgLight: (UInt32, UInt32) = (0x4C63F6, 0x9C4DF4)
    static let bgDark: (UInt32, UInt32) = (0x1E2350, 0x3E2166)
    static let bgTinted: (UInt32, UInt32) = (0x3A3D45, 0x55585F)
    static let accent: UInt32 = 0xFF5F6D

    static let cardW: CGFloat = CANVAS * 0.46
    static let cardH: CGFloat = CANVAS * 0.58
    static let cardRadius: CGFloat = CANVAS * 0.09
    static let centerX: CGFloat = CANVAS * 0.5
    static let centerY: CGFloat = CANVAS * 0.55

    struct CardSpec { let dx: CGFloat; let dy: CGFloat; let rotationDeg: CGFloat }
    static let back = CardSpec(dx: -CANVAS * 0.10, dy: -CANVAS * 0.06, rotationDeg: -11)
    static let mid = CardSpec(dx: -CANVAS * 0.035, dy: -CANVAS * 0.025, rotationDeg: -4.5)
    static let front = CardSpec(dx: 0, dy: 0, rotationDeg: 0)

    static func drawCard(ctx: CGContext, spec: CardSpec, fill: CGColor, stroke: CGColor?, shadow: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: centerX + spec.dx, y: centerY + spec.dy)
        ctx.rotate(by: deg(spec.rotationDeg))
        let rect = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
        let path = roundedRectPath(rect, radius: cardRadius)
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: black(0.30))
        }
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        if let stroke = stroke {
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(4)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    static func flat(appearance: Appearance) -> CGImage {
        flatCanvas { ctx, rect in
            let bg: (UInt32, UInt32)
            switch appearance {
            case .light: bg = bgLight
            case .dark: bg = bgDark
            case .tinted: bg = bgTinted
            }
            drawLinearGradient(ctx: ctx, path: nil, colors: [rgb(bg.0), rgb(bg.1)], locations: [0, 1],
                                start: CGPoint(x: 0, y: 0), end: CGPoint(x: rect.width, y: rect.height))

            switch appearance {
            case .light:
                drawCard(ctx: ctx, spec: back, fill: rgb(0xD9E0FF), stroke: rgb(0xC7CFFA), shadow: true)
                drawCard(ctx: ctx, spec: mid, fill: rgb(0xEFEEFF), stroke: rgb(0xC7CFFA), shadow: true)
                drawCard(ctx: ctx, spec: front, fill: rgb(0xFFFFFF), stroke: nil, shadow: true)
                drawAccentDot(ctx: ctx, color: rgb(accent))
            case .dark:
                drawCard(ctx: ctx, spec: back, fill: rgb(0x4A4E88), stroke: rgb(0x33356B), shadow: true)
                drawCard(ctx: ctx, spec: mid, fill: rgb(0x6E71AD), stroke: rgb(0x33356B), shadow: true)
                drawCard(ctx: ctx, spec: front, fill: rgb(0xEDEBFA), stroke: nil, shadow: true)
                drawAccentDot(ctx: ctx, color: rgb(0xFF7A85))
            case .tinted:
                drawCard(ctx: ctx, spec: back, fill: white(0.30), stroke: nil, shadow: false)
                drawCard(ctx: ctx, spec: mid, fill: white(0.55), stroke: nil, shadow: false)
                drawCard(ctx: ctx, spec: front, fill: white(0.94), stroke: nil, shadow: false)
            }
        }
    }

    static func drawAccentDot(ctx: CGContext, color: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: black(0.25))
        ctx.translateBy(x: centerX, y: centerY)
        let dotR = CANVAS * 0.052
        let dotCenter = CGPoint(x: cardW / 2 - dotR * 1.35, y: -cardH / 2 + dotR * 1.35)
        ctx.setFillColor(color)
        ctx.addEllipse(in: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2))
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func backgroundSVG() -> String {
        """
        \(svgHeader())
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="\(hexString(bgLight.0))"/>
              <stop offset="1" stop-color="\(hexString(bgLight.1))"/>
            </linearGradient>
          </defs>
          <rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>
        \(svgFooter())
        """
    }

    static func cardRectSVG(spec: CardSpec, fill: String, stroke: String?) -> String {
        let x = -cardW / 2, y = -cardH / 2
        let strokeAttr = stroke.map { " stroke=\"\($0)\" stroke-width=\"4\"" } ?? ""
        return "  <rect x=\"\(x)\" y=\"\(y)\" width=\"\(cardW)\" height=\"\(cardH)\" rx=\"\(cardRadius)\" ry=\"\(cardRadius)\" fill=\"\(fill)\"\(strokeAttr) transform=\"translate(\(centerX + spec.dx) \(centerY + spec.dy)) rotate(\(spec.rotationDeg))\"/>"
    }

    static func foregroundBackSVG() -> String {
        """
        \(svgHeader())
        \(cardRectSVG(spec: back, fill: hexString(0xD9E0FF), stroke: hexString(0xC7CFFA)))
        \(cardRectSVG(spec: mid, fill: hexString(0xEFEEFF), stroke: hexString(0xC7CFFA)))
        \(svgFooter())
        """
    }

    static func foregroundFrontSVG() -> String {
        let dotR = CANVAS * 0.052
        let dotCX = centerX + (cardW / 2 - dotR * 1.35)
        let dotCY = centerY + (-cardH / 2 + dotR * 1.35)
        return """
        \(svgHeader())
        \(cardRectSVG(spec: front, fill: hexString(0xFFFFFF), stroke: nil))
          <circle cx="\(dotCX)" cy="\(dotCY)" r="\(dotR)" fill="\(hexString(accent))"/>
        \(svgFooter())
        """
    }
}

// MARK: ======================================================================
// MARK: Concept 2 — Selection Shelf ("Capture Shelf")
// MARK: ======================================================================

enum SelectionShelf {
    static let bgLightTop: UInt32 = 0x2C2C33
    static let bgLightBottom: UInt32 = 0x131316
    static let bgDarkTop: UInt32 = 0x111114
    static let bgDarkBottom: UInt32 = 0x000000
    static let bgTinted: (UInt32, UInt32) = (0x3A3D45, 0x232529)
    static let accentLight: UInt32 = 0x0A84FF
    static let accentDark: UInt32 = 0x5AC8FF

    static let shelfWidth: CGFloat = CANVAS * 0.70
    static let shelfHeight: CGFloat = CANVAS * 0.058
    static let shelfY: CGFloat = CANVAS * 0.72
    static let shelfRadius: CGFloat = shelfHeight / 2

    static let cardW: CGFloat = CANVAS * 0.44
    static let cardH: CGFloat = CANVAS * 0.50
    static let cardRadius: CGFloat = CANVAS * 0.075
    static let foldSize: CGFloat = CANVAS * 0.085

    static let bracketMargin: CGFloat = CANVAS * 0.115
    static let bracketArm: CGFloat = CANVAS * 0.155
    static let bracketWidth: CGFloat = CANVAS * 0.042

    static func flat(appearance: Appearance) -> CGImage {
        flatCanvas { ctx, rect in
            switch appearance {
            case .light:
                drawLinearGradient(ctx: ctx, path: nil, colors: [rgb(bgLightTop), rgb(bgLightBottom)], locations: [0, 1],
                                    start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: rect.height))
            case .dark:
                drawLinearGradient(ctx: ctx, path: nil, colors: [rgb(bgDarkTop), rgb(bgDarkBottom)], locations: [0, 1],
                                    start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: rect.height))
            case .tinted:
                drawLinearGradient(ctx: ctx, path: nil, colors: [rgb(bgTinted.0), rgb(bgTinted.1)], locations: [0, 1],
                                    start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: rect.height))
            }

            // Shelf — a bright ledge, high-contrast against the dark background so the
            // two "wings" either side of the card read clearly even at 16px.
            let shelfRect = CGRect(x: (CANVAS - shelfWidth) / 2, y: shelfY, width: shelfWidth, height: shelfHeight)
            let shelfPath = roundedRectPath(shelfRect, radius: shelfRadius)
            ctx.saveGState()
            if appearance != .tinted {
                ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 16, color: black(0.4))
            }
            ctx.addPath(shelfPath)
            switch appearance {
            case .light: ctx.setFillColor(rgb(0xAEAEB6))
            case .dark: ctx.setFillColor(rgb(0x5A5A60))
            case .tinted: ctx.setFillColor(white(0.42))
            }
            ctx.fillPath()
            ctx.restoreGState()

            // Card resting on shelf, sunk in by ~45% of the shelf height so it reads
            // as "on" the ledge rather than floating above it. The top-right corner
            // is a straight diagonal cut (a dog-ear) instead of rounded, so the fold
            // flap drawn below sits flush against it — a paper-fold cue for
            // "captured image" without text or a photo.
            let cardRect = CGRect(x: (CANVAS - cardW) / 2, y: shelfY - cardH + shelfHeight * 0.45, width: cardW, height: cardH)
            let cardPath = foldedCornerCardPath(rect: cardRect, radius: cardRadius, foldSize: foldSize)
            ctx.saveGState()
            if appearance != .tinted {
                ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: black(0.4))
            }
            ctx.addPath(cardPath)
            switch appearance {
            case .light: ctx.setFillColor(rgb(0xFFFFFF))
            case .dark: ctx.setFillColor(rgb(0xEDEDF0))
            case .tinted: ctx.setFillColor(white(0.92))
            }
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(foldFlapPath(rect: cardRect, foldSize: foldSize))
            switch appearance {
            case .light: ctx.setFillColor(rgb(0xD7D7DC))
            case .dark: ctx.setFillColor(rgb(0xC7C7CE))
            case .tinted: ctx.setFillColor(white(0.7))
            }
            ctx.fillPath()
            ctx.restoreGState()

            // Selection brackets
            let accent: CGColor
            switch appearance {
            case .light: accent = rgb(accentLight)
            case .dark: accent = rgb(accentDark)
            case .tinted: accent = white(0.95)
            }
            for corner: Corner in [.topLeft, .topRight, .bottomLeft, .bottomRight] {
                strokeBracket(ctx: ctx, corner: corner, canvas: rect, margin: bracketMargin, armLength: bracketArm, width: bracketWidth, color: accent)
            }
        }
    }

    static func backgroundSVG() -> String {
        """
        \(svgHeader())
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1024" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="\(hexString(bgLightTop))"/>
              <stop offset="1" stop-color="\(hexString(bgLightBottom))"/>
            </linearGradient>
          </defs>
          <rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>
        \(svgFooter())
        """
    }

    static func shelfSVG() -> String {
        let x = (CANVAS - shelfWidth) / 2
        return """
        \(svgHeader())
          <rect x="\(x)" y="\(shelfY)" width="\(shelfWidth)" height="\(shelfHeight)" rx="\(shelfRadius)" ry="\(shelfRadius)" fill="\(hexString(0xAEAEB6))"/>
        \(svgFooter())
        """
    }

    static func cardSVG() -> String {
        let x = (CANVAS - cardW) / 2
        let y = shelfY - cardH + shelfHeight * 0.45
        let cardRect = CGRect(x: x, y: y, width: cardW, height: cardH)
        let cardD = svgPathData(foldedCornerCardPath(rect: cardRect, radius: cardRadius, foldSize: foldSize))
        let foldD = svgPathData(foldFlapPath(rect: cardRect, foldSize: foldSize))
        return """
        \(svgHeader())
          <path d="\(cardD)" fill="#FFFFFF"/>
          <path d="\(foldD)" fill="\(hexString(0xD7D7DC))"/>
        \(svgFooter())
        """
    }

    static func bracketsSVG() -> String {
        let corners: [Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let paths = corners.map { corner -> String in
            let d = svgPathData(bracketPath(corner: corner, canvas: CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS), margin: bracketMargin, armLength: bracketArm))
            return "  <path d=\"\(d)\" fill=\"none\" stroke=\"\(hexString(accentLight))\" stroke-width=\"\(bracketWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }.joined(separator: "\n")
        return """
        \(svgHeader())
        \(paths)
        \(svgFooter())
        """
    }
}

// MARK: ======================================================================
// MARK: Concept 3 — Viewfinder Tile ("Frame Stack")
// MARK: ======================================================================

enum ViewfinderTile {
    static let bgLight: (UInt32, UInt32) = (0x0EA5A0, 0x0891B2)
    static let bgDark: (UInt32, UInt32) = (0x053B3D, 0x073B4C)
    static let bgTinted: (UInt32, UInt32) = (0x3A3D45, 0x55585F)

    static let bracketMargin: CGFloat = CANVAS * 0.10
    static let bracketArm: CGFloat = CANVAS * 0.28
    static let bracketWidth: CGFloat = CANVAS * 0.072

    static let miniCardW: CGFloat = CANVAS * 0.33
    static let miniCardH: CGFloat = CANVAS * 0.40
    static let miniCardRadius: CGFloat = CANVAS * 0.06
    static let miniOffset: CGFloat = CANVAS * 0.05

    static func flat(appearance: Appearance) -> CGImage {
        flatCanvas { ctx, rect in
            let bg: (UInt32, UInt32)
            switch appearance {
            case .light: bg = bgLight
            case .dark: bg = bgDark
            case .tinted: bg = bgTinted
            }
            drawLinearGradient(ctx: ctx, path: nil, colors: [rgb(bg.0), rgb(bg.1)], locations: [0, 1],
                                start: CGPoint(x: 0, y: 0), end: CGPoint(x: rect.width, y: rect.height))

            // Bold viewfinder brackets
            let bracketColor: CGColor = appearance == .tinted ? white(0.95) : white(0.97)
            for corner: Corner in [.topLeft, .topRight, .bottomLeft, .bottomRight] {
                ctx.saveGState()
                if appearance != .tinted {
                    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: black(0.22))
                }
                ctx.setStrokeColor(bracketColor)
                ctx.setLineWidth(bracketWidth)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(bracketPath(corner: corner, canvas: rect, margin: bracketMargin, armLength: bracketArm))
                ctx.strokePath()
                ctx.restoreGState()
            }

            // Mini stacked-cards motif, centered. Both cards stay light so they
            // read as a clean two-tone stack against the teal background instead
            // of the dark "hole" a near-black back card produced in an earlier pass.
            let cx = CANVAS / 2, cy = CANVAS / 2
            func miniCard(dx: CGFloat, dy: CGFloat, fill: CGColor, stroke: CGColor?) {
                let r = CGRect(x: cx - miniCardW / 2 + dx, y: cy - miniCardH / 2 + dy, width: miniCardW, height: miniCardH)
                let path = roundedRectPath(r, radius: miniCardRadius)
                ctx.saveGState()
                if appearance != .tinted {
                    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: black(0.25))
                }
                ctx.addPath(path)
                ctx.setFillColor(fill)
                ctx.fillPath()
                if let stroke = stroke {
                    ctx.setShadow(offset: .zero, blur: 0, color: nil)
                    ctx.addPath(path)
                    ctx.setStrokeColor(stroke)
                    ctx.setLineWidth(3)
                    ctx.strokePath()
                }
                ctx.restoreGState()
            }
            switch appearance {
            case .light:
                miniCard(dx: -miniOffset, dy: -miniOffset, fill: white(0.55), stroke: white(0.85))
                miniCard(dx: 0, dy: 0, fill: white(1), stroke: nil)
            case .dark:
                miniCard(dx: -miniOffset, dy: -miniOffset, fill: white(0.30), stroke: white(0.55))
                miniCard(dx: 0, dy: 0, fill: rgb(0xEAFBF9), stroke: nil)
            case .tinted:
                miniCard(dx: -miniOffset, dy: -miniOffset, fill: white(0.45), stroke: nil)
                miniCard(dx: 0, dy: 0, fill: white(0.95), stroke: nil)
            }
        }
    }

    static func backgroundSVG() -> String {
        """
        \(svgHeader())
          <defs>
            <linearGradient id="bg" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">
              <stop offset="0" stop-color="\(hexString(bgLight.0))"/>
              <stop offset="1" stop-color="\(hexString(bgLight.1))"/>
            </linearGradient>
          </defs>
          <rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>
        \(svgFooter())
        """
    }

    static func bracketsSVG() -> String {
        let corners: [Corner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let paths = corners.map { corner -> String in
            let d = svgPathData(bracketPath(corner: corner, canvas: CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS), margin: bracketMargin, armLength: bracketArm))
            return "  <path d=\"\(d)\" fill=\"none\" stroke=\"#FFFFFF\" stroke-width=\"\(bracketWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }.joined(separator: "\n")
        return """
        \(svgHeader())
        \(paths)
        \(svgFooter())
        """
    }

    static func miniStackSVG() -> String {
        let cx = CANVAS / 2, cy = CANVAS / 2
        let backRect = CGRect(x: cx - miniCardW / 2 - miniOffset, y: cy - miniCardH / 2 - miniOffset, width: miniCardW, height: miniCardH)
        let frontRect = CGRect(x: cx - miniCardW / 2, y: cy - miniCardH / 2, width: miniCardW, height: miniCardH)
        return """
        \(svgHeader())
          <rect x="\(backRect.minX)" y="\(backRect.minY)" width="\(miniCardW)" height="\(miniCardH)" rx="\(miniCardRadius)" ry="\(miniCardRadius)" fill="#FFFFFF" fill-opacity="0.55" stroke="#FFFFFF" stroke-opacity="0.85" stroke-width="3"/>
          <rect x="\(frontRect.minX)" y="\(frontRect.minY)" width="\(miniCardW)" height="\(miniCardH)" rx="\(miniCardRadius)" ry="\(miniCardRadius)" fill="#FFFFFF"/>
        \(svgFooter())
        """
    }
}

// MARK: - Small-size legibility strip

func generateSmallStrip(name: String, master: CGImage) -> CGImage {
    let sizes = [16, 32, 64, 128]
    let pad: CGFloat = 24
    let rowHeight: CGFloat = 160
    let cellWidth: CGFloat = 176
    let width = Int(cellWidth) * sizes.count + Int(pad) * 2
    let height = Int(rowHeight) * 2 + Int(pad) * 3
    let ctx = makeContext(size: 1) // placeholder, replaced below
    _ = ctx
    let outCtx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    outCtx.interpolationQuality = .high

    // Two backdrop rows: light, then dark.
    let rowColors: [CGColor] = [rgb(0xF2F2F5), rgb(0x1C1C1E)]
    for (row, bgColor) in rowColors.enumerated() {
        let y = height - Int(pad) * (row + 1) - Int(rowHeight) * (row + 1)
        let rowRect = CGRect(x: 0, y: y, width: width, height: Int(rowHeight))
        outCtx.setFillColor(bgColor)
        outCtx.fill(rowRect)
    }

    for (row, _) in rowColors.enumerated() {
        let rowY = height - Int(pad) * (row + 1) - Int(rowHeight) * (row + 1)
        for (i, size) in sizes.enumerated() {
            let small = resize(master, to: size)
            let cellX = Int(pad) + i * Int(cellWidth)
            let drawX = cellX + (Int(cellWidth) - size) / 2
            let drawY = rowY + (Int(rowHeight) - size) / 2
            outCtx.draw(small, in: CGRect(x: drawX, y: drawY, width: size, height: size))
        }
    }
    return outCtx.makeImage()!
}

// MARK: - Comparison sheet

func drawLabel(_ text: String, in ctx: CGContext, rect: CGRect, fontSize: CGFloat, color: NSColor, centered: Bool = true) {
    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = nsContext
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = centered ? .center : .left
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    let attrString = NSAttributedString(string: text, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attrString)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    let x = centered ? rect.midX - bounds.width / 2 : rect.minX
    let y = rect.midY - bounds.height / 2 - bounds.origin.y
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
    NSGraphicsContext.current = previous
}

struct ConceptEntry {
    let displayName: String
    let master1024: CGImage
}

func generateComparisonSheet(entries: [ConceptEntry]) -> CGImage {
    let colWidth: CGFloat = 340
    let pad: CGFloat = 36
    let bigSize: CGFloat = 256
    let smallSize: CGFloat = 32
    let labelHeight: CGFloat = 56
    let width = Int(pad * 2 + colWidth * CGFloat(entries.count))
    let height = Int(pad * 2 + bigSize + 40 + smallSize + labelHeight)

    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high

    // Background: neutral light-to-mid gray so every palette reads fairly.
    ctx.setFillColor(rgb(0xE8E8EC))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for (i, entry) in entries.enumerated() {
        let colX = pad + CGFloat(i) * colWidth
        let bigX = colX + (colWidth - bigSize) / 2
        let bigY = CGFloat(height) - pad - bigSize
        let big = resize(entry.master1024, to: Int(bigSize))
        ctx.draw(big, in: CGRect(x: bigX, y: bigY, width: bigSize, height: bigSize))

        // 32px chip on a small dark card for contrast checking, placed under the big render.
        let chipSize: CGFloat = 72
        let chipX = colX + (colWidth - chipSize) / 2
        let chipY = bigY - 16 - chipSize
        ctx.saveGState()
        ctx.setFillColor(rgb(0x2C2C2E))
        let chipPath = roundedRectPath(CGRect(x: chipX, y: chipY, width: chipSize, height: chipSize), radius: 14)
        ctx.addPath(chipPath)
        ctx.fillPath()
        ctx.restoreGState()
        let small = resize(entry.master1024, to: Int(smallSize))
        ctx.draw(small, in: CGRect(x: chipX + (chipSize - smallSize) / 2, y: chipY + (chipSize - smallSize) / 2, width: smallSize, height: smallSize))

        // Label
        let labelRect = CGRect(x: colX, y: chipY - labelHeight, width: colWidth, height: labelHeight)
        drawLabel(entry.displayName, in: ctx, rect: labelRect, fontSize: 22, color: .black)
        let subRect = CGRect(x: colX, y: chipY - labelHeight - 22, width: colWidth, height: 20)
        drawLabel("256px  /  32px", in: ctx, rect: subRect, fontSize: 13, color: .darkGray)
    }

    return ctx.makeImage()!
}

// MARK: - Driver

func writeConcept(slug: String, displayName: String,
                   flatFn: (Appearance) -> CGImage,
                   backgroundSVG: String,
                   foregroundSVGs: [(String, String)]) -> ConceptEntry {
    let dir = conceptsDir.appendingPathComponent(slug)

    let flatLight = flatFn(.light)
    let flatDark = flatFn(.dark)
    let flatTinted = flatFn(.tinted)

    let previewLight = compositePreview(flat: flatLight)
    let previewDark = compositePreview(flat: flatDark)
    let previewTinted = compositePreview(flat: flatTinted)

    savePNG(previewLight, to: dir.appendingPathComponent("preview-1024.png"))
    savePNG(previewDark, to: dir.appendingPathComponent("preview-dark-1024.png"))
    savePNG(previewTinted, to: dir.appendingPathComponent("preview-tinted-1024.png"))

    saveText(backgroundSVG, to: dir.appendingPathComponent("background.svg"))
    for (name, svg) in foregroundSVGs {
        saveText(svg, to: dir.appendingPathComponent("\(name).svg"))
    }

    let strip = generateSmallStrip(name: slug, master: previewLight)
    savePNG(strip, to: dir.appendingPathComponent("small-size-strip.png"))

    return ConceptEntry(displayName: displayName, master1024: previewLight)
}

print("Generating SnapShelf icon concepts...")

let stackedEntry = writeConcept(
    slug: "stacked-cards",
    displayName: "Stacked Cards",
    flatFn: StackedCards.flat,
    backgroundSVG: StackedCards.backgroundSVG(),
    foregroundSVGs: [
        ("foreground-1-back-cards", StackedCards.foregroundBackSVG()),
        ("foreground-2-front-card", StackedCards.foregroundFrontSVG())
    ]
)

let selectionEntry = writeConcept(
    slug: "selection-shelf",
    displayName: "Selection Shelf",
    flatFn: SelectionShelf.flat,
    backgroundSVG: SelectionShelf.backgroundSVG(),
    foregroundSVGs: [
        ("foreground-1-shelf", SelectionShelf.shelfSVG()),
        ("foreground-2-card", SelectionShelf.cardSVG()),
        ("foreground-3-brackets", SelectionShelf.bracketsSVG())
    ]
)

let viewfinderEntry = writeConcept(
    slug: "viewfinder-tile",
    displayName: "Viewfinder Tile",
    flatFn: ViewfinderTile.flat,
    backgroundSVG: ViewfinderTile.backgroundSVG(),
    foregroundSVGs: [
        ("foreground-1-brackets", ViewfinderTile.bracketsSVG()),
        ("foreground-2-mini-stack", ViewfinderTile.miniStackSVG())
    ]
)

let comparison = generateComparisonSheet(entries: [stackedEntry, selectionEntry, viewfinderEntry])
savePNG(comparison, to: conceptsDir.appendingPathComponent("comparison.png"))

print("Done.")
