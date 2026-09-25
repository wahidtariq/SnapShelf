import Foundation
import Testing
@testable import SnapShelf

/// In-memory stand-in for `com.apple.screencapture` so tests never touch the real domain.
private final class FakeScreenCapturePreferences: ScreenCapturePreferences {
    private var storage: [String: Any] = [:]
    private(set) var synchronizeCallCount = 0

    func value(forKey key: String) -> Any? { storage[key] }
    func setValue(_ value: Any?, forKey key: String) { storage[key] = value }
    func removeValue(forKey key: String) { storage.removeValue(forKey: key) }

    @discardableResult
    func synchronize() -> Bool {
        synchronizeCallCount += 1
        return true
    }
}

@Suite("CaptureLocationService")
@MainActor
struct CaptureLocationServiceTests {
    /// The keys `CaptureLocationService` writes to `com.apple.screencapture`. Mirrors the
    /// service's own private constants so the fake store can be primed/inspected by name.
    private enum Key {
        static let location = "location"
        static let screenshotLocation = "location-screenshot"
        static let screenRecordingLocation = "location-screenrecording"
        static let showThumbnail = "show-thumbnail"
    }

    /// The legacy (pre-migration) `UserDefaults` baseline keys `CaptureLocationService` used when
    /// it only ever managed `location`. Mirrors the service's own private constants so a test can
    /// seed them directly to simulate an earlier version having already run `enable()`.
    private enum LegacyDefaultsKey {
        static let hasRemembered = "CaptureLocationService.hasRemembered"
        static let originalKeyExisted = "CaptureLocationService.originalKeyExisted"
        static let originalValue = "CaptureLocationService.originalValue"
    }

