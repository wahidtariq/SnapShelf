import Foundation

/// The Library sidebar's four destinations. `CaseIterable`'s order is also sidebar display order.
enum LibrarySection: String, Hashable, Identifiable, CaseIterable {
    case all
    case today
    case favorites
    case recentlyDeleted

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Screenshots"
        case .today: "Today"
        case .favorites: "Favorites"
        case .recentlyDeleted: "Recently Deleted"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "photo.on.rectangle.angled"
        case .today: "calendar"
        case .favorites: "star"
        case .recentlyDeleted: "trash"
        }
    }
}

/// The Library toolbar's sort menu. Ignored inside Recently Deleted, which is always sorted by
/// deletion date (most recently deleted first).
enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst
    case largestFirst

    var id: Self { self }

    var title: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        case .largestFirst: "Largest First"
        }
    }
}
