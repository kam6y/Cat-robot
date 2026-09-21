#!/bin/bash
# Launch each capacity in a fresh app process so peak memory is comparable.
set -euo pipefail
if [[ $# -lt 1 || "$1" == --help ]]; then
  echo "Usage: $0 <iPhone UDID> [08 12 16 24 32 ...]"
  exit 0
fi
DEVICE_ID="$1"
shift
if [[ $# -eq 0 ]]; then set -- 08 12 16 24 32; fi
for size in "$@"; do
  case "$size" in 08|12|16|24|32) ;; *) echo "Invalid capacity: $size" >&2; exit 1 ;; esac
done
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
RESULT_DIR="${GEMMA_RESULTS_DIR:-$REPO_ROOT/.build/context-benchmark/$(date -u +%Y%m%dT%H%M%SZ)}"
BUILD_DIR="${GEMMA_BUILD_DIR:-$REPO_ROOT/.build/context-benchmark-derived}"
PACKAGE_DIR="${GEMMA_PACKAGE_DIR:-$REPO_ROOT/.build/gemma-device-packages}"
mkdir -p "$RESULT_DIR"
COMMON=(-project CatRobot.xcodeproj -scheme GemmaContextBenchmarkTests
  -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$BUILD_DIR"
  -clonedSourcePackagesDirPath "$PACKAGE_DIR" -parallel-testing-enabled NO)
if [[ "${GEMMA_SKIP_BUILD:-0}" != 1 ]]; then
  GIT_LFS_SKIP_SMUDGE=1 xcodebuild "${COMMON[@]}" -allowProvisioningUpdates build-for-testing > "$RESULT_DIR/build.log" 2>&1
fi
case "${GEMMA_BENCHMARK_MODE:-stress}" in
  stress) METHOD_PREFIX=test ;;
  validation) METHOD_PREFIX=testValidation ;;
  *) echo "GEMMA_BENCHMARK_MODE must be stress or validation" >&2; exit 1 ;;
esac
FAILED=0
for size in "$@"; do
  TOKENS=$((10#$size * 1024))
  RUN_DIR="$RESULT_DIR/${size}k"
  if [[ -e "$RUN_DIR" ]]; then
    echo "Result directory already exists; choose a new GEMMA_RESULTS_DIR: $RUN_DIR" >&2
    exit 1
  fi
  mkdir -p "$RUN_DIR"
  STARTED=$(date +%s)
  echo "Measuring ${size}K ($TOKENS tokens)"
  set +e
  xcodebuild "${COMMON[@]}" -only-testing:"CatRobotTests/GemmaContextBenchmarkTests/${METHOD_PREFIX}${size}K" \
    -resultBundlePath "$RUN_DIR/test.xcresult" -test-timeouts-enabled YES \
    -maximum-test-execution-time-allowance 900 test-without-building > "$RUN_DIR/test.log" 2>&1
  STATUS=$?
  set -e
  if [[ "$STATUS" -ne 0 ]]; then FAILED=1; fi
  xcrun xcresulttool get test-results summary --path "$RUN_DIR/test.xcresult" --compact > "$RUN_DIR/summary.json" || true
  # A failed stress test may still have useful per-turn checkpoints. Only accept
  # a report created after this invocation began, never an old successful run.
  if xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier com.kamby.CatRobot \
    --source "Library/Application Support/CatRobot/LanguageModels/ContextBenchmark/results-${TOKENS}.json" \
    --destination "$RUN_DIR/downloaded.json" > "$RUN_DIR/copy.log" 2>&1; then
    python3 - "$RUN_DIR" "$TOKENS" "$STARTED" <<'PY'
import datetime, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
s = json.loads((root / 'downloaded.json').read_text())
meta = s['metadata']
started = datetime.datetime.fromisoformat(meta['startedAt'].replace('Z', '+00:00')).timestamp()
if meta['capacity'] == int(sys.argv[2]) and started >= int(sys.argv[3]):
    (root / 'downloaded.json').rename(root / 'results.json')
    print('Stage:', s['stage'], 'memory:', s['memory'])
else:
    print('Ignored stale/mismatched device report', file=sys.stderr)
PY
  fi
  if [[ ! -f "$RUN_DIR/results.json" ]]; then FAILED=1; fi
  echo "${size}K test exit: $STATUS; evidence: $RUN_DIR"
done
exit "$FAILED"
