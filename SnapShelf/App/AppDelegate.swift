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

        terminateIfAnotherInstanceIsRunning()

        AppState.shared?.start()
    }

    /// Two copies built to different DerivedData folders (e.g. Xcode vs. a CI build) share the
    /// same bundle identifier but run as separate processes — if both launch, both watch the
    /// inbox and race each other to import the same files. When another instance is already
    /// running, bring it forward and quit this one instead of starting up alongside it.
    private func terminateIfAnotherInstanceIsRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        guard let other = others.first else { return }

        other.activate()
        NSApp.terminate(nil)
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
