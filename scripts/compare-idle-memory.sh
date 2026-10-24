#!/bin/bash
# Real capture/PNG/HTTP/UI lifetimes; public fixture and local SSE, no keychain/API.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <before-git-ref> (requires an active desktop and existing screen-capture permission)" >&2
    exit 2
fi
BASE_REF="$(git rev-parse --verify "$1^{commit}")"
PROBE_DIR="$(mktemp -d "$PROJECT_ROOT/build/idle-memory-comparison.XXXXXX")"
SIGNING_ID="${SIGN_IDENTITY:-$(cat "$HOME/Library/Application Support/SnapTranslate/Signing/identity.sha1")}"
fixture_pid=""
server_pid=""
cleanup() {
    if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; fi
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
mkdir -p "$PROBE_DIR/before-sources" "$PROBE_DIR/after-sources"
git archive "$BASE_REF" Sources | tar -x -C "$PROBE_DIR/before-sources" --strip-components=1
cp -R Sources/. "$PROBE_DIR/after-sources/"
cp benchmarks/IdleMemoryProbe.swift "$PROBE_DIR/IdleMemoryProbe.swift"
python3 benchmarks/IdleTranslationServer.py "$PROBE_DIR" &
server_pid=$!
for _ in {1..100}; do
    if [ -s "$PROBE_DIR/port" ]; then break; fi
    sleep 0.05
done
PORT="$(cat "$PROBE_DIR/port")"
for version in before after; do
    VERSION_DIR="$PROBE_DIR/$version"
    mkdir -p "$VERSION_DIR/SnapTranslate.app/Contents/MacOS"
    cp Resources/Info.plist "$VERSION_DIR/SnapTranslate.app/Contents/Info.plist"
    python3 - "$PROBE_DIR/$version-sources" "$version" "$PORT" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
p=root/'SnapTranslate/AppMain.swift'
s=p.read_text()
needle='        let delegate = AppDelegate()'
assert s.count(needle)==1, 'App main changed: update the benchmark adapter'
s=s.replace(needle, '        let delegate = AppDelegate(settings: SettingsStore(defaults: UserDefaults(suiteName: "com.local.SnapTranslate.IdleBenchmark")!, keyStorage: BenchmarkKeys()), capturePermission: { true })')
s=s.replace('        withExtendedLifetime(delegate) { application.run() }','        Task { @MainActor in await runIdleBenchmark(delegate) }\n        withExtendedLifetime(delegate) { application.run() }')
p.write_text(s)
p=root/'TranslationCore/DeepSeekClient.swift'
s=p.read_text()
assert s.count('https://api.deepseek.com/chat/completions')==1
p.write_text(s.replace('https://api.deepseek.com/chat/completions',f'http://127.0.0.1:{sys.argv[3]}/chat/completions'))
if sys.argv[2]=='after':
    p=root/'SnapTranslate/TranslationWorker.swift'
    s=p.read_text()
    assert len(re.findall(r'^ +panel\.finish\(\)$',s,re.M))==1
    assert s.count('if !Task.isCancelled { panel.showError(error) }')==1
    # Close the actual worker window after success. Fail instead of letting an
    # error window wait indefinitely or masquerade as a successful translation.
    s=re.sub(r'^( +)panel\.finish\(\)$',lambda m:m.group(0)+'\n'+m.group(1)+'panel.dismiss()',s,flags=re.M)
    s=s.replace('if !Task.isCancelled { panel.showError(error) }','if !Task.isCancelled { exit(7) }')
    p.write_text(s)
PY
    swiftc -O -swift-version 6 -whole-module-optimization -parse-as-library -emit-object -emit-module \
        -module-name TranslationCore "$PROBE_DIR/$version-sources/TranslationCore/"*.swift \
        -emit-module-path "$VERSION_DIR/TranslationCore.swiftmodule" -o "$VERSION_DIR/TranslationCore.o"
    swiftc -O -swift-version 6 -parse-as-library -I "$VERSION_DIR" "$VERSION_DIR/TranslationCore.o" \
        "$PROBE_DIR/$version-sources/SnapTranslate/"*.swift "$PROBE_DIR/IdleMemoryProbe.swift" \
        -o "$VERSION_DIR/SnapTranslate.app/Contents/MacOS/SnapTranslate"
    codesign --force --sign "$SIGNING_ID" --identifier com.local.SnapTranslate "$VERSION_DIR/SnapTranslate.app" >&2
done
swiftc -O -swift-version 6 -parse-as-library benchmarks/IdleMemoryFixture.swift -o "$PROBE_DIR/fixture"
printf 'Snapshots and raw data: %s\n' "$PROBE_DIR" >&2
"$PROBE_DIR/fixture" &
fixture_pid=$!
sleep 1
printf 'version,run,stage,current_mib,main_peak_mib,round_ms\n'
for run in 1 2 3; do
    if (( run % 2 == 1 )); then versions=(before after); else versions=(after before); fi
    for version in "${versions[@]}"; do
        python3 benchmarks/IdleMemoryObserver.py "$PROBE_DIR" "$version" "$run" >&2
        python3 - "$PROBE_DIR/$version-$run.csv" "$version" "$run" <<'PY'
import csv,sys
with open(sys.argv[1]) as f:
    for row in csv.reader(f):
        assert len(row)==4, row
        print(','.join([sys.argv[2],sys.argv[3]]+row))
PY
    done
done
