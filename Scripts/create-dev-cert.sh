#!/bin/bash
# Creates a self-signed code-signing identity "Orbit Development" in the login
# keychain, for local development builds.
#
# Why: macOS stores privacy permissions (Automation, Accessibility, Contacts,
# Calendars, …) per code signature. An ad-hoc signature changes with every
# build, so macOS forgets the permissions after each rebuild. Builds signed with
# a stable certificate keep them:
#
#   Scripts/create-dev-cert.sh                  # once
#   ORBIT_SIGN_IDENTITY="Orbit Development" Scripts/build-app.sh debug
#
# The certificate is valid for ten years, can only sign code and never leaves
# this Mac. It is not marked as trusted (codesign does not need that, and TCC
# only compares the certificate hash in the designated requirement), so no
# system trust settings change. If macOS asks whether codesign may use the key
# on the first build, choose "Always Allow".
#
# Usage: Scripts/create-dev-cert.sh [--remove]
set -euo pipefail

NAME="Orbit Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# The system LibreSSL writes PKCS#12 files that `security import` understands
# (OpenSSL 3 defaults to algorithms macOS cannot read).
OPENSSL=/usr/bin/openssl

die() { echo "error: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ "${1:-}" == "--remove" ]]; then
    if ! security find-certificate -c "$NAME" "$KEYCHAIN" > /dev/null 2>&1; then
        echo "\"$NAME\" is not in the login keychain"
        exit 0
    fi
    security delete-identity -c "$NAME" -t "$KEYCHAIN" > /dev/null
    echo "✓ removed \"$NAME\" (certificate and private key)"
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--remove]" >&2
    exit 64
fi

# Untrusted self-signed identities are listed as "matching", not "valid".
if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "✓ \"$NAME\" already exists. Sign with: ORBIT_SIGN_IDENTITY=\"$NAME\" Scripts/build-app.sh debug"
    exit 0
fi
if security find-certificate -c "$NAME" "$KEYCHAIN" > /dev/null 2>&1; then
    die "a certificate \"$NAME\" exists without its private key; remove it first: $0 --remove"
fi
[[ -x "$OPENSSL" ]] || die "$OPENSSL not found"

umask 077
cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = subject
x509_extensions = codesigning
prompt = no

[ subject ]
CN = $NAME
OU = Local development
O = Orbit

[ codesigning ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

echo "▸ Creating the certificate"
"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2> "$WORK/openssl.log" \
    || { cat "$WORK/openssl.log" >&2; die "openssl could not create the certificate"; }
PASSWORD="$(uuidgen)"
"$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD" 2>> "$WORK/openssl.log" \
    || { cat "$WORK/openssl.log" >&2; die "openssl could not export the identity"; }

echo "▸ Importing into the login keychain (codesign may use the key)"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$PASSWORD" -T /usr/bin/codesign > /dev/null

security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\"" \
    || die "the identity was imported but codesign cannot use it"
echo "✓ Created \"$NAME\". Build with:"
echo "  ORBIT_SIGN_IDENTITY=\"$NAME\" Scripts/build-app.sh debug"
