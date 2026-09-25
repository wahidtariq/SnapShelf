import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Opens or closes the menu bar popover. Recordable by the user in Settings → General.
    static let togglePanel = Self("togglePanel", default: .init(.s, modifiers: [.command, .option]))
}
