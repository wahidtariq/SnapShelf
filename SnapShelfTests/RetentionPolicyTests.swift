import Foundation
import Testing
@testable import SnapShelf

@Suite("RetentionPolicy")
struct RetentionPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: now)!
    }

    @Test
    func keepingForeverNeverExpires() {
        let policy = RetentionPolicy(keepDays: nil)
        #expect(policy.shouldMoveToRecentlyDeleted(createdAt: daysAgo(3650), isFavorite: false, deletedAt: nil, now: now) == false)
    }

    @Test(arguments: [(31, true), (29, false)])
    func thirtyDayPolicyExpiresPastTheWindow(daysOld: Int, shouldExpire: Bool) {
        let policy = RetentionPolicy(keepDays: 30)
        #expect(policy.shouldMoveToRecentlyDeleted(createdAt: daysAgo(daysOld), isFavorite: false, deletedAt: nil, now: now) == shouldExpire)
    }

    @Test
    func favoritesNeverExpireEvenPastTheWindow() {
        let policy = RetentionPolicy(keepDays: 30)
        #expect(policy.shouldMoveToRecentlyDeleted(createdAt: daysAgo(365), isFavorite: true, deletedAt: nil, now: now) == false)
    }

    @Test
    func alreadyDeletedItemsAreSkippedByTheMoveRule() {
        let policy = RetentionPolicy(keepDays: 30)
        #expect(policy.shouldMoveToRecentlyDeleted(createdAt: daysAgo(365), isFavorite: false, deletedAt: now, now: now) == false)
    }

    @Test(arguments: [(31, true), (29, false)])
    func shouldPurgePastTheThirtyDayRecentlyDeletedWindow(daysDeleted: Int, shouldPurge: Bool) {
        let policy = RetentionPolicy(keepDays: nil)
        #expect(policy.shouldPurge(deletedAt: daysAgo(daysDeleted), now: now) == shouldPurge)
    }

    @Test
    func shouldPurgeIsFalseWhenNeverDeleted() {
        let policy = RetentionPolicy(keepDays: 30)
        #expect(policy.shouldPurge(deletedAt: nil, now: now) == false)
    }
}
