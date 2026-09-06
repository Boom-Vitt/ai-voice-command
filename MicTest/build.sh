#!/bin/bash
# Builds MicTest.app onto the Desktop.
#
# MicTest is a background Thai dictation app: tap Right-Option, speak, and the
# words are typed into whatever app has keyboard focus. It is an LSUIElement
# (agent) app -- no Dock icon, no window -- because a dictation tool that steals
# focus is worse than useless.
#
# The reason PhayaVoice's LSUIElement was called a defect was never the key
# itself: it was that a menubar icon was its ONLY affordance, and on a notched
# MacBook the status item hid behind the notch with no way back in. MicTest
# ships two affordances instead -- an NSStatusItem AND a floating HUD that never
# fully hides -- so the key is safe here in a way it was not there.
set -euo pipefail
cd "$(dirname "$0")"
SRC=Sources/MicTest
APP="${1:-$HOME/Desktop/MicTest.app}"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
ENTITLEMENTS="$SRC/MicTest.entitlements"
ICON="$SRC/MicTest.icns"

# ---------------------------------------------------------------------------
# Signing identity -- resolved FIRST, before anything is compiled or deleted.
# ---------------------------------------------------------------------------
# WHY A DEVELOPER ID AND NOT AD-HOC:
# An ad-hoc signature (--sign -) gives the bundle a *cdhash-based* designated
# requirement. The cdhash changes on every single rebuild, so macOS treats each
# build as a brand-new app and TCC throws away the microphone grant -- the app
# comes back up at `authorizationStatus: notDetermined` and prompts again. That
# was a deliberate choice while this was a throwaway probe; it is now simply the
# bug the user reported as "save always permission".
#
# Signing with the user's Developer ID instead yields a DR of
#   identifier "com.boombignose.mictest" and anchor apple generic
#   and certificate 1[field.1.2.840.113635.100.6.2.6]
#   and certificate leaf[field.1.2.840.113635.100.6.1.13]
#   and certificate leaf[subject.OU] = "YOUR_TEAM_ID"
# i.e. keyed on identifier + team OU, both of which are stable across rebuilds.
# The TCC grant therefore survives. The archived PhayaVoice used exactly this.
#
# Select your own Developer ID certificate explicitly. Certificate details are
# machine-specific and must not be hardcoded into a shared build script.
SIGN_ID="${MICTEST_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  echo "Set MICTEST_SIGN_ID to your Developer ID certificate SHA-1." >&2
  echo "List identities with: security find-identity -v -p codesigning" >&2
  echo "For a local development build, use ./build-dev.sh instead." >&2
  exit 1
fi
# "-" is codesign's ad-hoc pseudo-identity. Reject it explicitly rather than
# letting it reach codesign: overriding MICTEST_SIGN_ID=- would reintroduce the
# cdhash DR and the exact permission-reset bug this script exists to prevent.
if [ "$SIGN_ID" = "-" ]; then
  echo "✗ MICTEST_SIGN_ID=\"$SIGN_ID\" requests ad-hoc signing, which is refused." >&2
  echo "  Ad-hoc gives a cdhash designated requirement: macOS forgets the" >&2
  echo "  microphone grant on every rebuild and re-prompts. Use a Developer ID" >&2
  echo "  certificate SHA-1 instead." >&2
  exit 1
fi
if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF -- "$SIGN_ID"; then
  echo "✗ code signing identity not found: $SIGN_ID" >&2
  echo "" >&2
  echo "  Refusing to fall back to ad-hoc signing. PhayaVoice's build.sh had" >&2
  echo "  exactly that fallback and it was a defect: ad-hoc signing silently" >&2
  echo "  restores the cdhash-based designated requirement, so macOS forgets" >&2
  echo "  the microphone grant on EVERY rebuild and re-prompts -- while the" >&2
  echo "  build still exits 0 and looks fine." >&2
  echo "" >&2
  echo "  Fix: make the Developer ID available (check Keychain / \`security" >&2
  echo "  find-identity -v -p codesigning\`), or set MICTEST_SIGN_ID to the" >&2
  echo "  SHA-1 of another Developer ID certificate." >&2
  exit 1
