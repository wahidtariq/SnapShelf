import AppKit
import SwiftUI

/// The subset of `ScreenshotGrid`/`LibraryView`'s selection-driven actions that also need to be
/// reachable from the menu bar (Screenshot menu, View menu, ⌘0). Published as a focused scene
/// value so `LibraryCommands` can reach whichever Library window is currently key without a
/// singleton or a direct view reference.
struct LibraryActions {
    var hasSelection: Bool
    /// Markup edits one screenshot at a time, and not ones in Recently Deleted.
    var canMarkup: Bool
    var markup: () -> Void
    var quickLook: () -> Void
    var openInPreview: () -> Void
    var toggleFavorite: () -> Void
    var moveToRecentlyDeleted: () -> Void
    var toggleInspector: () -> Void
    var increaseThumbnailSize: () -> Void
    var decreaseThumbnailSize: () -> Void
}

private struct LibraryActionsKey: FocusedValueKey {
    typealias Value = LibraryActions
}

extension FocusedValues {
    var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
    }
}

/// Menu bar commands for the Library window: a "Screenshot" menu mirroring the toolbar/context
/// menu actions, thumbnail-size shortcuts in the View menu, and "Open Library" for reopening the
/// window from a menu-bar-only app. Every action routes through `@FocusedValue` so it's disabled
/// (rather than doing nothing) when no Library window has focus or nothing is selected.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryActions) private var actions
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Screenshot") {
            // No key equivalent: Space is handled in-grid, where Quick Look's paging needs focus.
            Button("Quick Look") { actions?.quickLook() }
                .disabled(!(actions?.hasSelection ?? false))

            Button("Open in Preview") { actions?.openInPreview() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!(actions?.hasSelection ?? false))

            Button("Markup…") { actions?.markup() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!(actions?.canMarkup ?? false))

            Button("Add to Favorites") { actions?.toggleFavorite() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!(actions?.hasSelection ?? false))

            Button("Move to Recently Deleted") { actions?.moveToRecentlyDeleted() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!(actions?.hasSelection ?? false))

            Divider()

            Button("Show Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Increase Thumbnail Size") { actions?.increaseThumbnailSize() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions == nil)
            Button("Decrease Thumbnail Size") { actions?.decreaseThumbnailSize() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions == nil)
        }

        CommandGroup(after: .newItem) {
            Button("Open Library") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
                openWindow(id: "library")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
