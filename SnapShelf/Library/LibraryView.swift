import SwiftData
import SwiftUI

/// The Library window: a sidebar of sections (All Screenshots, Today, Favorites, Recently
/// Deleted) and a grid for whichever one is selected. Search, sort, thumbnail size, and the
/// inspector all live on `ScreenshotGrid`, which owns the toolbar for the current section.
struct LibraryView: View {
    @State private var selection: LibrarySection? = .all
    @State private var searchText = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var quickLookURL: URL?

    @AppStorage("thumbnailSize") private var thumbnailSize: Double = 160
    @AppStorage("isInspectorPresented") private var isInspectorPresented = true
    @AppStorage("librarySortOrder") private var sortOrderRaw = LibrarySortOrder.newestFirst.rawValue

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection)
        } detail: {
            if let selection {
                ScreenshotGrid(
                    section: selection,
                    // Passed by value as well as by binding: reading it here makes this body
                    // depend on `searchText`, so each keystroke re-runs the grid's `init` and
                    // rebuilds its `@Query`. The binding alone doesn't create that dependency.
                    query: searchText,
                    searchText: $searchText,
                    sortOrder: sortOrder,
                    selectedIDs: $selectedIDs,
                    thumbnailSize: $thumbnailSize,
                    isInspectorPresented: $isInspectorPresented,
                    quickLookURL: $quickLookURL
                )
                .id(selection)
            } else {
                ContentUnavailableView("Select a Section", systemImage: "sidebar.left")
            }
        }
        .onChange(of: selection) {
            selectedIDs.removeAll()
            quickLookURL = nil
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRaw) ?? .newestFirst
    }
}

/// The sidebar list. Its four `@Query`s only fetch counts for badges — SwiftData models here hold
/// no image bytes, so fetching the full rows is cheap.
private struct LibrarySidebar: View {
    @Binding var selection: LibrarySection?

    @Query(filter: #Predicate<Screenshot> { $0.deletedAt == nil })
    private var activeScreenshots: [Screenshot]

    @Query(filter: #Predicate<Screenshot> { $0.deletedAt == nil && $0.isFavorite })
    private var favoriteScreenshots: [Screenshot]

    @Query(filter: #Predicate<Screenshot> { $0.deletedAt != nil })
    private var deletedScreenshots: [Screenshot]

    @Query private var todayScreenshots: [Screenshot]

    /// `todayStart` is computed once, here, rather than inside the `#Predicate` — SwiftData's
    /// predicate macro can only reference captured values, not call `Calendar` itself.
    init(selection: Binding<LibrarySection?>) {
        _selection = selection
        let todayStart = Calendar.current.startOfDay(for: .now)
        _todayScreenshots = Query(filter: #Predicate<Screenshot> { $0.deletedAt == nil && $0.createdAt >= todayStart })
    }

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label(LibrarySection.all.title, systemImage: LibrarySection.all.systemImage)
                    .badge(activeScreenshots.count)
                    .tag(LibrarySection.all)
                Label(LibrarySection.today.title, systemImage: LibrarySection.today.systemImage)
                    .badge(todayScreenshots.count)
                    .tag(LibrarySection.today)
                Label(LibrarySection.favorites.title, systemImage: LibrarySection.favorites.systemImage)
                    .badge(favoriteScreenshots.count)
                    .tag(LibrarySection.favorites)
            }

            Label(LibrarySection.recentlyDeleted.title, systemImage: LibrarySection.recentlyDeleted.systemImage)
                .badge(deletedScreenshots.count)
                .tag(LibrarySection.recentlyDeleted)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }
}
