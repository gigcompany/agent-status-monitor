#!/usr/bin/env bash
# Builds AgentMonitor.app. A real bundle (not a bare binary) is required for
# UNUserNotificationCenter to deliver notifications at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

APP_NAME="AgentMonitor"
BUNDLE_ID="com.gofloaters.agentmonitor"
VERSION="1.0.0"
DEST="${1:-$HERE/build}"
APP="$DEST/$APP_NAME.app"

echo "==> Compiling (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
[[ -x "$BIN" ]] || { echo "build failed: no binary at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Agent Monitor</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# macOS refuses notification authorization for ad-hoc signed apps, so use a
# real signing identity when one exists and fall back to ad-hoc otherwise.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' \
        | head -1 | tr -d '"')"
fi

if [[ -n "$IDENTITY" ]]; then
    echo "==> Signing as: $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
        --options runtime "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> Signing (ad-hoc) - notifications will NOT work."
    echo "    Install a free Apple Development certificate via Xcode to enable them."
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> Built $APP"
