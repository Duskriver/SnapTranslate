#!/bin/bash
# Same harness, flags and inputs; alternate fresh before/after processes.
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BASELINE_COMMIT="$(git rev-parse --verify "${1:?Usage: compare-request-encoding.sh <baseline-ref>}^{commit}")"
mkdir -p build
PROBE_DIR="$(mktemp -d "$PROJECT_ROOT/build/request-encoding-comparison.XXXXXX")"
mkdir -p "$PROBE_DIR/before" "$PROBE_DIR/after"
git archive "$BASELINE_COMMIT" Sources/TranslationCore | tar -x -C "$PROBE_DIR/before"
if [ -n "${REQUEST_AFTER_REF:-}" ]; then
    AFTER_COMMIT="$(git rev-parse --verify "$REQUEST_AFTER_REF^{commit}")"
    git archive "$AFTER_COMMIT" Sources/TranslationCore | tar -x -C "$PROBE_DIR/after"
    cp "$PROBE_DIR/after/Sources/TranslationCore/"*.swift "$PROBE_DIR/after/"
else
    cp Sources/TranslationCore/*.swift "$PROBE_DIR/after/"
fi
cp "${REQUEST_PROBE_SOURCE:-benchmarks/RequestEncodingProbe.swift}" "$PROBE_DIR/RequestEncodingProbe.swift"
swiftc -O -swift-version 6 -parse-as-library "$PROBE_DIR/before/Sources/TranslationCore/"*.swift \
    "$PROBE_DIR/RequestEncodingProbe.swift" -o "$PROBE_DIR/before-probe"
swiftc -O -swift-version 6 -parse-as-library "$PROBE_DIR/after/"*.swift \
    "$PROBE_DIR/RequestEncodingProbe.swift" -o "$PROBE_DIR/after-probe"
printf 'Baseline: %s\nSnapshots and binaries: %s\n' "$BASELINE_COMMIT" "$PROBE_DIR" >&2
swift --version >&2
shasum -a 256 "$PROBE_DIR/RequestEncodingProbe.swift" >&2
printf 'version,run,input_bytes,body_bytes,elapsed_ms,baseline_MiB,current_MiB,peak_MiB\n'
for input_bytes in 65536 1048576 10485760; do
    for run in 1 2 3 4 5; do
        if (( run % 2 == 1 )); then
            versions=(before after)
        else
            versions=(after before)
        fi
        for version in "${versions[@]}"; do
            measurement="$("$PROBE_DIR/$version-probe" "$input_bytes")"
            printf '%s,%d' "$version" "$run"
            for field in $measurement; do
                printf ',%s' "${field#*=}"
            done
            printf '\n'
        done
    done
done
