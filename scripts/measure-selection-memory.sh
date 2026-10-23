#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Override SELECTOR_SOURCE to compare the exact same harness with older code.
SELECTOR_SOURCE="${SELECTOR_SOURCE:-$PROJECT_ROOT/Sources/SnapTranslate/RegionSelector.swift}"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snaptranslate-memory.XXXXXX")"
trap 'rm -rf "$PROBE_DIR"' EXIT
APP="$PROBE_DIR/MemoryProbe.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>MemoryProbe</string><key>CFBundleIdentifier</key><string>com.local.SnapTranslateMemoryProbe</string><key>CFBundleName</key><string>MemoryProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
PROBE_SOURCE="$PROJECT_ROOT/benchmarks/MemoryProbe.swift"
if [ "${1:-}" = "--drag" ]; then
    PROBE_SOURCE="$PROJECT_ROOT/benchmarks/DragMemoryProbe.swift"
fi
swiftc -O -parse-as-library "$SELECTOR_SOURCE" "$PROBE_SOURCE" -o "$APP/Contents/MacOS/MemoryProbe"
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/MemoryProbe" "$@"
