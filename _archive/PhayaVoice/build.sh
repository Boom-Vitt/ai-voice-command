#!/bin/bash
# Builds PhayaVoice.app onto the Desktop.
set -euo pipefail
cd "$(dirname "$0")"
SRC=Sources/PhayaVoice
APP="${1:-$HOME/Desktop/PhayaVoice.app}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

echo "› compiling"
rm -rf build && mkdir -p build
# main.swift must NOT be compiled with -parse-as-library: top-level code is the entry point.
swiftc -swift-version 6 -O -wmo -module-name PhayaVoice \
  -sdk "$SDK" -target arm64-apple-macos26.0 \
  "$SRC"/*.swift -o build/PhayaVoice

echo "› assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/PhayaVoice "$APP/Contents/MacOS/PhayaVoice"

if [ -d /tmp/pvicon ]; then
  ICONSET=build/PhayaVoice.iconset; mkdir -p "$ICONSET"
  cp /tmp/pvicon/icon_16.png   "$ICONSET/icon_16x16.png"
  cp /tmp/pvicon/icon_32.png   "$ICONSET/icon_16x16@2x.png"
  cp /tmp/pvicon/icon_32.png   "$ICONSET/icon_32x32.png"
  cp /tmp/pvicon/icon_64.png   "$ICONSET/icon_32x32@2x.png"
  cp /tmp/pvicon/icon_128.png  "$ICONSET/icon_128x128.png"
  cp /tmp/pvicon/icon_256.png  "$ICONSET/icon_128x128@2x.png"
  cp /tmp/pvicon/icon_256.png  "$ICONSET/icon_256x256.png"
  cp /tmp/pvicon/icon_512.png  "$ICONSET/icon_256x256@2x.png"
  cp /tmp/pvicon/icon_512.png  "$ICONSET/icon_512x512.png"
  cp /tmp/pvicon/icon_1024.png "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/PhayaVoice.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>PhayaVoice</string>
  <key>CFBundleDisplayName</key><string>PhayaVoice</string>
  <key>CFBundleIdentifier</key><string>com.boombignose.phayavoice</string>
  <key>CFBundleExecutable</key><string>PhayaVoice</string>
  <key>CFBundleIconFile</key><string>PhayaVoice</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <!-- menubar-only: no Dock icon, no main window -->
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>PhayaVoice records your voice only while you hold the dictation key, and transcribes it on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>PhayaVoice converts your speech to text locally.</string>
  <key>NSHumanReadableCopyright</key><string>Local build</string>
</dict></plist>
PLIST

# Sign with the user's Developer ID. This is what makes the designated
# requirement "identifier + certificate leaf" instead of "cdhash" -- so a
# rebuild no longer revokes the Accessibility/Microphone grants.
# Referenced by SHA-1 because two certs share the same common name.
SIGN_ID="${PHAYAVOICE_SIGN_ID:-06A6DF4F3FF0A89E2B74786D7C36220260ACA82E}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "› signing with Developer ID $SIGN_ID"
else
  echo "› Developer ID not found, falling back to ad-hoc (grants will reset on each build)"
  SIGN_ID="-"
fi
# Entitlements. The hardened runtime (--options runtime, below) makes TCC
# *require* an explicit com.apple.security.device.audio-input entitlement
# before it will even show the microphone prompt -- with it missing, tccd logs
# "Prompting policy for hardened runtime; ... requires entitlement
# com.apple.security.device.audio-input but it is missing" and hard-denies the
# mic with no prompt. AudioRecorder.swift captures via AVFoundation, so that
# one key is required, and it is the only key we grant.
#
# Deliberately NOT granted:
#   com.apple.security.cs.disable-library-validation
#     Library validation gates code loaded *into this process*. The
#     third-party, ad-hoc-signed whisper-server is exec'd as a separate
#     process (WhisperServerManager.swift), and a child is validated against
#     its own signature, not the parent's flag. The app dlopen()s nothing and
#     embeds no frameworks, so no foreign code enters this address space.
#   com.apple.security.cs.allow-dyld-environment-variables
#     Only controls whether DYLD_* is honoured for *this* process. Nothing
#     sets DYLD_*; the child merely inherits the ambient environment.
#   com.apple.security.app-sandbox (and the .network.* keys that go with it)
#     Would break both the child-process spawn and the Accessibility APIs.
#
# NOTE: the entitlements plist must contain no XML comments -- AMFI's parser
# rejects them ("AMFIUnserializeXML: syntax error"), which is why the
# rationale lives here instead of in the file.
ENTITLEMENTS="$SRC/PhayaVoice.entitlements"
codesign --force --deep --sign "$SIGN_ID" \
  --identifier com.boombignose.phayavoice \
  --entitlements "$ENTITLEMENTS" \
  --options runtime "$APP" 2>&1 | sed 's/^/  /' || true
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input"; then
  echo "  entitlements embedded: com.apple.security.device.audio-input"
else
  echo "  WARNING: audio-input entitlement is NOT in the signature -- the mic will be denied"
fi

echo "✓ built $APP"
