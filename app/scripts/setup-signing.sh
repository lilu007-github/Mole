#!/bin/bash
# Create a local self-signed code-signing identity for Burrow (run once).
#
# Ad-hoc signatures are pinned to the code hash, so every rebuild looks like a
# new app to macOS and loses its privacy grants (App Management, Full Disk
# Access). A stable certificate makes the designated requirement
# "identifier dev.burrow.app and certificate leaf = <this cert>" instead.
#
# The identity lives in its own keychain, not the login keychain. Its random
# password is kept in ~/.config/burrow (mode 600) so build-app.sh can unlock it.
# Remove everything with: app/scripts/setup-signing.sh --remove

set -euo pipefail

NAME="Burrow Local Signing"
KEYCHAIN="$HOME/Library/Keychains/burrow-signing.keychain-db"
PASS_FILE="$HOME/.config/burrow/signing-keychain-password"

search_list() {
    security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//'
}

if [[ "${1:-}" == "--remove" ]]; then
    remaining=()
    while IFS= read -r kc; do
        [[ "$kc" == "$KEYCHAIN" ]] || remaining+=("$kc")
    done < <(search_list)
    security list-keychains -d user -s "${remaining[@]}"
    [[ -f "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN"
    rm -f "$PASS_FILE"
    echo "Removed $NAME"
    exit 0
fi

if [[ -f "$KEYCHAIN" && -f "$PASS_FILE" ]]; then
    security unlock-keychain -p "$(cat "$PASS_FILE")" "$KEYCHAIN"
    if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
        echo "$NAME already set up in $KEYCHAIN"
        exit 0
    fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" << EOF
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
EOF

# /usr/bin/openssl is LibreSSL, whose PKCS#12 output `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2> /dev/null
P12_PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" -passout "pass:$P12_PASS"

mkdir -p "$(dirname "$PASS_FILE")"
(umask 077 && /usr/bin/openssl rand -hex 24 > "$PASS_FILE")
KC_PASS="$(cat "$PASS_FILE")"

[[ -f "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN"
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign > /dev/null
# Let codesign use the key without a confirmation dialog.
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KEYCHAIN" > /dev/null

# codesign only finds identities in keychains on the user search list.
existing=()
while IFS= read -r kc; do
    [[ "$kc" == "$KEYCHAIN" ]] || existing+=("$kc")
done < <(search_list)
security list-keychains -d user -s "${existing[@]}" "$KEYCHAIN"

echo "Created $NAME in $KEYCHAIN"
security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
