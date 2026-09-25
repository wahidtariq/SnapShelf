import Foundation
import Observation

/// Abstracts the `com.apple.screencapture` preferences domain so `CaptureLocationService` can be
/// unit-tested against a fake store instead of touching the user's real system settings.
protocol ScreenCapturePreferences {
    func value(forKey key: String) -> Any?
    func setValue(_ value: Any?, forKey key: String)
    func removeValue(forKey key: String)
    @discardableResult
    func synchronize() -> Bool
}

/// The real `com.apple.screencapture` preferences domain, via `CFPreferences`.
struct CFPreferencesScreenCapturePreferences: ScreenCapturePreferences {
    private static let appID = "com.apple.screencapture" as CFString

    func value(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, Self.appID)
    }

    func setValue(_ value: Any?, forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, Self.appID)
    }

    func removeValue(forKey key: String) {
        CFPreferencesSetAppValue(key as CFString, nil, Self.appID)
    }

    @discardableResult
    func synchronize() -> Bool {
        CFPreferencesAppSynchronize(Self.appID)
    }
}

/// Reads and writes where macOS saves new screenshots and screen recordings
/// (`com.apple.screencapture`'s location keys), redirecting screenshots to SnapShelf's inbox and
/// recordings straight to `~/Movies/Screen Recordings`, then restoring whatever was there before
/// on request.
///
/// Three keys are involved, because screencaptureui's key changed on macOS 27:
/// - `location` — the legacy key. Pre-macOS 27 screencaptureui only looks at this one.
/// - `location-screenshot` — macOS 27+ screencaptureui reads this for still screenshots and
///   ignores `location` entirely.
/// - `location-screenrecording` — macOS 27+ screencaptureui reads this for screen recordings.
///
/// `enable()` writes all three so the redirect works on both old and new macOS; `location` is
/// kept in sync with `location-screenshot` purely for the older OS's benefit.
///
/// This never runs automatically — `enable()` and `restore()` are only ever called from explicit
/// user actions (the Welcome window's button, Settings, or the popover's "Quit & Restore" menu
/// item), never from app launch or background code.
@Observable
@MainActor
final class CaptureLocationService {
    enum Status: Equatable {
        case savingToSnapShelf
        case savingToDesktop
        case savingElsewhere(URL)
    }

    private static let locationKey = "location"
    private static let screenshotLocationKey = "location-screenshot"
    private static let screenRecordingLocationKey = "location-screenrecording"
    private static let thumbnailKey = "show-thumbnail"

    /// The keys `enable()`/`restore()` manage together.
    private static let managedKeys = [locationKey, screenshotLocationKey, screenRecordingLocationKey]

    /// Base names for the per-key baseline `UserDefaults` entries that back `enable()`/
    /// `restore()`. Older versions of SnapShelf only ever managed `location`, using these exact,
    /// un-suffixed names — so `locationKey` keeps resolving to them, and a baseline recorded
    /// before `location-screenshot`/`location-screenrecording` existed is picked up as-is with no
    /// migration step. The two new keys get their own suffixed entries below, recorded the next
    /// time `enable()` runs.
    private static let hasRememberedDefaultsKeyBase = "CaptureLocationService.hasRemembered"
    private static let rememberedKeyExistedDefaultsKeyBase = "CaptureLocationService.originalKeyExisted"
    private static let rememberedValueDefaultsKeyBase = "CaptureLocationService.originalValue"

    private static func hasRememberedDefaultsKey(for key: String) -> String {
        key == locationKey ? hasRememberedDefaultsKeyBase : "\(hasRememberedDefaultsKeyBase).\(key)"
    }

    private static func rememberedKeyExistedDefaultsKey(for key: String) -> String {
        key == locationKey ? rememberedKeyExistedDefaultsKeyBase : "\(rememberedKeyExistedDefaultsKeyBase).\(key)"
    }

    private static func rememberedValueDefaultsKey(for key: String) -> String {
        key == locationKey ? rememberedValueDefaultsKeyBase : "\(rememberedValueDefaultsKeyBase).\(key)"
    }

    private(set) var status: Status = .savingToDesktop

    private let preferences: ScreenCapturePreferences
    private let defaults: UserDefaults
    private let inboxPath: String
    private let recordingsURL: URL

    private var recordingsPath: String { recordingsURL.path }

    init(
        preferences: ScreenCapturePreferences = CFPreferencesScreenCapturePreferences(),
        defaults: UserDefaults = .standard,
        inboxURL: URL = LibraryPaths.inbox,
        recordingsURL: URL = LibraryPaths.screenRecordings
    ) {
        self.preferences = preferences
        self.defaults = defaults
        self.inboxPath = inboxURL.standardizedFileURL.path
        self.recordingsURL = recordingsURL.standardizedFileURL
        refresh()
    }

