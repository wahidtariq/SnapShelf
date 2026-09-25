import CoreServices
import Foundation
import SwiftData

/// Something that can copy an external file into the library — narrowed from `ScreenshotImporter`
/// so `DesktopCleanupService` can be driven by a fake in tests instead of a real `ModelContainer`.
protocol ExternalFileImporting: Sendable {
    @discardableResult
    func importExternalFile(at url: URL) async throws -> PersistentIdentifier
}

/// Finds screenshots sitting on the Desktop and moves them into SnapShelf. Scanning only ever
/// happens in direct response to the user clicking "Clean Up Desktop…" — reading `~/Desktop`'s
/// contents is what triggers macOS's Desktop-folder privacy prompt, so this must never run
/// automatically (not on appear, not on a timer).
@MainActor
final class DesktopCleanupService {
    /// What a scan found, split by what happens to each kind on cleanup.
    struct ScanResult: Equatable {
        var images: [URL] = []
        var movies: [URL] = []

        var isEmpty: Bool { images.isEmpty && movies.isEmpty }
        var total: Int { images.count + movies.count }
    }

    /// What cleanup actually did, for the confirmation-follow-up summary.
    struct CleanupSummary: Equatable {
        var importedImageCount = 0
        var movedMovieCount = 0
        var failureCount = 0
    }

    private let desktopURL: URL
    private let fileManager: FileManager
    private let importer: ExternalFileImporting

    init(
        desktopURL: URL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default,
        importer: ExternalFileImporting
    ) {
        self.desktopURL = desktopURL
        self.fileManager = fileManager
        self.importer = importer
    }

    /// Scans `~/Desktop` (non-recursively) for screenshots. Call this only from the "Clean Up
    /// Desktop…" button handler.
    func scanDesktop() -> ScanResult {
        Self.scan(in: desktopURL, fileManager: fileManager)
    }

    /// Imports every found image (copy, then Trash the original) and moves every found movie into
    /// `~/Movies/Screen Recordings`. The Trash is used, not permanent deletion, so a mis-scan is
    /// always recoverable.
    func cleanUp(_ result: ScanResult) async -> CleanupSummary {
        var summary = CleanupSummary()

        for url in result.images {
            do {
                try await importer.importExternalFile(at: url)
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                summary.importedImageCount += 1
            } catch {
                summary.failureCount += 1
            }
        }

        for url in result.movies {
            do {
                let destination = try LibraryPaths.uniqueScreenRecordingURL(for: url.lastPathComponent)
                try fileManager.moveItem(at: url, to: destination)
                summary.movedMovieCount += 1
            } catch {
                summary.failureCount += 1
            }
        }

        return summary
    }

    // MARK: - Pure scanning (testable, directory injected)

    /// `nonisolated` and static so this — the part with actual classification logic — is callable
    /// and testable independent of the main actor and of a real Desktop folder.
    nonisolated static func scan(in directory: URL, fileManager: FileManager = .default) -> ScanResult {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            return ScanResult()
        }

        var result = ScanResult()
        for url in entries where isScreenshot(url) {
            switch ImportKind.classify(url) {
            case .image: result.images.append(url)
            case .movie: result.movies.append(url)
            case .ignore: break
            }
        }
        return result
    }

    /// Primary signal: the `kMDItemIsScreenCapture` Spotlight attribute macOS tags every ⇧⌘3/4/5
    /// capture with. That attribute name isn't part of the public `MDItem.h` constants, so it's
    /// passed as a raw string rather than a (nonexistent) Swift symbol.
    ///
    /// Fallback (attribute missing or `false` — e.g. a screenshot that's been re-saved by another
    /// app): the file's name starts with "Screenshot " or "Screen Shot ", the way macOS names them
    /// in every region, and it's an image or movie.
    nonisolated static func isScreenshot(_ url: URL) -> Bool {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let isCapture = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool {
            return isCapture
        }

        let name = url.lastPathComponent
        guard name.hasPrefix("Screenshot ") || name.hasPrefix("Screen Shot ") else { return false }
        return ImportKind.classify(url) != .ignore
    }
}
