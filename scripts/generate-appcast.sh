#!/usr/bin/env bash
set -euo pipefail

USAGE="Usage: generate-appcast.sh <version> <build-number> <ed-signature> <length> <release-tag>"
VERSION="${1:?$USAGE}"
BUILD_NUMBER="${2:?$USAGE}"
SIGNATURE="${3:?$USAGE}"
LENGTH="${4:?$USAGE}"
# The enclosure points at the dated release's zip, not the rolling `nightly`
# one: the feed then never references a zip that is being replaced, and every
# dated release's appcast stays valid if it is republished to roll back.
RELEASE_TAG="${5:?$USAGE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

cat > "$ROOT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Nirux</title>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/xikimay/nirux/releases/download/${RELEASE_TAG}/Nirux.app.zip"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}"
        length="${LENGTH}"
      />
    </item>
  </channel>
</rss>
EOF

echo "Generated: $ROOT/appcast.xml"
