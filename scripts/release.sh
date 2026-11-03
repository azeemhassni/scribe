#!/usr/bin/env bash
# Tag a release and point the Homebrew tap at it.
#
#   scripts/release.sh 0.1.0
#
# Scribe is distributed as source: Homebrew compiles and signs it on the user's
# own Mac. Nothing ships as a binary, so there is nothing to notarize and no
# Sparkle appcast to sign.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
TAP="${SCRIBE_TAP:-$HOME/Code/homebrew-tap}"
REPO="azeemhassni/scribe"
TAG="v$VERSION"
NOTES="build/release-notes.md"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: scripts/release.sh X.Y.Z"
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
[ "$(git branch --show-current)" = "main" ] || fail "releases are made from main"
git rev-parse "$TAG" >/dev/null 2>&1 && fail "$TAG already exists"
[ -d "$TAP/.git" ] || fail "no tap checkout at $TAP (set SCRIBE_TAP)"
[ -z "$(git -C "$TAP" status --porcelain Formula)" ] || fail "the tap has uncommitted formula changes"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in"

# The formula builds from source, so a tag that does not compile is a broken
# release for everyone who installs it. Find that out before tagging.
echo "==> Building $VERSION"
SCRIBE_VERSION="$VERSION" scripts/bundle.sh >/dev/null

echo "==> Publishing $TAG"
PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
git log --format='- %s' ${PREVIOUS:+"$PREVIOUS"..}HEAD > "$NOTES"
git tag -a "$TAG" -m "Scribe $VERSION"
git push origin "$TAG"
gh release create "$TAG" --title "Scribe $VERSION" --notes-file "$NOTES"

# GitHub builds the source tarball from the tag, so its checksum only exists
# once the tag is pushed.
echo "==> Updating the tap"
URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)"
FORMULA="$TAP/Formula/scribe.rb"
sed -i '' \
  -e "s|^  url \".*\"$|  url \"$URL\"|" \
  -e "s|^  sha256 \".*\"$|  sha256 \"$SHA\"|" \
  "$FORMULA"
grep -q "\"$SHA\"" "$FORMULA" || fail "could not rewrite $FORMULA"

git -C "$TAP" pull -q --ff-only
git -C "$TAP" commit -qm "Scribe $VERSION" -- Formula/scribe.rb
git -C "$TAP" push -q
echo "Released: $(gh release view "$TAG" --json url --jq .url)"
