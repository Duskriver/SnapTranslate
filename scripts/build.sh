#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
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
strip -S "$APP_DIR/Contents/MacOS/SnapTranslate"
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.local.SnapTranslate "$APP_DIR"
codesign --verify --strict "$APP_DIR"
DESTINATION="$PROJECT_ROOT/build/SnapTranslate.app"
# Replace the bundle only after successful signing. Never truncate the executable
# of an already running instance. Relaunch it to use the newly built version.
if [ -d "$DESTINATION" ]; then
    mv "$DESTINATION" "$STAGING_DIR/previous.app"
fi
mv "$APP_DIR" "$DESTINATION"
echo "Built: $DESTINATION"
