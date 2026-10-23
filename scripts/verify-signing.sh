#!/bin/bash
# Verify that changing a signed app still satisfies the previous version's identity.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$PROJECT_ROOT/build/SnapTranslate.app}"
SIGNING_DIR="${SIGNING_CONFIG_DIR:-$HOME/Library/Application Support/SnapTranslate/Signing}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(cat "$SIGNING_DIR/identity.sha1")}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaptranslate-signing-check.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

codesign --verify --strict "$APP_DIR"
ditto "$APP_DIR" "$TEMP_DIR/updated.app"
# Updating a sealed resource changes the CodeDirectory hash, as a real update does.
printf 'Changed contents for signing regression check.\n' > "$TEMP_DIR/updated.app/Contents/Resources/SigningCheck.txt"
codesign --force --sign "$SIGN_IDENTITY" --identifier com.local.SnapTranslate "$TEMP_DIR/updated.app"
codesign --verify --strict "$TEMP_DIR/updated.app"
codesign -d -r- "$APP_DIR" > "$TEMP_DIR/original.txt" 2> /dev/null
codesign -d -r- "$TEMP_DIR/updated.app" > "$TEMP_DIR/updated.txt" 2> /dev/null
for VERSION in original updated; do
    if ! grep -q '^designated => ' "$TEMP_DIR/$VERSION.txt" || grep -q 'cdhash H' "$TEMP_DIR/$VERSION.txt"; then
        echo "Missing stable signing identity: $VERSION" >&2
        exit 1
    fi
    sed -n 's/^designated => //p' "$TEMP_DIR/$VERSION.txt" > "$TEMP_DIR/$VERSION.req"
done
ORIGINAL_HASH="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 | sed -n 's/^CDHash=//p')"
UPDATED_HASH="$(codesign -dv --verbose=4 "$TEMP_DIR/updated.app" 2>&1 | sed -n 's/^CDHash=//p')"
if [ -z "$ORIGINAL_HASH" ] || [ -z "$UPDATED_HASH" ] || [ "$ORIGINAL_HASH" = "$UPDATED_HASH" ]; then
    echo "The fixture did not produce different code hashes." >&2
    exit 1
fi
codesign --verify --strict -R "$TEMP_DIR/original.req" "$TEMP_DIR/updated.app"
codesign --verify --strict -R "$TEMP_DIR/updated.req" "$APP_DIR"

# Matching only the bundle identifier must never be enough to impersonate the app.
codesign --force --sign - --identifier com.local.SnapTranslate "$TEMP_DIR/updated.app"
if codesign --verify --strict -R "$TEMP_DIR/original.req" "$TEMP_DIR/updated.app" 2> /dev/null; then
    echo "An ad-hoc signature incorrectly satisfied the certificate requirement." >&2
    exit 1
fi
echo "PASS: different app contents share a certificate identity; an ad-hoc impostor is rejected."
echo "Scope: code identity only. Self-signed builds may still require Keychain approval after their code hash changes."
