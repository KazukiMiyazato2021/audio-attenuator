#!/bin/bash
# Creates a local self-signed code-signing identity for development.
#
# Why this exists: TCC keys its grants to a code identity. An ad-hoc signature
# changes on every build, so the microphone and audio-capture permissions have
# to be re-approved after every rebuild. Signing with a stable certificate
# keeps the identity constant, so the permissions are granted once.
#
# The certificate lives in the user's login keychain and is only meaningful on
# this machine — it is a development convenience, not a substitute for a
# Developer ID when distributing the app.

set -e

CERT_NAME="${CERT_NAME:-Attenuator Dev}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Signing identity '$CERT_NAME' already exists."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# extendedKeyUsage=codeSigning is what makes the certificate usable by
# codesign; without it the identity is created but never offered.
cat > "$WORK/cert.conf" <<CONF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = v3

[ dn ]
CN = $CERT_NAME

[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

echo "Generating self-signed certificate '$CERT_NAME'..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/cert.conf" 2>/dev/null

# macOS's Security framework rejects PKCS#12 files that use the stronger
# defaults of current OpenSSL, so the bundle is written with the older
# algorithms it accepts. A throwaway password is used because an empty one
# also trips the MAC check.
P12_PASS=attenuator
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASS" -name "$CERT_NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "Importing into the login keychain..."
# -T /usr/bin/codesign lets codesign use the key without a prompt each time.
security import "$WORK/identity.p12" \
    -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$P12_PASS" -T /usr/bin/codesign

# Trust for code signing, in the *user's* trust settings so no sudo is needed.
# Signing itself only needs the key; this keeps codesign from complaining and
# lets the signature verify locally.
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$WORK/cert.pem" 2>/dev/null || {
    echo "Note: could not set trust settings automatically."
    echo "Signing usually still works; if codesign rejects the identity, open"
    echo "Keychain Access, find '$CERT_NAME', and set 'Code Signing' to 'Always Trust'."
}

echo ""
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo ""
echo "Done. Build and sign with:"
echo "  CODESIGN_IDENTITY='$CERT_NAME' scripts/package-app.sh"
