#!/bin/bash
set -euo pipefail
if [[ $# != 4 || "$1" != --attended ]]; then
  echo 'Usage: run_robot_motion_device_test.sh --attended <iPhone-UDID> <small|medium|large> <saved-robot-name>'
  echo 'Moves real hardware. Observe the robot; leave the app foreground without tapping Begin Conversation.'
  exit 2
fi
ROBOT_PHONE="$2"
export ROBOT_STAGE="$3" ROBOT_DEVICE_NAME="$4"
case "$ROBOT_STAGE" in small|medium|large) ;; *) exit 2 ;; esac
[[ -n "$ROBOT_PHONE" && -n "$ROBOT_DEVICE_NAME" ]] || exit 2
cd "$(cd "$(dirname "$0")/.." && pwd)"
export ROBOT_BUILD_DIR="${ROBOT_BUILD_DIR:-/private/tmp/cat-robot-motion/device}"
ROBOT_PACKAGE_DIR="${ROBOT_PACKAGE_DIR:-/private/tmp/cat-ios-link/packages}"
export ROBOT_RUN_ID
ROBOT_RUN_ID="$(uuidgen)"
export ROBOT_RESULT_DIR="${ROBOT_RESULT_DIR:-/private/tmp/cat-robot-motion/runs/$ROBOT_RUN_ID}"
mkdir -p "$ROBOT_RESULT_DIR"
if [[ "${ROBOT_SKIP_BUILD:-0}" != 1 ]]; then
  ROBOT_REVISION="$(git rev-parse HEAD)"
  if [[ -n "$(git status --porcelain)" ]]; then ROBOT_REVISION="$ROBOT_REVISION-working"; fi
  GIT_LFS_SKIP_SMUDGE=1 xcodebuild -project CatRobot.xcodeproj -scheme CatRobot \
    -destination "platform=iOS,id=$ROBOT_PHONE" -derivedDataPath "$ROBOT_BUILD_DIR" \
    -clonedSourcePackagesDirPath "$ROBOT_PACKAGE_DIR" -parallel-testing-enabled NO \
    "CATROBOT_SOURCE_REVISION=$ROBOT_REVISION" build-for-testing > "$ROBOT_RESULT_DIR/build.log" 2>&1
fi
if [[ "${ROBOT_BUILD_ONLY:-0}" == 1 ]]; then
  printf 'Build only; no motion executed. Log: %s/build.log\n' "$ROBOT_RESULT_DIR"
  exit 0
fi
export ROBOT_RUN_FILE="$ROBOT_BUILD_DIR/Build/Products/RobotMotionRun-$ROBOT_RUN_ID.xctestrun"
trap 'rm -f "$ROBOT_RUN_FILE"' EXIT
python3 - <<'PY'
import json, os, plistlib
from pathlib import Path
root = Path(os.environ['ROBOT_BUILD_DIR']) / 'Build/Products'
sources = list(root.glob('CatRobot_iphoneos*.xctestrun'))
if len(sources) != 1:
    raise SystemExit(f'Expected exactly one device test configuration, found {len(sources)}')
value = plistlib.loads(sources[0].read_bytes())
targets = [value['CatRobotTests']] if 'CatRobotTests' in value else [t for c in value['TestConfigurations'] for t in c['TestTargets']]
for target in targets:
    target['OnlyTestIdentifiers'] = ['RobotMotionIntegrationDeviceTests/testSelectedStage']
    env = target.setdefault('EnvironmentVariables', {})
    for key in ('ROBOT_RUN_ID', 'ROBOT_STAGE', 'ROBOT_DEVICE_NAME'): env[key] = os.environ[key]
    env['ROBOT_MOTION_DEVICE_TESTS'] = '1'
    env['ROBOT_ATTENDED'] = '1'
Path(os.environ['ROBOT_RUN_FILE']).write_bytes(plistlib.dumps(value))
request = {k: os.environ[k] for k in ('ROBOT_RUN_ID', 'ROBOT_STAGE', 'ROBOT_DEVICE_NAME')}
request['builtSourceRevision'] = plistlib.loads((root/'Debug-iphoneos/CatRobot.app/Info.plist').read_bytes()).get('CatRobotSourceRevision')
Path(os.environ['ROBOT_RESULT_DIR'], 'request.json').write_text(json.dumps(request, indent=2))
PY
printf 'ROBOT_RUN %s %s; order: nod shake tilt look_up look_down look_at_user center\n' "$ROBOT_RUN_ID" "$ROBOT_RESULT_DIR"
set +e
xcodebuild -xctestrun "$ROBOT_RUN_FILE" -destination "platform=iOS,id=$ROBOT_PHONE" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$ROBOT_RESULT_DIR/test.xcresult" test-without-building > "$ROBOT_RESULT_DIR/test.log" 2>&1
ROBOT_TEST_STATUS=$?
xcrun xcresulttool get test-results summary --path "$ROBOT_RESULT_DIR/test.xcresult" --compact > "$ROBOT_RESULT_DIR/summary.json"
xcrun devicectl device copy from --device "$ROBOT_PHONE" --domain-type appDataContainer \
  --domain-identifier com.kamby.CatRobot --source "Documents/RobotMotionValidation/$ROBOT_RUN_ID" --destination "$ROBOT_RESULT_DIR/data" \
  > "$ROBOT_RESULT_DIR/export.log" 2>&1
ROBOT_EXPORT_STATUS=$?
set -e
if [[ "$ROBOT_TEST_STATUS" -ne 0 ]]; then exit "$ROBOT_TEST_STATUS"; fi
if [[ "$ROBOT_EXPORT_STATUS" -ne 0 ]]; then exit "$ROBOT_EXPORT_STATUS"; fi
python3 - <<'PY'
import json, os
from pathlib import Path
p = json.loads((Path(os.environ['ROBOT_RESULT_DIR'])/'data/results.json').read_text())
expected = ['nod', 'shake', 'tilt', 'look_up', 'look_down', 'look_at_user', 'center']
assert p['runID'] == os.environ['ROBOT_RUN_ID'] and p['intensity'] == os.environ['ROBOT_STAGE']
assert p['outcome'] == 'success' and [r['gesture'] for r in p['records']] == expected
assert all(r['outcome'] == 'success' for r in p['records'])
print('Seven motion cycles completed; physical smoothness requires the observer report.')
PY
printf 'Evidence: %s\n' "$ROBOT_RESULT_DIR"
