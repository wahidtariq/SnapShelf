#!/usr/bin/env xcrun swift
//
//  generate_final.swift
//  SnapShelf icon design — stage 2 final-asset renderer.
//
//  Renders the approved "viewfinder-tile" concept's refined layers as flat,
//  undecorated, unmasked 1024x1024 transparent PNGs for hand-authoring
//  SnapShelf/Resources/AppIcon.icon. No squircle mask, no drop shadow, no
//  glass highlight baked in — Icon Composer / the system applies all of
//  that from icon.json's group settings. Also renders a same-process
//  16/32/64/128px legibility strip so the screenshot-hint details (title
//  bar band, mountain, sun) can be sanity-checked before hand-authoring
//  the .icon bundle and running ictool.
//
//  Run with: xcrun swift design/icon/generate_final.swift
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
let finalDir = iconDir.appendingPathComponent("final")

// MARK: - Color helpers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

func white(_ alpha: CGFloat) -> CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: alpha) }
func black(_ alpha: CGFloat) -> CGColor { CGColor(red: 0, green: 0, blue: 0, alpha: alpha) }

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
    // Non-atomic: an atomic write (temp file + swap) trips the sandbox's
    // "Operation not permitted" even though this directory is writable.
    try? data.write(to: url, options: [])
    print("wrote \(url.path)")
    return url
}

func resize(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = makeContext(size: size)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// MARK: - Geometry helpers

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

/// A rect with only the top-left/top-right corners rounded (`radius`) and a
/// flat bottom edge at `minY + height`. Used for the front card's title-bar
/// band: when `height == radius` the band's bottom edge lands exactly where
/// the card's own corner arcs finish curving into its vertical sides, so the
/// band reads as a clean cap on the card rather than a separately-edged box.
func topRoundedRectPath(rect: CGRect, radius: CGFloat, height: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let r = rect
    let bandBottom = r.minY + height
    path.move(to: CGPoint(x: r.minX, y: bandBottom))
    path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
    path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
    path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
    path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
    path.addLine(to: CGPoint(x: r.maxX, y: bandBottom))
    path.closeSubpath()
    return path
}

/// A closed polygon with each vertex rounded by its own radius, using a
/// quadratic curve toward the original vertex as control point (cheap,
/// good-enough "rounded polygon" trick at icon scale — no true circular
/// arcs needed). `radii[i]` rounds `points[i]`.
func roundedPolygonPath(points: [CGPoint], radii: [CGFloat]) -> CGPath {
    let path = CGMutablePath()
    let n = points.count
    func pt(_ i: Int) -> CGPoint { points[(i + n) % n] }
    func radius(_ i: Int) -> CGFloat { radii[(i + n) % n] }
    for i in 0..<n {
        let curr = pt(i)
        let prev = pt(i - 1)
        let next = pt(i + 1)
        let r = radius(i)
        let toPrev = CGVector(dx: prev.x - curr.x, dy: prev.y - curr.y)
        let toNext = CGVector(dx: next.x - curr.x, dy: next.y - curr.y)
        let lenPrev = max(hypot(toPrev.dx, toPrev.dy), 0.0001)
        let lenNext = max(hypot(toNext.dx, toNext.dy), 0.0001)
        let rClamped = min(r, lenPrev * 0.5, lenNext * 0.5)
        let p1 = CGPoint(x: curr.x + toPrev.dx / lenPrev * rClamped, y: curr.y + toPrev.dy / lenPrev * rClamped)
        let p2 = CGPoint(x: curr.x + toNext.dx / lenNext * rClamped, y: curr.y + toNext.dy / lenNext * rClamped)
        if i == 0 {
            path.move(to: p1)
        } else {
            path.addLine(to: p1)
        }
        path.addQuadCurve(to: p2, control: curr)
    }
    path.closeSubpath()
    return path
}

enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

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

// MARK: - Canvas constant

let CANVAS: CGFloat = 1024

/// Runs `draw` in a top-left-origin, y-down coordinate space over the full
/// 1024x1024 canvas, transparent unless `draw` paints over it. No mask, no
/// shadow, no highlight sweep — these are raw layer assets for Icon
/// Composer; the system's Liquid Glass settings in icon.json add all of
/// that at render time.
func flatCanvas(_ draw: (CGContext, CGRect) -> Void) -> CGImage {
    let ctx = makeContext(size: Int(CANVAS))
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CANVAS)
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx, CGRect(x: 0, y: 0, width: CANVAS, height: CANVAS))
    ctx.restoreGState()
    return ctx.makeImage()!
}

