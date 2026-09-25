import AppKit
import SwiftUI

/// SnapShelf is `LSUIElement` (no Dock icon, no app menu) by default. Whenever a real window —
/// Library, Welcome, or Settings — is open, the app needs to become a regular, activatable app so
/// that window behaves normally (gets focus, shows in the Dock/⌘-Tab, has a menu bar). This
/// tracks how many such windows are currently open and flips `NSApp.activationPolicy` at zero.
@MainActor
final class ActivationPolicy {
    static let shared = ActivationPolicy()

    private var openWindowCount = 0

    private init() {}

    func windowDidAppear() {
        openWindowCount += 1
        updatePolicy()
    }

    func windowDidDisappear() {
        openWindowCount = max(0, openWindowCount - 1)
        updatePolicy()
    }

    private func updatePolicy() {
        if openWindowCount > 0 {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// Applies `ActivationPolicy` tracking to a window's root view.
private struct ActivationPolicyTracking: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { ActivationPolicy.shared.windowDidAppear() }
            .onDisappear { ActivationPolicy.shared.windowDidDisappear() }
    }
}

extension View {
    /// Marks this view's window as one that should keep the app in `.regular` activation policy
    /// (Dock icon, ⌘-Tab, menu bar) while it's open. Apply to the root view of every `Window` and
    /// `Settings` scene.
    func trackingWindowActivation() -> some View {
        modifier(ActivationPolicyTracking())
    }
}
