import Foundation
import Observation
import ServiceManagement

/// Wraps `SMAppService.mainApp` for the "Open SnapShelf at Login" setting. Deliberately doesn't
/// mirror the registration state into `@AppStorage` — `SMAppService.status` is the single source
/// of truth (the user can also flip this from System Settings → Login Items, outside the app).
///
/// Note: a Debug build launched from Xcode registers *DerivedData's* copy of the app as the login
/// item, since that's `Bundle.main` at the time `register()` runs. `status` will still read back
/// correctly, but the binary that actually launches at the next login is the DerivedData one, not
/// whatever you build next — test this setting from a build copied to /Applications.
@MainActor
@Observable
final class LaunchAtLoginService {
    private(set) var status: SMAppService.Status = .notRegistered

    init() {
        refresh()
    }

    /// `SMAppService.status` makes a synchronous XPC call to `launchd`, which can briefly block —
    /// read it off the main actor and publish the result back.
    func refresh() {
        Task.detached {
            let current = SMAppService.mainApp.status
            await MainActor.run { [weak self] in
                self?.status = current
            }
        }
    }

    func register() {
        try? SMAppService.mainApp.register()
        refresh()
    }

    func unregister() {
        try? SMAppService.mainApp.unregister()
        refresh()
    }

    /// `status == .requiresApproval` means macOS needs the user to flip this on in System
    /// Settings themselves — this opens straight to the Login Items pane.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
