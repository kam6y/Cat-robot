#!/bin/bash
# Explicit paid model acceptance. Run only after the fixture/cost review and user consent.
set -euo pipefail
if [[ $# != 2 || -z "$1" || -z "$2" ]]; then
  echo 'Usage: run_clarification_history_model_tests.sh <Xcode-device-ID> <CoreDevice-ID>'
  exit 2
fi
ISSUE29_XCODE_DEVICE="$1"
ISSUE29_CORE_DEVICE="$2"
cd "$(cd "$(dirname "$0")/.." && pwd)"
export ISSUE29_MODEL_RUN_ID
ISSUE29_MODEL_RUN_ID="$(uuidgen)"
export ISSUE29_MODEL_RESULT_DIR="${ISSUE29_MODEL_RESULT_DIR:-/private/tmp/cat-issue29-clarification-20261107/model-runs/$ISSUE29_MODEL_RUN_ID}"
export ISSUE29_MODEL_BUILD_DIR="${ISSUE29_MODEL_BUILD_DIR:-/private/tmp/cat-issue29-clarification-20261107/DeviceModelDerived}"
ISSUE29_MODEL_PACKAGES_DIR="${ISSUE29_MODEL_PACKAGES_DIR:-/private/tmp/cat-ios-link/packages}"
mkdir -p "$ISSUE29_MODEL_RESULT_DIR"
export ISSUE29_MODEL_XCODE_DEVICE="$ISSUE29_XCODE_DEVICE" ISSUE29_MODEL_CORE_DEVICE="$ISSUE29_CORE_DEVICE"

python3 - <<'PY'
import hashlib, json, os, subprocess
from pathlib import Path
def git(*args): return subprocess.check_output(['git', *args])
files = {}
for name in sorted(set(git('ls-files', '-co', '--exclude-standard', '-z', '--', 'CatRobot', 'CatRobotTests', 'CatRobot.xcodeproj', 'scripts', 'native').split(b'\0'))):
    if name and Path(name.decode()).is_file(): files[name.decode()] = hashlib.sha256(Path(name.decode()).read_bytes()).hexdigest()
digest = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
resolved = json.loads(Path('CatRobot.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())
sdk = next(p['state'] for p in resolved['pins'] if p['identity'].lower() == 'claudeforfoundationmodels')
assert sdk['version'] == '0.2.3' and sdk['revision'] == '0262e1a766c461a4268dcec656eca95dd74cebf8'
head = git('rev-parse', 'HEAD').decode().strip()
value = {'head': head, 'inputSHA256': digest, 'files': files,
         'trackedPatchSHA256': hashlib.sha256(git('diff', '--binary', 'HEAD')).hexdigest(),
         'sourceTag': head + '-' + digest[:16], 'sdkVersion': sdk['version'], 'sdkRevision': sdk['revision'],
         'xcodeDeviceID': os.environ['ISSUE29_MODEL_XCODE_DEVICE'], 'coreDeviceID': os.environ['ISSUE29_MODEL_CORE_DEVICE']}
value['documentSHA256'] = {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in (
    'docs/superpowers/specs/2026-11-07-clarification-history-design.md',
    'docs/superpowers/plans/2026-11-07-clarification-history.md',
    'docs/validation/2026-11-07-clarification-history.md')}
Path(os.environ['ISSUE29_MODEL_RESULT_DIR'], 'source-before.json').write_text(json.dumps(value, indent=2) + '\n')
PY
ISSUE29_SOURCE_TAG="$(python3 - "$ISSUE29_MODEL_RESULT_DIR/source-before.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['sourceTag'])
PY
)"
COMMON=(-project CatRobot.xcodeproj -scheme CatRobot -configuration Debug
        -destination "platform=iOS,id=$ISSUE29_XCODE_DEVICE" -derivedDataPath "$ISSUE29_MODEL_BUILD_DIR"
        -clonedSourcePackagesDirPath "$ISSUE29_MODEL_PACKAGES_DIR" -disableAutomaticPackageResolution
        -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO)
GIT_LFS_SKIP_SMUDGE=1 xcodebuild "${COMMON[@]}" "CATROBOT_SOURCE_REVISION=$ISSUE29_SOURCE_TAG" build-for-testing \
  > "$ISSUE29_MODEL_RESULT_DIR/build.log" 2>&1

export ISSUE29_MODEL_RUN_FILE="$ISSUE29_MODEL_BUILD_DIR/Build/Products/ClarificationHistory-$ISSUE29_MODEL_RUN_ID.xctestrun"
trap 'rm -f "$ISSUE29_MODEL_RUN_FILE"' EXIT
python3 - <<'PY'
import json, os, plistlib
from pathlib import Path
root = Path(os.environ['ISSUE29_MODEL_BUILD_DIR']) / 'Build/Products'
sources = list(root.glob('CatRobot_iphoneos*.xctestrun'))
assert len(sources) == 1, f'Expected one device xctestrun, found {len(sources)}'
value = plistlib.loads(sources[0].read_bytes())
targets = [value['CatRobotTests']] if 'CatRobotTests' in value else [t for c in value['TestConfigurations'] for t in c['TestTargets']]
assert len(targets) == 1, 'The acceptance runner requires exactly one test target'
source = json.loads(Path(os.environ['ISSUE29_MODEL_RESULT_DIR'], 'source-before.json').read_text())
built = plistlib.loads((root / 'Debug-iphoneos/CatRobot.app/Info.plist').read_bytes()).get('CatRobotSourceRevision')
assert built == source['sourceTag'], 'Built source tag does not match the frozen source'
target = targets[0]
target['OnlyTestIdentifiers'] = ['ClarificationHistoryModelTests/testAcceptanceMatrix']
target['ParallelizationEnabled'] = False
target['RetryTestsOnFailure'] = False
target['MaximumTestRepetitions'] = 1
env = target.setdefault('EnvironmentVariables', {})
env.update({'CLARIFICATION_HISTORY_MODEL_TESTS': '1',
            'CLARIFICATION_HISTORY_RUN_ID': os.environ['ISSUE29_MODEL_RUN_ID'],
            'CLARIFICATION_HISTORY_SOURCE_HEAD': source['head'],
            'CLARIFICATION_HISTORY_INPUT_SHA256': source['inputSHA256'],
            'CLARIFICATION_HISTORY_SDK_REVISION': source['sdkRevision']})
Path(os.environ['ISSUE29_MODEL_RUN_FILE']).write_bytes(plistlib.dumps(value))
request = {'runID': os.environ['ISSUE29_MODEL_RUN_ID'], 'source': source,
           'builtSourceRevision': built, 'onlyTestIdentifiers': target['OnlyTestIdentifiers'],
           'repetitions': 3, 'topLevelTrials': 72, 'haikuTrials': 54, 'opusTrials': 18,
           'parallelTesting': False, 'automaticRetry': False,
           'acceptanceRequiresNavigatorSemanticReview': True}
Path(os.environ['ISSUE29_MODEL_RESULT_DIR'], 'request.json').write_text(json.dumps(request, indent=2) + '\n')
PY
printf 'CLARIFICATION_HISTORY_RUN %s %s\n' "$ISSUE29_MODEL_RUN_ID" "$ISSUE29_MODEL_RESULT_DIR"
set +e
xcodebuild -xctestrun "$ISSUE29_MODEL_RUN_FILE" -destination "platform=iOS,id=$ISSUE29_XCODE_DEVICE" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$ISSUE29_MODEL_RESULT_DIR/tests.xcresult" test-without-building \
  > "$ISSUE29_MODEL_RESULT_DIR/test.log" 2>&1
ISSUE29_TEST_STATUS=$?
xcrun xcresulttool get test-results summary --path "$ISSUE29_MODEL_RESULT_DIR/tests.xcresult" \
  > "$ISSUE29_MODEL_RESULT_DIR/summary.json"
ISSUE29_SUMMARY_STATUS=$?
xcrun devicectl device copy from --device "$ISSUE29_CORE_DEVICE" --domain-type appDataContainer \
  --domain-identifier com.kamby.CatRobot --source "Documents/ClarificationHistory/$ISSUE29_MODEL_RUN_ID" \
  --destination "$ISSUE29_MODEL_RESULT_DIR/data" > "$ISSUE29_MODEL_RESULT_DIR/export.log" 2>&1
ISSUE29_EXPORT_STATUS=$?
set -e
export ISSUE29_MODEL_TEST_STATUS="$ISSUE29_TEST_STATUS" ISSUE29_MODEL_SUMMARY_STATUS="$ISSUE29_SUMMARY_STATUS" ISSUE29_MODEL_EXPORT_STATUS="$ISSUE29_EXPORT_STATUS"

python3 - <<'PY'
import collections, hashlib, json, os, subprocess
from pathlib import Path
root = Path(os.environ['ISSUE29_MODEL_RESULT_DIR'])
(root/'process-status.json').write_text(json.dumps({key: int(os.environ[key]) for key in (
    'ISSUE29_MODEL_TEST_STATUS','ISSUE29_MODEL_SUMMARY_STATUS','ISSUE29_MODEL_EXPORT_STATUS')}, indent=2) + '\n')
before = json.loads((root/'source-before.json').read_text())
files = {}
names = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z', '--', 'CatRobot', 'CatRobotTests', 'CatRobot.xcodeproj', 'scripts', 'native']).split(b'\0')
for name in sorted(set(names)):
    if name and Path(name.decode()).is_file(): files[name.decode()] = hashlib.sha256(Path(name.decode()).read_bytes()).hexdigest()
after = {'head': subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(), 'files': files,
         'inputSHA256': hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
         'trackedPatchSHA256': hashlib.sha256(subprocess.check_output(['git','diff','--binary','HEAD'])).hexdigest()}
after['documentSHA256'] = {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in before['documentSHA256']}
(root/'source-after.json').write_text(json.dumps(after, indent=2) + '\n')
assert all(after[k] == before[k] for k in after), 'Source inputs changed during the run'
summary = json.loads((root/'summary.json').read_text())
assert summary['passedTests'] == 1 and summary['failedTests'] == 0 and summary['skippedTests'] == 0 and summary['expectedFailures'] == 0, 'XCTest did not execute the single acceptance method successfully'
value = json.loads((root/'data/results.json').read_text())
assert value['runID'] == os.environ['ISSUE29_MODEL_RUN_ID'] and value['fixtureVersion'] == 'issue29-v1'
assert value['sourceHEAD'] == before['head'] and value['inputSHA256'] == before['inputSHA256']
assert value['sdkRevision'] == before['sdkRevision'] and value['state'] == 'completed'
fixtures = value['fixtures']
assert collections.Counter(f['kind'] for f in fixtures) == {'classification':13, 'reply':6, 'summary':5}
expected = {f"{f['kind']}/{f['fixtureID']}/{r}" for f in fixtures for r in (1,2,3)}
records = value['records']
assert len(records) == len(expected) == 72 and {r['trialID'] for r in records} == expected
assert collections.Counter(r['kind'] for r in records) == {'classification':39, 'reply':18, 'summary':15}
assert collections.Counter(r['model'] for r in records) == {'claude-haiku-5-5':54, 'claude-opus-5-5':18}
assert all(r['outcome'] == 'success' and r['error'] == '' and r['effort'] == 'low' for r in records)
assert all(r['automaticChecks'] and all(r['automaticChecks'].values()) for r in records)
report = {'executionComplete': True, 'automaticChecksPassed': True, 'totalTrials':72,
          'inputUnchanged': True, 'acceptance': 'pending-navigator-semantic-review',
          'reviewRequired': [r['trialID'] for r in records if r['kind'] in ('reply','summary')],
          'resultsSHA256': hashlib.sha256((root/'data/results.json').read_bytes()).hexdigest()}
(root/'execution-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('72 trials complete with automatic checks passed. Navigator must review all 18 replies and 15 summaries before acceptance.')
PY
if [[ "$ISSUE29_TEST_STATUS" -ne 0 ]]; then exit "$ISSUE29_TEST_STATUS"; fi
if [[ "$ISSUE29_SUMMARY_STATUS" -ne 0 ]]; then exit "$ISSUE29_SUMMARY_STATUS"; fi
if [[ "$ISSUE29_EXPORT_STATUS" -ne 0 ]]; then exit "$ISSUE29_EXPORT_STATUS"; fi
printf 'Evidence: %s\n' "$ISSUE29_MODEL_RESULT_DIR"