// MARK: ======================================================================
// MARK: Viewfinder Tile — final geometry
// MARK: ======================================================================

enum Final {
    // Background gradient stops (used for our own local preview only — the
    // real .icon defines these via icon.json's fill-specializations, no PNG).
    static let bgLight: (UInt32, UInt32) = (0x0EA5A0, 0x0891B2)
    static let bgDark: (UInt32, UInt32) = (0x053B3D, 0x073B4C)

    // Brackets — pulled in from v1's 10%/28%/7.2% margin/arm/width so the
    // silhouette (including round-cap bleed) sits within roughly the
    // central 78% of the canvas, with a touch shorter arms.
    static let bracketMargin: CGFloat = CANVAS * 0.14    // 143.36
    static let bracketArm: CGFloat = CANVAS * 0.235      // 240.64
    static let bracketWidth: CGFloat = CANVAS * 0.065    // 66.56

    // Mini card stack — unchanged from v1; it was already comfortably
    // central, only the brackets were crowding the edge.
    static let cardW: CGFloat = CANVAS * 0.33            // 337.92
    static let cardH: CGFloat = CANVAS * 0.40             // 409.6
    static let cardRadius: CGFloat = CANVAS * 0.06        // 61.44
    static let cardOffset: CGFloat = CANVAS * 0.05        // 51.2

    // Front-card screenshot hint, in card-local (0,0)-(cardW,cardH) coords.
    static let bandHeight: CGFloat = cardRadius // seams flush with the card's own corner rounding
    static let bandColor = rgb(bgLight.0, 0.28) // pale teal over white
    static let mountainColor = rgb(bgLight.0, 1.0)
    static let sunColor = rgb(bgLight.1, 1.0)

