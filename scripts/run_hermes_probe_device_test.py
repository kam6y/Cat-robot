#!/usr/bin/env python3
"""Stdlib-only XCTest runner for the Debug Hermes connection probe.

The relay and isolated Windows gateway must already be ready for this lifetime.
This runner never starts/restarts them. Credentials are read only into a 0600
bootstrap; process arguments and xctestrun contain paths and nonsecret metadata.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import uuid

BUNDLE = "com.kamby.CatRobot"


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def snapshot(repo: Path):
    paths = subprocess.check_output(["git", "ls-files", "-c", "-o", "--exclude-standard", "-z"], cwd=repo).decode().split("\0")
    files = {path: hashlib.sha256((repo / path).read_bytes()).hexdigest()
             for path in sorted(set(paths)) if path and path != "CatRobot/LocalAssets/claude-api-key.txt" and (repo / path).is_file()}
    return {"files": files, "sha256": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()}


def write_bootstrap(secrets_path: Path, metadata: dict, output: Path, device_id: str):
    if stat.S_IMODE(secrets_path.stat().st_mode) != 0o600:
        raise ValueError("secrets file must have mode 0600")
    secrets = json.loads(secrets_path.read_bytes())
    key = secrets.get("apiKey")
    if not isinstance(key, str) or not key:
        raise ValueError("probe credential missing")
    bootstrap = {"endpoint": metadata["endpoints"][0], "pins": [metadata["pin"]], "deviceID": device_id, "apiKey": key}
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(bootstrap, handle)
    return {"key_present": True, "bootstrapPath": str(output)}


def configure_xctestrun(source: bytes, *, run_id: str, stage: str, source_hash: str, bootstrap: Path | None):
    if str(uuid.UUID(run_id)) != run_id.lower() or stage not in ("lifetime1", "lifetime2"):
        raise ValueError("invalid probe selection")
    value = plistlib.loads(source)
    targets = [value["CatRobotTests"]] if "CatRobotTests" in value else [
        target for config in value["TestConfigurations"] for target in config["TestTargets"]
        if target.get("BlueprintName") == "CatRobotTests"
    ]
    if not targets:
        raise ValueError("CatRobotTests not found in xctestrun")
    for target in targets:
        target["OnlyTestIdentifiers"] = ["HermesProbeDeviceTests/testSelectedStage"]
        target.pop("SkipTestIdentifiers", None)
        env = target.setdefault("EnvironmentVariables", {})
        env.update({"HERMES_PROBE": "1", "HERMES_PROBE_RUN_ID": run_id,
                    "HERMES_PROBE_STAGE": stage, "HERMES_PROBE_SOURCE_SHA256": source_hash})
        # A physical host only reads the fixed Documents bootstrap; no Mac path is injected.
        env.pop("HERMES_PROBE_BOOTSTRAP", None)
        if bootstrap is not None:
            env["HERMES_PROBE_BOOTSTRAP"] = str(bootstrap)
    return plistlib.dumps(value)


def validate_device_readiness(details: dict):
    result = details.get("result", {})
    connection = result.get("connectionProperties", {})
    device = result.get("deviceProperties", {})
    if not (connection.get("tunnelState") == "connected" and connection.get("pairingState") == "paired"
            and device.get("ddiServicesAvailable") is True and device.get("developerModeStatus") == "enabled"):
        raise ValueError("physical device is not connected and ready for development")


def validate_result(result: dict, *, run_id: str, stage: str, source_hash: str, target: str):
    expected = {"runID": run_id, "stage": stage, "sourceInputSHA256": source_hash, "target": target,
                "outcome": "success", "physicalOperations": False, "compositionCreated": False,
                "key_present": True, "bootstrapRemoved": True}
    if any(result.get(key) != value for key, value in expected.items()):
        raise ValueError("probe result does not match the requested successful run")
    rows = result.get("records", [])
    if stage == "lifetime1":
        for credential, status in (("absent", 401), ("wrong", 401), ("present", 200)):
            if not any(row.get("operation") == "capabilities" and row.get("credential") == credential
                       and row.get("status") == status for row in rows):
                raise ValueError("authentication evidence missing")
        for operation in ("plain", "boundTerminal"):
            if not any(row.get("operation") == operation and row.get("status") == "completed"
                       and row.get("nonceMatched") is True for row in rows):
                raise ValueError("completed nonce evidence missing")
        if not any(row.get("operation") == "mockEcho" and row.get("accepted") is True for row in rows):
            raise ValueError("mock result acknowledgement missing")
    elif not any(row.get("operation") == "cancel" and row.get("revokeAccepted") is True
                 and row.get("status") in ("completed", "cancelled", "failed")
                 and row.get("heldCallDiscarded") is True and row.get("mockExecuted") is False for row in rows):
        raise ValueError("held-call cancellation evidence missing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["simulator", "device"], required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--stage", choices=["lifetime1", "lifetime2"], required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--secrets", type=Path, required=True)
    parser.add_argument("--tls-metadata", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--package-cache", type=Path, required=True)
    parser.add_argument("--windows-ready-receipt", type=Path, required=True,
                        help="Nonsecret parent acknowledgement for this relay/gateway lifetime")
    args = parser.parse_args()
    for name in ("out", "secrets", "tls_metadata", "derived_data", "package_cache", "windows_ready_receipt"):
        setattr(args, name, getattr(args, name).resolve())
    repo = Path(__file__).resolve().parent.parent
    args.out.mkdir(parents=True, exist_ok=False, mode=0o700)
    args.out = args.out.resolve()
    run_id = str(uuid.uuid4())
    before = snapshot(repo)
    (args.out / "before.json").write_text(json.dumps(before, indent=2))
    receipt = {"runID": run_id, "stage": args.stage, "target": args.target, "udid": args.udid,
               "startedAt": timestamp(), "sourceInputSHA256": before["sha256"],
               "windowsReadyReceipt": str(args.windows_ready_receipt), "deviceBootstrapMayRemain": False, "commands": []}
    run_file = None
    bootstrap = None
    code = 1

    def run(name, command, timeout=600):
        with (args.out / (name + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        receipt["commands"].append({"name": name, "command": command, "exit": result.returncode})
        if result.returncode:
            raise RuntimeError(name + " failed")

    try:
        if not args.windows_ready_receipt.is_file():
            raise ValueError("parent ready acknowledgement is missing")
        shutil.copy2(args.windows_ready_receipt, args.out / "windows-ready-receipt.txt")
        metadata = json.loads(args.tls_metadata.read_bytes())
        destination = f"platform={'iOS Simulator' if args.target == 'simulator' else 'iOS'},id={args.udid}"
        run("build", ["xcodebuild", "-project", "CatRobot.xcodeproj", "-scheme", "CatRobot", "-destination", destination,
                      "-derivedDataPath", str(args.derived_data), "-clonedSourcePackagesDirPath", str(args.package_cache),
                      "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES",
                      "CATROBOT_SOURCE_REVISION=" + before["sha256"], "build-for-testing"], timeout=1200)
        products = args.derived_data / "Build/Products"
        app = products / ("Debug-iphonesimulator" if args.target == "simulator" else "Debug-iphoneos") / "CatRobot.app"
        bootstrap = args.out / "hermes-probe-bootstrap.json"
        receipt.update(write_bootstrap(args.secrets, metadata, bootstrap, args.target + "-" + args.udid))
        if args.target == "simulator":
            run("install", ["xcrun", "simctl", "install", args.udid, str(app)], timeout=120)
        else:
            run("readiness", ["xcrun", "devicectl", "--timeout", "20", "device", "info", "details", "--device", args.udid,
                              "--json-output", str(args.out / "device-details.json")], timeout=30)
            validate_device_readiness(json.loads((args.out / "device-details.json").read_bytes()))
            run("install", ["xcrun", "devicectl", "--timeout", "120", "device", "install", "app", "--device", args.udid, str(app)], timeout=150)
            receipt["deviceBootstrapMayRemain"] = True  # A failed copy can still leave a partial file.
            run("bootstrap-copy", ["xcrun", "devicectl", "--timeout", "30", "device", "copy", "to", "--device", args.udid,
                                  "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                                  "--source", str(bootstrap), "--destination", "Documents/hermes-probe-bootstrap.json"], timeout=45)
        candidates = list(products.glob("CatRobot_*.xctestrun"))
        if len(candidates) != 1:
            raise ValueError("expected one generated CatRobot xctestrun")
        run_file = products / ("HermesProbe-" + run_id + ".xctestrun")
        run_file.write_bytes(configure_xctestrun(candidates[0].read_bytes(), run_id=run_id, stage=args.stage,
                                                source_hash=before["sha256"], bootstrap=bootstrap if args.target == "simulator" else None))
        # Export is attempted even when XCTest fails, preserving the partial sanitized receipt.
        test_error = None
        try:
            run("test", ["xcodebuild", "-xctestrun", str(run_file), "-destination", destination,
                         "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                         "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "600",
                         "-resultBundlePath", str(args.out / "test.xcresult"), "test-without-building"], timeout=900)
        except (RuntimeError, subprocess.TimeoutExpired) as failure:
            test_error = failure
        result_path = args.out / "results.json"
        if args.target == "simulator":
            container = subprocess.check_output(["xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"], timeout=30).decode().strip()
            shutil.copy2(Path(container) / "Documents/HermesProbe" / run_id / "results.json", result_path)
        else:
            run("export", ["xcrun", "devicectl", "--timeout", "30", "device", "copy", "from", "--device", args.udid,
                           "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                           "--source", f"Documents/HermesProbe/{run_id}/results.json", "--destination", str(result_path)], timeout=45)
        observed = json.loads(result_path.read_bytes())
        if args.target == "device":
            receipt["deviceBootstrapMayRemain"] = observed.get("bootstrapRemoved") is not True
        if test_error:
            raise test_error
        validate_result(observed, run_id=run_id, stage=args.stage,
                        source_hash=before["sha256"], target=args.target)
        receipt["outcome"] = "success"
        code = 0
    except Exception as failure:
        # Fixed type only: never serialize arbitrary exception/locals/request data.
        receipt["outcome"] = "failed"
        receipt["failureType"] = type(failure).__name__
    finally:
        try:
            if bootstrap is not None:
                bootstrap.unlink(missing_ok=True)
            receipt["localBootstrapRemoved"] = True
        except OSError:
            receipt["localBootstrapRemoved"] = False
            receipt["outcome"] = "failed"
            receipt["failureType"] = "BootstrapCleanupError"
            code = 1
        if run_file is not None:
            run_file.unlink(missing_ok=True)
        after = snapshot(repo)
        (args.out / "after.json").write_text(json.dumps(after, indent=2))
        receipt["sourceUnchanged"] = before == after
        receipt["finishedAt"] = timestamp()
        if before != after:
            code = 99
            receipt["outcome"] = "invalid-source-changed"
        (args.out / "receipt.json").write_text(json.dumps(receipt, indent=2))
    print(json.dumps({"outcome": receipt["outcome"], "evidence": str(args.out), "runID": run_id}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
