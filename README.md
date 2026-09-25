# SnapShelf

Every ⇧⌘3/4/5 screenshot goes into a menu bar library instead of cluttering the Desktop.

SnapShelf is a personal macOS menu bar app. It redirects where macOS saves new screenshots, imports them into a searchable library, and gets out of the way — no Dock icon, no extra windows unless you open them.

## Features

- Native screenshot shortcuts (⇧⌘3/4/5) keep working exactly as before.
- Menu bar popover with a scrollable grid of recent screenshots:
  - Click a tile to copy it (PNG + TIFF + a file URL in one pasteboard item, so it pastes cleanly into Slack, Figma, and Messages).
  - Drag a tile out of the popover as a real file.
  - Hover a tile for Copy / Favorite / Delete actions.
  - Navigate with the keyboard (arrows, Return, ⌘1–⌘9).
- Global shortcut to open/close the popover — ⌥⌘S by default, customizable in Settings.
- A separate Library window with four sections (All Screenshots, Today, Favorites, Recently Deleted), search that also matches text *inside* screenshots (Vision OCR), Quick Look, an inspector, and paste/drag-and-drop import.
- Retention settings (auto-expire old screenshots), one-tap Desktop cleanup, and launch at login.
- Screen recordings are moved straight to `~/Movies/Screen Recordings` instead of being imported into the library.

## How it works

SnapShelf doesn't intercept screenshots as they're taken. Instead, it changes *where* macOS's own screenshot tool saves them:

1. It points the `com.apple.screencapture` preferences domain at a hidden inbox folder it owns.
2. It watches that folder (`InboxWatcher`) and, once a new file's write has settled, imports it into a SwiftData library (`ScreenshotImporter`). Movies go to `~/Movies/Screen Recordings` instead of the library.
3. It remembers whatever was in `com.apple.screencapture` before it touched it, so turning the redirect off restores the exact prior state — not just "the Desktop".

Three preference keys are involved, written together by `CaptureLocationService`:

| Key | Purpose |
|---|---|
| `location` | The long-documented legacy key, read by older macOS versions. |
| `location-screenshot` | macOS 27+'s screenshot tool reads this for still screenshots and ignores `location` entirely. |
| `location-screenrecording` | macOS 27+'s screenshot tool reads this for screen recordings. |

The `location-screenshot` / `location-screenrecording` split isn't documented anywhere — it was found by inspecting `screencaptureui` itself. SnapShelf writes all three keys so the redirect works correctly on both older and newer macOS.

### Where data lives

| Path | Contents |
|---|---|
| `~/Library/Application Support/SnapShelf/Inbox` | Where macOS writes new screenshots once capture is redirected. Watched, then emptied as files are imported. |
| `~/Library/Application Support/SnapShelf/Library/<uuid>/<original name>` | Imported screenshots, one folder per shot so the original file name survives (drag-out and Finder copies keep a human-readable name). |
| `~/Library/Application Support/SnapShelf/SnapShelf.store` | The SwiftData store — metadata only (dimensions, dates, favorite/deleted flags, recognized text). Image bytes always stay on disk as files, never in the store. |
| `~/Movies/Screen Recordings` | Where screen recordings are moved; SnapShelf never imports them into its library. |

## Requirements

- macOS 26 or later (developed on macOS 27). The deployment target is set in `project.yml` (`options.deploymentTarget.macOS`).
- Xcode 26 or later (built with Xcode 27).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only if you change `project.yml`:

  ```bash
  brew install xcodegen
  ```

## Build & run

The `.xcodeproj` is committed, so for day-to-day work you don't need XcodeGen at all:

```bash
git clone git@github.com:wahidtariq/SnapShelf.git
cd SnapShelf
open SnapShelf.xcodeproj
```

Press ⌘R in Xcode to build and run.

If you edit `project.yml` (targets, settings, dependencies), regenerate the project before building:

```bash
xcodegen generate
```

Command-line build and test:

```bash
xcodebuild -project SnapShelf.xcodeproj -scheme SnapShelf -destination 'platform=macOS' build
xcodebuild -project SnapShelf.xcodeproj -scheme SnapShelf -destination 'platform=macOS' test
```

### Dependencies

Two Swift packages, declared in `project.yml` and pinned in `Package.resolved`:

