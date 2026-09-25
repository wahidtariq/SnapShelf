#!/bin/bash
set -euo pipefail

# Always run from the repo root, regardless of where this script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

BUNDLE_ID="dev.wahidtariq.SnapShelf"
DERIVED_DATA=".build/Release"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/SnapShelf.app"
INSTALLED_APP="/Applications/SnapShelf.app"

# project.yml is the source of truth; regenerate so the committed .xcodeproj can't drift from it.
if command -v xcodegen >/dev/null 2>&1; then
    echo "Running xcodegen generate..."
    xcodegen generate
else
    echo "xcodegen not installed, skipping generate (using committed SnapShelf.xcodeproj as-is)."
fi

echo "Building Release..."
xcodebuild -project SnapShelf.xcodeproj -scheme SnapShelf -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates -quiet build

echo "Verifying signature..."
codesign --verify --deep --strict "$BUILT_APP"
codesign -dvv "$BUILT_APP" 2>&1 | grep "^Authority=" | head -1

# The installed copy and any Xcode Debug copy share a bundle identifier, so there can be more than
# one process named SnapShelf running at once — quit all of them before replacing the app bundle
# out from under whichever one is running. `osascript quit` is the polite ask; pkill is the
# backstop if something ignores it (e.g. a hung app, or a Debug copy with dialogs on screen).
echo "Quitting running SnapShelf instances..."
for _ in $(seq 1 20); do
    if ! pgrep -x SnapShelf >/dev/null 2>&1; then
        break
    fi
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    sleep 0.5
done
if pgrep -x SnapShelf >/dev/null 2>&1; then
    echo "SnapShelf still running after 10s, forcing quit..."
    pkill -x SnapShelf || true
fi

echo "Installing to $INSTALLED_APP..."
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

open "$INSTALLED_APP"

echo
echo "Installed. To keep SnapShelf running every day, turn on:"
echo "  Settings -> General -> Open at Login"
echo "in the installed copy."
