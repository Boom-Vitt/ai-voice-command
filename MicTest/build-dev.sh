#!/bin/bash
# Explicit local-development build for a Mac without the production Developer ID.
# Uses a separate bundle identifier/preferences/TCC grants. Ad-hoc signatures can
# require microphone, speech and Accessibility approval again after each rebuild.
# For stable production signing, use build.sh instead.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  echo "Usage: $0 [absolute output.app path]"
  echo "Default: $HOME/Applications/MicTest Dev.app"
  echo "Local development only; permissions may need approval after rebuilding."
}
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then usage; exit 0; fi
if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi

APP="${1:-$HOME/Applications/MicTest Dev.app}"
BUNDLE_ID="com.boombignose.mictest.dev"
SRC="$PWD/Sources/MicTest"
case "$APP" in
  /*.app) ;;
  *) echo "Output must be an absolute path ending in .app" >&2; exit 2 ;;
esac
if [ "$(uname -m)" != "arm64" ]; then
  echo "MicTest currently targets Apple silicon (arm64)." >&2; exit 1
fi
check_destination() {
  if [ -L "$APP" ]; then
    echo "Refusing to replace a symlink: $APP" >&2; exit 1
  fi
  if [ -e "$APP" ]; then
    local existing_id
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
    if [ "$existing_id" != "$BUNDLE_ID" ]; then
      echo "Refusing to replace a bundle that is not MicTest Dev: $APP" >&2; exit 1
    fi
  fi
  # comm excludes process arguments; fixed-string matching accepts spaces and
  # regex characters in the destination without missing a running executable.
  if /bin/ps -axo comm= | /usr/bin/grep -Fx "$APP/Contents/MacOS/MicTest" >/dev/null; then
    echo "Quit MicTest Dev before rebuilding the installed app." >&2; exit 1
  fi
}
check_destination
SDK="$(xcrun --show-sdk-path --sdk macosx)"
test -f "$SRC/MicTest.icns"
/usr/bin/plutil -lint "$SRC/MicTest.entitlements" >/dev/null

# Stage next to the destination so installation can use a same-volume rename.
# The existing app is preserved until compilation and signature verification pass.
APP_PARENT="$(dirname "$APP")"
mkdir -p "$APP_PARENT"
APP_PARENT="$(cd "$APP_PARENT" && pwd -P)"
APP="$APP_PARENT/$(basename "$APP")"
check_destination
STAGING="$(mktemp -d "$APP_PARENT/.mictest-dev.XXXXXX")"
STAGED_APP="$STAGING/MicTest Dev.app"
cleanup() {
  if [ -d "$STAGING/previous.app" ] && [ ! -e "$APP" ]; then
    mv "$STAGING/previous.app" "$APP"
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

echo "Compiling MicTest Dev (Swift 6, arm64, macOS 26)..."
swiftc -swift-version 6 -O -wmo -module-name MicTest \
  -sdk "$SDK" -target arm64-apple-macos26.0 \
  "$SRC"/*.swift -o "$STAGED_APP/Contents/MacOS/MicTest"
cp "$SRC/MicTest.icns" "$STAGED_APP/Contents/Resources/MicTest.icns"
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MicTest Dev</string>
  <key>CFBundleDisplayName</key><string>MicTest Dev</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>MicTest</string>
  <key>CFBundleIconFile</key><string>MicTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M%S)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>MicTest Dev uses the microphone to type your speech. Tap Right Option to start and again to stop.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MicTest Dev uses on-device speech recognition to turn spoken Thai into text.</string>
  <key>NSHumanReadableCopyright</key><string>Local development build</string>
</dict></plist>
PLIST

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --entitlements "$SRC/MicTest.entitlements" --options runtime "$STAGED_APP"
codesign --verify --strict --verbose=2 "$STAGED_APP"
codesign -d --entitlements - --xml "$STAGED_APP" > "$STAGING/entitlements.plist" 2>/dev/null
if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$STAGING/entitlements.plist")" != "true" ]; then
  echo "Audio-input entitlement missing from the signature." >&2; exit 1
fi

# Compilation takes time; the user may have opened/replaced the destination.
check_destination
if [ -e "$APP" ]; then mv "$APP" "$STAGING/previous.app"; fi
mv "$STAGED_APP" "$APP"
echo "Installed: $APP"
echo "Development signature: macOS permissions may need approval after rebuilding."
echo "Launch this app from Finder; tap Right Option to start/stop dictation."
