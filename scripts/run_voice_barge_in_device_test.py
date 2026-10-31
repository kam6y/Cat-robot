#!/usr/bin/env python3
"""Run the opt-in iPhone voice-interruption fixture; external plays known speech on this Mac."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="Connected iPhone UDID")
    parser.add_argument("stage", choices=("self-only", "external"))
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-dir", type=Path, default=Path("/private/tmp/CatRobotIdleLifeDeviceDerived"))
    parser.add_argument("--packages", type=Path, default=Path("/private/tmp/CatRobotIdleSleepDerived/SourcePackages"))
    parser.add_argument("--output", type=Path, default=Path("/private/tmp/cat-voice-barge-in-device"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    run_id = str(uuid.uuid4())
    out = (args.output / run_id).resolve()
    out.mkdir(parents=True)
    build_dir = args.build_dir.resolve()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=repo):
        revision += "-working"
    request = {"runID": run_id, "stage": args.stage, "workingSourceRevision": revision,
        "externalFixture": "待って、明日の話をして" if args.stage == "external" else None,
        "externalVoice": "Kyoko" if args.stage == "external" else None}
    print(f"VOICE_BARGE_RUN {run_id} {out}", flush=True)
    if not args.skip_build:
        with (out / "build.log").open("w") as log:
            subprocess.run(["xcodebuild", "build-for-testing", "-project", "CatRobot.xcodeproj", "-scheme", "CatRobot",
                "-destination", f"platform=iOS,id={args.device}", "-derivedDataPath", str(build_dir),
                "-clonedSourcePackagesDirPath", str(args.packages.resolve()), "-parallel-testing-enabled", "NO",
                f"CATROBOT_SOURCE_REVISION={revision}"], cwd=repo, stdout=log, stderr=subprocess.STDOUT, check=True)
    products = build_dir / "Build/Products"
    candidates = sorted(products.glob("CatRobot_*.xctestrun"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        raise RuntimeError("No CatRobot device test build is available")
    request["builtSourceRevision"] = plistlib.loads((products / "Debug-iphoneos/CatRobot.app/Info.plist").read_bytes()).get("CatRobotSourceRevision", "unknown")
    (out / "request.json").write_text(json.dumps(request, ensure_ascii=False, indent=2))
    value = plistlib.loads(candidates[0].read_bytes())
    targets = [value["CatRobotTests"]] if "CatRobotTests" in value else [t for c in value["TestConfigurations"] for t in c["TestTargets"]]
    for target in targets:
        target["OnlyTestIdentifiers"] = ["VoiceBargeInDeviceTests/testSelectedStage"]
        # Existing dedicated speech host mode keeps the live scene from opening a
        # second microphone/player or contacting the conversation model during trials.
        target.setdefault("EnvironmentVariables", {}).update(VOICE_BARGE_TESTS="1", VOICE_BARGE_RUN_ID=run_id,
                                                               VOICE_BARGE_STAGE=args.stage, SUPER_INTEGRATION_TESTS="1")
    run_file = products / f"VoiceBargeIn-{run_id}.xctestrun"
    run_file.write_bytes(plistlib.dumps(value))
    result = out / "test.xcresult"
    spoken_trials = set()
    try:
        with (out / "test.log").open("w") as log:
            test = subprocess.Popen(["xcodebuild", "-xctestrun", str(run_file), "-destination", f"platform=iOS,id={args.device}",
                "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", str(result),
                "test-without-building"], cwd=repo, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 300
                while test.poll() is None:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Device test exceeded five minutes")
                    if args.stage == "external":
                        ready = out / "ready.json"
                        copied = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
                            "--domain-type", "appDataContainer", "--domain-identifier", "com.kamby.CatRobot",
                            "--source", f"Documents/VoiceBargeIn/{run_id}/ready.json", "--destination", str(ready)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                        if copied.returncode == 0 and ready.exists():
                            signal = json.loads(ready.read_text())
                            trial = signal.get("trial", 0)
                            if signal.get("runID") == run_id and trial not in spoken_trials:
                                spoken_trials.add(trial)
                                print(f"EXTERNAL_FIXTURE trial={trial}", flush=True)
                                subprocess.run(["say", "-v", "Kyoko", "待って、明日の話をして"], check=True, timeout=20)
                    time.sleep(1)
                status = test.returncode
            finally:
                if test.poll() is None:
                    test.terminate()
                    try:
                        test.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        test.kill()
                        test.wait()
    finally:
        run_file.unlink(missing_ok=True)
    summary = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result), "--compact"], text=True)
    (out / "summary.json").write_text(summary)
    with (out / "export.log").open("w") as log:
        export = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
            "--domain-type", "appDataContainer", "--domain-identifier", "com.kamby.CatRobot",
            "--source", f"Documents/VoiceBargeIn/{run_id}", "--destination", str(out / "data")],
            stdout=log, stderr=subprocess.STDOUT)
    totals = json.loads(summary)
    print(json.dumps({key: totals.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")}), flush=True)
    print(f"Evidence: {out}", flush=True)
    if status or export.returncode or totals.get("passedTests") != 1 or totals.get("skippedTests") != 0:
        return 1
    metrics = json.loads((out / "data/results.json").read_text())
    if metrics.get("runID") != run_id or metrics.get("stage") != args.stage:
        raise RuntimeError("Exported results belong to a different run or stage")
    if metrics.get("sourceRevision") != request["builtSourceRevision"]:
        raise RuntimeError("Results revision does not match the tested application")
    print(json.dumps(metrics, ensure_ascii=False, indent=2), flush=True)
    print("Acoustic measurements require inspection; a passing fixture does not establish acceptance.", flush=True)
    if args.stage == "external" and not spoken_trials:
        raise RuntimeError("The external fixture was never played")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
