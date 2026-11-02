#!/usr/bin/env bash
# Build build/Scribe.app for Apple Silicon.
#
# Signs with the first "Developer ID Application" identity in the keychain, or
# SCRIBE_SIGN_IDENTITY if set. macOS ties microphone and audio permissions to
# the signature, so an ad-hoc signed build loses them on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Scribe.app"
VERSION="${SCRIBE_VERSION:-}"

# SwiftPM compiles Package.swift inside its own sandbox-exec, which cannot nest
# inside Homebrew's build sandbox ("sandbox_apply: Operation not permitted"), so
# the formula sets this to --disable-sandbox. Left empty everywhere else.
SWIFT_BUILD=(swift build -c release --arch arm64)
if [ -n "${SCRIBE_SWIFT_FLAGS:-}" ]; then
  # shellcheck disable=SC2206 # deliberate word splitting: these are flags
  SWIFT_BUILD+=($SCRIBE_SWIFT_FLAGS)
fi

"${SWIFT_BUILD[@]}"
BIN="$("${SWIFT_BUILD[@]}" --show-bin-path)/Scribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle, for updates. Its XPC services exist for sandboxed apps; Scribe is
# not sandboxed, so they are left out.
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Scribe"

if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  # Sparkle compares this number, so it must grow with every release.
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${SCRIBE_BUILD:-$(git rev-list --count HEAD)}" "$APP/Contents/Info.plist"
fi

IDENTITY="${SCRIBE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  # Notarization requires a secure timestamp and the hardened runtime on
  # every executable, nested ones first.
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
else
  # Ad-hoc, and deliberately without the hardened runtime: library validation
  # refuses to load an ad-hoc signed Sparkle.framework into an ad-hoc signed
  # app ("different Team IDs"), so the app builds and signs cleanly and then
  # will not launch at all.
  echo "No Developer ID identity, signing ad-hoc." >&2
  SIGN=(codesign --force --sign -)
fi
FW="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" --entitlements Resources/Scribe.entitlements "$APP"

codesign --verify --strict "$APP"
echo "$APP"
