#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
SIGNING_DIR="${SIGNING_CONFIG_DIR:-$HOME/Library/Application Support/SnapTranslate/Signing}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if [ ! -f "$SIGNING_DIR/identity.sha1" ]; then
        echo "No persistent signing identity configured. Run ./scripts/setup-signing.sh once, or set SIGN_IDENTITY to an existing certificate." >&2
        exit 1
    fi
    SIGN_IDENTITY="$(cat "$SIGNING_DIR/identity.sha1")"
    if ! [[ "$SIGN_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
        echo "Invalid signing identity file: $SIGNING_DIR/identity.sha1" >&2
        exit 1
    fi
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Ad-hoc signing is disabled: it loses privacy authorization after code changes. Configure a persistent certificate." >&2
    exit 1
fi
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$PROJECT_ROOT/build"
STAGING_DIR="$(mktemp -d "$PROJECT_ROOT/build/.stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/SnapTranslate.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SnapTranslate" "$APP_DIR/Contents/MacOS/SnapTranslate"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
cp -R Resources/ThirdPartyLicenses "$APP_DIR/Contents/Resources/ThirdPartyLicenses"
strip -S "$APP_DIR/Contents/MacOS/SnapTranslate"
codesign --force --sign "$SIGN_IDENTITY" --identifier com.local.SnapTranslate "$APP_DIR"
codesign --verify --strict "$APP_DIR"
DESTINATION="$PROJECT_ROOT/build/SnapTranslate.app"
codesign -d -r- "$APP_DIR" > "$STAGING_DIR/new-requirement.txt" 2> /dev/null
if ! grep -q '^designated => ' "$STAGING_DIR/new-requirement.txt" || grep -q 'cdhash H' "$STAGING_DIR/new-requirement.txt"; then
    echo "Refusing a signature tied to this binary's hash." >&2
    exit 1
fi
if [ -d "$DESTINATION" ]; then
    codesign -d -r- "$DESTINATION" > "$STAGING_DIR/old-requirement.txt" 2> /dev/null
    if grep -q 'cdhash H' "$STAGING_DIR/old-requirement.txt"; then
        echo "Migrating from ad-hoc signing. Privacy permissions may need renewal; self-signed Keychain access can still prompt after code updates."
    else
        sed -n 's/^designated => //p' "$STAGING_DIR/old-requirement.txt" > "$STAGING_DIR/old.req"
        sed -n 's/^designated => //p' "$STAGING_DIR/new-requirement.txt" > "$STAGING_DIR/new.req"
        if ! codesign --verify --strict -R "$STAGING_DIR/old.req" "$APP_DIR" \
            || ! codesign --verify --strict -R "$STAGING_DIR/new.req" "$DESTINATION"; then
            echo "Signing identity changed. The current app was preserved. Reuse the original certificate to retain the app identity." >&2
            exit 1
        fi
    fi
fi
# Replace the bundle only after successful signing. Never truncate the executable
# of an already running instance. Relaunch it to use the newly built version.
if [ -d "$DESTINATION" ]; then
    mv "$DESTINATION" "$STAGING_DIR/previous.app"
fi
mv "$APP_DIR" "$DESTINATION"
echo "Built: $DESTINATION"
