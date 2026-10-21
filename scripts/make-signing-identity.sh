#!/bin/sh
# Creates Monoword's stable code-signing identity: a self-signed certificate whose private key lives
# only in a dedicated keychain file, .signing/signing.keychain-db (gitignored, never
# committed). It is NOT added to the login keychain, the keychain search list is put back exactly as
# it was, and no trust settings are changed. build-app.sh signs with it when it exists, so every build
# has the same designated requirement and the Accessibility permission survives rebuilds.
# Keep .signing/ backed up: a new identity means granting Accessibility again.
# Usage: scripts/make-signing-identity.sh
set -e
cd "$(dirname "$0")/.."
DIR="$(pwd)/.signing"
KC="$DIR/signing.keychain-db"
NAME="Monoword Self-Signed Code Signing"
if [ -e "$KC" ]; then echo "$KC already exists; nothing to do."; exit 0; fi
mkdir -p "$DIR"; chmod 700 "$DIR"
umask 077
OSSL=/usr/bin/openssl   # LibreSSL: its .p12 encryption is the kind `security import` reads
"$OSSL" rand -base64 32 | tr -d '\n' > "$DIR/keychain-password"
"$OSSL" rand -base64 32 | tr -d '\n' > "$DIR/p12-password"
KPW=$(cat "$DIR/keychain-password"); PPW=$(cat "$DIR/p12-password")
cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
# The private key is written encrypted (never in plain text), then bundled into a .p12 backup.
"$OSSL" req -x509 -newkey rsa:2048 -sha256 -days 7300 -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.enc.pem" -passout "pass:$PPW" -out "$DIR/cert.pem"
"$OSSL" pkcs12 -export -name "$NAME" -inkey "$DIR/key.enc.pem" -passin "pass:$PPW" -in "$DIR/cert.pem" \
  -out "$DIR/identity-backup.p12" -passout "pass:$PPW"

# `security create-keychain` also appends the new file to the user's search list: put the list back.
BEFORE=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//')
security create-keychain -p "$KPW" "$KC"
echo "$BEFORE" | tr '\n' '\0' | xargs -0 security list-keychains -d user -s
AFTER=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//')
if [ "$BEFORE" != "$AFTER" ]; then echo "Keychain search list differs after restore:"; echo "$AFTER"; exit 1; fi
security set-keychain-settings "$KC"            # no auto-lock timeout on this file
security unlock-keychain -p "$KPW" "$KC"
security import "$DIR/identity-backup.p12" -k "$KC" -P "$PPW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KPW" "$KC" >/dev/null
echo "Created $KC"
security find-certificate -c "$NAME" -Z "$KC" | awk '/SHA-1 hash/ {print "Certificate SHA-1:", $3}'
echo "Search list unchanged:"; security list-keychains -d user
