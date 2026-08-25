#!/bin/bash
# xcode-hackatime installer
#
#   curl -fsSL https://raw.githubusercontent.com/hackclub/xcode-hackatime/main/install.sh | bash
#
# curl downloads carry no quarantine xattr, so Gatekeeper does not block
set -euo pipefail

URL="https://github.com/hackclub/xcode-hackatime/releases/latest/download/xcode-hackatime-darwin-universal.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ downloading latest xcode-hackatime release"
curl -fsSL -o "$TMP/xcode-hackatime.zip" "$URL"
ditto -x -k "$TMP/xcode-hackatime.zip" "$TMP"

# the URL is mutable (latest) and the binary is about to run: require
# Apple's Developer ID chain and The Hack Foundation's team before executing
echo "→ verifying code signature"
codesign --verify --strict \
  '-R=anchor apple generic and certificate leaf[subject.OU] = "P6PV2R9443"' \
  "$TMP/xcode-hackatime"

chmod +x "$TMP/xcode-hackatime"
"$TMP/xcode-hackatime" install

echo ""
echo "Almost done! Enable it in:"
echo "  System Settings → Privacy & Security → Accessibility → xcode-hackatime"
echo "Then code in Xcode as usual - that's it!"
