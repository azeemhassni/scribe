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
codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" \
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

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Dry run: $ZIP is ready, nothing published."
  exit 0
fi

echo "==> Publishing $TAG"
git tag -a "$TAG" -m "Scribe $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "Scribe $VERSION" --generate-notes
echo "Released: $(gh release view "$TAG" --json url --jq .url)"
