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

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Scribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi

IDENTITY="${SCRIBE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)}"

if [ -n "$IDENTITY" ]; then
  # Notarization requires a secure timestamp.
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Scribe.entitlements --sign "$IDENTITY" "$APP"
else
  echo "No Developer ID identity found, signing ad-hoc." >&2
  codesign --force --entitlements Resources/Scribe.entitlements --sign - "$APP"
fi

codesign --verify --strict "$APP"
echo "$APP"
