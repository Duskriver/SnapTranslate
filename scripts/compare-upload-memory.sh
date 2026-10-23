#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BASELINE_COMMIT="$(git rev-parse --verify "${1:?Usage: compare-upload-memory.sh <baseline-ref>}^{commit}")"
mkdir -p build
PROBE_DIR="$(mktemp -d "$PROJECT_ROOT/build/upload-memory-comparison.XXXXXX")"
mkdir -p "$PROBE_DIR/before" "$PROBE_DIR/after/Sources/TranslationCore"
git archive "$BASELINE_COMMIT" Sources/TranslationCore | tar -x -C "$PROBE_DIR/before"
cp Sources/TranslationCore/*.swift "$PROBE_DIR/after/Sources/TranslationCore/"
cp benchmarks/UploadMemoryProbe.swift "$PROBE_DIR/UploadMemoryProbe.swift"
cp benchmarks/upload_memory_server.py "$PROBE_DIR/upload_memory_server.py"
# Change only the destination in isolated snapshots, never in production sources.
python3 - "$PROBE_DIR" <<'PY'
from pathlib import Path
import sys
for version in ('before', 'after'):
    path = Path(sys.argv[1]) / version / 'Sources/TranslationCore/DeepSeekClient.swift'
    text = path.read_text()
    endpoint = '"https://api.deepseek.com/chat/completions"'
    assert text.count(endpoint) == 1
    path.write_text(text.replace(endpoint, 'ProcessInfo.processInfo.environment["PROBE_URL"]!'))
PY
for version in before after; do
    swiftc -O -swift-version 6 -parse-as-library "$PROBE_DIR/$version/Sources/TranslationCore/"*.swift \
        "$PROBE_DIR/UploadMemoryProbe.swift" -o "$PROBE_DIR/$version-probe"
done
printf 'Baseline: %s\nSnapshots and binaries: %s\n' "$BASELINE_COMMIT" "$PROBE_DIR" >&2
swift --version >&2
shasum -a 256 "$PROBE_DIR/UploadMemoryProbe.swift" "$PROBE_DIR/upload_memory_server.py" >&2
python3 "$PROBE_DIR/upload_memory_server.py" "$PROBE_DIR"