fi

# Preflight: the Swift source is authored separately. Fail legibly if it is not
# there yet, instead of letting the unmatched glob reach swiftc as a literal.
if ! compgen -G "$SRC/*.swift" > /dev/null; then
  echo "✗ no Swift sources in $SRC/ -- $SRC/main.swift has not landed yet" >&2
  exit 1
fi

# Same reason the Swift preflight is up here: checked BEFORE the build starts
# removing things. The icon is copied in during bundle assembly, which is after
# `rm -rf "$APP"`, so a missing .icns discovered there would abort with the old
# app already deleted and the new one half-built -- a bundle that looks installed
# and has no icon. The .icns is committed; tools/make-icon.py regenerates it.
if [ ! -f "$ICON" ]; then
  echo "✗ missing app icon: $ICON" >&2
  echo "  Regenerate it with: python3 tools/make-icon.py $ICON" >&2
  exit 1
fi

echo "› compiling"
rm -rf build && mkdir -p build
# main.swift uses top-level code as its entry point, so it must NEVER be
# compiled with -parse-as-library.
swiftc -swift-version 6 -O -wmo -module-name MicTest \
  -sdk "$SDK" -target arm64-apple-macos26.0 \
  "$SRC"/*.swift -o build/MicTest

echo "› assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/MicTest "$APP/Contents/MacOS/MicTest"
# Resources/ is covered by the code signature, so the icon has to be in place
# BEFORE the codesign call below -- adding a file to a signed bundle invalidates
# it, and `codesign --verify` would then fail and delete $APP.
cp "$ICON" "$APP/Contents/Resources/MicTest.icns"

# LSUIElement=true makes this an agent app: no Dock icon, no app switcher entry,
# and -- critically for dictation -- showing the HUD cannot steal keyboard focus
# from the app being dictated into. main.swift sets NSApplicationActivationPolicy
# to .accessory to match; both are needed, the plist key for launch-time
# behaviour and the runtime call for everything after.
#
# NSSpeechRecognitionUsageDescription is as load-bearing as the microphone one:
# LiveRecognizer uses SFSpeechRecognizer, and without this key TCC refuses to
# prompt for kTCCServiceSpeechRecognition at all, so on-device recognition is
# hard-denied and the app produces no live text with no visible reason.
# NSMicrophoneUsageDescription stays: the audio engine still needs it.
#
# CFBundleIconFile names Resources/MicTest.icns; the extension is optional and
# omitted by convention. Because LSUIElement hides the Dock icon, this is not
# decoration -- Finder, Get Info, the Force Quit window, Login Items and the
# Microphone/Accessibility panes of System Settings are the ONLY places the user
# ever sees this app pictured, and those permission panes are exactly where a
# blank generic icon costs a grant. Deliberately NOT CFBundleIconName: that key
# resolves against an asset catalog (Assets.car), which this hand-assembled
# bundle does not have, so it would name nothing.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MicTest</string>
  <key>CFBundleDisplayName</key><string>MicTest</string>
  <key>CFBundleIdentifier</key><string>com.boombignose.mictest</string>
  <key>CFBundleExecutable</key><string>MicTest</string>
  <key>CFBundleIconFile</key><string>MicTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>MicTest listens to your microphone while you hold the dictation hotkey, so it can turn what you say into text.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>MicTest uses on-device speech recognition to turn what you say into Thai text while you hold the dictation hotkey.</string>
  <key>NSHumanReadableCopyright</key><string>Local build</string>
</dict></plist>
PLIST

echo "› signing with $SIGN_ID"
# The hardened runtime (--options runtime) makes TCC *require* an explicit
# com.apple.security.device.audio-input entitlement before it will even show
# the microphone prompt. With it missing, tccd logs
#   "Prompting policy for hardened runtime; service: kTCCServiceMicrophone
#    requires entitlement com.apple.security.device.audio-input but it is
#    missing"
#   -> "Policy disallows prompt ...; access to kTCCServiceMicrophone denied"
# i.e. a hard denial with no prompt at all. That one key is load-bearing, which
# is why both --options runtime and --entitlements must stay.
#
# NOTE: the entitlements plist must contain NO XML comments -- AMFI's parser
# rejects them ("AMFIUnserializeXML: syntax error") and the app then fails to
# launch. Do not "document" MicTest.entitlements inline; the rationale lives
# here in build.sh instead.
#
# NOTE: unlike PhayaVoice's build.sh, this codesign call is NOT suffixed with
# `|| true`. That defect let a malformed entitlements plist silently produce an
# unsigned/stripped app while still printing a success banner.
# Every failure path below also deletes $APP before exiting: a leftover
# signed-but-wrong bundle is a quieter version of the same defect -- it looks
# built, and it hard-denies the mic.
#
# No --deep: it is deprecated, and there is no nested code in this bundle.
if ! codesign --force --sign "$SIGN_ID" \
  --identifier com.boombignose.mictest \
  --entitlements "$ENTITLEMENTS" \
  --options runtime "$APP" 2>&1 | sed 's/^/  /'; then
  echo "✗ codesign FAILED -- $APP is not correctly signed. Refusing to continue." >&2
  rm -rf "$APP"
  exit 1
fi

echo "› verifying"
if ! codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/  /'; then
  echo "✗ codesign --verify FAILED for $APP" >&2
  rm -rf "$APP"
  exit 1
fi

if codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.device.audio-input"; then
  echo "  entitlements embedded: com.apple.security.device.audio-input"
else
  echo "✗ com.apple.security.device.audio-input is NOT in the signature." >&2
  echo "  Under the hardened runtime TCC will hard-deny the microphone with no" >&2
  echo "  prompt. Check $ENTITLEMENTS (no XML comments allowed)." >&2
  rm -rf "$APP"
  exit 1
fi

# Designated-requirement guard. Permission persistence is the entire point of
# signing with a Developer ID, so the DR gets checked just as hard as the
# entitlement does -- guarding one and not the other is the wrong asymmetry.
# A DR that mentions subject.OU is keyed on the team identifier and is stable
# across rebuilds; a DR without it has regressed to cdhash (e.g. something
# re-signed the bundle ad-hoc) and the grants would reset on every build again.
# `codesign -d -r-` prints "designated => ..." on stderr, hence the 2>&1.
if ! DR="$(codesign -d -r- "$APP" 2>&1)"; then
  echo "✗ could not read the designated requirement of $APP." >&2
  printf '%s\n' "$DR" | sed 's/^/  /' >&2
  rm -rf "$APP"
  exit 1
fi
printf '%s\n' "$DR" | sed 's/^/  /'
case "$DR" in
  *subject.OU*) ;;
  *)
    echo "✗ designated requirement has no certificate leaf[subject.OU] term," >&2
    echo "  so it is not keyed on the team identifier. Usually this means the" >&2
    echo "  DR regressed to cdhash (ad-hoc signing), which changes on every" >&2
    echo "  rebuild: macOS forgets the microphone grant each time and" >&2
    echo "  re-prompts. That is exactly the bug this build script exists to" >&2
    echo "  prevent, so the build is failing rather than shipping it." >&2
    echo "  Sign with a Developer ID certificate (see MICTEST_SIGN_ID above)." >&2
    rm -rf "$APP"
    exit 1
    ;;
esac

echo "✓ built $APP"
# One-time consequence of moving from ad-hoc to Developer ID signing: the app's
# TCC identity changes once more with this build, so macOS will ask for
# microphone permission ONE more time. After that the grant persists across
# rebuilds. Do not mistake that single re-prompt for the old bug.
echo "ℹ NOTE: this build changes the app's signing identity, so macOS will ask for microphone permission one final time -- after that the grant persists across rebuilds."
