#!/bin/bash
# Upload the signing and notarization secrets that .github/workflows/release.yaml
# reads. Run once per certificate; re-run to rotate.
#
# Usage: scripts/setup-signing.sh <identity.p12>
#
# The .p12 must hold one Apple code-signing certificate on The Hack
# Foundation team AND its private key. "Developer ID Application" gives
# notarized, Gatekeeper-clean releases; a development cert ("Mac Developer"
# / "Apple Development") works for the curl and hackatime_setup install
# paths, which pin the team ID rather than the certificate type.
# Export the identity from Keychain Access (right-click > Export) on the
# Mac that generated its signing request; only that Mac has the key.
#
# Notarization runs only for Developer ID and needs an app-specific
# password from appleid.apple.com (Sign-In and Security > App-Specific
# Passwords); the prompts are skipped for development certs.
set -euo pipefail
cd "$(dirname "$0")/.."

P12="${1:?usage: scripts/setup-signing.sh <identity.p12>}"
TEAM_ID=P6PV2R9443

read -rsp "p12 password: " P12_PASSWORD; echo

CERT=$(openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nokeys -clcerts -legacy 2>/dev/null ||
       openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nokeys -clcerts 2>/dev/null)
[ -n "$CERT" ] || { echo "could not read $P12 (wrong password?)" >&2; exit 1; }
[ "$(echo "$CERT" | grep -c 'BEGIN CERT')" = 1 ] ||
  { echo "p12 holds more than one certificate; export a single identity" >&2; exit 1; }
SUBJECT=$(echo "$CERT" | openssl x509 -noout -subject)
echo "$SUBJECT" | grep -q "OU ?= ?$TEAM_ID" ||
  { echo "certificate is not on team $TEAM_ID: $SUBJECT" >&2; exit 1; }
{ openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nocerts -nodes -legacy 2>/dev/null ||
  openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -nocerts -nodes 2>/dev/null; } | grep -q "PRIVATE KEY" ||
  { echo "p12 has no private key - export the identity, not just the certificate" >&2; exit 1; }

IDENTITY=$(echo "$SUBJECT" | sed -E 's/.*CN ?= ?([^,]*).*/\1/')
echo "→ identity: $IDENTITY"

base64 -i "$P12" | gh secret set CSC_LINK
gh secret set CSC_KEY_PASSWORD --body "$P12_PASSWORD"
gh secret set APPLE_SIGNING_IDENTITY --body "$IDENTITY"
gh secret set APPLE_TEAM_ID --body "$TEAM_ID"

if echo "$IDENTITY" | grep -q "^Developer ID Application"; then
  read -rp "Apple ID for notarization [mahad@hackclub.com]: " APPLE_ID
  gh secret set APPLE_ID --body "${APPLE_ID:-mahad@hackclub.com}"
  read -rsp "app-specific password: " APPLE_PASSWORD; echo
  gh secret set APPLE_APP_SPECIFIC_PASSWORD --body "$APPLE_PASSWORD"
else
  echo "→ development cert: notarization will be skipped in CI"
fi

echo "→ done. Push a v* tag to build, sign and publish."
gh secret list
