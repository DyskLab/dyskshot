#!/bin/bash
# Creates a stable self-signed code-signing identity "DyskShot Local Signing" in the login keychain,
# so macOS privacy permissions (Screen & System Audio Recording, Mic, Camera) survive rebuilds.
# Remove later with: security delete-identity -c "DyskShot Local Signing"
set -euo pipefail
NAME="DyskShot Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Identity '$NAME' already exists."; exit 0
fi
TMP=$(mktemp -d)
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" >/dev/null 2>&1
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:dyskshot >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:dyskshot
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P dyskshot -T /usr/bin/codesign >/dev/null
rm -rf "$TMP"
echo "Created '$NAME'."
