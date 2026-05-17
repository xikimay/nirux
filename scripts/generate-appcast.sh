#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: generate-appcast.sh <version> <build-number> <ed-signature> <length>}"
BUILD_NUMBER="${2:?Usage: generate-appcast.sh <version> <build-number> <ed-signature> <length>}"
SIGNATURE="${3:?Usage: generate-appcast.sh <version> <build-number> <ed-signature> <length>}"
LENGTH="${4:?Usage: generate-appcast.sh <version> <build-number> <ed-signature> <length>}"

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
        url="https://github.com/xikimay/nirux/releases/download/nightly/Nirux.app.zip"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}"
        length="${LENGTH}"
      />
    </item>
  </channel>
</rss>
EOF

echo "Generated: $ROOT/appcast.xml"
