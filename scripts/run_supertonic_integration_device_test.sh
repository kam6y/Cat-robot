#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then
  echo 'Usage: run_supertonic_integration_device_test.sh <UDID> <voices|fixed|gemma|lifecycle|offline>'
  exit 2
fi
SUPER_DEVICE="$1"
export SUPER_STAGE="$2"
case "$SUPER_STAGE" in voices|fixed|gemma|lifecycle|offline) ;; *) exit 2 ;; esac
cd "$(cd "$(dirname "$0")/.." && pwd)"
export SUPER_BUILD_DIR="${SUPER_BUILD_DIR:-/private/tmp/cat-supertonic-integration/device}"
SUPER_PACKAGE_DIR="${SUPER_PACKAGE_DIR:-/private/tmp/cat-speech-comparison/packages}"
export SUPER_CONNECTION="${SUPER_CONNECTION:-usb}"
export SUPER_RUN_ID
SUPER_RUN_ID="$(uuidgen)"
export SUPER_RESULT_DIR="${SUPER_RESULT_DIR:-/private/tmp/cat-supertonic-integration/runs/$SUPER_RUN_ID}"
mkdir -p "$SUPER_RESULT_DIR"
COMMON=(-project CatRobot.xcodeproj -scheme SupertonicIntegrationDeviceTests -destination "platform=iOS,id=$SUPER_DEVICE"
        -derivedDataPath "$SUPER_BUILD_DIR" -clonedSourcePackagesDirPath "$SUPER_PACKAGE_DIR" -parallel-testing-enabled NO)
if [[ "${SUPER_SKIP_BUILD:-0}" != 1 ]]; then
  SUPER_REVISION="$(git rev-parse HEAD)"
  if ! git diff --quiet HEAD; then SUPER_REVISION="$SUPER_REVISION-working"; fi
  GIT_LFS_SKIP_SMUDGE=1 xcodebuild "${COMMON[@]}" "CATROBOT_SOURCE_REVISION=$SUPER_REVISION" build-for-testing > "$SUPER_RESULT_DIR/build.log" 2>&1
fi
export SUPER_RUN_FILE="$SUPER_BUILD_DIR/Build/Products/SupertonicRun-$SUPER_RUN_ID.xctestrun"
trap 'rm -f "$SUPER_RUN_FILE"' EXIT
python3 - <<'PY'
import json, os, plistlib
from pathlib import Path
root = Path(os.environ['SUPER_BUILD_DIR']) / 'Build/Products'
source = next(root.glob('SupertonicIntegrationDeviceTests_*.xctestrun'))
value = plistlib.loads(source.read_bytes())
targets = [value['CatRobotTests']] if 'CatRobotTests' in value else [t for c in value['TestConfigurations'] for t in c['TestTargets']]
for target in targets:
    target['OnlyTestIdentifiers'] = ['SupertonicIntegrationDeviceTests/testSelectedStage']
    env = target.setdefault('EnvironmentVariables', {})
    for key in ('SUPER_RUN_ID', 'SUPER_STAGE', 'SUPER_CONNECTION'): env[key] = os.environ[key]
    env['SUPER_INTEGRATION_TESTS'] = '1'
Path(os.environ['SUPER_RUN_FILE']).write_bytes(plistlib.dumps(value))
request = {k: os.environ[k] for k in ('SUPER_RUN_ID','SUPER_STAGE','SUPER_CONNECTION')}
request['builtSourceRevision'] = plistlib.loads((root/'Debug-iphoneos/CatRobot.app/Info.plist').read_bytes()).get('CatRobotSourceRevision')
Path(os.environ['SUPER_RESULT_DIR'], 'request.json').write_text(json.dumps(request, indent=2))
PY
printf 'SUPER_RUN %s %s\n' "$SUPER_RUN_ID" "$SUPER_RESULT_DIR"
set +e
xcodebuild -xctestrun "$SUPER_RUN_FILE" -destination "platform=iOS,id=$SUPER_DEVICE" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$SUPER_RESULT_DIR/test.xcresult" test-without-building > "$SUPER_RESULT_DIR/test.log" 2>&1
SUPER_TEST_STATUS=$?
xcrun xcresulttool get test-results summary --path "$SUPER_RESULT_DIR/test.xcresult" --compact > "$SUPER_RESULT_DIR/summary.json"
xcrun devicectl device copy from --device "$SUPER_DEVICE" --domain-type appDataContainer \
  --domain-identifier com.kamby.CatRobot --source "Documents/SupertonicIntegration/$SUPER_RUN_ID" --destination "$SUPER_RESULT_DIR/data" \
  > "$SUPER_RESULT_DIR/export.log" 2>&1
SUPER_EXPORT_STATUS=$?
set -e
if [[ "$SUPER_TEST_STATUS" -ne 0 ]]; then exit "$SUPER_TEST_STATUS"; fi
if [[ "$SUPER_EXPORT_STATUS" -ne 0 ]]; then exit "$SUPER_EXPORT_STATUS"; fi
python3 scripts/summarize_supertonic_integration.py "$SUPER_RESULT_DIR/data/results.json" --expected-run-id "$SUPER_RUN_ID" > "$SUPER_RESULT_DIR/metrics.json"
printf 'Evidence: %s\n' "$SUPER_RESULT_DIR"
