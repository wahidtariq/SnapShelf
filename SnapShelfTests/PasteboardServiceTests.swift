import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SnapShelf

@Suite("PasteboardService")
struct PasteboardServiceTests {
    private func makeLibraryRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShelfTests-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A private, uniquely-named pasteboard — never `.general`.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("SnapShelfTests.\(UUID().uuidString)"))
    }

    private func makeBitmap(size: (Int, Int)) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size.0,
            pixelsHigh: size.1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: size.0, height: size.1).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @discardableResult
    private func writeScreenshot(
        named fileName: String,
        contentType: String,
        format: NSBitmapImageRep.FileType,
        libraryRoot: URL
    ) throws -> (screenshot: Screenshot, fileData: Data) {
        let relativeDir = UUID().uuidString
        let directory = libraryRoot.appendingPathComponent(relativeDir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let relativePath = "\(relativeDir)/\(fileName)"
        let fileURL = libraryRoot.appendingPathComponent(relativePath)

        let data = try #require(makeBitmap(size: (4, 4)).representation(using: format, properties: [:]))
        try data.write(to: fileURL)

        let screenshot = Screenshot(
            createdAt: .now,
            fileName: relativePath,
            originalName: (fileName as NSString).deletingPathExtension,
            contentType: contentType,
            pixelWidth: 4,
            pixelHeight: 4,
            byteSize: data.count
        )
        return (screenshot, data)
    }

    @Test
    func copyingAPNGBackedScreenshotWritesPNGTIFFAndFileURLTypes() throws {
        let libraryRoot = try makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let (screenshot, pngData) = try writeScreenshot(
            named: "shot.png", contentType: UTType.png.identifier, format: .png, libraryRoot: libraryRoot
        )

        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        PasteboardService().copy([screenshot], to: pasteboard, libraryRoot: libraryRoot)

        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.types.contains(.png))
        #expect(item.types.contains(.tiff))
        #expect(item.types.contains(.fileURL))
        #expect(item.data(forType: .png) == pngData)
    }

    @Test
    func copyingAJPEGBackedScreenshotStillGetsPNGData() throws {
        let libraryRoot = try makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let (screenshot, _) = try writeScreenshot(
            named: "shot.jpg", contentType: UTType.jpeg.identifier, format: .jpeg, libraryRoot: libraryRoot
        )

        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        PasteboardService().copy([screenshot], to: pasteboard, libraryRoot: libraryRoot)

        let item = try #require(pasteboard.pasteboardItems?.first)
        let pngData = try #require(item.data(forType: .png))
        // PNG signature bytes — confirms real PNG-encoded data, not a pass-through of the JPEG bytes.
        #expect(pngData.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(item.types.contains(.tiff))
    }

    @Test
    func aMissingFileWritesNoItemsButStillClearsThePasteboard() throws {
        let libraryRoot = try makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let screenshot = Screenshot(
            createdAt: .now,
            fileName: "\(UUID().uuidString)/missing.png",
            originalName: "missing",
            contentType: UTType.png.identifier,
            pixelWidth: 1,
            pixelHeight: 1,
            byteSize: 0
        )

        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("sentinel", forType: .string)

        PasteboardService().copy([screenshot], to: pasteboard, libraryRoot: libraryRoot)

        // `copy` calls `clearContents()` unconditionally before resolving any file, so a missing
        // file still clears whatever was on the pasteboard — it just writes no replacement items.
        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test
    func copyingTwoScreenshotsWritesTwoItems() throws {
        let libraryRoot = try makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let (first, _) = try writeScreenshot(named: "one.png", contentType: UTType.png.identifier, format: .png, libraryRoot: libraryRoot)
        let (second, _) = try writeScreenshot(named: "two.png", contentType: UTType.png.identifier, format: .png, libraryRoot: libraryRoot)

        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        PasteboardService().copy([first, second], to: pasteboard, libraryRoot: libraryRoot)

        #expect(pasteboard.pasteboardItems?.count == 2)
    }
}
