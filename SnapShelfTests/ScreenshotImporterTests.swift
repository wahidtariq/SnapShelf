import AppKit
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import SnapShelf

@Suite("ScreenshotImporter")
struct ScreenshotImporterTests {
    /// In-memory container — never the real `SnapShelf.store`.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Screenshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShelfTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writePNGFile(named name: String, in directory: URL, size: (Int, Int) = (8, 6)) throws -> URL {
        let url = directory.appendingPathComponent(name)
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
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: size.0, height: size.1).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }

    private func samplePNGData(size: (Int, Int) = (4, 4)) throws -> Data {
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
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: size.0, height: size.1).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test
    func importingAPNGMovesItIntoTheLibraryAndInsertsAScreenshot() async throws {
        let container = try makeContainer()
        let importer = ScreenshotImporter(modelContainer: container)
        let sourceDir = try makeTempDir("source")
        let libraryRoot = try makeTempDir("library")
        let recordingsRoot = try makeTempDir("recordings")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: recordingsRoot)
        }

        let sourceURL = try writePNGFile(named: "Screenshot Test.png", in: sourceDir, size: (8, 6))

        await importer.importFiles(at: [sourceURL], libraryRoot: libraryRoot, screenRecordingsRoot: recordingsRoot)

        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))

        let rows = try container.mainContext.fetch(FetchDescriptor<Screenshot>())
        let inserted = try #require(rows.first)

        #expect(rows.count == 1)
        #expect(inserted.originalName == "Screenshot Test")
        #expect(inserted.pixelWidth == 8)
        #expect(inserted.pixelHeight == 6)
        #expect(inserted.contentType == UTType.png.identifier)
        #expect(inserted.byteSize > 0)
        #expect(inserted.fileName.hasSuffix("/Screenshot Test.png"))

        let expectedURL = libraryRoot.appendingPathComponent(inserted.fileName)
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    @Test
    func importingAMovieMovesItToRecordingsNotLibraryAndUniquifiesCollisions() async throws {
        let container = try makeContainer()
        let importer = ScreenshotImporter(modelContainer: container)
        let sourceDir = try makeTempDir("source")
        let libraryRoot = try makeTempDir("library")
        let recordingsRoot = try makeTempDir("recordings")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: recordingsRoot)
        }

        let collidingName = "Screen Recording.mov"
        try Data("existing".utf8).write(to: recordingsRoot.appendingPathComponent(collidingName))

        let movURL = sourceDir.appendingPathComponent(collidingName)
        try Data("movie-bytes".utf8).write(to: movURL)

        await importer.importFiles(at: [movURL], libraryRoot: libraryRoot, screenRecordingsRoot: recordingsRoot)

        #expect(!FileManager.default.fileExists(atPath: movURL.path))

        let uniquified = recordingsRoot.appendingPathComponent("Screen Recording 2.mov")
        #expect(FileManager.default.fileExists(atPath: uniquified.path))

        let libraryContents = try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path)
        #expect(libraryContents.isEmpty)

        let rows = try container.mainContext.fetch(FetchDescriptor<Screenshot>())
        #expect(rows.isEmpty)
    }

    @Test
    func aTextFileIsLeftInPlaceAndNothingIsInserted() async throws {
        let container = try makeContainer()
        let importer = ScreenshotImporter(modelContainer: container)
        let sourceDir = try makeTempDir("source")
        let libraryRoot = try makeTempDir("library")
        let recordingsRoot = try makeTempDir("recordings")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: recordingsRoot)
        }

        let txtURL = sourceDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: txtURL)

        await importer.importFiles(at: [txtURL], libraryRoot: libraryRoot, screenRecordingsRoot: recordingsRoot)

        #expect(FileManager.default.fileExists(atPath: txtURL.path))
        let rows = try container.mainContext.fetch(FetchDescriptor<Screenshot>())
        #expect(rows.isEmpty)
    }

    @Test(arguments: ["Pasted Image", "Pasted Image.png", "Pasted Image.PNG"])
    func importImageAppendsPNGExtensionOnlyWhenMissing(suggestedName: String) async throws {
        let container = try makeContainer()
        let importer = ScreenshotImporter(modelContainer: container)
        let libraryRoot = try makeTempDir("library")
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let pngData = try samplePNGData()
        let id = try await importer.importImage(data: pngData, suggestedName: suggestedName, libraryRoot: libraryRoot)

        let screenshot = try #require(container.mainContext.model(for: id) as? Screenshot)
        #expect(screenshot.fileName.lowercased().hasSuffix(".png"))
        #expect(!screenshot.fileName.lowercased().hasSuffix(".png.png"))
    }

    @Test
    func importExternalFileCopiesLeavingTheSourceInPlace() async throws {
        let container = try makeContainer()
        let importer = ScreenshotImporter(modelContainer: container)
        let sourceDir = try makeTempDir("source")
        let libraryRoot = try makeTempDir("library")
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: libraryRoot)
        }

        let sourceURL = try writePNGFile(named: "External.png", in: sourceDir)

        let id = try await importer.importExternalFile(at: sourceURL, libraryRoot: libraryRoot)

        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        let screenshot = try #require(container.mainContext.model(for: id) as? Screenshot)
        let destinationURL = libraryRoot.appendingPathComponent(screenshot.fileName)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    }
}
