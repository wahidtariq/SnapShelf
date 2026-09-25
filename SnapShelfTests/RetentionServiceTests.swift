import Foundation
import SwiftData
import Testing
@testable import SnapShelf

@Suite("RetentionService")
@MainActor
struct RetentionServiceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    /// In-memory container — never the real `SnapShelf.store`.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Screenshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeScreenshot(createdAt: Date, isFavorite: Bool = false, deletedAt: Date? = nil) -> Screenshot {
        Screenshot(
            createdAt: createdAt,
            fileName: "\(UUID().uuidString)/shot.png",
            originalName: "shot",
            contentType: "public.png",
            pixelWidth: 1,
            pixelHeight: 1,
            byteSize: 1,
            isFavorite: isFavorite,
            deletedAt: deletedAt
        )
    }

    /// Isolated `UserDefaults` for `retentionDays`, never `.standard`.
    private func makeDefaults(retentionDays: Int) -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "SnapShelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(retentionDays, forKey: "retentionDays")
        return (defaults, suiteName)
    }

    @Test
    func applyRetentionPolicySoftDeletesExpiredItemsButExemptsFavoritesAndRecent() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let old = makeScreenshot(createdAt: daysAgo(31))
        let recent = makeScreenshot(createdAt: daysAgo(1))
        let oldFavorite = makeScreenshot(createdAt: daysAgo(60), isFavorite: true)
        context.insert(old)
        context.insert(recent)
        context.insert(oldFavorite)
        try context.save()

        let (defaults, suiteName) = makeDefaults(retentionDays: 30)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var hardDeleted: [Screenshot] = []
        let service = RetentionService(modelContainer: container, defaults: defaults) { screenshots, _ in
            hardDeleted.append(contentsOf: screenshots)
        }

        service.applyRetentionPolicy(now: now)

        #expect(old.deletedAt == now)
        #expect(recent.deletedAt == nil)
        #expect(oldFavorite.deletedAt == nil)
        #expect(hardDeleted.isEmpty)
    }

    @Test
    func applyRetentionPolicyHardDeletesItemsPurgedFromRecentlyDeleted() throws {
        let container = try makeContainer()
        let context = container.mainContext

        let oldDeleted = makeScreenshot(createdAt: now, deletedAt: daysAgo(31))
        let recentDeleted = makeScreenshot(createdAt: now, deletedAt: daysAgo(5))
        context.insert(oldDeleted)
        context.insert(recentDeleted)
        try context.save()

        // Forever: no new soft-deletes, only the Recently Deleted purge sweep runs.
        let (defaults, suiteName) = makeDefaults(retentionDays: 0)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var hardDeleted: [Screenshot] = []
        let service = RetentionService(modelContainer: container, defaults: defaults) { screenshots, _ in
            hardDeleted.append(contentsOf: screenshots)
        }

        service.applyRetentionPolicy(now: now)

        #expect(hardDeleted.map(\.id) == [oldDeleted.id])
    }
}
