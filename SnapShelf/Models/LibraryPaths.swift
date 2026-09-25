import Foundation

/// Centralizes every on-disk location SnapShelf reads from and writes to.
///
/// Layout under `~/Library/Application Support/SnapShelf/`:
/// - `Inbox/` — macOS writes new screenshots here once capture is redirected.
/// - `Library/<uuid>/<original file name>` — imported screenshots, one folder per shot so the
///   original file name survives (drag-out and Finder copies keep a human-readable name).
/// - `SnapShelf.store` — the SwiftData store.
///
/// Screen recordings don't live in the library at all; they're moved to
/// `~/Movies/Screen Recordings`.
///
/// `nonisolated` because this is pure path arithmetic over `FileManager` (itself thread-safe) —
/// it's called from both the main actor (UI, `AppState`) and the `ScreenshotImporter` actor, and
/// has no reason to inherit the project's default main-actor isolation.
nonisolated enum LibraryPaths {
    /// `~/Library/Application Support/SnapShelf`
    static var base: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("SnapShelf", isDirectory: true)
    }

    /// Folder macOS writes new screenshots into once capture is redirected here.
    static var inbox: URL {
        base.appendingPathComponent("Inbox", isDirectory: true)
    }

    /// Folder imported screenshots live in, one subfolder per screenshot.
    static var library: URL {
        base.appendingPathComponent("Library", isDirectory: true)
    }

    /// SwiftData store file.
    static var storeURL: URL {
        base.appendingPathComponent("SnapShelf.store", isDirectory: false)
    }

    /// `~/Movies/Screen Recordings`. Screen recordings are moved here, not into the library.
    static var screenRecordings: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("Screen Recordings", isDirectory: true)
    }

    /// Creates every folder SnapShelf owns if it doesn't already exist. Safe to call repeatedly;
    /// call this once at launch before starting the inbox watcher.
    static func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        for url in [base, inbox, library] {
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    /// Resolves a `Screenshot.fileName` (a `<uuid>/<original name>` relative path) to a full URL.
    static func fileURL(forRelativePath relativePath: String) -> URL {
        library.appendingPathComponent(relativePath)
    }

    /// A URL inside `directory` that doesn't collide with an existing file, creating the folder
    /// first if needed. `directory` defaults to `screenRecordings` (the real
    /// `~/Movies/Screen Recordings`); overridable so tests can point uniquification at a
    /// temporary folder instead of the real one.
    static func uniqueScreenRecordingURL(for fileName: String, in directory: URL = screenRecordings) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let candidateBase = directory.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: candidateBase.path) else { return candidateBase }

        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        var counter = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
