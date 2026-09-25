import AppKit
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The Library window's main content: a `LazyVGrid` of screenshots for the selected sidebar
/// section, filtered by search text and sorted per the toolbar's sort menu.
///
/// Builds its `@Query` from `section`/`query`/`sortOrder` in `init`, the standard "dynamic
/// @Query via child view init" pattern — `LibraryView` re-creates this view (with new
/// parameters) whenever any of those change, which re-runs `init` and rebuilds the query.
/// `query` and `searchText` carry the same string but serve different purposes: `query` is read
/// by `LibraryView`'s body (not just passed through a binding), which is what makes that body
/// — and therefore this view's `init` — actually re-run on every keystroke; `searchText` is the
/// live `Binding` `.searchable` needs to read from and write back to.
struct ScreenshotGrid: View {
    let section: LibrarySection

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query private var screenshots: [Screenshot]

    @Binding var searchText: String
    @Binding var selectedIDs: Set<UUID>
    @Binding var thumbnailSize: Double
    @Binding var isInspectorPresented: Bool
    @Binding var quickLookURL: URL?

    @State private var lastClickedID: UUID?
    @State private var gridWidth: CGFloat = 0
    @State private var isConfirmingDeleteForever = false
    @State private var isConfirmingEmptyRecentlyDeleted = false
    @State private var isTargetedForDrop = false

    private let gridSpacing: CGFloat = 16

    /// Stored (rather than re-trimmed from `query` on every access) so `emptyState` can tell a
    /// no-results search apart from a genuinely empty section without redoing the trim.
    private let trimmedSearchText: String

    init(
        section: LibrarySection,
        query: String,
        searchText: Binding<String>,
        sortOrder: LibrarySortOrder,
        selectedIDs: Binding<Set<UUID>>,
        thumbnailSize: Binding<Double>,
        isInspectorPresented: Binding<Bool>,
        quickLookURL: Binding<URL?>
    ) {
        self.section = section
        _searchText = searchText
        _selectedIDs = selectedIDs
        _thumbnailSize = thumbnailSize
        _isInspectorPresented = isInspectorPresented
        _quickLookURL = quickLookURL

        let trimmedSearchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trimmedSearchText = trimmedSearchText

        let predicate = Self.makePredicate(section: section, searchText: trimmedSearchText)
        let sort = Self.makeSortDescriptors(section: section, sortOrder: sortOrder)
        _screenshots = Query(filter: predicate, sort: sort, animation: .default)
    }

