#!/bin/bash
# Create a reusable, local-only signing identity. Never recreate it on each build.
set -euo pipefail
umask 077

SIGNING_DIR="${SIGNING_CONFIG_DIR:-$HOME/Library/Application Support/SnapTranslate/Signing}"
IDENTITY_FILE="$SIGNING_DIR/identity.sha1"
CERTIFICATE_NAME="SnapTranslate Local Signing"
KEYCHAIN="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaptranslate-signing.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

if [ -f "$IDENTITY_FILE" ]; then
    IDENTITY="$(cat "$IDENTITY_FILE")"
    if ! [[ "$IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
        echo "Invalid signing identity file: $IDENTITY_FILE" >&2
        exit 1
    fi
else
    # Reuse an earlier setup, including one interrupted after importing the key.
    security find-identity -p codesigning "$KEYCHAIN" > "$TEMP_DIR/identities.txt"
    sed -nE "s/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) \"$CERTIFICATE_NAME\".*$/\1/p" \
        "$TEMP_DIR/identities.txt" | sort -u > "$TEMP_DIR/matches.txt"
    MATCH_COUNT="$(wc -l < "$TEMP_DIR/matches.txt" | tr -d ' ')"
    if [ "$MATCH_COUNT" -gt 1 ]; then
        echo "Multiple local signing identities found. Select the original certificate instead of creating another." >&2
        exit 1
    elif [ "$MATCH_COUNT" -eq 1 ]; then
        IDENTITY="$(cat "$TEMP_DIR/matches.txt")"
    else
        if security find-certificate -c "$CERTIFICATE_NAME" "$KEYCHAIN" > /dev/null 2>&1; then
            echo "The signing certificate exists but its private key is unavailable. Restore it in Keychain Access; do not replace the identity." >&2
            exit 1
        fi
        /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
            -subj "/CN=$CERTIFICATE_NAME/" \
            -addext 'basicConstraints=critical,CA:FALSE' \
            -addext 'keyUsage=critical,digitalSignature' \
            -addext 'extendedKeyUsage=critical,codeSigning' \
            -keyout "$TEMP_DIR/private-key.pem" -out "$TEMP_DIR/certificate.pem" \
            > /dev/null 2> "$TEMP_DIR/openssl.log"
        # security's OpenSSL importer expects traditional PKCS#1, not PKCS#8 PEM.
        /usr/bin/openssl rsa -in "$TEMP_DIR/private-key.pem" -out "$TEMP_DIR/private-rsa.pem" > /dev/null 2>&1
        # Restrict unattended access to codesign; never grant all apps access (-A).
        # -x makes the imported key non-extractable. No key or password is saved in the repo.
        security import "$TEMP_DIR/private-rsa.pem" -k "$KEYCHAIN" -f openssl -t priv \
            -x -T /usr/bin/codesign > /dev/null
        security import "$TEMP_DIR/certificate.pem" -k "$KEYCHAIN" > /dev/null
        IDENTITY="$(/usr/bin/openssl x509 -in "$TEMP_DIR/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')"
    fi
fi

# Confirm the identity can actually sign before making it the build default.
# This does not add certificate trust overrides or alter any privacy permissions.
printf 'int main(void) { return 0; }\n' > "$TEMP_DIR/probe.c"
xcrun clang "$TEMP_DIR/probe.c" -o "$TEMP_DIR/probe"
codesign --force --sign "$IDENTITY" --identifier com.local.SnapTranslate.signing-probe "$TEMP_DIR/probe"
codesign --verify --strict "$TEMP_DIR/probe"
codesign -d -r- "$TEMP_DIR/probe" > "$TEMP_DIR/requirement.txt" 2> /dev/null
if ! grep -q '^designated => ' "$TEMP_DIR/requirement.txt" || grep -q 'cdhash H' "$TEMP_DIR/requirement.txt"; then
    echo "The identity did not produce a stable certificate-based signature." >&2
    exit 1
fi
printf '%s\n' "$IDENTITY" > "$SIGNING_DIR/identity.sha1.tmp"
mv "$SIGNING_DIR/identity.sha1.tmp" "$IDENTITY_FILE"
echo "Reusable local signing identity configured: $IDENTITY"
echo "Private key: $KEYCHAIN (SnapTranslate Local Signing)"
echo "Next: ./scripts/build.sh"
