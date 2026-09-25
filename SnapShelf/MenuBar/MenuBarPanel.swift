import AppKit
import SwiftData
import SwiftUI

/// The `MenuBarExtra(.window)` popover content: header with status + quick actions, a scrollable
/// 3-column grid of every non-deleted screenshot, keyboard navigation, and a "Copied" toast.
struct MenuBarPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @Query(screenshotsDescriptor) private var screenshots: [Screenshot]

    @FocusState private var isPanelFocused: Bool
    @State private var selectedIndex: Int?

    private static let screenshotsDescriptor: FetchDescriptor<Screenshot> = {
        FetchDescriptor<Screenshot>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
    }()

    // MARK: - Grid sizing

    // These are `nonisolated` — plain compile-time constants — so `gridHeight(forCount:)` below
    // can be `nonisolated` too and stay callable (and unit-testable) without hopping to the main
    // actor for what's just arithmetic.
    nonisolated private static let panelWidth: CGFloat = 380
    nonisolated private static let horizontalPadding: CGFloat = 16
    nonisolated private static let columnCount = 3
    nonisolated private static let gridSpacing: CGFloat = 8
    nonisolated private static let tileAspectRatio: CGFloat = 16.0 / 10.0
    /// Rows visible before the grid caps and starts scrolling. The ".5" leaves the next row
    /// half-visible, which hints that there's more to scroll to.
    nonisolated private static let visibleRows: CGFloat = 4.5

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: Self.columnCount)

    /// The scrollable grid's ideal height for `count` tiles: full rows of a `tileAspectRatio`
    /// tile (width derived from `panelWidth` minus its padding and the gaps between
    /// `columnCount` columns) stacked with `gridSpacing` between them, capped at `visibleRows`.
    /// `MenuBarExtra(.window)` sizes its window from the content's *ideal* size, and a bare
    /// `ScrollView` has no intrinsic height to report there — so this feeds an explicit
    /// `.frame(height:)` instead. Pure and `nonisolated` so the row math is unit-testable
    /// without rendering a view.
    nonisolated static func gridHeight(forCount count: Int) -> CGFloat {
        guard count > 0 else { return 0 }

        let contentWidth = panelWidth - horizontalPadding * 2
        let tileWidth = (contentWidth - gridSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        let tileHeight = tileWidth / tileAspectRatio

        let rows = Int((Double(count) / Double(columnCount)).rounded(.up))
        let contentHeight = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gridSpacing

        let maxGridHeight = visibleRows * tileHeight + (visibleRows - 1) * gridSpacing
        return min(contentHeight, maxGridHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .frame(width: Self.panelWidth)
        // Without this, the window measures its height against whatever the `MenuBarExtra`
        // window proposes rather than the content's own ideal height — the empty state and the
        // grid have very different ideal heights, so the window would either clip the taller one
        // or leave dead space under the shorter one.
        .fixedSize(horizontal: false, vertical: true)
        .background { windowDragArea }
        .background { HostingWindowReader { appState.menuBarWindowPositioner.attach(to: $0) } }
        .overlay(alignment: .bottom) {
            if let toast = appState.copiedToast {
                CopiedToast(message: toast)
                    .padding(.bottom, 12)
            }
        }
        .animation(.default, value: appState.copiedToast)
        .background(hiddenKeyboardShortcuts)
        .focusable(true)
        .focusEffectDisabled()
        .focused($isPanelFocused)
        .onAppear {
            isPanelFocused = true
            appState.captureLocationService.refresh()
        }
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -3) }
        .onKeyPress(.downArrow) { moveSelection(by: 3) }
        .onKeyPress(.return) { copySelected() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SnapShelf")
                    .font(.headline)
                statusLine
            }

            Spacer()

            Button {
                activateAndOpen { openWindow(id: "library") }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .buttonStyle(.plain)
            .help("Open Library")
            .accessibilityLabel("Open Library")

            Menu {
                Button("Open Library") {
                    activateAndOpen { openWindow(id: "library") }
                }
                Divider()
                captureToggleItem
                Divider()
                Button("Settings…") {
                    activateAndOpen { openSettings() }
                }
                Button("Quit & Restore Desktop Saving") {
                    appState.captureLocationService.restore()
                    NSApp.terminate(nil)
                }
                Divider()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More")
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    @ViewBuilder
    private var statusLine: some View {
        switch appState.captureLocationService.status {
        case .savingToSnapShelf:
            Text("Saving to SnapShelf")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .savingToDesktop:
            Button("Saving to Desktop — Turn On") {
                appState.captureLocationService.enable()
            }
            .buttonStyle(.link)
            .font(.caption)
        case .savingElsewhere(let url):
            Text("Saving elsewhere (\(url.lastPathComponent))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The popover's ⋯ menu's Pause/Resume item: it flips between the two save locations,
    /// mirroring the toolbar action in Settings → Capture.
    @ViewBuilder
    private var captureToggleItem: some View {
        switch appState.captureLocationService.status {
        case .savingToSnapShelf:
            Button("Save Screenshots to Desktop") {
                appState.captureLocationService.restore()
            }
        case .savingToDesktop, .savingElsewhere:
            Button("Save Screenshots to SnapShelf") {
                appState.captureLocationService.enable()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if screenshots.isEmpty {
            emptyState
        } else {
            // `MenuBarExtra(.window)` sizes itself to the content's *ideal* height, and a bare
            // `ScrollView`'s ideal height collapses to ~0 there — it has no intrinsic content
            // size to report, so the popover would render empty. `gridHeight(forCount:)` gives
            // it an explicit height instead: the popover stays compact for a few screenshots and
            // caps out (scrolling) once there are many.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(Array(screenshots.enumerated()), id: \.element.id) { index, screenshot in
                            ScreenshotTile(
                                screenshot: screenshot,
                                isSelected: selectedIndex == index,
                                onCopy: { selectedIndex = index; copy(screenshot) },
                                onToggleFavorite: { screenshot.isFavorite.toggle() },
                                onDelete: { screenshot.deletedAt = Date() }
                            )
                            .id(screenshot.id)
                        }
                    }
                    .background { windowDragArea }
                }
                .scrollIndicators(.automatic)
                .frame(height: Self.gridHeight(forCount: screenshots.count))
                // Keeps arrow-key/⌘1–9 selection visible as it moves past the capped, scrollable
                // grid's visible rows.
                .onChange(of: selectedIndex) { _, newValue in
                    guard let newValue, screenshots.indices.contains(newValue) else { return }
                    proxy.scrollTo(screenshots[newValue].id)
                }
            }
        }
    }

    // `ContentUnavailableView` reports no useful ideal height inside a `MenuBarExtra` window, so
    // the window measured it too short and left a stale empty-state box behind when screenshots
    // arrived. This custom layout has a real ideal height instead.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.stack")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text("No Screenshots Yet")
                .font(.headline)
            Text("Press ⇧⌘4 to take a screenshot — it'll appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if appState.captureLocationService.status != .savingToSnapShelf {
                Button("Save Screenshots to SnapShelf") {
                    appState.captureLocationService.enable()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    // MARK: - Moving the popover

    /// Drags the whole popover from any spot that isn't a tile or a control. Tiles sit on top of
    /// this, so their click-to-copy and file drag-out are unaffected. `MenuBarWindowPositioner`
    /// puts the popover back under the menu bar icon when it closes.
    private var windowDragArea: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }

    // MARK: - Keyboard

    /// Invisible buttons carrying the ⌘1–9 and ⌘⌫ shortcuts — `Button.keyboardShortcut` routes
    /// through the responder chain regardless of visibility, which is more reliable here than
    /// trying to disambiguate modified key presses inside `onKeyPress`.
    private var hiddenKeyboardShortcuts: some View {
        Group {
            ForEach(1...9, id: \.self) { number in
                Button("") { copyTile(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            Button("") { deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !screenshots.isEmpty else { return .ignored }
        let current = selectedIndex ?? -1
        selectedIndex = min(max(current + delta, 0), screenshots.count - 1)
        return .handled
    }

    private func copySelected() -> KeyPress.Result {
        guard let index = selectedIndex, screenshots.indices.contains(index) else { return .ignored }
        copy(screenshots[index])
        return .handled
    }

    private func copyTile(number: Int) {
        let index = number - 1
        guard screenshots.indices.contains(index) else { return }
        selectedIndex = index
        copy(screenshots[index])
    }

    private func deleteSelected() {
        guard let index = selectedIndex, screenshots.indices.contains(index) else { return }
        screenshots[index].deletedAt = Date()
    }

    // MARK: - Actions

    private func copy(_ screenshot: Screenshot) {
        appState.pasteboardService.copy([screenshot])
        appState.showCopiedToast()
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            appState.isMenuPresented = false
        }
    }

    private func activateAndOpen(_ action: () -> Void) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        action()
        appState.isMenuPresented = false
    }
}
