import AppKit
import KeyboardShortcuts
import MenuBarExtraAccess
import SwiftData
import SwiftUI

@main
struct SnapShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        let container = AppState.makeSharedModelContainer()
        _appState = State(initialValue: AppState.bootstrap(modelContainer: container))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(appState)
                .environment(appState.thumbnailProvider)
                .modelContainer(appState.modelContainer)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }
        .menuBarExtraAccess(isPresented: Bindable(appState).isMenuPresented)
        .menuBarExtraStyle(.window)

        Window("Library", id: "library") {
            LibraryView()
                .environment(appState)
                .environment(appState.thumbnailProvider)
                .modelContainer(appState.modelContainer)
                .trackingWindowActivation()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1000, height: 680)
        .commands {
            LibraryCommands()
        }

        Window("Welcome to SnapShelf", id: "welcome") {
            WelcomeView()
                .environment(appState)
                .trackingWindowActivation()
        }
        .defaultLaunchBehavior(hasCompletedOnboarding ? .suppressed : .presented)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environment(appState)
                .modelContainer(appState.modelContainer)
                .trackingWindowActivation()
        }
    }
}

/// The `MenuBarExtra` icon view. Unlike the popover content, this is rendered at launch, which is
/// why it — not `MenuBarPanel` — is where we capture `openWindow` for `AppDelegate` to call when
/// the app is reopened from Finder/Spotlight with no windows visible.
private struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "photo.stack")
            .task {
                appState.openLibraryWindow = {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                    openWindow(id: "library")
                }
            }
    }
}
