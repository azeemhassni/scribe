#!/usr/bin/env bash
# Build, notarize and publish a release to GitHub.
#
#   scripts/release.sh 0.1.0            build, notarize, tag and publish
#   scripts/release.sh 0.1.0 --dry-run  build and notarize only
#
# Needs a notarytool keychain profile (default name: scribe-notary):
#   xcrun notarytool store-credentials scribe-notary \
#     --apple-id you@example.com --team-id TEAMID --password app-specific-password
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN="${2:-}"
PROFILE="${NOTARY_PROFILE:-scribe-notary}"
TAG="v$VERSION"
APP="build/Scribe.app"
ZIP="build/Scribe.zip"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/release.sh X.Y.Z [--dry-run]"
if [ "$DRY_RUN" != "--dry-run" ]; then
  [ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
  [ "$(git branch --show-current)" = "main" ] || fail "releases are made from main"
  git rev-parse "$TAG" >/dev/null 2>&1 && fail "$TAG already exists"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in"
fi
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "notarytool profile '$PROFILE' not found (see the top of this script)"

echo "==> Building $VERSION"
SCRIBE_VERSION="$VERSION" scripts/bundle.sh
# Read the signature first: with pipefail, `codesign | grep -q` fails on a match.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application"* ]] \
  || fail "the app is not signed with a Developer ID identity"

echo "==> Notarizing"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"

# Re-zip so the download carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"

echo "==> Writing appcast"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
NOTES="build/release-notes.md"
PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
git log --format='- %s' ${PREVIOUS:+"$PREVIOUS"..}HEAD > "$NOTES"
scripts/appcast.sh "$ZIP" "$VERSION" "$BUILD" \
  "https://github.com/azeemhassni/scribe/releases/download/$TAG/Scribe.zip" "$NOTES" > build/appcast.xml
xmllint --noout build/appcast.xml

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Dry run: $ZIP is ready, nothing published."
  exit 0
fi

echo "==> Publishing $TAG"
git tag -a "$TAG" -m "Scribe $VERSION"
git push origin "$TAG"
# appcast.xml rides along with every release, so
# releases/latest/download/appcast.xml always describes the newest version.
gh release create "$TAG" "$ZIP" build/appcast.xml --title "Scribe $VERSION" --notes-file "$NOTES"
echo "Released: $(gh release view "$TAG" --json url --jq .url)"
