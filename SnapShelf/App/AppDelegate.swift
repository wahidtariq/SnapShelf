import AppKit

/// Bridges AppKit lifecycle events into `AppState`. `AppState.shared` is set from
/// `SnapShelfApp.init()`, which runs before AppKit delivers `applicationDidFinishLaunching` — see
/// the comment on `AppState.shared` for why this indirection exists instead of injecting a
/// reference directly.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // The SnapShelfTests target hosts inside this app, so it launches on every test run.
        // `start()` has real side effects (watches the real inbox, sweeps retention against the
        // real store, registers a global shortcut) that must never run under test — it must never
        // call `enable()`/`restore()` either, and it doesn't. The single-instance check below must
        // be skipped for the same reason: under test there may be a real, developer-launched
        // SnapShelf.app running, and it must not be activated or have this test host quit it out
        // from under the test runner.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // See SingleInstanceCoordinator for why this differs between Release and Debug.
        SingleInstanceCoordinator.resolve()

        AppState.shared?.start()
    }

    /// Reopening SnapShelf from Finder or Spotlight (with no visible windows) opens the Library,
    /// so the app stays usable even if the menu bar icon is hidden or hard to find.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppState.shared?.openLibraryWindow?()
        }
        return true
    }
}
