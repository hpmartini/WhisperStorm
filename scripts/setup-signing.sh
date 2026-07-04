#!/bin/bash
# Creates a stable self-signed code-signing identity "WhisperStorm Dev" in a
# dedicated keychain. WhisperStorm signs every build with it so the
# Accessibility (TCC) permission survives rebuilds — ad-hoc signing changes
# the code hash each build and silently invalidates the grant, which breaks
# text insertion.
#
# Run once:  ./scripts/setup-signing.sh
# Idempotent: re-running recreates the identity from scratch.
set -euo pipefail

IDENTITY="WhisperStorm Dev"
KEYCHAIN="$HOME/Library/Keychains/whisperstorm-dev.keychain-db"
KC_PASS="wskcpass"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=$IDENTITY" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
  -out "$WORKDIR/dev.p12" -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -passout pass:wsp12 >/dev/null 2>&1

echo "==> Creating dedicated keychain"
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

echo "==> Importing identity"
security import "$WORKDIR/dev.p12" -k "$KEYCHAIN" -P wsp12 -A -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1

echo "==> Adding keychain to the search list"
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
case " $EXISTING " in
  *" $KEYCHAIN "*) ;;                                       # already present
  *) security list-keychains -d user -s "$KEYCHAIN" $EXISTING ;;
esac

echo
echo "Done. Identity installed:"
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY" || true
echo
echo "The identity is self-signed, so it shows as untrusted (CSSMERR_TP_NOT_TRUSTED)"
echo "in the trust store — that is expected and does not stop local signing."
echo "Now build: xcodegen generate && xcodebuild ... (see README)."
echo "Grant Accessibility once more after the first signed build; it will then"
echo "persist across future rebuilds."