    static func cardRect(cx: CGFloat, cy: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CGRect {
        CGRect(x: cx - cardW / 2 + dx, y: cy - cardH / 2 + dy, width: cardW, height: cardH)
    }

    // MARK: Layers

    static func bracketsLayer() -> CGImage {
        flatCanvas { ctx, rect in
            for corner: Corner in [.topLeft, .topRight, .bottomLeft, .bottomRight] {
                ctx.saveGState()
                ctx.setStrokeColor(white(1))
                ctx.setLineWidth(bracketWidth)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.addPath(bracketPath(corner: corner, canvas: rect, margin: bracketMargin, armLength: bracketArm))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }

    static func backCardLayer() -> CGImage {
        flatCanvas { ctx, rect in
            let cx = rect.midX, cy = rect.midY
            let r = cardRect(cx: cx, cy: cy, dx: -cardOffset, dy: -cardOffset)
            ctx.addPath(roundedRectPath(r, radius: cardRadius))
            ctx.setFillColor(white(1))
            ctx.fillPath()
        }
    }

    static func frontCardLayer() -> CGImage {
        flatCanvas { ctx, rect in
            let cx = rect.midX, cy = rect.midY
            let r = cardRect(cx: cx, cy: cy)

            // Card base.
            ctx.addPath(roundedRectPath(r, radius: cardRadius))
            ctx.setFillColor(white(1))
            ctx.fillPath()

            // Title-bar band — reads as "screenshot", not blank paper.
            ctx.saveGState()
            ctx.addPath(roundedRectPath(r, radius: cardRadius))
            ctx.clip()
            ctx.addPath(topRoundedRectPath(rect: r, radius: cardRadius, height: bandHeight))
            ctx.setFillColor(bandColor)
            ctx.fillPath()
            ctx.restoreGState()

            // Landscape motif in card-local coordinates, translated into place.
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY)
            let W = cardW, H = cardH
            let padding = W * 0.09
            let bodyBottomY = H - padding
            let bodyTopY = bandHeight
            let baseW = W * 0.66
            let baseLeftX = (W - baseW) / 2
            let baseRightX = baseLeftX + baseW
            let peakHeight = (bodyBottomY - bodyTopY) * 0.55
            let apexY = bodyBottomY - peakHeight
            let apexX = W / 2

            let mountainPoints = [
                CGPoint(x: baseLeftX, y: bodyBottomY),
                CGPoint(x: apexX, y: apexY),
                CGPoint(x: baseRightX, y: bodyBottomY)
            ]
            let mountainRadii: [CGFloat] = [W * 0.02, W * 0.06, W * 0.02]
            ctx.addPath(roundedPolygonPath(points: mountainPoints, radii: mountainRadii))
            ctx.setFillColor(mountainColor)
            ctx.fillPath()

            let sunR = W * 0.085
            let sunCX = W * 0.68
            let sunCY = bodyTopY + (apexY - bodyTopY) * 0.42
            ctx.addEllipse(in: CGRect(x: sunCX - sunR, y: sunCY - sunR, width: sunR * 2, height: sunR * 2))
            ctx.setFillColor(sunColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    // MARK: Local preview compositor (sanity check only — not shipped)

    static func preview(appearance bg: (UInt32, UInt32), brackets: CGImage, back: CGImage, front: CGImage) -> CGImage {
        let ctx = makeContext(size: Int(CANVAS))
        let scale: CGFloat = 0.90
        let radius = (CANVAS * scale) / 2
        let center = CGPoint(x: CANVAS / 2, y: CANVAS / 2)
        let squircle = superellipsePath(center: center, radius: radius, exponent: 4.8)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: black(0.38))
        ctx.addPath(squircle)
        ctx.setFillColor(black(1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let inset = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        // Background gradient.
        drawLinearGradient(ctx: ctx, path: nil, colors: [rgb(bg.0), rgb(bg.1)], locations: [0, 1],
                            start: CGPoint(x: inset.minX, y: inset.minY), end: CGPoint(x: inset.maxX, y: inset.maxY))

        ctx.draw(brackets, in: inset)
        ctx.saveGState()
        ctx.setAlpha(0.55)
        ctx.draw(back, in: inset)
        ctx.restoreGState()
        ctx.draw(front, in: inset)
        ctx.restoreGState()

        // Edge stroke + glass sweep, matching stage-1 mockups.
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let cs = CGColorSpaceCreateDeviceRGB()
        let hiColors = [white(0.32), white(0.0)]
        let hiGradient = CGGradient(colorsSpace: cs, colors: hiColors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(hiGradient, start: CGPoint(x: center.x, y: center.y - radius), end: CGPoint(x: center.x, y: center.y - radius * 0.15), options: [])
        ctx.addPath(squircle)
        ctx.setStrokeColor(white(0.14))
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()

        return ctx.makeImage()!
    }
}

// MARK: - Small-size legibility strip

func generateSmallStrip(master: CGImage) -> CGImage {
    let sizes = [16, 32, 64, 128]
    let pad: CGFloat = 24
    let rowHeight: CGFloat = 160
    let cellWidth: CGFloat = 176
    let width = Int(cellWidth) * sizes.count + Int(pad) * 2
    let height = Int(rowHeight) + Int(pad) * 2
    let outCtx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    outCtx.interpolationQuality = .high
    outCtx.setFillColor(rgb(0xF2F2F5))
    outCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let rowY = height - Int(pad) - Int(rowHeight)
    for (i, size) in sizes.enumerated() {
        let small = resize(master, to: size)
        let cellX = Int(pad) + i * Int(cellWidth)
        let drawX = cellX + (Int(cellWidth) - size) / 2
        let drawY = rowY + (Int(rowHeight) - size) / 2
        outCtx.draw(small, in: CGRect(x: drawX, y: drawY, width: size, height: size))
    }
    return outCtx.makeImage()!
}

// MARK: - Driver

print("Generating SnapShelf final icon layers (viewfinder-tile)...")

let brackets = Final.bracketsLayer()
let backCard = Final.backCardLayer()
let frontCard = Final.frontCardLayer()

savePNG(brackets, to: finalDir.appendingPathComponent("brackets.png"))
savePNG(backCard, to: finalDir.appendingPathComponent("card-back.png"))
savePNG(frontCard, to: finalDir.appendingPathComponent("card-front.png"))

let previewLight = Final.preview(appearance: Final.bgLight, brackets: brackets, back: backCard, front: frontCard)
let previewDark = Final.preview(appearance: Final.bgDark, brackets: brackets, back: backCard, front: frontCard)
savePNG(previewLight, to: finalDir.appendingPathComponent("local-preview-1024.png"))
savePNG(previewDark, to: finalDir.appendingPathComponent("local-preview-dark-1024.png"))

let strip = generateSmallStrip(master: previewLight)
savePNG(strip, to: finalDir.appendingPathComponent("local-small-size-strip.png"))

print("Done.")
