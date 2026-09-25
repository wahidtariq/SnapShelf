import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Draws a screenshot with its markup. The editor's canvas and the exported PNG both go through
/// `draw(_:pending:in:)`, so what you see while editing is exactly what gets saved.
///
/// Every drawing call expects a context whose units are image pixels with a top-left origin
/// (y pointing down) — the editor gets that from SwiftUI's `Canvas` plus a scale, and `export`
/// flips a bitmap context to match.
final class MarkupRenderer {
    let image: CGImage
    let imageSize: CGSize

    /// The whole screenshot pixelated once, up front; each blur region just draws the matching
    /// part of it, so dragging a blur box stays cheap.
    private lazy var pixelatedImage: CGImage? = Self.makePixelated(image)

    init(image: CGImage) {
        self.image = image
        self.imageSize = CGSize(width: image.width, height: image.height)
    }

    /// `pending` is the mark currently being dragged out, drawn on top without being committed.
    func draw(_ document: MarkupDocument, pending: MarkupAnnotation? = nil, in context: CGContext) {
        let fullRect = CGRect(origin: .zero, size: imageSize)
        Self.drawImage(image, in: fullRect, context: context)

        let annotations = document.annotations + (pending.map { [$0] } ?? [])

        // Blurs hide what's in the screenshot itself, so they go under every other mark.
        if let pixelatedImage {
            for annotation in annotations {
                guard case .blur(let rect) = annotation.kind else { continue }
                context.saveGState()
                context.clip(to: rect)
                Self.drawImage(pixelatedImage, in: fullRect, context: context)
                context.restoreGState()
            }
        }

        for annotation in annotations {
            drawMark(annotation, in: context)
        }
    }

    /// The final image: markup flattened onto the screenshot, then cropped.
    func export(_ document: MarkupDocument) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        draw(document, in: context)

        guard let flattened = context.makeImage() else { return nil }
        guard let cropRect = document.cropRect,
              let crop = MarkupGeometry.pixelAlignedCrop(cropRect, imageSize: imageSize) else { return flattened }
        // `CGImage.cropping(to:)` measures from the top-left, matching the document's coordinates.
        return flattened.cropping(to: crop)
    }

    func exportPNG(_ document: MarkupDocument) -> Data? {
        guard let image = export(document) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: - Marks

    private func drawMark(_ annotation: MarkupAnnotation, in context: CGContext) {
        let lineWidth = MarkupGeometry.lineWidth(for: annotation.size, imageSize: imageSize)
        let color = annotation.color.cgColor

        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.kind {
        case .arrow(let from, let to):
            let head = MarkupGeometry.arrowHead(from: from, to: to, lineWidth: lineWidth)
            // The shaft stops at the head's base so its round cap doesn't poke through the tip.
            let headBase = CGPoint(x: (head[1].x + head[2].x) / 2, y: (head[1].y + head[2].y) / 2)
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.move(to: from)
            context.addLine(to: headBase)
            context.strokePath()

            context.setFillColor(color)
            context.move(to: head[0])
            context.addLine(to: head[1])
            context.addLine(to: head[2])
            context.closePath()
            context.fillPath()

        case .rectangle(let rect):
            // `CGPath(roundedRect:)` traps if the radius exceeds half a side, so tiny boxes clamp it.
            let radius = min(lineWidth, rect.width / 2, rect.height / 2)
            context.setStrokeColor(color)
            context.setLineWidth(lineWidth)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()

        case .highlight(let points):
            guard let first = points.first else { return }
            context.setStrokeColor(color.copy(alpha: 0.4) ?? color)
            context.setLineWidth(lineWidth * 4)
            context.move(to: first)
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
            // A single click still leaves a dot.
            if points.count == 1 { context.addLine(to: first) }
            context.strokePath()

        case .text(let string, let origin):
            drawText(string, at: origin, annotation: annotation, in: context)

        case .blur:
            break
        }
    }

    private func drawText(_ string: String, at origin: CGPoint, annotation: MarkupAnnotation, in context: CGContext) {
        let fontSize = MarkupGeometry.fontSize(for: annotation.size, imageSize: imageSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor(cgColor: annotation.color.cgColor) ?? .red,
            .strokeColor: NSColor(cgColor: annotation.color.textOutline) ?? .white,
            // Negative means fill *and* stroke, giving the text an outline.
            .strokeWidth: -4.0,
        ]
        // `flipped: true` tells AppKit the context is already y-down, so text comes out upright.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: string, attributes: attributes).draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Helpers

    /// `CGContext.draw` assumes a y-up context, so flip locally to keep the image upright.
    private static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func makePixelated(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        // Clamped first so blocks along the edges don't average in transparent pixels.
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(12, CGFloat(max(image.width, image.height)) / 60))
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }
}
