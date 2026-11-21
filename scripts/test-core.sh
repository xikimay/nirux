#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../NiruxCore"

swift=$(xcrun --find swift)
plugins="$(dirname "$swift")/../lib/swift/host/plugins/testing"
# The standalone Command Line Tools ship TestingMacros outside the default plugin path.
if [[ -d "$plugins" ]] && ! xcrun --find xctest >/dev/null 2>&1; then
    exec "$swift" test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec "$swift" test "$@"
