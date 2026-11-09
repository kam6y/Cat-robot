#!/bin/bash
# Explicit paid model acceptance. Run only after the fixture/cost review and user consent.
set -euo pipefail
if [[ $# != 2 || -z "$1" || -z "$2" ]]; then
  echo 'Usage: run_haiku_addressing_model_tests.sh <Xcode-device-ID> <CoreDevice-ID>'
  exit 2
fi
ISSUE30_XCODE_DEVICE="$1"
ISSUE30_CORE_DEVICE="$2"
cd "$(cd "$(dirname "$0")/.." && pwd)"
export ISSUE30_MODEL_RUN_ID
ISSUE30_MODEL_RUN_ID="$(uuidgen)"
export ISSUE30_MODEL_RESULT_DIR="${ISSUE30_MODEL_RESULT_DIR:-/private/tmp/cat-issue30-haiku-20261109/model-runs/$ISSUE30_MODEL_RUN_ID}"
export ISSUE30_MODEL_BUILD_DIR="${ISSUE30_MODEL_BUILD_DIR:-/private/tmp/cat-issue30-haiku-20261109/DeviceModelDerived}"
ISSUE30_MODEL_PACKAGES_DIR="${ISSUE30_MODEL_PACKAGES_DIR:-/private/tmp/cat-ios-link/packages}"
mkdir -p "$ISSUE30_MODEL_RESULT_DIR"
export ISSUE30_MODEL_XCODE_DEVICE="$ISSUE30_XCODE_DEVICE" ISSUE30_MODEL_CORE_DEVICE="$ISSUE30_CORE_DEVICE"

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
         'xcodeDeviceID': os.environ['ISSUE30_MODEL_XCODE_DEVICE'], 'coreDeviceID': os.environ['ISSUE30_MODEL_CORE_DEVICE']}
value['documentSHA256'] = {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in (
    'docs/superpowers/specs/2026-11-09-haiku-only-design.md',
    'docs/superpowers/plans/2026-11-09-haiku-only.md',
)}
Path(os.environ['ISSUE30_MODEL_RESULT_DIR'], 'source-before.json').write_text(json.dumps(value, indent=2) + '\n')
PY
ISSUE30_SOURCE_TAG="$(python3 - "$ISSUE30_MODEL_RESULT_DIR/source-before.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['sourceTag'])
PY
)"
COMMON=(-project CatRobot.xcodeproj -scheme CatRobot -configuration Debug
        -destination "platform=iOS,id=$ISSUE30_XCODE_DEVICE" -derivedDataPath "$ISSUE30_MODEL_BUILD_DIR"
        -clonedSourcePackagesDirPath "$ISSUE30_MODEL_PACKAGES_DIR" -disableAutomaticPackageResolution
        -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO)
GIT_LFS_SKIP_SMUDGE=1 xcodebuild "${COMMON[@]}" "CATROBOT_SOURCE_REVISION=$ISSUE30_SOURCE_TAG" build-for-testing \
  > "$ISSUE30_MODEL_RESULT_DIR/build.log" 2>&1

export ISSUE30_MODEL_RUN_FILE="$ISSUE30_MODEL_BUILD_DIR/Build/Products/HaikuAddressing-$ISSUE30_MODEL_RUN_ID.xctestrun"
trap 'rm -f "$ISSUE30_MODEL_RUN_FILE"' EXIT
python3 - <<'PY'
import json, os, plistlib
from pathlib import Path
root = Path(os.environ['ISSUE30_MODEL_BUILD_DIR']) / 'Build/Products'
sources = list(root.glob('CatRobot_iphoneos*.xctestrun'))
assert len(sources) == 1, f'Expected one device xctestrun, found {len(sources)}'
value = plistlib.loads(sources[0].read_bytes())
targets = [value['CatRobotTests']] if 'CatRobotTests' in value else [t for c in value['TestConfigurations'] for t in c['TestTargets']]
assert len(targets) == 1, 'The acceptance runner requires exactly one test target'
source = json.loads(Path(os.environ['ISSUE30_MODEL_RESULT_DIR'], 'source-before.json').read_text())
built = plistlib.loads((root / 'Debug-iphoneos/CatRobot.app/Info.plist').read_bytes()).get('CatRobotSourceRevision')
assert built == source['sourceTag'], 'Built source tag does not match the frozen source'
target = targets[0]
target['OnlyTestIdentifiers'] = ['HaikuAddressingModelTests/testAcceptanceMatrix']
target['ParallelizationEnabled'] = False
target['RetryTestsOnFailure'] = False
target['MaximumTestRepetitions'] = 1
env = target.setdefault('EnvironmentVariables', {})
env.update({'SUPER_INTEGRATION_TESTS': '1',
            'HAIKU_ADDRESSING_MODEL_TESTS': '1',
            'HAIKU_ADDRESSING_RUN_ID': os.environ['ISSUE30_MODEL_RUN_ID'],
            'HAIKU_ADDRESSING_SOURCE_HEAD': source['head'],
            'HAIKU_ADDRESSING_INPUT_SHA256': source['inputSHA256'],
            'HAIKU_ADDRESSING_SDK_REVISION': source['sdkRevision']})
