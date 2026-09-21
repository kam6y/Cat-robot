#!/bin/bash
# Real-device probe; deliberately separate from the ordinary unit-test scheme.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || "$1" == "--help" ]]; then
  echo "Usage: $0 <iPhone UDID> [path/to/gemma-4-E2B-it.litertlm]"
  echo "Unlock the paired iPhone. The optional model file is copied only after SHA-256 verification."
  exit 0
fi
MODEL_FILE=""
if [[ $# -eq 2 ]]; then
  MODEL_FILE="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
DEVICE_ID="$1"
RESULT_DIR="${GEMMA_RESULTS_DIR:-$REPO_ROOT/.build/gemma-device/$(date -u +%Y%m%dT%H%M%SZ)}"
BUILD_DIR="${GEMMA_BUILD_DIR:-$REPO_ROOT/.build/gemma-device-derived}"
PACKAGE_DIR="${GEMMA_PACKAGE_DIR:-$REPO_ROOT/.build/gemma-device-packages}"
mkdir -p "$RESULT_DIR"
COMMON=(-project CatRobot.xcodeproj -scheme GemmaDeviceTests
  -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$BUILD_DIR"
  -clonedSourcePackagesDirPath "$PACKAGE_DIR" -parallel-testing-enabled NO)
# The upstream repository contains unrelated LFS binaries; the Apple binary is
# resolved separately by SwiftPM and checked against its package checksum.
GIT_LFS_SKIP_SMUDGE=1 xcodebuild "${COMMON[@]}" -allowProvisioningUpdates build-for-testing \
  > "$RESULT_DIR/build.log" 2>&1
if [[ $# -eq 2 ]]; then
  EXPECTED_SHA=181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c
  ACTUAL_SHA="$(shasum -a 256 "$MODEL_FILE" | cut -d ' ' -f 1)"
  if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
    echo "Model SHA-256 mismatch; refusing to copy." >&2
    exit 1
  fi
  xcrun devicectl device install app --device "$DEVICE_ID" \
    "$BUILD_DIR/Build/Products/Debug-iphoneos/CatRobot.app"
  xcrun devicectl device copy to --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier com.kamby.CatRobot \
    --source "$MODEL_FILE" \
    --destination 'Library/Application Support/CatRobot/LanguageModels/Gemma4E2B/gemma-4-E2B-it.litertlm'
fi
# Preserve xcodebuild's failure status and its authoritative per-run xcresult.
set +e
xcodebuild "${COMMON[@]}" -resultBundlePath "$RESULT_DIR/test.xcresult" \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 600 \
  test-without-building > "$RESULT_DIR/test.log" 2>&1
TEST_STATUS=$?
set -e
xcrun xcresulttool get test-results summary --path "$RESULT_DIR/test.xcresult" \
  --compact > "$RESULT_DIR/summary.json" || true
# Only export the convenience JSON after success; on failure an older on-device
# results.json must not be mistaken for the current test's evidence.
if [[ "$TEST_STATUS" -eq 0 ]]; then
  xcrun devicectl device copy from --device "$DEVICE_ID" \
    --domain-type appDataContainer --domain-identifier com.kamby.CatRobot \
    --source 'Library/Application Support/GemmaDeviceTest-20260921/results.json' \
    --destination "$RESULT_DIR/results.json"
fi
printf 'Evidence: %s\n' "$RESULT_DIR"
exit "$TEST_STATUS"
