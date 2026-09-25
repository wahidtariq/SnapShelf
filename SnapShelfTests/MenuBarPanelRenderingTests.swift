import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import SnapShelf

/// Visual regression coverage for the popover tile-overflow / stale-empty-state fix: renders
/// `MenuBarPanel` with `ImageRenderer` into a PNG and asserts it comes out non-empty, since
/// neither XCTest nor Swift Testing has a SwiftUI layout inspector — the actual "did it overflow"
/// judgment is made by a human `Read`ing the PNGs this writes to
/// `FileManager.default.temporaryDirectory`, not by an in-process assertion.
///
/// `ScreenshotThumbnail` loads its image asynchronously via `.task(id:)`, which `ImageRenderer`
/// doesn't wait for — so each screenshot's `ThumbnailProvider` cache entry is pre-warmed with a
/// real, already-decoded image (see `ThumbnailProvider.preloadForTesting`) instead of relying on
/// the snapshot renderer to await a disk read that may never finish before it samples the view.
@Suite("MenuBarPanel rendering")
@MainActor
struct MenuBarPanelRenderingTests {
    /// In-memory stand-in for `com.apple.screencapture` so this never touches the real domain —
    /// mirrors `CaptureLocationServiceTests`'s fake, redeclared here since that one is file-private.
    private final class FakeScreenCapturePreferences: ScreenCapturePreferences {
        private var storage: [String: Any] = [:]
        func value(forKey key: String) -> Any? { storage[key] }
        func setValue(_ value: Any?, forKey key: String) { storage[key] = value }
        func removeValue(forKey key: String) { storage.removeValue(forKey: key) }
        @discardableResult
        func synchronize() -> Bool { true }
    }

    private struct Harness {
        let appState: AppState
        let thumbnailProvider: ThumbnailProvider
        let container: ModelContainer
        let tempDir: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// `captureLocationService` is wired to a fake store and disposable, never-created
    /// inbox/recordings URLs — never the real `com.apple.screencapture` domain,
    /// `UserDefaults.standard`, or `LibraryPaths`. `container` is in-memory — never the real
    /// `SnapShelf.store`.
    private func makeHarness() throws -> Harness {
        let schema = Schema([Screenshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShelfTests-panel-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let captureLocationService = CaptureLocationService(
            preferences: FakeScreenCapturePreferences(),
            defaults: UserDefaults(suiteName: "SnapShelfTests.\(UUID().uuidString)")!,
            inboxURL: tempDir.appendingPathComponent("Inbox", isDirectory: true),
            recordingsURL: tempDir.appendingPathComponent("Recordings", isDirectory: true)
        )
        let appState = AppState(modelContainer: container, captureLocationService: captureLocationService)

        return Harness(appState: appState, thumbnailProvider: appState.thumbnailProvider, container: container, tempDir: tempDir)
    }

    /// Six very different aspect ratios — wide, tall, square-ish, and short-and-wide — the shapes
    /// that used to spill outside a 16:10 tile before `ScreenshotTile` was rebuilt from a
    /// fixed-shape `Color.clear` base.
    private static let testSizes: [(width: Int, height: Int, color: NSColor)] = [
        (409, 313, .systemRed),
        (490, 512, .systemBlue),
        (523, 422, .systemGreen),
        (346, 134, .systemOrange),
        (304, 152, .systemPurple),
        (200, 800, .systemTeal)
    ]

    /// Writes a real PNG (via `CoreGraphics`/`NSBitmapImageRep`, not a placeholder) to `directory`
    /// and decodes it back — a solid fill plus a black corner mark so a fit/crop is visible in the
    /// rendered panel instead of being indistinguishable from a uniform color.
    private func makeImage(width: Int, height: Int, color: NSColor, in directory: URL) throws -> NSImage {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: min(24, width), height: min(24, height)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return try #require(NSImage(contentsOf: url))
    }

    private func makeScreenshot(fileName: String, createdAt: Date) -> Screenshot {
        Screenshot(
            createdAt: createdAt,
            fileName: fileName,
            originalName: (fileName as NSString).lastPathComponent,
            contentType: "public.png",
            pixelWidth: 100,
            pixelHeight: 100,
            byteSize: 1
        )
    }

    /// Renders `content` to `url`. The first `nsImage` access lays out the view and schedules
    /// every tile's `.task`; yielding a few times afterward gives those (pre-warmed, so
    /// effectively synchronous) thumbnail lookups a chance to land and SwiftUI a chance to redraw
    /// before the image is sampled again for the file that's actually written out.
    private func renderPNG(_ content: some View, to url: URL) async throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2

        _ = renderer.nsImage
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(200))

        let nsImage = try #require(renderer.nsImage)
        let tiff = try #require(nsImage.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }

    @Test
    func emptyStateRendersACompactPanelWithNoStaleBox() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }

        let content = MenuBarPanel()
            .environment(h.appState)
            .environment(h.thumbnailProvider)
            .modelContainer(h.container)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarPanel-empty-\(UUID().uuidString).png")
        try await renderPNG(content, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        print("MenuBarPanel empty state PNG: \(url.path)")
    }

    @Test
    func gridWithMixedAspectRatiosRendersUniformNonOverlappingTiles() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }

        let context = h.container.mainContext
        for (index, spec) in Self.testSizes.enumerated() {
            let image = try makeImage(width: spec.width, height: spec.height, color: spec.color, in: h.tempDir)
            let fileName = "\(UUID().uuidString)/shot-\(index).png"
            let screenshot = makeScreenshot(fileName: fileName, createdAt: .now.addingTimeInterval(TimeInterval(-index)))
            context.insert(screenshot)
            h.thumbnailProvider.preloadForTesting(image, url: screenshot.fileURL, maxPixelSize: 240)
        }
        try context.save()

