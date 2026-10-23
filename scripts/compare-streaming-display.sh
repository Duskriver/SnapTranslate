#!/bin/bash
# Restore the immediately preceding implementation in an isolated snapshot.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p build
PROBE_DIR="$(mktemp -d "$PROJECT_ROOT/build/streaming-display-comparison.XXXXXX")"
mkdir -p "$PROBE_DIR/after/Sources/TranslationCore" "$PROBE_DIR/after/Sources/SnapTranslate" "$PROBE_DIR/before"
cp Sources/TranslationCore/*.swift "$PROBE_DIR/after/Sources/TranslationCore/"
for source_file in ResultPanelController ResultErrorPresentation ScreenCapturePermission WindowResourcePolicy; do
    cp "Sources/SnapTranslate/$source_file.swift" "$PROBE_DIR/after/Sources/SnapTranslate/"
done
cp -R "$PROBE_DIR/after/Sources" "$PROBE_DIR/before/"
patch -s -f -F0 -p1 -d "$PROBE_DIR/before" < benchmarks/fixtures/streaming-display-before.patch >&2
cp benchmarks/StreamingDisplayProbe.swift "$PROBE_DIR/StreamingDisplayProbe.swift"
for version in before after; do
    VERSION_DIR="$PROBE_DIR/$version"
    APP_DIR="$VERSION_DIR/StreamingDisplayProbe.app"
    mkdir -p "$APP_DIR/Contents/MacOS"
    cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>StreamingDisplayProbe</string><key>CFBundleIdentifier</key><string>com.local.SnapTranslate.StreamingDisplayProbe</string><key>CFBundleName</key><string>StreamingDisplayProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
    swiftc -O -swift-version 6 -emit-library -emit-module -enable-testing -module-name TranslationCore \
        "$VERSION_DIR/Sources/TranslationCore/"*.swift \
        -emit-module-path "$VERSION_DIR/TranslationCore.swiftmodule" -o "$VERSION_DIR/libTranslationCore.dylib"
    flags=(-O -swift-version 6 -parse-as-library)
    if [ "$version" = after ]; then flags+=(-D INCREMENTAL_STREAMING); fi
    swiftc "${flags[@]}" \
        -I "$VERSION_DIR" -L "$VERSION_DIR" -lTranslationCore -Xlinker -rpath -Xlinker "$VERSION_DIR" \
        "$VERSION_DIR/Sources/SnapTranslate/"*.swift "$PROBE_DIR/StreamingDisplayProbe.swift" \
        -o "$APP_DIR/Contents/MacOS/StreamingDisplayProbe"
    codesign --force --sign - "$APP_DIR" >&2
done
printf 'Snapshots and binaries: %s\n' "$PROBE_DIR" >&2
swift --version >&2
shasum -a 256 "$PROBE_DIR/StreamingDisplayProbe.swift" >&2
printf 'version,run,updates,output_bytes,elapsed_ms,baseline_MiB,current_MiB,peak_MiB\n'
for updates in 32 128 512; do
    for run in 1 2 3 4 5; do
        if (( run % 2 == 1 )); then versions=(before after); else versions=(after before); fi
        for version in "${versions[@]}"; do
            measurement="$("$PROBE_DIR/$version/StreamingDisplayProbe.app/Contents/MacOS/StreamingDisplayProbe" "$updates")"
            printf '%s,%d' "$version" "$run"
            for field in $measurement; do printf ',%s' "${field#*=}"; done
            printf '\n'
        done
    done
done
