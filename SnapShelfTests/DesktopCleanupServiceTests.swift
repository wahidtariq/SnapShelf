import Foundation
import Testing
@testable import SnapShelf

/// `cleanUp(_:)` is intentionally not tested here: its image branch trashes through
/// `FileManager.trashItem` (the real Trash — `fileManager` is injectable, but redirecting a
/// system-trash call safely would need a risky `FileManager` subclass), and its movie branch
/// resolves through `LibraryPaths.uniqueScreenRecordingURL(for:)` with no root override, which
/// lands in the real `~/Movies/Screen Recordings`. Only the pure, directory-injected scanning
/// logic is covered below.
@Suite("DesktopCleanupService")
struct DesktopCleanupServiceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShelfTests-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(
        "isScreenshot falls back to the file-name heuristic",
        arguments: [
            ("Screenshot 2026-09-24 at 10.15.03.png", true),
            ("Screen Shot 2019-01-02 at 3.04.05 PM.png", true),
            ("Report.png", false),
            ("Screenshot notes.txt", false)
        ]
    )
    func isScreenshotUsesNameFallback(name: String, expected: Bool) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))

        // Temp files carry no `kMDItemIsScreenCapture` Spotlight attribute, so this exercises the
        // name-based fallback rather than the primary MDItem signal.
        #expect(DesktopCleanupService.isScreenshot(url) == expected)
    }

    @Test
    func scanSplitsImagesAndMoviesIgnoresOthersAndDoesNotRecurse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        let imageURL = dir.appendingPathComponent("Screenshot 2026-09-24 at 10.15.03.png")
        let movieURL = dir.appendingPathComponent("Screen Shot 2026-09-24 at 10.16.00.mov")
        let otherURL = dir.appendingPathComponent("Report.png")
        let subdir = dir.appendingPathComponent("Sub", isDirectory: true)
        try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
        let nestedURL = subdir.appendingPathComponent("Screenshot 2026-09-24 at 10.17.00.png")

        fm.createFile(atPath: imageURL.path, contents: Data("img".utf8))
        fm.createFile(atPath: movieURL.path, contents: Data("mov".utf8))
        fm.createFile(atPath: otherURL.path, contents: Data("other".utf8))
        fm.createFile(atPath: nestedURL.path, contents: Data("nested".utf8))

        let result = DesktopCleanupService.scan(in: dir)

        #expect(result.images.map(\.lastPathComponent) == [imageURL.lastPathComponent])
        #expect(result.movies.map(\.lastPathComponent) == [movieURL.lastPathComponent])
        #expect(result.total == 2)
    }

    @Test
    func scanOfAnEmptyOrMissingDirectoryReturnsAnEmptyResult() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelfTests-missing-\(UUID().uuidString)")
        let result = DesktopCleanupService.scan(in: missing)
        #expect(result.isEmpty)
    }
}