    /// Re-reads `com.apple.screencapture` and updates `status`. Safe to call anytime, including
    /// from background polling — it never writes anything.
    ///
    /// `.savingToSnapShelf` requires `location-screenshot` itself to point at the inbox — that's
    /// the only key macOS 27+ screencaptureui actually reads for still screenshots. Otherwise the
    /// effective location falls back from `location-screenshot` to the legacy `location` to the
    /// Desktop; if that effective location turns out to be the inbox, only the legacy key is
    /// pointing at us, which macOS 27+ ignores, so it's reported as `.savingToDesktop` rather than
    /// claiming a redirect that isn't actually in effect.
    func refresh() {
        let screenshotValue = preferences.value(forKey: Self.screenshotLocationKey) as? String
        if let screenshotValue, URL(fileURLWithPath: screenshotValue).standardizedFileURL.path == inboxPath {
            status = .savingToSnapShelf
            return
        }

        let effectiveRaw = screenshotValue ?? (preferences.value(forKey: Self.locationKey) as? String)
        guard let effectiveRaw else {
            status = .savingToDesktop
            return
        }
        let standardized = URL(fileURLWithPath: effectiveRaw).standardizedFileURL
        if standardized.path == inboxPath || standardized.path == desktopPath {
            status = .savingToDesktop
        } else {
            status = .savingElsewhere(standardized)
        }
    }

    private var desktopPath: String {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].standardizedFileURL.path
    }

    /// Points `com.apple.screencapture` at SnapShelf: `location` and `location-screenshot` at the
    /// inbox, `location-screenrecording` at `~/Movies/Screen Recordings` (creating that folder
    /// first if it's missing) so recordings land there directly instead of round-tripping through
    /// the app. The first time each key is touched, its prior existence/value is remembered so
    /// `restore()` can put it back exactly as it was.
    func enable() {
        for key in Self.managedKeys {
            rememberBaselineIfNeeded(for: key)
        }

        ensureRecordingsFolderExists()

        preferences.setValue(inboxPath, forKey: Self.locationKey)
        preferences.setValue(inboxPath, forKey: Self.screenshotLocationKey)
        preferences.setValue(recordingsPath, forKey: Self.screenRecordingLocationKey)
        preferences.synchronize()
        refresh()
    }

    /// Puts back whatever value existed for each managed key before its first `enable()` call, or
    /// removes the key entirely if there wasn't one — also removing it if the remembered value
    /// happens to be one of the paths we write (shouldn't normally happen, but leaves nothing
    /// pointing at us). Clears all remembered baselines, so a later `enable()` captures fresh
    /// ones.
    func restore() {
        for key in Self.managedKeys {
            restoreBaseline(for: key)
        }
        preferences.synchronize()

        for key in Self.managedKeys {
            defaults.removeObject(forKey: Self.hasRememberedDefaultsKey(for: key))
            defaults.removeObject(forKey: Self.rememberedKeyExistedDefaultsKey(for: key))
            defaults.removeObject(forKey: Self.rememberedValueDefaultsKey(for: key))
        }

        refresh()
    }

    private func rememberBaselineIfNeeded(for key: String) {
        let hasRememberedKey = Self.hasRememberedDefaultsKey(for: key)
        guard !defaults.bool(forKey: hasRememberedKey) else { return }

        let keyExisted = preferences.value(forKey: key) != nil
        let previousValue = preferences.value(forKey: key) as? String

        defaults.set(true, forKey: hasRememberedKey)
        defaults.set(keyExisted, forKey: Self.rememberedKeyExistedDefaultsKey(for: key))
        if let previousValue {
            defaults.set(previousValue, forKey: Self.rememberedValueDefaultsKey(for: key))
        } else {
            defaults.removeObject(forKey: Self.rememberedValueDefaultsKey(for: key))
        }
    }

    private func restoreBaseline(for key: String) {
        let keyExisted = defaults.bool(forKey: Self.rememberedKeyExistedDefaultsKey(for: key))
        let rememberedValue = defaults.string(forKey: Self.rememberedValueDefaultsKey(for: key))

        if keyExisted, let rememberedValue {
            let standardizedRemembered = URL(fileURLWithPath: rememberedValue).standardizedFileURL.path
            if standardizedRemembered == inboxPath {
                // The remembered value was already pointing at the inbox (shouldn't normally
                // happen) — there's nothing meaningful to restore, so just remove the key. A
                // remembered recordings path is left alone: `~/Movies/Screen Recordings` may be
                // the user's own choice, not something `enable()` wrote.
                preferences.removeValue(forKey: key)
            } else {
                preferences.setValue(rememberedValue, forKey: key)
            }
        } else {
            preferences.removeValue(forKey: key)
        }
    }

    private func ensureRecordingsFolderExists() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: recordingsURL.path) else { return }
        try? fm.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
    }

    /// Whether the floating screenshot thumbnail is hidden. The underlying key is absent by
    /// default, which means the thumbnail is shown.
    var isFloatingThumbnailHidden: Bool {
        get {
            (preferences.value(forKey: Self.thumbnailKey) as? Bool).map { !$0 } ?? false
        }
        set {
            preferences.setValue(!newValue, forKey: Self.thumbnailKey)
            preferences.synchronize()
        }
    }
}
