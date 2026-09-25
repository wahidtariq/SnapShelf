import AppKit
import SwiftUI

/// Lets the menu bar popover be dragged anywhere on screen, then puts it back under the menu bar
/// icon when it closes, so it always reopens in the usual place.
///
/// Records the popover's top-left just before the first move of each presentation and restores
/// it when the window resigns key — the one thing every dismissal (click outside, ⌥⌘S, copying a
/// tile, opening the Library) has in common. Top-left rather than origin because the popover is
/// top-anchored and its height changes as screenshots arrive.
@MainActor
final class MenuBarWindowPositioner {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var homeTopLeft: NSPoint?
    /// Set while restoring, so the restore's own move isn't recorded as the next home.
    private var isRestoring = false

    func attach(to window: NSWindow) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        homeTopLeft = nil

        // `MenuBarExtra` windows aren't movable by default, and `WindowDragGesture` respects that.
        window.isMovable = true

        // `queue: .main` delivers on the main thread, so `assumeIsolated` is safe.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willMoveNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recordHomeIfNeeded() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreHome() }
            },
        ]
    }

    private func recordHomeIfNeeded() {
        guard !isRestoring, homeTopLeft == nil, let window else { return }
        homeTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    private func restoreHome() {
        guard let home = homeTopLeft, let window else { return }
        homeTopLeft = nil
        isRestoring = true
        window.setFrameTopLeftPoint(home)
        isRestoring = false
    }
}

/// Hands back the `NSWindow` hosting this view as soon as the view is placed in one.
struct HostingWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        private let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
