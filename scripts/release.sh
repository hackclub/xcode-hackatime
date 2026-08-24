#!/bin/bash
# Build, sign, and (when possible) notarize a distributable xcode-hackatime
# release. Produces dist/xcode-hackatime-darwin-universal.zip — the stable
# asset name that install.sh and the hackatime_setup installer download.
#
# Usage: scripts/release.sh [signing-identity]
#   signing-identity defaults to "Developer ID Application"; pass
#   "Apple Development" (or a cert hash) for interim dev-cert releases.
#
# Notarization runs only for Developer ID identities (Apple rejects others)
# and needs stored credentials:
#   xcrun notarytool store-credentials hackatime-notary \
#     --apple-id mahad@hackclub.com --team-id <TEAM_ID> \
#     --password <app-specific password from appleid.apple.com>
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-Developer ID Application}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-hackatime-notary}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

echo "→ building universal binary"
swift build -c release --arch arm64 --arch x86_64
BIN=.build/apple/Products/Release/xcode-hackatime

echo "→ signing with: $IDENTITY"
codesign -f --options runtime --timestamp \
  -s "$IDENTITY" \
  --identifier com.hackclub.hackatime.xcode-hackatime \
  "$BIN"
codesign -dv "$BIN" 2>&1 | grep -E "Authority|TeamIdentifier|flags" || true

mkdir -p dist
ZIP="dist/xcode-hackatime-darwin-universal.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k "$BIN" "$ZIP"

if codesign -dv "$BIN" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "→ notarizing (waits for Apple)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
else
  echo "⚠️  not a Developer ID signature — skipping notarization."
  echo "   Users must install via install.sh / hackatime_setup (curl path);"
  echo "   browser-downloaded copies will be blocked by Gatekeeper."
fi

echo "→ done: $ZIP ($("$BIN" version))"
echo "Publish with: gh release create v$("$BIN" version) $ZIP --generate-notes"
