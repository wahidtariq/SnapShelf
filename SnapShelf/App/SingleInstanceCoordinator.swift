import AppKit

/// Two copies built to different DerivedData folders (e.g. Xcode vs. the installed
/// `/Applications` copy) share the same bundle identifier but run as separate processes — if both
/// launch, both watch the inbox and race each other to import the same files. Exactly one
/// instance may run at a time.
///
/// Release keeps the simple rule: whichever instance launches second loses, and activates the
/// first instead of starting up alongside it. Debug flips it, since once the Release copy is
/// always running from `/Applications`, that rule would make every Xcode ⌘R activate the
/// installed copy and quit itself immediately. So in Debug, the newest instance wins — it asks
/// every other instance to quit and takes over.
///
/// The quit request travels over `DistributedNotificationCenter` rather than
/// `NSRunningApplication.terminate()`, because sending an Apple Event to another app (which
/// `terminate()` does under the hood) can trigger an Automation permission prompt.
@MainActor
enum SingleInstanceCoordinator {
    // Plain Sendable constants, so they stay readable from the nonisolated notification closure
    // below without needing to hop onto MainActor first.
    private nonisolated static let quitRequestNotification = Notification.Name("dev.wahidtariq.SnapShelf.quitRequest")
    private nonisolated static let requesterPIDKey = "requesterPID"

    /// Called once at launch, before `AppState.start()`. In Release, may terminate the app here
    /// and never return.
    static func resolve() {
        observeQuitRequests()

        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = runningInstances(bundleID: bundleID, excludingPID: currentPID)
        guard !others.isEmpty else { return }

        #if DEBUG
        requestQuit(currentPID: currentPID)
        waitForExit(bundleID: bundleID, currentPID: currentPID)
        #else
        others.first?.activate()
        NSApp.terminate(nil)
        #endif
    }

    /// Every instance — Release and Debug — listens for this, so a newly launched Debug copy can
    /// ask any other running copy, including the installed Release copy, to step aside.
    private static func observeQuitRequests() {
        // `addObserver(using:)`'s closure type is nonisolated regardless of the actor it's
        // declared in, so pull the Sendable payload out here; `queue: .main` guarantees the
        // closure itself is invoked on the main thread, so `assumeIsolated` is safe for the rest.
        DistributedNotificationCenter.default().addObserver(
            forName: quitRequestNotification, object: nil, queue: .main
        ) { notification in
            let requesterPID = (notification.userInfo?[requesterPIDKey] as? Int).map(pid_t.init)
            MainActor.assumeIsolated {
                guard let requesterPID, requesterPID != ProcessInfo.processInfo.processIdentifier else { return }
                NSApp.terminate(nil)
            }
        }
    }

    private static func runningInstances(bundleID: String, excludingPID currentPID: pid_t) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
    }

    #if DEBUG
    private static func requestQuit(currentPID: pid_t) {
        DistributedNotificationCenter.default().postNotificationName(
            quitRequestNotification,
            object: nil,
            userInfo: [requesterPIDKey: Int(currentPID)],
            deliverImmediately: true
        )
    }

    /// Blocks briefly during launch rather than making `resolve()` async — simplest way to give
    /// the other instances a moment to act on the quit request before this one starts watching the
    /// inbox alongside them.
    private static func waitForExit(bundleID: String, currentPID: pid_t) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !runningInstances(bundleID: bundleID, excludingPID: currentPID).isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    #endif
}
