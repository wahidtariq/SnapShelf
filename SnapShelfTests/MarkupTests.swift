import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SnapShelf

@Suite("Markup geometry")
struct MarkupGeometryTests {
    @Test("A rect built from two points is normalised whichever way the drag ran")
    func rectIsNormalised() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(MarkupGeometry.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60)) == expected)
        #expect(MarkupGeometry.rect(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)) == expected)
        #expect(MarkupGeometry.rect(from: CGPoint(x: 40, y: 20), to: CGPoint(x: 10, y: 60)) == expected)
    }

    @Test("An image is aspect-fitted and centered in its container")
    func fittedRectCentersImage() {
        let rect = MarkupGeometry.fittedRect(imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 400, height: 400))
        #expect(rect == CGRect(x: 0, y: 100, width: 400, height: 200))
    }

    @Test("A zero-sized image or container fits to nothing")
    func fittedRectHandlesZeroSizes() {
        #expect(MarkupGeometry.fittedRect(imageSize: .zero, in: CGSize(width: 100, height: 100)) == .zero)
        #expect(MarkupGeometry.fittedRect(imageSize: CGSize(width: 10, height: 10), in: .zero) == .zero)
    }

    @Test("View points map to image pixels and clamp to the image")
    func imagePointScalesAndClamps() {
        let display = CGRect(x: 0, y: 0, width: 100, height: 50)
        let imageSize = CGSize(width: 1000, height: 500)

        #expect(MarkupGeometry.imagePoint(fromView: CGPoint(x: 50, y: 25), displayRect: display, imageSize: imageSize) == CGPoint(x: 500, y: 250))
        #expect(MarkupGeometry.imagePoint(fromView: CGPoint(x: -20, y: 80), displayRect: display, imageSize: imageSize) == CGPoint(x: 0, y: 500))
    }

    @Test("A crop is rounded out to whole pixels and clamped to the image")
    func cropIsPixelAlignedAndClamped() {
        let imageSize = CGSize(width: 100, height: 100)
        #expect(MarkupGeometry.pixelAlignedCrop(CGRect(x: 10.4, y: 10.6, width: 20.2, height: 20.1), imageSize: imageSize) == CGRect(x: 10, y: 10, width: 21, height: 21))
        #expect(MarkupGeometry.pixelAlignedCrop(CGRect(x: 90, y: 90, width: 50, height: 50), imageSize: imageSize) == CGRect(x: 90, y: 90, width: 10, height: 10))
        #expect(MarkupGeometry.pixelAlignedCrop(CGRect(x: 200, y: 200, width: 10, height: 10), imageSize: imageSize) == nil)
    }

    @Test("An arrowhead's tip is the arrow's end, and it stays within half the arrow's length")
    func arrowHeadPointsAtTheEnd() {
        let from = CGPoint(x: 0, y: 0)
        let to = CGPoint(x: 20, y: 0)
        let head = MarkupGeometry.arrowHead(from: from, to: to, lineWidth: 10)

        #expect(head.count == 3)
        #expect(head[0] == to)
        for corner in head.dropFirst() {
            #expect(corner.x >= 10 - 0.001)
            #expect(corner.x < to.x)
        }
    }
}

@Suite("Markup history")
struct MarkupHistoryTests {
    private let annotation = MarkupAnnotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)), color: .red, size: .medium)

    @Test("Undo and redo step through committed edits")
    func undoAndRedo() {
        var history = MarkupHistory()
        history.commit { $0.annotations.append(annotation) }
        #expect(history.document.annotations == [annotation])
        #expect(history.canUndo)

        history.undo()
        #expect(history.document.isEmpty)
        #expect(history.canRedo)

        history.redo()
        #expect(history.document.annotations == [annotation])
        #expect(!history.canRedo)
    }

    @Test("A new edit after an undo clears the redo stack")
    func newEditClearsRedo() {
        var history = MarkupHistory()
        history.commit { $0.annotations.append(annotation) }
        history.undo()
        history.commit { $0.cropRect = CGRect(x: 0, y: 0, width: 5, height: 5) }

        #expect(!history.canRedo)
        #expect(history.document.annotations.isEmpty)
        #expect(history.document.cropRect != nil)
    }

    @Test("A commit that changes nothing isn't recorded")
    func noOpCommitIsIgnored() {
        var history = MarkupHistory()
        history.commit { _ in }
        #expect(!history.canUndo)
    }
}