    var body: some View {
        Group {
            if screenshots.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .navigationTitle(section.title)
        .navigationSubtitle(subtitle)
        // Colocated with `.toolbar` (rather than living on the enclosing `NavigationSplitView`,
        // where it previously was) so macOS reliably merges the search field into this toolbar
        // instead of it losing out to `LibraryToolbar`'s custom items.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Screenshots")
        .toolbar {
            LibraryToolbar(
                section: section,
                itemCount: screenshots.count,
                thumbnailSize: $thumbnailSize,
                sortOrder: sortOrderBinding,
                isInspectorPresented: $isInspectorPresented,
                onEmptyRecentlyDeleted: { isConfirmingEmptyRecentlyDeleted = true }
            )
        }
        .inspector(isPresented: $isInspectorPresented) {
            InspectorView(screenshots: orderedSelection())
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .onDeleteCommand { softDeleteSelected() }
        .onCopyCommand {
            let ordered = orderedSelection()
            guard !ordered.isEmpty else { return [] }
            appState.pasteboardService.copy(ordered)
            return []
        }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .image]) { providers in
            Task { await importProviders(providers) }
        }
        .onDrop(of: [.fileURL, .png, .tiff, .image], isTargeted: $isTargetedForDrop) { providers in
            Task { await importProviders(providers) }
            return true
        }
        .quickLookPreview($quickLookURL, in: screenshots.map(\.fileURL))
        .focusedSceneValue(\.libraryActions, libraryActions)
        .confirmationDialog(
            "Delete Immediately?",
            isPresented: $isConfirmingDeleteForever
        ) {
            Button("Delete Immediately", role: .destructive) { hardDeleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Empty Recently Deleted?",
            isPresented: $isConfirmingEmptyRecentlyDeleted
        ) {
            Button("Empty Recently Deleted", role: .destructive) { emptyRecentlyDeleted() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Screenshots in Recently Deleted will be removed for good. This can't be undone.")
        }
    }

    // MARK: - Grid

    private var grid: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth), spacing: gridSpacing)], spacing: gridSpacing) {
                    ForEach(screenshots) { screenshot in
                        ScreenshotCell(
                            screenshot: screenshot,
                            isSelected: selectedIDs.contains(screenshot.id),
                            isRecentlyDeleted: section == .recentlyDeleted,
                            thumbnailSize: thumbnailSize
                        )
                        .onTapGesture {
                            // `count: 2` followed by `count: 1` gestures make every single click
                            // wait out the double-click timeout before firing. Reading the real
                            // event's click count instead resolves both in one gesture, instantly.
                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                openInPreview([screenshot])
                            } else {
                                handleClick(screenshot)
                            }
                        }
                        .onDrag { NSItemProvider(object: screenshot.fileURL as NSURL) }
                        .contextMenu { contextMenu(for: screenshot) }
                    }
                }
                .padding(gridSpacing)
                .background {
                    // Tapping the gaps between cells clears the selection, matching Finder.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { selectedIDs.removeAll() }
                }
            }
            .onAppear { gridWidth = geometry.size.width }
            .onChange(of: geometry.size.width) { _, newValue in gridWidth = newValue }
        }
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -columnCount) }
        .onKeyPress(.downArrow) { moveSelection(by: columnCount) }
        .onKeyPress(.space) {
            guard let url = orderedSelection().first?.fileURL else { return .ignored }
            quickLookURL = url
            return .handled
        }
    }

    /// Each cell is padded out to `thumbnailSize + 16` (see `ScreenshotCell`), so the grid's
    /// column width — and this arithmetic — must match that, not the bare `thumbnailSize`, or
    /// cells end up wider than their column and overlap their neighbors.
    private var cellWidth: CGFloat { thumbnailSize + 16 }

    private var columnCount: Int {
        max(1, Int((gridWidth + gridSpacing) / (cellWidth + gridSpacing)))
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        if !trimmedSearchText.isEmpty {
            ContentUnavailableView.search(text: trimmedSearchText)
        } else {
            sectionEmptyState
        }
    }

    @ViewBuilder
    private var sectionEmptyState: some View {
        switch section {
        case .all:
            ContentUnavailableView(
                "No Screenshots Yet",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Press ⇧⌘4 to take a screenshot — it'll appear here.")
            )
        case .today:
            ContentUnavailableView(
                "No Screenshots Yet",
                systemImage: "calendar",
                description: Text("Screenshots you take today will show up here.")
            )
        case .favorites:
            ContentUnavailableView(
                "No Favorites",
                systemImage: "star",
                description: Text("Star screenshots to find them here.")
            )
        case .recentlyDeleted:
            ContentUnavailableView(
                "Recently Deleted is Empty",
                systemImage: "trash",
                description: Text("Screenshots you delete are kept here for 30 days.")
            )
        }
    }

    // MARK: - Toolbar

    /// Local `@AppStorage` binding (rather than a value passed down from `LibraryView`) so
    /// `LibraryToolbar`'s sort `Picker` can write straight back to the same key the query's
    /// initial `sortOrder` snapshot was read from.
    @AppStorage("librarySortOrder") private var sortOrderRaw = LibrarySortOrder.newestFirst.rawValue
    private var sortOrderBinding: Binding<LibrarySortOrder> {
        Binding(
            get: { LibrarySortOrder(rawValue: sortOrderRaw) ?? .newestFirst },
            set: { sortOrderRaw = $0.rawValue }
        )
    }

    private var subtitle: String {
        "\(screenshots.count) Screenshot\(screenshots.count == 1 ? "" : "s")"
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for screenshot: Screenshot) -> some View {
        let targets = selectionTargets(clicking: screenshot)

        if section == .recentlyDeleted {
            Button("Put Back") { putBack(targets) }
            Button("Delete Immediately…") {
                selectedIDs = Set(targets.map(\.id))
                isConfirmingDeleteForever = true
            }
        } else {
            Button("Copy") { appState.pasteboardService.copy(targets) }
            Button("Open in Preview") { openInPreview(targets) }
            ShareLink("Share…", items: targets.map(\.fileURL))
            if targets.count == 1 {
                Button("Save As…") { saveAs(targets[0]) }
            }

            Divider()

            let allFavorited = targets.allSatisfy(\.isFavorite)
            Button(allFavorited ? "Remove from Favorites" : "Add to Favorites") {
                setFavorite(!allFavorited, for: targets)
            }

            Divider()

            Button("Move to Recently Deleted") { softDelete(targets) }
        }
    }

    /// If the right-clicked item is already part of a multi-selection, act on the whole
    /// selection (standard Finder behavior); otherwise act on just the clicked item.
    private func selectionTargets(clicking screenshot: Screenshot) -> [Screenshot] {
        if selectedIDs.contains(screenshot.id), selectedIDs.count > 1 {
            return orderedSelection()
        }
        return [screenshot]
    }

    // MARK: - Selection

    private func handleClick(_ screenshot: Screenshot) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selectedIDs.contains(screenshot.id) {
                selectedIDs.remove(screenshot.id)
            } else {
                selectedIDs.insert(screenshot.id)
            }
            lastClickedID = screenshot.id
        } else if modifiers.contains(.shift), let lastID = lastClickedID,
                  let lastIndex = screenshots.firstIndex(where: { $0.id == lastID }),
                  let currentIndex = screenshots.firstIndex(where: { $0.id == screenshot.id }) {
            let range = lastIndex < currentIndex ? lastIndex...currentIndex : currentIndex...lastIndex
            selectedIDs.formUnion(screenshots[range].map(\.id))
        } else {
            selectedIDs = [screenshot.id]
            lastClickedID = screenshot.id
        }
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !screenshots.isEmpty else { return .ignored }
        let currentIndex = lastClickedID.flatMap { id in screenshots.firstIndex(where: { $0.id == id }) } ?? -1
        let newIndex = min(max(currentIndex + delta, 0), screenshots.count - 1)
        let screenshot = screenshots[newIndex]
        selectedIDs = [screenshot.id]
        lastClickedID = screenshot.id
        return .handled
    }

    /// The current selection, in the grid's display order (not `Set`'s undefined order) — needed
    /// for Copy, Quick Look paging, and range-selection anchoring.
    private func orderedSelection() -> [Screenshot] {
        screenshots.filter { selectedIDs.contains($0.id) }
    }

    // MARK: - Delete / Put Back

    private func softDeleteSelected() {
        softDelete(orderedSelection().filter { $0.deletedAt == nil })
    }

    private func softDelete(_ targets: [Screenshot]) {
        guard !targets.isEmpty else { return }
        for screenshot in targets { screenshot.deletedAt = Date() }
        try? modelContext.save()
        selectedIDs.subtract(targets.map(\.id))
    }

    private func putBack(_ targets: [Screenshot]) {
        guard !targets.isEmpty else { return }
        for screenshot in targets { screenshot.deletedAt = nil }
        try? modelContext.save()
        selectedIDs.subtract(targets.map(\.id))
    }

    private func hardDeleteSelected() {
        let targets = orderedSelection()
        AppState.permanentlyDelete(targets, modelContext: modelContext)
        selectedIDs.removeAll()
    }

    private func emptyRecentlyDeleted() {
        let descriptor = FetchDescriptor<Screenshot>(predicate: #Predicate<Screenshot> { $0.deletedAt != nil })
        guard let all = try? modelContext.fetch(descriptor) else { return }
        AppState.permanentlyDelete(all, modelContext: modelContext)
        selectedIDs.removeAll()
    }

    private func setFavorite(_ isFavorite: Bool, for targets: [Screenshot]) {
        for screenshot in targets { screenshot.isFavorite = isFavorite }
        try? modelContext.save()
    }

    // MARK: - Open / Save

    private func openInPreview(_ targets: [Screenshot]) {
        let urls = targets.map(\.fileURL)
        guard !urls.isEmpty else { return }
        if let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open(urls, withApplicationAt: previewURL, configuration: NSWorkspace.OpenConfiguration())
        } else {
            for url in urls { NSWorkspace.shared.open(url) }
        }
    }

    private func saveAs(_ screenshot: Screenshot) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = screenshot.fileURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.copyItem(at: screenshot.fileURL, to: destination)
    }

    // MARK: - Paste / drop import

    private func importProviders(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await Self.loadFileURL(provider),
               UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                _ = try? await appState.importExternalFile(at: url)
                continue
            }
            if let data = await Self.loadImageData(provider) {
                _ = try? await appState.importImage(data: data, suggestedName: Self.pastedImageName())
            }
        }
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
                continuation.resume(returning: (reading as? NSURL) as URL?)
            }
        }
    }

    /// Loads PNG or TIFF pasteboard/drop data, normalizing TIFF to PNG so every path into
    /// `importImage(data:suggestedName:)` writes the same file format.
    private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        for identifier in [UTType.png.identifier, UTType.tiff.identifier]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data else { continue }
            if identifier == UTType.tiff.identifier,
               let image = NSImage(data: data),
               let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData) {
                return bitmap.representation(using: .png, properties: [:])
            }
            return data
        }
        return nil
    }

    private static func pastedImageName(at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Pasted Image \(formatter.string(from: date))"
    }

    // MARK: - Menu commands

    private var libraryActions: LibraryActions {
        LibraryActions(
            hasSelection: !selectedIDs.isEmpty,
            quickLook: { quickLookURL = orderedSelection().first?.fileURL },
            openInPreview: { openInPreview(orderedSelection()) },
            toggleFavorite: {
                let targets = orderedSelection()
                let allFavorited = targets.allSatisfy(\.isFavorite)
                setFavorite(!allFavorited, for: targets)
            },
            moveToRecentlyDeleted: { softDeleteSelected() },
            toggleInspector: { isInspectorPresented.toggle() },
            increaseThumbnailSize: { thumbnailSize = min(320, thumbnailSize + 20) },
            decreaseThumbnailSize: { thumbnailSize = max(110, thumbnailSize - 20) }
        )
    }

    // MARK: - Query building

    private static func makePredicate(section: LibrarySection, searchText: String) -> Predicate<Screenshot> {
        let today = Calendar.current.startOfDay(for: .now)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch (section, query.isEmpty) {
        case (.all, true):
            return #Predicate<Screenshot> { $0.deletedAt == nil }
        case (.all, false):
            return #Predicate<Screenshot> {
                $0.deletedAt == nil &&
                ($0.originalName.localizedStandardContains(query) || $0.recognizedText.localizedStandardContains(query))
            }
        case (.today, true):
            return #Predicate<Screenshot> { $0.deletedAt == nil && $0.createdAt >= today }
        case (.today, false):
            return #Predicate<Screenshot> {
                $0.deletedAt == nil && $0.createdAt >= today &&
                ($0.originalName.localizedStandardContains(query) || $0.recognizedText.localizedStandardContains(query))
            }
        case (.favorites, true):
            return #Predicate<Screenshot> { $0.deletedAt == nil && $0.isFavorite }
        case (.favorites, false):
            return #Predicate<Screenshot> {
                $0.deletedAt == nil && $0.isFavorite &&
                ($0.originalName.localizedStandardContains(query) || $0.recognizedText.localizedStandardContains(query))
            }
        case (.recentlyDeleted, true):
            return #Predicate<Screenshot> { $0.deletedAt != nil }
        case (.recentlyDeleted, false):
            return #Predicate<Screenshot> {
                $0.deletedAt != nil &&
                ($0.originalName.localizedStandardContains(query) || $0.recognizedText.localizedStandardContains(query))
            }
        }
    }

    private static func makeSortDescriptors(section: LibrarySection, sortOrder: LibrarySortOrder) -> [SortDescriptor<Screenshot>] {
        if section == .recentlyDeleted {
            return [SortDescriptor(\.deletedAt, order: .reverse)]
        }
        switch sortOrder {
        case .newestFirst: return [SortDescriptor(\.createdAt, order: .reverse)]
        case .oldestFirst: return [SortDescriptor(\.createdAt, order: .forward)]
        case .largestFirst: return [SortDescriptor(\.byteSize, order: .reverse)]
        }
    }
}

/// One grid cell: a square-ish thumbnail, the file name (middle-truncated to one line), and a
/// secondary line — the creation date normally, or "N days left" in Recently Deleted.
private struct ScreenshotCell: View {
    let screenshot: Screenshot
    let isSelected: Bool
    let isRecentlyDeleted: Bool
    let thumbnailSize: Double

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // `contentMode: .fit` (not the default `.fill`) so the whole screenshot is visible
            // inside the square box, whatever its aspect ratio, instead of being cropped.
            ScreenshotThumbnail(url: screenshot.fileURL, maxPixelSize: thumbnailSize * backingScale, contentMode: .fit)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(screenshot.originalName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(secondaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(width: thumbnailSize + 16)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(screenshot.originalName)
    }

    private var backgroundFill: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    private var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    private var secondaryLine: String {
        if isRecentlyDeleted, let deletedAt = screenshot.deletedAt {
            let elapsedDays = Calendar.current.dateComponents([.day], from: deletedAt, to: .now).day ?? 0
            let remaining = max(0, RetentionPolicy.recentlyDeletedPurgeDays - elapsedDays)
            return "\(remaining) day\(remaining == 1 ? "" : "s") left"
        }
        return screenshot.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}
