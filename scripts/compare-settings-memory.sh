#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <before-git-ref> (requires an active desktop)" >&2
    exit 2
fi
BEFORE_REF="$(git rev-parse --verify "$1^{commit}")"
PROBE_DIR="$(mktemp -d "$PROJECT_ROOT/build/settings-memory.XXXXXX")"
SIGNING_ID="${SIGN_IDENTITY:-$(cat "$HOME/Library/Application Support/SnapTranslate/Signing/identity.sha1")}"
mkdir -p "$PROBE_DIR/before-sources" "$PROBE_DIR/after-sources"
git archive "$BEFORE_REF" Sources | tar -x -C "$PROBE_DIR/before-sources" --strip-components=1
cp -R Sources/. "$PROBE_DIR/after-sources/"
for version in before after; do
    VERSION_DIR="$PROBE_DIR/$version"
    mkdir -p "$VERSION_DIR/SnapTranslate.app/Contents/MacOS"
    cp Resources/Info.plist "$VERSION_DIR/SnapTranslate.app/Contents/Info.plist"
    python3 - "$PROBE_DIR/$version-sources" "$version" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'SnapTranslate/AppMain.swift'
s = p.read_text()
for before, after in [
    ('        let delegate = AppDelegate()', '        let delegate = settingsBenchmarkDelegate()'),
    ('        withExtendedLifetime(delegate) { application.run() }',
     '        Task { @MainActor in await runSettingsMemoryBenchmark(delegate) }\n        withExtendedLifetime(delegate) { application.run() }'),
]:
    assert s.count(before) == 1, before
    s = s.replace(before, after)
p.write_text(s)
if sys.argv[2] == 'after':
    p = root / 'SnapTranslate/SettingsWorker.swift'
    s = p.read_text()
    needle = '            controller.present()'
    assert s.count(needle) == 1
    p.write_text(s.replace(needle, needle + '\n            Task { @MainActor in await settingsProbeWorker(controller) }'))
PY
    flags=(-D SETTINGS_LOCAL)
    if [ "$version" = after ]; then flags=(-D SETTINGS_WORKER); fi
    swiftc -O -swift-version 6 -whole-module-optimization -parse-as-library -emit-object -emit-module \
        -module-name TranslationCore "$PROBE_DIR/$version-sources/TranslationCore/"*.swift \
        -emit-module-path "$VERSION_DIR/TranslationCore.swiftmodule" -o "$VERSION_DIR/TranslationCore.o"
    swiftc -O -swift-version 6 -parse-as-library "${flags[@]}" -I "$VERSION_DIR" "$VERSION_DIR/TranslationCore.o" \
        "$PROBE_DIR/$version-sources/SnapTranslate/"*.swift benchmarks/SettingsMemoryProbe.swift \
        -o "$VERSION_DIR/SnapTranslate.app/Contents/MacOS/SnapTranslate"
    codesign --force --sign "$SIGNING_ID" --identifier com.local.SnapTranslate "$VERSION_DIR/SnapTranslate.app" >&2
done
printf 'Snapshots and raw data: %s\n' "$PROBE_DIR" >&2
printf 'version,run,stage,main_mib,child_mib,sum_mib,child_count,open_ms\n'
for run in 1 2 3; do
    if (( run % 2 == 1 )); then versions=(before after); else versions=(after before); fi
    for version in "${versions[@]}"; do
        python3 benchmarks/SettingsMemoryObserver.py "$PROBE_DIR" "$version" "$run"
    done
done
