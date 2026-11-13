#!/usr/bin/env bash
# One-time: creates a private code-signing certificate for this Mac only, so every Ember Mail build has
# the same signature. macOS then remembers "Always Allow" for the Keychain across app updates.
# Run in Terminal:  ./scripts/setup-signing.sh      (asks for your Mac password up to twice)
# Undo: Keychain Access → login → My Certificates → delete "Ember Mail Local Signing".
set -euo pipefail
NAME="Ember Mail Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "✓ Signing identity already set up."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "▸ Certificate exists but isn't trusted yet — fixing that."
  security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
else
  echo "▸ Creating certificate"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
  PASS=$(openssl rand -hex 16)
  openssl pkcs12 -export -name "$NAME" -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout "pass:$PASS"
  security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
fi

echo
echo "▸ macOS will now ask for your password to trust this certificate for code signing (this Mac only)."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "▸ Letting codesign use the key without a prompt on every build."
echo "  Enter your Mac login password when asked for the keychain password:"
security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" "$KEYCHAIN" >/dev/null || \
  echo "  (skipped — you may see one 'codesign wants to use key' prompt; choose Always Allow)"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo
  echo "✓ Done. Rebuild with ./scripts/build-app.sh --install"
else
  echo "✗ The certificate isn't showing as valid. Open Keychain Access → login → Certificates →"
  echo "  '$NAME' → Trust → Code Signing: Always Trust."
  exit 1
fi
