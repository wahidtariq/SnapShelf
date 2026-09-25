import Foundation
import SwiftData

/// Pure date-comparison rules for retention, kept separate from `RetentionService` so they're
/// trivially unit-testable without a `ModelContainer`.
///
/// `nonisolated` — this is pure arithmetic over `Date`, with no reason to inherit the project's
/// default main-actor isolation.
nonisolated struct RetentionPolicy: Equatable {
    /// How long to keep a screenshot before moving it to Recently Deleted. `nil` means forever.
    var keepDays: Int?

    /// How long an item stays in Recently Deleted before it's purged for good. Not configurable —
    /// matches Photos/Finder's Recently Deleted behavior.
    static let recentlyDeletedPurgeDays = 30

    /// Whether a non-deleted screenshot has aged past `keepDays` and should be soft-deleted.
    /// Favorites are exempt, and an already-deleted item is left for `shouldPurge` instead.
    func shouldMoveToRecentlyDeleted(createdAt: Date, isFavorite: Bool, deletedAt: Date?, now: Date = .now) -> Bool {
        guard deletedAt == nil, !isFavorite, let keepDays else { return false }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: now) else { return false }
        return createdAt < cutoff
    }

    /// Whether a Recently Deleted item has aged past the purge window and should be removed for good.
    func shouldPurge(deletedAt: Date?, now: Date = .now) -> Bool {
        guard let deletedAt else { return false }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.recentlyDeletedPurgeDays, to: now) else {
            return false
        }
        return deletedAt < cutoff
    }
}

/// Applies `RetentionPolicy` to the library: soft-deletes screenshots older than the "Keep
/// screenshots" setting, then hard-purges anything that's been in Recently Deleted for more than
/// 30 days. Runs at launch, whenever the setting changes, and once every 24 hours.
@MainActor
final class RetentionService {
    private let modelContainer: ModelContainer
    private let defaults: UserDefaults
    private let hardDelete: ([Screenshot], ModelContext) -> Void

    private var dailyTimerTask: Task<Void, Never>?
    private let dailyInterval: Duration = .seconds(24 * 60 * 60)

    /// `retentionDays` mirrors the Storage tab's `@AppStorage("retentionDays")`: 0 means Forever.
    private static let retentionDaysDefaultsKey = "retentionDays"

    /// `hardDelete` is injected so this shares exactly the same on-disk removal logic as the
    /// Library's "Delete Immediately" action instead of duplicating it — see `AppState.permanentlyDelete`.
    init(
        modelContainer: ModelContainer,
        defaults: UserDefaults = .standard,
        hardDelete: @escaping ([Screenshot], ModelContext) -> Void
    ) {
        self.modelContainer = modelContainer
        self.defaults = defaults
        self.hardDelete = hardDelete
    }

    deinit {
        dailyTimerTask?.cancel()
    }

    /// Applies the policy once immediately, then schedules the 24h repeat. Call once at launch.
    func start() {
        applyRetentionPolicy()
        dailyTimerTask?.cancel()
        dailyTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.dailyInterval)
                guard !Task.isCancelled else { return }
                self.applyRetentionPolicy()
            }
        }
    }

    /// Re-reads the "Keep screenshots" setting and sweeps the library. Safe to call anytime —
    /// call this again whenever the Storage tab's picker changes so the new setting takes effect
    /// immediately rather than waiting for the next daily sweep.
    func applyRetentionPolicy(now: Date = .now) {
        let storedDays = defaults.integer(forKey: Self.retentionDaysDefaultsKey)
        let policy = RetentionPolicy(keepDays: storedDays == 0 ? nil : storedDays)
        let context = modelContainer.mainContext

        if policy.keepDays != nil {
            let active = FetchDescriptor<Screenshot>(predicate: #Predicate { $0.deletedAt == nil })
            if let candidates = try? context.fetch(active) {
                for screenshot in candidates
                where policy.shouldMoveToRecentlyDeleted(
                    createdAt: screenshot.createdAt,
                    isFavorite: screenshot.isFavorite,
                    deletedAt: screenshot.deletedAt,
                    now: now
                ) {
                    screenshot.deletedAt = now
                }
            }
        }

        let deleted = FetchDescriptor<Screenshot>(predicate: #Predicate { $0.deletedAt != nil })
        if let deletedItems = try? context.fetch(deleted) {
            let toPurge = deletedItems.filter { policy.shouldPurge(deletedAt: $0.deletedAt, now: now) }
            if !toPurge.isEmpty {
                hardDelete(toPurge, context)
            }
        }

        try? context.save()
    }
}
