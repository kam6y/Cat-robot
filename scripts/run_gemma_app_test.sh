#!/bin/bash
# Uses live Gemma dependencies and the actual iPhone speech synthesizer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export GEMMA_TEST_SCHEME=GemmaAppDeviceTests
export GEMMA_DEVICE_RESULT_PATH='Library/Application Support/GemmaAppDeviceTest/results.json'
exec "$SCRIPT_DIR/run_gemma_device_test.sh" "$@"
