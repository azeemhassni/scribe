#!/usr/bin/env bash
# Print a Sparkle appcast for one release.
#
#   scripts/appcast.sh <zip> <version> <build> <download-url> [notes-file]
#
# Signs the zip with the EdDSA key stored in the keychain under the account
# "scribe" (create it once with: .build/artifacts/sparkle/Sparkle/bin/generate_keys --account scribe).
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="$1" VERSION="$2" BUILD="$3" URL="$4" NOTES="${5:-}"
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account scribe "$ZIP")"

DESCRIPTION=""
if [ -n "$NOTES" ] && [ -s "$NOTES" ]; then
  ITEMS="$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/^- \(.*\)$/<li>\1<\/li>/' "$NOTES")"
  DESCRIPTION="<description><![CDATA[<ul>${ITEMS}</ul>]]></description>"
fi

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Scribe</title>
    <item>
      <title>Scribe $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/azeemhassni/scribe/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      $DESCRIPTION
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