Path(os.environ['ISSUE30_MODEL_RUN_FILE']).write_bytes(plistlib.dumps(value))
request = {'runID': os.environ['ISSUE30_MODEL_RUN_ID'], 'source': source,
           'builtSourceRevision': built, 'onlyTestIdentifiers': target['OnlyTestIdentifiers'],
           'repetitions': 3, 'topLevelTrials': 69, 'haikuTrials': 69, 'opusTrials': 0,
           'parallelTesting': False, 'automaticRetry': False,
           'acceptanceRequiresNavigatorSemanticReview': False,
           'dedicatedHostSceneDisabled': True}
Path(os.environ['ISSUE30_MODEL_RESULT_DIR'], 'request.json').write_text(json.dumps(request, indent=2) + '\n')
PY
printf 'HAIKU_ADDRESSING_RUN %s %s\n' "$ISSUE30_MODEL_RUN_ID" "$ISSUE30_MODEL_RESULT_DIR"
set +e
xcodebuild -xctestrun "$ISSUE30_MODEL_RUN_FILE" -destination "platform=iOS,id=$ISSUE30_XCODE_DEVICE" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -resultBundlePath "$ISSUE30_MODEL_RESULT_DIR/tests.xcresult" test-without-building \
  > "$ISSUE30_MODEL_RESULT_DIR/test.log" 2>&1
ISSUE30_TEST_STATUS=$?
xcrun xcresulttool get test-results summary --path "$ISSUE30_MODEL_RESULT_DIR/tests.xcresult" \
  > "$ISSUE30_MODEL_RESULT_DIR/summary.json"
ISSUE30_SUMMARY_STATUS=$?
xcrun devicectl device copy from --device "$ISSUE30_CORE_DEVICE" --domain-type appDataContainer \
  --domain-identifier com.kamby.CatRobot --source "Documents/HaikuAddressing/$ISSUE30_MODEL_RUN_ID" \
  --destination "$ISSUE30_MODEL_RESULT_DIR/data" > "$ISSUE30_MODEL_RESULT_DIR/export.log" 2>&1
ISSUE30_EXPORT_STATUS=$?
set -e
export ISSUE30_MODEL_TEST_STATUS="$ISSUE30_TEST_STATUS" ISSUE30_MODEL_SUMMARY_STATUS="$ISSUE30_SUMMARY_STATUS" ISSUE30_MODEL_EXPORT_STATUS="$ISSUE30_EXPORT_STATUS"

python3 - <<'PY'
import collections, hashlib, json, os, subprocess
from pathlib import Path
root = Path(os.environ['ISSUE30_MODEL_RESULT_DIR'])
(root/'process-status.json').write_text(json.dumps({key: int(os.environ[key]) for key in (
    'ISSUE30_MODEL_TEST_STATUS','ISSUE30_MODEL_SUMMARY_STATUS','ISSUE30_MODEL_EXPORT_STATUS')}, indent=2) + '\n')
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
assert value['runID'] == os.environ['ISSUE30_MODEL_RUN_ID'] and value['fixtureVersion'] == 'issue30-v1'
assert value['sourceHEAD'] == before['head'] and value['inputSHA256'] == before['inputSHA256']
assert value['sdkRevision'] == before['sdkRevision'] and value['state'] == 'completed'
fixtures = value['fixtures']
assert collections.Counter(f['kind'] for f in fixtures) == {'classification':23}
expected = {f"{f['kind']}/{f['fixtureID']}/{r}" for f in fixtures for r in (1,2,3)}
records = value['records']
assert len(records) == len(expected) == 69 and {r['trialID'] for r in records} == expected
assert collections.Counter(r['kind'] for r in records) == {'classification':69}
assert collections.Counter(r['model'] for r in records) == {'claude-haiku-5-5':69}
assert all(r['outcome'] == 'success' and r['error'] == '' and r['effort'] == 'low' for r in records)
assert all(r['automaticChecks'] and all(r['automaticChecks'].values()) for r in records)
allowed = {f['fixtureID']: set(f['expectation'].split('|')) for f in fixtures}
assert all(r['target'] in allowed[r['fixtureID']] for r in records)
report = {'executionComplete': True, 'automaticChecksPassed': True, 'totalTrials':69,
          'inputUnchanged': True, 'acceptance': 'passed-all-enum-expectations',
          'reviewRequired': [],
          'evaluationScope': 'approved regression/rule fixtures, not held-out generalization',
          'resultsSHA256': hashlib.sha256((root/'data/results.json').read_bytes()).hexdigest()}
(root/'execution-verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('69 Haiku classification trials completed; every expected-enum check passed.')
PY
if [[ "$ISSUE30_TEST_STATUS" -ne 0 ]]; then exit "$ISSUE30_TEST_STATUS"; fi
if [[ "$ISSUE30_SUMMARY_STATUS" -ne 0 ]]; then exit "$ISSUE30_SUMMARY_STATUS"; fi
if [[ "$ISSUE30_EXPORT_STATUS" -ne 0 ]]; then exit "$ISSUE30_EXPORT_STATUS"; fi
printf 'Evidence: %s\n' "$ISSUE30_MODEL_RESULT_DIR"