        let content = MenuBarPanel()
            .environment(h.appState)
            .environment(h.thumbnailProvider)
            .modelContainer(h.container)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarPanel-grid-\(UUID().uuidString).png")
        try await renderPNG(content, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        print("MenuBarPanel mixed-aspect-ratio grid PNG: \(url.path)")
    }

    /// 20 screenshots is well past the ~12 that used to fit without scrolling, so this exercises
    /// the capped, scrollable grid end to end. `ImageRenderer` is AppKit-backed and may not draw
    /// `ScrollView` content on macOS (its viewport can sample as blank or as a placeholder) — this
    /// is still worth rendering to catch anything above/around the `ScrollView` (header, toast,
    /// panel framing) breaking, but `gridContentRendersAllTilesAtCappedWidth` below is the one
    /// that actually verifies tile layout at this count, by rendering the `LazyVGrid` directly
    /// without the `ScrollView` wrapper.
    @Test
    func gridWithTwentyScreenshotsRendersCappedAndScrollable() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }

        let context = h.container.mainContext
        for index in 0..<20 {
            let spec = Self.testSizes[index % Self.testSizes.count]
            let image = try makeImage(width: spec.width, height: spec.height, color: spec.color, in: h.tempDir)
            let fileName = "\(UUID().uuidString)/shot-\(index).png"
            let screenshot = makeScreenshot(fileName: fileName, createdAt: .now.addingTimeInterval(TimeInterval(-index)))
            context.insert(screenshot)
            h.thumbnailProvider.preloadForTesting(image, url: screenshot.fileURL, maxPixelSize: 240)
        }
        try context.save()

        let content = MenuBarPanel()
            .environment(h.appState)
            .environment(h.thumbnailProvider)
            .modelContainer(h.container)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarPanel-grid-20-\(UUID().uuidString).png")
        try await renderPNG(content, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        print("MenuBarPanel 20-screenshot grid PNG: \(url.path)")
    }

    /// `MenuBarPanel.content`'s `LazyVGrid` isn't reachable directly (it's a private computed
    /// property), so this rebuilds the same shape — `ScreenshotTile`s in a 3-column
    /// `LazyVGrid`, at the panel's content width (`380` panel width − `16` padding per side) —
    /// without the `ScrollView` wrapper that `ImageRenderer` may not draw. 20 tiles span more
    /// than the ~4.5 visible rows the real grid caps at, so this is what actually confirms tiles
    /// at that count still lay out uniformly with no overlap.
    @Test
    func gridContentRendersAllTilesAtCappedWidth() async throws {
        let h = try makeHarness()
        defer { h.cleanUp() }

        var screenshots: [Screenshot] = []
        for index in 0..<20 {
            let spec = Self.testSizes[index % Self.testSizes.count]
            let image = try makeImage(width: spec.width, height: spec.height, color: spec.color, in: h.tempDir)
            let fileName = "\(UUID().uuidString)/shot-\(index).png"
            let screenshot = makeScreenshot(fileName: fileName, createdAt: .now.addingTimeInterval(TimeInterval(-index)))
            h.thumbnailProvider.preloadForTesting(image, url: screenshot.fileURL, maxPixelSize: 240)
            screenshots.append(screenshot)
        }

        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        let content = LazyVGrid(columns: columns, spacing: 8) {
            ForEach(screenshots, id: \.id) { screenshot in
                ScreenshotTile(
                    screenshot: screenshot,
                    isSelected: false,
                    onCopy: {},
                    onToggleFavorite: {},
                    onDelete: {}
                )
            }
        }
        .environment(h.thumbnailProvider)
        .frame(width: 348) // 380 panel width − 16 pt padding on each side.

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarPanel-gridContentOnly-20-\(UUID().uuidString).png")
        try await renderPNG(content, to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        print("MenuBarPanel 20-tile grid-only PNG: \(url.path)")
    }
}

/// `MenuBarPanel.gridHeight(forCount:)` row math, checked against hand-computed values rather
/// than by re-deriving the same formula, so a mistake in the production formula doesn't also
/// land in the test. At `panelWidth` 380 with 16 pt padding, 3 columns and 8 pt spacing, tiles
/// are `(348 − 16) / 3 ≈ 110.667` wide and, at 16:10, `≈ 69.167` tall; the cap sits at 4.5 rows
/// (`4.5 × 69.167 + 3.5 × 8 ≈ 339.25`).
@Suite("MenuBarPanel grid height")
struct MenuBarPanelGridHeightTests {
    private static let tolerance: CGFloat = 0.01

    @Test("matches row math below the cap, and caps at ~4.5 rows above it")
    func gridHeightMatchesRowMathOrCaps() {
        let cases: [(count: Int, expected: CGFloat)] = [
            (0, 0),
            (1, 69.166667), // 1 row
            (3, 69.166667), // still 1 row — fits within a single row
            (4, 146.333333), // 2 rows
            (12, 300.666667), // 4 rows — the old fetchLimit, still uncapped
            (20, 339.25), // 7 rows uncapped (≈532.17) — capped
            (100, 339.25) // 34 rows uncapped (≈2615.67) — capped
        ]

        for testCase in cases {
            let actual = MenuBarPanel.gridHeight(forCount: testCase.count)
            #expect(abs(actual - testCase.expected) < Self.tolerance)
        }
    }

    @Test
    func gridHeightNeverExceedsTheCap() {
        for count in [12, 13, 20, 50, 100, 1000] {
            #expect(MenuBarPanel.gridHeight(forCount: count) <= 339.25 + Self.tolerance)
        }
    }
}
