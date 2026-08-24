#!/bin/bash
# xcode-hackatime installer - Hackatime/WakaTime tracking for Xcode.
#
#   curl -fsSL https://raw.githubusercontent.com/hackclub/xcode-hackatime/main/install.sh | bash
#
# Downloads the latest signed release and installs the background agent.
# (curl downloads don't get the quarantine xattr, so Gatekeeper won't block.)
set -euo pipefail

URL="https://github.com/hackclub/xcode-hackatime/releases/latest/download/xcode-hackatime-darwin-universal.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ downloading latest xcode-hackatime release"
curl -fsSL -o "$TMP/xcode-hackatime.zip" "$URL"
ditto -x -k "$TMP/xcode-hackatime.zip" "$TMP"
chmod +x "$TMP/xcode-hackatime"

"$TMP/xcode-hackatime" install

echo ""
echo "Almost done! Enable it in:"
echo "  System Settings → Privacy & Security → Accessibility → xcode-hackatime"
echo "Then code in Xcode as usual - that's it!"
