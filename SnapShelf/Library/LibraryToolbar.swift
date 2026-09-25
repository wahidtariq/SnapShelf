import SwiftUI

/// `ScreenshotGrid`'s toolbar: thumbnail zoom, sort (or "Empty Recently Deleted" in that one
/// section), and the inspector toggle — split out so the grid's selection/drag/drop logic and
/// this control layout can change independently.
///
/// `.searchable` itself stays on `ScreenshotGrid` (a `ToolbarContent` can't declare it) so the
/// search field is colocated with `.toolbar`, which is what makes macOS reliably merge it into
/// this toolbar. `DefaultToolbarItem(kind: .search)` below only controls where that field lands.
struct LibraryToolbar: ToolbarContent {
    let section: LibrarySection
    /// Screenshot count for the current section — drives the "Empty…" button's disabled state.
    let itemCount: Int

    @Binding var thumbnailSize: Double
    @Binding var sortOrder: LibrarySortOrder
    @Binding var isInspectorPresented: Bool

    let onEmptyRecentlyDeleted: () -> Void

    /// ±20 per step within 110...320 — matches the View menu's ⌘+/⌘− commands in `LibraryCommands`.
    private static let thumbnailSizeStep: Double = 20
    private static let thumbnailSizeRange: ClosedRange<Double> = 110...320

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            ControlGroup {
                Button {
                    thumbnailSize = max(Self.thumbnailSizeRange.lowerBound, thumbnailSize - Self.thumbnailSizeStep)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Smaller Thumbnails")
                .disabled(thumbnailSize <= Self.thumbnailSizeRange.lowerBound)

                Button {
                    thumbnailSize = min(Self.thumbnailSizeRange.upperBound, thumbnailSize + Self.thumbnailSizeStep)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Larger Thumbnails")
                .disabled(thumbnailSize >= Self.thumbnailSizeRange.upperBound)
            }
        }

        ToolbarSpacer(.fixed)

        if section == .recentlyDeleted {
            // Sorting here is fixed to deletion date, so the sort menu would do nothing — swap it
            // for the one action this section actually needs.
            ToolbarItem(placement: .automatic) {
                Button(role: .destructive, action: onEmptyRecentlyDeleted) {
                    Label("Empty Recently Deleted", systemImage: "trash.slash")
                }
                .help("Empty Recently Deleted")
                .disabled(itemCount == 0)
            }
        } else {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .menuIndicator(.hidden)
                .help("Sort")
            }
        }

        ToolbarSpacer(.fixed)

        // Repositions the field `.searchable` already declared on `ScreenshotGrid` into a
        // guaranteed slot, rather than leaving it to compete for automatic placement against the
        // groups above and below.
        DefaultToolbarItem(kind: .search, placement: .automatic)

        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            Button {
                isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
        }
    }
}
