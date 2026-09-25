import Foundation
import KeyboardShortcuts
import Observation
import SwiftData

/// Owns every long-lived service and the transient UI state the menu bar popover and windows
/// share. One instance is created in `SnapShelfApp.init()` and injected into the view hierarchy
/// via `.environment(_:)`.
@MainActor
@Observable
final class AppState {
    /// Set once from `SnapShelfApp.init()`, which runs before AppKit delivers
    /// `applicationDidFinishLaunching`. `AppDelegate` is constructed by
    /// `@NSApplicationDelegateAdaptor` without any way for us to hand it a reference directly, so
    /// it reads this instead.
    static private(set) var shared: AppState?

    let modelContainer: ModelContainer
    let captureLocationService: CaptureLocationService
    let thumbnailProvider: ThumbnailProvider
    let launchAtLoginService = LaunchAtLoginService()
    let pasteboardService = PasteboardService()
    let menuBarWindowPositioner = MenuBarWindowPositioner()

    private let importer: ScreenshotImporter
    private var inboxWatcher: InboxWatcher?

    /// Depends on `importer` (via `ExternalFileImporting`), which must already be assigned before
    /// this is constructed — kept as the last property initialized below.
    let retentionService: RetentionService
    let desktopCleanupService: DesktopCleanupService

    var isMenuPresented = false
    var copiedToast: String?

    /// Captured from the `MenuBarExtra` label view's `openWindow` environment action (that view
    /// is rendered at launch, unlike the popover content). Lets `AppDelegate` open the Library
    /// window on Dock reopen without a view of its own to read the environment from.
    var openLibraryWindow: (() -> Void)?

    /// `captureLocationService` defaults to the real `com.apple.screencapture` domain; overridable
    /// so tests can inject one backed by a fake preferences store instead — nothing in
    /// `AppState.init` may otherwise touch the real preferences domain.
    init(modelContainer: ModelContainer, captureLocationService: CaptureLocationService = CaptureLocationService()) {
        self.modelContainer = modelContainer
        self.captureLocationService = captureLocationService
        self.thumbnailProvider = ThumbnailProvider()
        let importer = ScreenshotImporter(modelContainer: modelContainer)
        self.importer = importer

        self.retentionService = RetentionService(modelContainer: modelContainer) { screenshots, context in
            AppState.permanentlyDelete(screenshots, modelContext: context)
        }
        self.desktopCleanupService = DesktopCleanupService(importer: importer)

        // Created last: its closure captures `self` weakly, which Swift only allows once every
        // stored property above has a value.
        self.inboxWatcher = InboxWatcher { [weak self] urls in
            self?.handleReadyFiles(urls)
        }
    }

    /// Creates and registers the shared instance. Call once, from `SnapShelfApp.init()`.
    @discardableResult
    static func bootstrap(modelContainer: ModelContainer) -> AppState {
        let state = AppState(modelContainer: modelContainer)
        shared = state
        return state
    }

    /// The `ModelContainer` backing store lives under `LibraryPaths.base`, so its parent folder
    /// must exist first.
    ///
    /// The `SnapShelfTests` target hosts inside this app, so this runs on every test launch too.
    /// Under test, an in-memory container is used instead — the test host must never open (and
    /// thereby contend for, or migrate) the user's real on-disk store, and must never create the
    /// real `Inbox`/`Library` folders under `~/Library/Application Support/SnapShelf`.
    static func makeSharedModelContainer() -> ModelContainer {
        let schema = Schema([Screenshot.self])

        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("SnapShelf couldn't create its in-memory test ModelContainer: \(error)")
            }
        }

        try? LibraryPaths.ensureDirectoriesExist()
        let configuration = ModelConfiguration(schema: schema, url: LibraryPaths.storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("SnapShelf couldn't create its ModelContainer at \(LibraryPaths.storeURL.path): \(error)")
        }
    }

    /// Ensures on-disk folders exist, starts watching the inbox, registers the global shortcut,
    /// and starts the retention sweep and text-recognition backfill. Called once from
    /// `AppDelegate.applicationDidFinishLaunching`.
    func start() {
        try? LibraryPaths.ensureDirectoriesExist()
        inboxWatcher?.start()
        retentionService.start()

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.isMenuPresented.toggle()
        }

        Task { [importer] in
            await importer.backfillTextRecognition()
        }
    }

    private func handleReadyFiles(_ urls: [URL]) {
        Task {
            await importer.importFiles(at: urls)
            for url in urls {
                inboxWatcher?.markComplete(url)
            }
        }
    }

    /// Shows a transient "Copied" confirmation in the popover, clearing itself after ~1s.
    func showCopiedToast(_ message: String = "Copied") {
        copiedToast = message
        Task {
            try? await Task.sleep(for: .seconds(1))
            if copiedToast == message {
                copiedToast = nil
            }
        }
    }

    // MARK: - Import (Library paste / drag-and-drop / Desktop cleanup)

    /// Imports raw image data (e.g. from the pasteboard) into the library. Exposed here because
    /// the Library window has no reason to talk to the actor-isolated importer directly.
    @discardableResult
    func importImage(data: Data, suggestedName: String) async throws -> PersistentIdentifier {
        try await importer.importImage(data: data, suggestedName: suggestedName)
    }

    /// Copies an external file (drag-and-drop, Desktop cleanup) into the library.
    @discardableResult
    func importExternalFile(at url: URL) async throws -> PersistentIdentifier {
        try await importer.importExternalFile(at: url)
    }

    // MARK: - Hard delete

    /// Removes a screenshot's on-disk `Library/<uuid>/` folder and its model row for good. Shared
    /// by the Library's "Delete Immediately" / "Empty Recently Deleted…" actions and
    /// `RetentionService`'s Recently Deleted purge, so there's exactly one place that does this.
    /// `static` so `RetentionService` can be wired up to it from inside `AppState.init` before
    /// `self` is fully initialized.
    static func permanentlyDelete(_ screenshots: [Screenshot], modelContext: ModelContext) {
        guard !screenshots.isEmpty else { return }
        let fm = FileManager.default
        for screenshot in screenshots {
            let folder = LibraryPaths.library.appendingPathComponent(screenshot.id.uuidString, isDirectory: true)
            try? fm.removeItem(at: folder)
            modelContext.delete(screenshot)
        }
        try? modelContext.save()
    }
}
