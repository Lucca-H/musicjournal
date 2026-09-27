#!/usr/bin/env bash
# Creates a local, self-signed code-signing identity ("MusicJournal Local Signing") in your
# login keychain, so every build of MusicJournal has the same signature. macOS then keeps
# permissions you grant (Screen Recording, controlling Spotify, Keychain access) across
# rebuilds instead of treating each build as a new app.
# Remove it any time: Keychain Access › login › My Certificates › delete it.
set -euo pipefail
NAME="MusicJournal Local Signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Already set up: $NAME"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.conf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout pass:musicjournal 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -name "$NAME" -out "$WORK/identity.p12" -passout pass:musicjournal

# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P musicjournal -T /usr/bin/codesign >/dev/null
echo "Created: $NAME"
