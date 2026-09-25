import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// How the importer sorts a file it finds in the inbox.
///
/// `nonisolated` because `classify` is pure and needs to be callable synchronously from both the
/// main actor (`InboxWatcher`) and the `ScreenshotImporter` actor, with no dependency on either.
nonisolated enum ImportKind: Equatable {
    case image
    case movie
    case ignore

    /// Pure and static so it's trivially unit-testable and callable from any isolation context.
    static func classify(_ url: URL) -> ImportKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .ignore }
        if type.conforms(to: .image) || type.conforms(to: .pdf) {
            return .image
        }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            return .movie
        }
        return .ignore
    }
}

/// Moves files out of the inbox: images become library entries, movies go to
/// `~/Movies/Screen Recordings`, anything else is left alone. Runs off the main actor so decoding
/// image properties never blocks the UI; all writes go through one shared `ModelContainer` so
/// `@Query` in the UI sees new imports immediately.
@ModelActor
actor ScreenshotImporter {
    private let textRecognitionService = TextRecognitionService()

    /// Imports every ready URL from the inbox, one at a time. `libraryRoot` and
    /// `screenRecordingsRoot` default to the real `LibraryPaths` locations; overridable so tests
    /// can point imports at temporary folders instead.
    func importFiles(
        at urls: [URL],
        libraryRoot: URL = LibraryPaths.library,
        screenRecordingsRoot: URL = LibraryPaths.screenRecordings
    ) async {
        for url in urls {
            importFile(at: url, libraryRoot: libraryRoot, screenRecordingsRoot: screenRecordingsRoot)
        }
    }

    /// Imports raw image data directly into the library, bypassing the inbox — used by
    /// clipboard-paste and drag-and-drop import in the Library window. `libraryRoot` defaults to
    /// the real `LibraryPaths.library`; overridable so tests can point it at a temporary folder.
    @discardableResult
    func importImage(data: Data, suggestedName: String, libraryRoot: URL = LibraryPaths.library) throws -> PersistentIdentifier {
        let id = UUID()
        let fileName = suggestedName.lowercased().hasSuffix(".png") ? suggestedName : "\(suggestedName).png"

        let destinationDirectory = libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent(fileName)

        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try data.write(to: destinationURL)

        let (pixelWidth, pixelHeight) = Self.pixelSize(of: destinationURL)

        let id2 = try insertScreenshot(
            id: id,
            createdAt: Date(),
            relativeFileName: "\(id.uuidString)/\(fileName)",
            originalName: (fileName as NSString).deletingPathExtension,
            contentType: UTType.png.identifier,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteSize: data.count
        )
        queueTextRecognition(for: id2)
        return id2
    }

    /// Copies an external file (Desktop cleanup, drag-and-drop) into the library, preserving its
    /// original name and creation date. Unlike `importFile(at:)`, the source is left in place —
    /// callers decide what happens to it (Desktop cleanup trashes it; drag-and-drop just leaves it).
    ///
    /// This is the `ExternalFileImporting` witness, so it keeps the protocol's exact single-argument
    /// signature (a default-valued second parameter wouldn't satisfy the protocol requirement) and
    /// delegates to the `libraryRoot:` overload below, supplying the real library.
    @discardableResult
    func importExternalFile(at url: URL) throws -> PersistentIdentifier {
        try importExternalFile(at: url, libraryRoot: LibraryPaths.library)
    }

    /// Test seam for `importExternalFile(at:)` — production always goes through the overload
    /// above, which supplies `LibraryPaths.library`.
    @discardableResult
    func importExternalFile(at url: URL, libraryRoot: URL) throws -> PersistentIdentifier {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let createdAt = (attributes?[.creationDate] as? Date) ?? Date()
        let byteSize = (attributes?[.size] as? Int) ?? 0

        let id = UUID()
        let originalName = url.deletingPathExtension().lastPathComponent
        let contentType = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        let (pixelWidth, pixelHeight) = Self.pixelSize(of: url)

        let destinationDirectory = libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent(url.lastPathComponent)

        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: destinationURL)

        let insertedID = try insertScreenshot(
            id: id,
            createdAt: createdAt,
            relativeFileName: "\(id.uuidString)/\(url.lastPathComponent)",
            originalName: originalName,
            contentType: contentType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteSize: byteSize
        )
        queueTextRecognition(for: insertedID)
        return insertedID
    }

    /// Runs Vision text recognition for one screenshot and writes the result back through this
    /// actor's `modelContext`. Called fire-and-forget after every import (`queueTextRecognition`)
    /// and serially, in a loop, from `backfillTextRecognition()` at launch.
    func recognizeText(for id: PersistentIdentifier) async {
        guard let screenshot = modelContext.model(for: id) as? Screenshot else { return }
        let text = (try? await textRecognitionService.recognizeText(in: screenshot.fileURL)) ?? ""
        screenshot.recognizedText = text
        screenshot.isTextRecognized = true
        try? modelContext.save()
    }

    /// Launch-time catch-up for rows that were imported before text recognition finished (app
    /// quit mid-recognition) or before this feature existed. Serial by design — Vision requests
    /// are already expensive enough per image that concurrency isn't worth the complexity here.
    func backfillTextRecognition() async {
        let descriptor = FetchDescriptor<Screenshot>(
            predicate: #Predicate<Screenshot> { $0.isTextRecognized == false && $0.deletedAt == nil }
        )
        guard let pending = try? modelContext.fetch(descriptor) else { return }
        for screenshot in pending {
            await recognizeText(for: screenshot.persistentModelID)
        }
    }

    /// Fires text recognition on a separate `Task` so import (insert + save, which is what the UI
    /// is waiting on) never blocks on Vision. The task re-enters this same actor via `await self`,
    /// so recognition still runs serially relative to other importer work.
    private func queueTextRecognition(for id: PersistentIdentifier) {
        Task { [weak self] in
            await self?.recognizeText(for: id)
        }
    }

    private func importFile(at url: URL, libraryRoot: URL, screenRecordingsRoot: URL) {
        switch ImportKind.classify(url) {
        case .image:
            importImageFile(at: url, libraryRoot: libraryRoot)
        case .movie:
            importMovieFile(at: url, screenRecordingsRoot: screenRecordingsRoot)
        case .ignore:
            break
        }
    }

    private func importImageFile(at url: URL, libraryRoot: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }

        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let createdAt = (attributes?[.creationDate] as? Date) ?? Date()
        let byteSize = (attributes?[.size] as? Int) ?? 0

        let id = UUID()
        let originalName = url.deletingPathExtension().lastPathComponent
        let contentType = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        let (pixelWidth, pixelHeight) = Self.pixelSize(of: url)

        let destinationDirectory = libraryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent(url.lastPathComponent)

        do {
            try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: destinationURL)
        } catch {
            return
        }

        guard let id2 = try? insertScreenshot(
            id: id,
            createdAt: createdAt,
            relativeFileName: "\(id.uuidString)/\(url.lastPathComponent)",
            originalName: originalName,
            contentType: contentType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteSize: byteSize
        ) else { return }
        queueTextRecognition(for: id2)
    }

    /// Shared insert-and-save for the three import entry points above.
    @discardableResult
    private func insertScreenshot(
        id: UUID,
        createdAt: Date,
        relativeFileName: String,
        originalName: String,
        contentType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        byteSize: Int
    ) throws -> PersistentIdentifier {
        let screenshot = Screenshot(
            id: id,
            createdAt: createdAt,
            fileName: relativeFileName,
            originalName: originalName,
            contentType: contentType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            byteSize: byteSize
        )
        modelContext.insert(screenshot)
        try modelContext.save()
        return screenshot.persistentModelID
    }

    private func importMovieFile(at url: URL, screenRecordingsRoot: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        guard let destination = try? LibraryPaths.uniqueScreenRecordingURL(for: url.lastPathComponent, in: screenRecordingsRoot) else {
            return
        }
        try? fm.moveItem(at: url, to: destination)
    }

    /// Reads pixel dimensions without decoding full image data: ImageIO for raster images, the
    /// first page's media box for PDFs.
    private static func pixelSize(of url: URL) -> (width: Int, height: Int) {
        if url.pathExtension.lowercased() == "pdf" {
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) else {
                return (0, 0)
            }
            let box = page.getBoxRect(.mediaBox)
            return (Int(box.width), Int(box.height))
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (0, 0)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return (width, height)
    }
}

/// `importExternalFile(at:)` is actor-isolated and synchronous, which Swift allows to satisfy an
/// `async` protocol requirement — every cross-actor call already implicitly awaits.
extension ScreenshotImporter: ExternalFileImporting {}