    private struct Harness {
        let sut: CaptureLocationService
        let prefs: FakeScreenCapturePreferences
        let defaults: UserDefaults
        let suiteName: String
        let inboxURL: URL
        let recordingsURL: URL

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: recordingsURL)
        }
    }

    /// Builds a `CaptureLocationService` wired to a fake preferences store, an isolated
    /// `UserDefaults` suite, and temporary (never created) inbox/recordings URLs — never the real
    /// `com.apple.screencapture` domain, `UserDefaults.standard`, `LibraryPaths.inbox`, or the
    /// real `~/Movies/Screen Recordings`.
    private func makeHarness(prefs: FakeScreenCapturePreferences = FakeScreenCapturePreferences()) -> Harness {
        let suiteName = "SnapShelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let inboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShelfTests-inbox-\(UUID().uuidString)", isDirectory: true)
        let recordingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapShelfTests-recordings-\(UUID().uuidString)", isDirectory: true)
        let sut = CaptureLocationService(
            preferences: prefs,
            defaults: defaults,
            inboxURL: inboxURL,
            recordingsURL: recordingsURL
        )
        return Harness(
            sut: sut,
            prefs: prefs,
            defaults: defaults,
            suiteName: suiteName,
            inboxURL: inboxURL,
            recordingsURL: recordingsURL
        )
    }

    private var desktopPath: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL.path
    }

    // MARK: - status

    @Test
    func statusIsSavingToDesktopWhenKeyIsAbsent() {
        let h = makeHarness()
        defer { h.cleanUp() }
        #expect(h.sut.status == .savingToDesktop)
    }

    @Test
    func statusIsSavingToDesktopWhenKeyIsTheDesktopPath() {
        let prefs = FakeScreenCapturePreferences()
        prefs.setValue(desktopPath, forKey: Key.location)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        #expect(h.sut.status == .savingToDesktop)
    }

    /// macOS 27+ screencaptureui ignores the legacy `location` key entirely for screenshots, so a
    /// value only there — never mirrored to `location-screenshot` — isn't really redirecting
    /// anything on that OS.
    @Test
    func statusIsSavingToDesktopWhenOnlyTheLegacyLocationKeyIsTheInboxPath() {
        let prefs = FakeScreenCapturePreferences()
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        prefs.setValue(h.inboxURL.path, forKey: Key.location)
        h.sut.refresh()
        #expect(h.sut.status == .savingToDesktop)
    }

    @Test
    func statusIsSavingToSnapShelfWhenBothLocationKeysAreTheInboxPath() {
        let prefs = FakeScreenCapturePreferences()
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        prefs.setValue(h.inboxURL.path, forKey: Key.location)
        prefs.setValue(h.inboxURL.path, forKey: Key.screenshotLocation)
        h.sut.refresh()
        #expect(h.sut.status == .savingToSnapShelf)
    }

    @Test
    func statusIsSavingToSnapShelfWhenScreenshotLocationIsTheInboxPathAndLegacyLocationIsAbsent() {
        let prefs = FakeScreenCapturePreferences()
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        prefs.setValue(h.inboxURL.path, forKey: Key.screenshotLocation)
        h.sut.refresh()
        #expect(h.sut.status == .savingToSnapShelf)
    }

    @Test
    func statusIsSavingElsewhereForAnyOtherPath() {
        let prefs = FakeScreenCapturePreferences()
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelfTests-elsewhere")
        prefs.setValue(elsewhere.path, forKey: Key.location)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        #expect(h.sut.status == .savingElsewhere(elsewhere.standardizedFileURL))
    }

    @Test
    func statusStandardizesATrailingSlashOnTheInboxPath() {
        let prefs = FakeScreenCapturePreferences()
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        // `location-screenshot`, not the legacy `location`: that's the key `.savingToSnapShelf`
        // is keyed off of.
        prefs.setValue(h.inboxURL.path + "/", forKey: Key.screenshotLocation)
        h.sut.refresh()
        #expect(h.sut.status == .savingToSnapShelf)
    }

    @Test
    func statusStandardizesADotDotComponentForAnElsewherePath() {
        let prefs = FakeScreenCapturePreferences()
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelfTests-elsewhere")
        let messy = elsewhere.appendingPathComponent("sub").appendingPathComponent("..").path
        prefs.setValue(messy, forKey: Key.location)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }

        // Asserting on `.path` rather than full `Status`/`URL` equality: resolving a `..`
        // component leaves the URL's internal isDirectory hint set (a trailing slash in
        // `absoluteString`) even though the string path is identical, which would make this
        // over-strict for no behavioral reason — `refresh()` itself only ever compares `.path`
        // strings, and every production call site of `.savingElsewhere` only ever reads
        // `url.path`/`url.lastPathComponent`, never full equality against another `Status`.
        guard case .savingElsewhere(let url) = h.sut.status else {
            Issue.record("Expected .savingElsewhere, got \(h.sut.status)")
            return
        }
        #expect(url.path == elsewhere.path)
    }

    // MARK: - enable / restore

    @Test
    func enableThenRestoreRemovesTheKeyWhenNoneExistedBefore() {
        let h = makeHarness()
        defer { h.cleanUp() }

        h.sut.enable()
        #expect(h.prefs.value(forKey: Key.location) as? String == h.inboxURL.standardizedFileURL.path)

        h.sut.restore()
        #expect(h.prefs.value(forKey: Key.location) == nil)
        #expect(h.sut.status == .savingToDesktop)
    }

    @Test
    func enableThenRestorePutsBackACustomPriorLocation() {
        let prefs = FakeScreenCapturePreferences()
        let customPath = "/Users/example/CustomScreenshots"
        prefs.setValue(customPath, forKey: Key.location)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }

        h.sut.enable()
        h.sut.restore()

        #expect(h.prefs.value(forKey: Key.location) as? String == customPath)
        #expect(h.sut.status == .savingElsewhere(URL(fileURLWithPath: customPath).standardizedFileURL))
    }

    @Test
    func callingEnableTwiceKeepsTheFirstBaseline() {
        let prefs = FakeScreenCapturePreferences()
        let firstPath = "/Users/example/First"
        prefs.setValue(firstPath, forKey: Key.location)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }

        h.sut.enable()
        h.sut.enable() // must not re-capture the baseline as the inbox path

        h.sut.restore()
        #expect(h.prefs.value(forKey: Key.location) as? String == firstPath)
    }

    @Test
    func enableAfterRestoreCapturesAFreshBaseline() {
        let prefs = FakeScreenCapturePreferences()
        let firstPath = "/Users/example/First"
        prefs.setValue(firstPath, forKey: Key.location)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }

        h.sut.enable()
        h.sut.restore()

        let secondPath = "/Users/example/Second"
        h.prefs.setValue(secondPath, forKey: Key.location)
        h.sut.enable()
        h.sut.restore()

        #expect(h.prefs.value(forKey: Key.location) as? String == secondPath)
    }

    @Test
    func enableWritesAnAbsoluteStandardizedPathWithNoTilde() throws {
        let h = makeHarness()
        defer { h.cleanUp() }

        h.sut.enable()

        let written = try #require(h.prefs.value(forKey: Key.location) as? String)
        #expect(!written.contains("~"))
        #expect(written.hasPrefix("/"))
        #expect(written == h.inboxURL.standardizedFileURL.path)
    }

    // MARK: - enable / restore: per-type keys (macOS 27)

    @Test
    func enableWritesAllThreeKeysWithRecordingsKeyPointingAtTheInjectedRecordingsDirectory() {
        let h = makeHarness()
        defer { h.cleanUp() }

        h.sut.enable()

        #expect(h.prefs.value(forKey: Key.location) as? String == h.inboxURL.standardizedFileURL.path)
        #expect(h.prefs.value(forKey: Key.screenshotLocation) as? String == h.inboxURL.standardizedFileURL.path)
        #expect(h.prefs.value(forKey: Key.screenRecordingLocation) as? String == h.recordingsURL.standardizedFileURL.path)
    }

    @Test
    func restoreWithNoPriorKeysRemovesAllThreeKeys() {
        let h = makeHarness()
        defer { h.cleanUp() }

        h.sut.enable()
        h.sut.restore()

        #expect(h.prefs.value(forKey: Key.location) == nil)
        #expect(h.prefs.value(forKey: Key.screenshotLocation) == nil)
        #expect(h.prefs.value(forKey: Key.screenRecordingLocation) == nil)
        #expect(h.sut.status == .savingToDesktop)
    }

    @Test
    func restorePutsBackCustomPriorScreenshotAndScreenRecordingLocations() {
        let prefs = FakeScreenCapturePreferences()
        let customScreenshotPath = "/Users/example/CustomScreenshots"
        let customRecordingPath = "/Users/example/CustomRecordings"
        prefs.setValue(customScreenshotPath, forKey: Key.screenshotLocation)
        prefs.setValue(customRecordingPath, forKey: Key.screenRecordingLocation)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }

        h.sut.enable()
        h.sut.restore()

        #expect(h.prefs.value(forKey: Key.screenshotLocation) as? String == customScreenshotPath)
        #expect(h.prefs.value(forKey: Key.screenRecordingLocation) as? String == customRecordingPath)
    }

    /// A remembered `location-screenrecording` baseline that happens to equal our own recordings
    /// path may be the user's own prior choice, not something `enable()` wrote — only a baseline
    /// equal to the *inbox* is safe to assume is ours and drop.
    @Test
    func restorePutsBackARememberedScreenRecordingLocationEvenWhenItMatchesOurRecordingsPath() {
        let prefs = FakeScreenCapturePreferences()
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        prefs.setValue(h.recordingsURL.standardizedFileURL.path, forKey: Key.screenRecordingLocation)

        h.sut.enable()
        h.sut.restore()

        #expect(h.prefs.value(forKey: Key.screenRecordingLocation) as? String == h.recordingsURL.standardizedFileURL.path)
    }

    @Test
    func statusPrefersScreenshotLocationOverLegacyLocation() {
        let prefs = FakeScreenCapturePreferences()
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }

        prefs.setValue(h.inboxURL.path, forKey: Key.location)
        prefs.setValue(desktopPath, forKey: Key.screenshotLocation)
        h.sut.refresh()

        #expect(h.sut.status == .savingToDesktop)
    }

    @Test
    func enableAfterLegacyMigrationRecordsBaselinesForNewKeysAndRestoreRemovesAllThree() {
        let prefs = FakeScreenCapturePreferences()
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }

        // Simulate an earlier version of SnapShelf that already ran `enable()` back when it only
        // managed `location`: the legacy (un-suffixed) baseline defaults are set, recording that
        // `location` didn't exist beforehand, and the fake store already holds the redirected
        // inbox path. The two new keys have no baseline yet.
        h.defaults.set(true, forKey: LegacyDefaultsKey.hasRemembered)
        h.defaults.set(false, forKey: LegacyDefaultsKey.originalKeyExisted)
        h.defaults.removeObject(forKey: LegacyDefaultsKey.originalValue)
        prefs.setValue(h.inboxURL.standardizedFileURL.path, forKey: Key.location)

        h.sut.enable()

        // The legacy `location` baseline was used in place, not re-captured from its current
        // (already-redirected) value.
        #expect(h.prefs.value(forKey: Key.location) as? String == h.inboxURL.standardizedFileURL.path)
        #expect(h.prefs.value(forKey: Key.screenshotLocation) as? String == h.inboxURL.standardizedFileURL.path)
        #expect(h.prefs.value(forKey: Key.screenRecordingLocation) as? String == h.recordingsURL.standardizedFileURL.path)

        h.sut.restore()

        #expect(h.prefs.value(forKey: Key.location) == nil)
        #expect(h.prefs.value(forKey: Key.screenshotLocation) == nil)
        #expect(h.prefs.value(forKey: Key.screenRecordingLocation) == nil)
        #expect(h.sut.status == .savingToDesktop)
    }

    // MARK: - isFloatingThumbnailHidden

    @Test
    func floatingThumbnailHiddenDefaultsToFalseWhenKeyIsAbsent() {
        let h = makeHarness()
        defer { h.cleanUp() }
        #expect(h.sut.isFloatingThumbnailHidden == false)
    }

    @Test
    func floatingThumbnailHiddenIsTrueWhenShowThumbnailIsFalse() {
        let prefs = FakeScreenCapturePreferences()
        prefs.setValue(false, forKey: Key.showThumbnail)
        let h = makeHarness(prefs: prefs)
        defer { h.cleanUp() }
        #expect(h.sut.isFloatingThumbnailHidden == true)
    }

    @Test
    func settingFloatingThumbnailHiddenWritesTheInverseAndSynchronizes() {
        let h = makeHarness()
        defer { h.cleanUp() }

        h.sut.isFloatingThumbnailHidden = true

        #expect(h.prefs.value(forKey: Key.showThumbnail) as? Bool == false)
        #expect(h.prefs.synchronizeCallCount > 0)
    }
}
