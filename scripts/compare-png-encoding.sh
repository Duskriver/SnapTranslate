#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
mkdir -p build
PROBE_DIR="$(mktemp -d "$PROJECT_ROOT/build/png-encoding-comparison.XXXXXX")"
mkdir -p "$PROBE_DIR/after/Sources/SnapTranslate" "$PROBE_DIR/before"
for source_file in ScreenCapture PNGEncoder; do
    cp "Sources/SnapTranslate/$source_file.swift" "$PROBE_DIR/after/Sources/SnapTranslate/"
done
if [ "$#" -gt 0 ]; then
    BASELINE_COMMIT="$(git rev-parse --verify "$1^{commit}")"
    git archive "$BASELINE_COMMIT" Sources/SnapTranslate/ScreenCapture.swift Sources/SnapTranslate/PNGEncoder.swift \
        | tar -x -C "$PROBE_DIR/before"
    printf 'Baseline: %s\n' "$BASELINE_COMMIT" >&2
else
    cp -R "$PROBE_DIR/after/Sources" "$PROBE_DIR/before/"
    patch -s -f -F0 -p1 -d "$PROBE_DIR/before" < benchmarks/fixtures/png-encoding-before.patch >&2
fi
OUTPUT_SIZES=false
if [ "${2:-}" = "--output-sizes" ]; then
    OUTPUT_SIZES=true
    cp benchmarks/PNGOutputMemoryProbe.swift "$PROBE_DIR/PNGEncodingProbe.swift"
elif [ "$#" -gt 1 ]; then
    echo "Usage: compare-png-encoding.sh [baseline-ref [--output-sizes]]" >&2
    exit 2
else
    cp benchmarks/PNGEncodingProbe.swift "$PROBE_DIR/PNGEncodingProbe.swift"
fi
# Replace ScreenCaptureKit with the same synthetic capture callback, retaining
# each version's real encoding path and before/after capture admission ordering.
# Both snapshots add identical counters around the synchronous ImageIO function.
python3 - "$PROBE_DIR" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for version in ('before', 'after'):
    directory = root / version / 'Sources/SnapTranslate'
    capture = directory / 'ScreenCapture.swift'
    text = capture.read_text()
    prefix = text[:text.index('enum ScreenCapture {')]
    adapter = ('enum ScreenCapture {\n'
               '    static func encodeForBenchmark(_ capture: @Sendable () async throws -> CGImage) async throws -> CapturedImage {\n')
    legacy = 'return try await PNGEncoder.shared.captureAndEncode' not in text
    if legacy:
        marker = '        // Encoding can be CPU intensive.'
        assert text.count(marker) == 1
        text = prefix + adapter + '        try Task.checkCancellation()\n        let image = try await capture()\n        try Task.checkCancellation()\n' + text[text.index(marker):]
    else:
        assert text.count('return try await PNGEncoder.shared.captureAndEncode') == 1
        text = prefix + adapter + '        return try await PNGEncoder.shared.captureAndEncode(capture)\n    }\n}\n'
    capture.write_text(text)
    encoder = capture if legacy else directory / 'PNGEncoder.swift'
    text = encoder.read_text()
    signature = ('    private static func encode(_ image: CGImage) throws -> CapturedImage {' if legacy
                 else '    static func encodePNG(_ image: CGImage) throws -> CapturedImage {')
    assert text.count(signature) == 1
    encoder.write_text(text.replace(signature, signature + '\n        PNGProbeMetrics.begin()\n        defer { PNGProbeMetrics.end() }'))
PY
for version in before after; do
    swiftc -O -swift-version 6 -parse-as-library \
        "$PROBE_DIR/$version/Sources/SnapTranslate/"*.swift "$PROBE_DIR/PNGEncodingProbe.swift" \
        -o "$PROBE_DIR/$version/png-encoding-probe"
done
printf 'Snapshots and binaries: %s\n' "$PROBE_DIR" >&2
swift --version >&2
shasum -a 256 "$PROBE_DIR/PNGEncodingProbe.swift" >&2
printf 'version,run,pixels,requests,encoded,max_concurrent,cancelled,png_bytes,elapsed_ms,latest_ms,cpu_ms,baseline_MiB,current_MiB,peak_MiB'
if [ "$OUTPUT_SIZES" = true ]; then
    printf ',rejected,png_sha256\n'
    workloads=('noise 1' 'mixed 1' 'oversized 1')
else
    printf '\n'
    workloads=('1 1' '8 1' '8 3' '8 8')
fi
for workload in "${workloads[@]}"; do
    for run in 1 2 3 4 5; do
        if (( run % 2 == 1 )); then versions=(before after); else versions=(after before); fi
        for version in "${versions[@]}"; do
            measurement="$("$PROBE_DIR/$version/png-encoding-probe" $workload)"
            printf '%s,%d' "$version" "$run"
            for field in $measurement; do printf ',%s' "${field#*=}"; done
            printf '\n'
        done
    done
done
