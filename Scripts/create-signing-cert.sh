#!/bin/bash
# Creates a self-signed code-signing identity "LockWidgets Local Signing" in the login keychain.
# Signing with a stable identity means macOS keeps Full Disk Access / Accessibility / Bluetooth
# permissions across rebuilds (ad-hoc signatures change every build, so TCC forgets them).
set -euo pipefail

NAME="LockWidgets Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Identity \"$NAME\" already exists."
    exit 0
fi

WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

# Random one-time password just for moving the key into the keychain.
P12PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$P12PASS" 2>/dev/null

# -T lets codesign use the private key without a keychain prompt.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/security

echo "Created identity \"$NAME\" (valid 10 years) in the login keychain."