@Suite("Markup rendering")
struct MarkupRendererTests {
    /// A solid white 200×100 image.
    private func makeImage(width: Int = 200, height: Int = 100) throws -> CGImage {
        let context = try #require(Self.makeContext(width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    /// Checkerboard, so pixelating it visibly changes pixels.
    private func makeCheckerboard(width: Int = 200, height: Int = 100) throws -> CGImage {
        let context = try #require(Self.makeContext(width: width, height: height))
        for x in 0..<width {
            for y in 0..<height {
                let isDark = (x + y).isMultiple(of: 2)
                context.setFillColor(isDark ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try #require(context.makeImage())
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// RGBA bytes of the pixel at (x, y), measured from the top-left.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try #require(Self.makeContext(width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        let offset = (y * image.width + x) * 4
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { bytes[offset + $0] }
    }

    @Test("Exporting with no crop keeps the screenshot's size")
    func exportKeepsSize() throws {
        let renderer = MarkupRenderer(image: try makeImage())
        let output = try #require(renderer.export(MarkupDocument()))
        #expect(output.width == 200)
        #expect(output.height == 100)
    }

    @Test("Exporting with a crop returns just the cropped area")
    func exportAppliesCrop() throws {
        let renderer = MarkupRenderer(image: try makeImage())
        let document = MarkupDocument(cropRect: CGRect(x: 20, y: 10, width: 50, height: 40))
        let output = try #require(renderer.export(document))
        #expect(output.width == 50)
        #expect(output.height == 40)
    }

    @Test("A red rectangle is drawn where it was placed, measured from the top-left")
    func rectangleIsDrawnInPlace() throws {
        let renderer = MarkupRenderer(image: try makeImage())
        // Near the top, so a flipped y-axis would put the stroke near the bottom instead.
        let mark = MarkupAnnotation(kind: .rectangle(CGRect(x: 20, y: 10, width: 100, height: 30)), color: .red, size: .large)
        let output = try #require(renderer.export(MarkupDocument(annotations: [mark])))

        let onStroke = try pixel(output, x: 70, y: 10)
        #expect(onStroke[0] > 200 && onStroke[1] < 100 && onStroke[2] < 100)

        let inside = try pixel(output, x: 70, y: 25)
        #expect(inside == [255, 255, 255, 255])
    }

    @Test("Pixelating changes pixels inside its box and nothing outside")
    func blurStaysInsideItsBox() throws {
        let image = try makeCheckerboard()
        let renderer = MarkupRenderer(image: image)
        let mark = MarkupAnnotation(kind: .blur(CGRect(x: 0, y: 0, width: 100, height: 100)), color: .red, size: .medium)
        let output = try #require(renderer.export(MarkupDocument(annotations: [mark])))

        // Inside: neighbours that differed in the checkerboard now share one pixel block.
        // (50 and 51 fall in the same 12px block, which starts at 48.)
        #expect(try pixel(image, x: 50, y: 50) != pixel(image, x: 51, y: 50))
        #expect(try pixel(output, x: 50, y: 50) == pixel(output, x: 51, y: 50))

        // Outside: still exactly the checkerboard.
        #expect(try pixel(output, x: 150, y: 50) == pixel(image, x: 150, y: 50))
    }

    @Test("The PNG export decodes back to the exported size")
    func pngExportIsValid() throws {
        let renderer = MarkupRenderer(image: try makeImage())
        let data = try #require(renderer.exportPNG(MarkupDocument(cropRect: CGRect(x: 0, y: 0, width: 30, height: 20))))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 30)
        #expect(decoded.height == 20)
    }
}
