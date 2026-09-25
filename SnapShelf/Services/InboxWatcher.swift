import AppKit
import Foundation
import ImageIO

/// Watches `LibraryPaths.inbox` for new files, waits for writes to settle, then hands ready URLs
/// to `onFilesReady`. Also rescans on start, whenever the Mac wakes, and on a light safety timer
/// — so shots that land while the app is closed or missed by FSEvents still get picked up.
@MainActor
final class InboxWatcher {
    private let inboxURL: URL
    private let onFilesReady: ([URL]) -> Void

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceTask: Task<Void, Never>?
    private var safetyTimerTask: Task<Void, Never>?
    // `NSObjectProtocol` observer tokens aren't Sendable, but this one is only ever touched from
    // the main actor except in `deinit` (which runs nonisolated) — `nonisolated(unsafe)` reflects
    // that instead of fighting the compiler over a token that's safe to pass to
    // `removeObserver(_:)` from any thread.
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?

    /// Paths currently being handed off to the importer, so a rescan doesn't hand them off twice.
    private var inFlightPaths: Set<String> = []

    private let debounceInterval: Duration = .milliseconds(300)
    private let safetyInterval: Duration = .seconds(30)
    private let settleInterval: Duration = .milliseconds(250)

    init(inboxURL: URL = LibraryPaths.inbox, onFilesReady: @escaping ([URL]) -> Void) {
        self.inboxURL = inboxURL
        self.onFilesReady = onFilesReady
    }

    deinit {
        source?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func start() {
        startWatchingFileSystem()
        observeWake()
        startSafetyTimer()
        scheduleRescan()
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        safetyTimerTask?.cancel()
        safetyTimerTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    /// Called once the importer has finished with a URL (moved, or left in place as unsupported),
    /// so it can be picked up again in the (rare) case it's still sitting in the inbox.
    func markComplete(_ url: URL) {
        inFlightPaths.remove(url.path)
    }

    private func startWatchingFileSystem() {
        let fd = open(inboxURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.scheduleRescan()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    private func observeWake() {
        // `queue: .main` guarantees this runs on the main thread at runtime, but
        // `NotificationCenter`'s handler parameter type is `nonisolated @Sendable`, so the
        // compiler can't verify that statically — hop back onto the main actor explicitly before
        // touching `self`.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRescan()
            }
        }
    }

    private func startSafetyTimer() {
        safetyTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.safetyInterval)
                guard !Task.isCancelled else { return }
                self.scheduleRescan()
            }
        }
    }

    private func scheduleRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self.rescan()
        }
    }

    private func rescan() async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var ready: [URL] = []
        for url in entries {
            if url.lastPathComponent.hasPrefix(".") { continue }
            if inFlightPaths.contains(url.path) { continue }

            if await isFileReady(url) {
                inFlightPaths.insert(url.path)
                ready.append(url)
            }
        }

        if !ready.isEmpty {
            onFilesReady(ready)
        }
    }

    /// A file is "done" once its size is stable across two reads ~250ms apart and — for images —
    /// ImageIO reports it as fully decodable. This avoids importing a screenshot mid-write.
    private func isFileReady(_ url: URL) async -> Bool {
        let fm = FileManager.default
        guard let size1 = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size1 > 0 else {
            return false
        }
        try? await Task.sleep(for: settleInterval)
        guard let size2 = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size1 == size2 else {
            return false
        }

        if ImportKind.classify(url) == .image {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceGetStatus(source) == .statusComplete
        }
        return true
    }
}
