#!/usr/bin/env bash
# Legt eine selbstsignierte Code-Signing-Identität in einem eigenen Schlüsselbund an.
#
# Warum: Ad-hoc-signierte Apps (codesign -s -) bekommen bei jedem Build eine neue
# Identität – macOS vergisst dann die Bedienungshilfen-Freigabe. Mit einem festen
# Zertifikat bleibt die „Designated Requirement" über Updates gleich und die
# Freigabe bleibt bestehen. Ein Apple-Developer-Konto ist dafür nicht nötig.
#
# Ergebnis (nicht ins Repo!):
#   ~/.redefluss-signing/redefluss-signing.keychain-db  (Schlüsselbund, Passwort in .password)
#   ~/.redefluss-signing/redefluss-signing.p12          (Export für GitHub-Actions-Secrets)
set -euo pipefail

NAME="${SIGN_IDENTITY_NAME:-Redefluss Open Source}"
DIR="$HOME/.redefluss-signing"
KEYCHAIN="$DIR/redefluss-signing.keychain-db"

if [[ -f "$KEYCHAIN" ]]; then
  echo "Identität existiert schon: $KEYCHAIN"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
PASSWORD="$(openssl rand -hex 24)"
echo -n "$PASSWORD" > "$DIR/.password"
chmod 600 "$DIR/.password"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
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

openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# -legacy: macOS' security-Tool liest die neuen OpenSSL-3-PKCS12-Algorithmen nicht.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$DIR/redefluss-signing.p12" -passout "pass:$PASSWORD" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -name "$NAME" -out "$DIR/redefluss-signing.p12" -passout "pass:$PASSWORD"
chmod 600 "$DIR/redefluss-signing.p12"
cp "$TMP/cert.pem" "$DIR/redefluss-signing.cer.pem"

security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # kein Auto-Lock
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$DIR/redefluss-signing.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

echo "✅ Identität „${NAME}“ angelegt in $KEYCHAIN"
echo "   Für GitHub Actions: Secrets SIGNING_P12_BASE64 (base64 von redefluss-signing.p12) und SIGNING_P12_PASSWORD (.password)"
echo "   Für lokale Builds einmalig vertrauen (fragt nach deinem Passwort):"
echo "   security add-trusted-cert -r trustRoot -p codeSign -k \"$KEYCHAIN\" \"$DIR/redefluss-signing.cer.pem\""
