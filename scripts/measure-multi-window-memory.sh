#!/bin/bash
# Actual capture/PNG/HTTP/result windows; --real-api uses the saved credential.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
REAL_API=0
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--real-api" ]; }; then
    echo "Usage: $0 [--real-api]" >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then REAL_API=1; fi
PROBE_DIR="$(mktemp -d "$PROJECT_ROOT/build/multi-window-memory.XXXXXX")"
SIGNING_ID="${SIGN_IDENTITY:-$(cat "$HOME/Library/Application Support/SnapTranslate/Signing/identity.sha1")}"
fixture_pid=""
server_pid=""
cleanup() {
    if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; fi
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
mkdir -p "$PROBE_DIR/sources" "$PROBE_DIR/SnapTranslate.app/Contents/MacOS"
cp -R Sources/. "$PROBE_DIR/sources/"
cp Resources/Info.plist "$PROBE_DIR/SnapTranslate.app/Contents/Info.plist"
cp benchmarks/MultiWindowMemoryProbe.swift "$PROBE_DIR/Probe.swift"
PORT=0
if [ "$REAL_API" -eq 0 ]; then
    python3 benchmarks/IdleTranslationServer.py "$PROBE_DIR" &
    server_pid=$!
    for _ in {1..100}; do if [ -s "$PROBE_DIR/port" ]; then break; fi; sleep 0.05; done
    PORT="$(cat "$PROBE_DIR/port")"
fi
python3 - "$PROBE_DIR/sources" "$PORT" "$REAL_API" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
p = root / 'SnapTranslate/AppMain.swift'
s = p.read_text()
needle = '        let delegate = AppDelegate()'
assert s.count(needle) == 1
s = s.replace(needle, '        let delegate = multiBenchmarkDelegate()')
needle = '        withExtendedLifetime(delegate) { application.run() }'
assert s.count(needle) == 1
p.write_text(s.replace(needle, '        Task { @MainActor in await runMultiWindowBenchmark(delegate) }\n' + needle))
p = root / 'TranslationCore/DeepSeekClient.swift'
s = p.read_text()
assert s.count('https://api.deepseek.com/chat/completions') == 1
if sys.argv[3] == '0':
    p.write_text(s.replace('https://api.deepseek.com/chat/completions', f'http://127.0.0.1:{sys.argv[2]}/chat/completions'))
p = root / 'SnapTranslate/TranslationWorker.swift'
s = p.read_text()
for before, after in [
    ('presentation.panel.showLoading(near: request.rect, avoiding: occupied)',
     'presentation.panel.showLoading(near: request.rect, avoiding: occupied)\n        multiWorkerRecordState(presentations.count)'),
    ('        presentation.panel.dismiss()',
     '        presentation.panel.dismiss()\n        multiWorkerRecordState(presentations.count)'),
    ('                panel.finish()', '                panel.finish()\n                multiWorkerCompleted(panel)'),
    ('if !Task.isCancelled { panel.showError(error) }', 'if !Task.isCancelled { multiWorkerFailure(error); exit(7) }'),
]:
    assert s.count(before) == 1, before
    s = s.replace(before, after)
if sys.argv[3] == '1':
    before = '        let server = WorkerWindowServer(emit: writer.send)'
    assert s.count(before) == 1
    s = s.replace(before, before + '\n        multiInstallWorkerControl(server)')
    before = '        let admission = WorkerNetworkAdmission.shared'
    assert s.count(before) == 1
    s = s.replace(before, '        multiValidateRealCapture(image)\n' + before)
p.write_text(s)
PY
swiftc -O -swift-version 6 -whole-module-optimization -parse-as-library -emit-object -emit-module \
    -module-name TranslationCore "$PROBE_DIR/sources/TranslationCore/"*.swift \
    -emit-module-path "$PROBE_DIR/TranslationCore.swiftmodule" -o "$PROBE_DIR/TranslationCore.o"
swiftc -O -swift-version 6 -parse-as-library -I "$PROBE_DIR" "$PROBE_DIR/TranslationCore.o" \
    "$PROBE_DIR/sources/SnapTranslate/"*.swift "$PROBE_DIR/Probe.swift" \
    -o "$PROBE_DIR/SnapTranslate.app/Contents/MacOS/SnapTranslate"
codesign --force --sign "$SIGNING_ID" --identifier com.local.SnapTranslate "$PROBE_DIR/SnapTranslate.app" >&2
swiftc -O -swift-version 6 -parse-as-library benchmarks/IdleMemoryFixture.swift -o "$PROBE_DIR/fixture"
printf 'Snapshots and raw data: %s\n' "$PROBE_DIR" >&2
if [ "$REAL_API" -eq 1 ]; then "$PROBE_DIR/fixture" --floating & else "$PROBE_DIR/fixture" & fi
fixture_pid=$!
sleep 1
printf 'run,stage,windows,main_mib,worker_mib,sum_mib,child_count\n'
if [ "$REAL_API" -eq 1 ]; then
    SNAP_MULTI_REAL_API=1 python3 benchmarks/MultiWindowMemoryObserver.py "$PROBE_DIR" 1
else
    for run in 1 2 3; do python3 benchmarks/MultiWindowMemoryObserver.py "$PROBE_DIR" "$run"; done
fi