| Package | Minimum (`project.yml`) | Resolved |
|---|---|---|
| [MenuBarExtraAccess](https://github.com/orchetect/MenuBarExtraAccess) | 1.3.1 | 1.3.1 |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 1.9.4 | 1.17.0 |

## Install

To run SnapShelf every day instead of launching it from Xcode:

```bash
make install          # or: ./scripts/install.sh
```

This builds a signed Release copy and installs it to `/Applications/SnapShelf.app`, quitting any running copy first. Then turn on **Settings → General → Open at Login** in the installed copy.

Running from Xcode (⌘R) temporarily takes over from the installed copy — the newest launch wins, asking the other running copy to quit. Stop the Xcode run and reopen `/Applications/SnapShelf.app` to go back to the installed copy.

## First launch

The Welcome window opens automatically the first time you launch SnapShelf, offering:

- **Save Screenshots to SnapShelf** — turns on the redirect described above.
- **Import instantly (hides the macOS floating thumbnail)** — see below.
- **Open SnapShelf at login**.

Once enabled, it offers a one-tap **Clean Up Desktop…** to move existing screenshots already sitting on your Desktop into the library (originals go to the Trash, not permanently deleted).

**About the floating-thumbnail delay:** by default, macOS shows a floating thumbnail after every capture and only writes the file to disk once that thumbnail disappears — around 5 seconds later, or sooner if you interact with it. SnapShelf can't import a screenshot before macOS writes it, so with the thumbnail on, imports lag by about 5 seconds. Hiding the thumbnail (the "Import instantly" option, or **Settings → General → Show floating thumbnail after capture**) makes macOS write the file immediately, so imports are instant.

## Usage

### Menu bar popover

| Action | Shortcut |
|---|---|
| Move selection | Arrow keys |
| Copy selected screenshot | Return, or click a tile |
| Copy tile 1–9 | ⌘1 – ⌘9 |
| Delete selected screenshot | ⌘⌫ |
| Open Library | Click the grid icon, or the ⋯ menu |
| Move the popover | Drag its header or any empty space — it returns under the menu bar icon when closed |
| Settings / Quit & Restore Desktop Saving | ⋯ menu |

### Library window

| Action | Shortcut |
|---|---|
| Open Library | ⌘0 |
| Select by dragging | Click and drag over the grid (⇧ adds, ⌘ toggles) |
| Select All | ⌘A |
| Quick Look selection | Space |
| Copy selection | ⌘C |
| Paste / drop to import | ⌘V, or drag files in |
| Move to Recently Deleted | Delete, or ⌘⌫ |
| Toggle Favorite | ⇧⌘F |
| Open in Preview | ⌘O |
| Toggle Inspector | ⌥⌘I |
| Increase / decrease thumbnail size | ⌘+ / ⌘− |

Deleted screenshots move to **Recently Deleted** and are kept there for 30 days before being purged for good (not configurable — matches Finder/Photos). Favorites are exempt from the "Keep screenshots" auto-expiry setting in Settings → Storage.

## Switching back / uninstalling

**Before deleting the app**, turn off the redirect, or macOS will keep saving new screenshots into SnapShelf's hidden inbox folder where nothing is watching it — with the app gone, they'll just pile up unseen.

Do one of:

- Settings → Capture → **Save Screenshots to Desktop**, or
- The popover's ⋯ menu → **Quit & Restore Desktop Saving**

Either one restores `com.apple.screencapture`'s original settings exactly as they were before SnapShelf touched them.

After that, you can optionally delete `~/Library/Application Support/SnapShelf` (this removes your entire screenshot library, so make sure you've moved out anything you want to keep first).

## Notes & limitations

- **Not sandboxed.** SnapShelf edits another app's (`com.apple.screencapture`'s) preferences, which the App Sandbox doesn't allow — so it isn't, and can't be, Mac App Store-ready.
- **Signed with a Personal Team** (`DEVELOPMENT_TEAM: M233Y22CJD` in `project.yml`), automatically. Launch at login is only reliable from a signed copy running in `/Applications` (see [Install](#install)) — a Debug build launched from Xcode registers DerivedData's copy as the login item instead.
- **App icon** is an Icon Composer file (`SnapShelf/Resources/AppIcon.icon`); the generator scripts and design renders live in `design/icon/`.
- **PDFs are skipped for OCR.** `TextRecognitionService` returns an empty string for PDFs rather than rendering a page through Core Graphics first; screenshots are overwhelmingly PNG/HEIC in practice.

## Project structure

```
SnapShelf/
├── App/          # App entry point, AppState (owns every service), AppDelegate, activation policy
├── Services/      # Capture-location redirect, inbox watching, import, retention, OCR, pasteboard, thumbnails, launch-at-login, Desktop cleanup
├── MenuBar/       # The menu bar popover UI (grid, tiles, copy toast)
├── Library/       # The Library window UI (sidebar, grid, toolbar, inspector, menu commands)
├── Onboarding/    # First-launch Welcome window
├── Settings/      # General / Capture / Storage preference tabs
├── Models/        # SwiftData model and on-disk path helpers
└── Resources/     # Asset catalog
```

`SnapShelfTests/` uses [Swift Testing](https://developer.apple.com/documentation/testing) (`@Suite`/`@Test`), with fakes for `com.apple.screencapture` and in-memory SwiftData stores — tests never touch your real preferences, screenshots, or `~/Movies/Screen Recordings`.
