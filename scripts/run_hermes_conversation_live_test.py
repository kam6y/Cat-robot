#!/usr/bin/env python3
"""DEBUG normal-conversation acceptance runner; never starts a backend or relay."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import ssl
import stat
import subprocess
import tempfile
from urllib.parse import urlsplit
import uuid

from run_hermes_probe_device_test import BUNDLE, snapshot as probe_snapshot, timestamp, validate_device_readiness


def snapshot(repo: Path):
    result = probe_snapshot(repo)
    result["sha256"] = hashlib.sha256(json.dumps(result["files"], sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return result


def selection(run_id: str, source_hash: str | None = None):
    if str(uuid.UUID(run_id)) != run_id or (source_hash is not None and re.fullmatch(r"[0-9a-f]{64}", source_hash) is None):
        raise ValueError("invalid acceptance selection")


def write_bootstrap(credentials: Path, metadata: dict, output: Path, run_id: str, endpoint: str):
    selection(run_id)
    parts = urlsplit(endpoint)
    if (endpoint not in metadata["endpoints"] or parts.scheme != "https" or not parts.hostname
            or parts.username is not None or parts.password is not None or parts.path not in ("", "/")
            or parts.query or parts.fragment or re.fullmatch(r"[0-9a-f]{64}", metadata["pin"]) is None):
        raise ValueError("endpoint or pin is not approved")
    if stat.S_IMODE(credentials.stat().st_mode) != 0o600:
        raise ValueError("credentials must have mode 0600")
    secrets = json.loads(credentials.read_bytes())
    key = secrets.get("client_key")
    upstream = secrets.get("upstream_key")
    if (not isinstance(key, str) or not key or any(not 0x21 <= ord(char) <= 0x7e for char in key)
            or not isinstance(upstream, str) or not upstream or key == upstream):
        raise ValueError("distinct client credential missing or invalid")
    payload = {"endpoint": endpoint, "pins": [metadata["pin"]], "deviceID": "conversation-" + run_id, "apiKey": key}
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle)
    return {"key_present": True, "bootstrapPath": str(output)}


def configure_xctestrun(source: bytes, *, run_id: str, source_hash: str, bootstrap: Path | None):
    selection(run_id, source_hash)
    value = plistlib.loads(source)
    targets = [value["CatRobotTests"]] if "CatRobotTests" in value else [
        target for config in value.get("TestConfigurations", []) for target in config["TestTargets"]
        if target.get("BlueprintName") == "CatRobotTests"]
    if not targets:
        raise ValueError("CatRobotTests missing")
    for target in targets:
        target["OnlyTestIdentifiers"] = ["HermesConversationLiveTests/testNormalConversationLifecycle"]
        target.pop("SkipTestIdentifiers", None)
        env = target.setdefault("EnvironmentVariables", {})
        for key in list(env):
            if key.startswith(("HERMES_PROBE", "HERMES_CONVERSATION_")):
                del env[key]
        env.update({"HERMES_CONVERSATION_LIVE": "1", "HERMES_CONVERSATION_RUN_ID": run_id,
                    "HERMES_CONVERSATION_SOURCE_SHA256": source_hash})
        if bootstrap is not None:
            env["HERMES_CONVERSATION_BOOTSTRAP"] = str(bootstrap)
    return plistlib.dumps(value)


def validate_result(result: dict, *, run_id: str, source_hash: str, target: str):
    expected = {"schemaVersion": 1, "runID": run_id, "sourceInputSHA256": source_hash, "target": target,
                "outcome": "success", "normalComposition": True, "processRestart": False, "physicalOperations": False,
                "bootstrapRemoved": True, "taskStateRemoved": True}
    if any(result.get(key) != value for key, value in expected.items()):
        raise ValueError("result is stale, incomplete, or unsafe")
    sections = {"twoTurns": {"contextMatched": True, "userRows": 2, "assistantRows": 2},
                "reconstruction": {"sameSession": True, "historyMatched": True},
                "cancellation": {"lateOutputRejected": True, "stopObserved": True, "gateTimedOut": False},
                "reconnect": {"fault": "accepted-response-loss", "droppedOnce": True, "sameKeyAndBody": True,
                              "replayed": True, "uniqueRunCount": 1, "userRows": 4, "assistantRows": 4}}
    for name, fields in sections.items():
        if not isinstance(result.get(name), dict) or any(result[name].get(key) != value for key, value in fields.items()):
            raise ValueError("scenario evidence missing")
    if result["cancellation"].get("terminal") not in ("completed", "cancelled", "failed", "interrupted"):
        raise ValueError("stop acknowledgement is not termination")


def validate_candidate(manifest: dict, snapshot: dict):
    # This is a Driver's final-input declaration, not a new parent approval gate.
    if (manifest.get("input_digest") != snapshot["sha256"] or manifest.get("file_count") != len(snapshot["files"])
            or manifest.get("live_acceptance_ready") is not True):
        raise ValueError("UI-complete final candidate does not match current inputs")


def inspect_tls(metadata: dict, endpoint: str):
    """Public certificate only; never read metadata's privateKeyPath."""
    certificate = Path(metadata["certificate"])
    der = ssl.PEM_cert_to_DER_cert(certificate.read_text())
    if hashlib.sha256(der).hexdigest() != metadata["pin"]:
        raise ValueError("public certificate pin mismatch")
    dates = subprocess.check_output(["openssl", "x509", "-in", str(certificate), "-noout", "-dates"], timeout=10).decode()
    parsed = dict(line.split("=", 1) for line in dates.splitlines())
    start, end = [datetime.strptime(parsed[key], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
                  for key in ("notBefore", "notAfter")]
    if not start <= datetime.now(timezone.utc) < end:
        raise ValueError("certificate is not currently valid")
    host = urlsplit(endpoint).hostname
    try:
        ipaddress.ip_address(host)
        check = "-checkip"
    except ValueError:
        check = "-checkhost"
    subprocess.run(["openssl", "x509", "-in", str(certificate), "-noout", check, host],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=10)
    return {"checkedAt": timestamp(), "pinMatched": True, "hostnameMatched": True,
            "notBefore": start.isoformat(), "notAfter": end.isoformat()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=["simulator", "device"], required=True)
    parser.add_argument("--udid", required=True)
    for name in ("out", "credentials", "tls-metadata", "candidate-manifest", "backend-ready", "derived-data", "package-cache"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--endpoint", required=True, help="One endpoint in the already approved public TLS metadata")
    parser.add_argument("--lan-interface", default="en0")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    args.out.mkdir(parents=True, exist_ok=False, mode=0o700)
    run_id, before, bootstrap, run_file = str(uuid.uuid4()), None, None, None
    bootstrap_directory = None
    receipt = {"runID": run_id, "target": args.target, "startedAt": timestamp(), "commands": [],
               "outcome": "failed", "deviceBootstrapMayRemain": False}
    code = 1

    def run(name, command, timeout=600):
        with (args.out / (name + ".log")).open("w") as log:
            completed = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
        receipt["commands"].append({"name": name, "command": command, "exit": completed.returncode})
        if completed.returncode:
            raise RuntimeError(name + " failed")

    def fresh_device_and_lan():
        address = subprocess.check_output(["ipconfig", "getifaddr", args.lan_interface], timeout=10).decode().strip()
        if address != urlsplit(args.endpoint).hostname:
            raise ValueError("approved relay endpoint is not on the current LAN")
        run("device-details", ["xcrun", "devicectl", "--timeout", "20", "device", "info", "details", "--device", args.udid,
                               "--json-output", str(args.out / "device-details.json")], 30)
        validate_device_readiness(json.loads((args.out / "device-details.json").read_bytes()))
        run("device-lock", ["xcrun", "devicectl", "--timeout", "20", "device", "info", "lockState", "--device", args.udid,
                            "--json-output", str(args.out / "device-lock.json")], 30)
        lock = json.loads((args.out / "device-lock.json").read_bytes()).get("result", {})
        if lock.get("passcodeRequired") is not False or lock.get("unlockedSinceBoot") is not True:
            raise ValueError("device is locked or not unlocked since boot")
        receipt["deviceFreshAt"] = timestamp()

    try:
        before = snapshot(repo)
        (args.out / "before.json").write_text(json.dumps(before, indent=2))
        receipt["sourceInputSHA256"] = before["sha256"]
        validate_candidate(json.loads(args.candidate_manifest.read_bytes()), before)
        ready = json.loads(args.backend_ready.read_bytes())
        if (ready.get("profile") != "catrobot-conversation-test" or ready.get("apiToolsets") != []
                or ready.get("effectiveToolNames") != []):
            raise ValueError("isolated backend without tools is required")
        metadata = json.loads(args.tls_metadata.read_bytes())
        if args.endpoint not in metadata["endpoints"]:
            raise ValueError("unapproved endpoint")
        receipt["tlsBeforeBuild"] = inspect_tls(metadata, args.endpoint)
        # A fresh task-owned directory avoids copied XCBuildData retaining old absolute cleanup paths.
        args.derived_data.mkdir(parents=True, exist_ok=False)
        destination = f"platform={'iOS Simulator' if args.target == 'simulator' else 'iOS'},id={args.udid}"
        run("build", ["xcodebuild", "-project", "CatRobot.xcodeproj", "-scheme", "CatRobot", "-configuration", "Debug",
                      "-destination", destination, "-derivedDataPath", str(args.derived_data),
                      "-clonedSourcePackagesDirPath", str(args.package_cache), "-disableAutomaticPackageResolution",
                      "-onlyUsePackageVersionsFromResolvedFile", "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=YES",
                      "build-for-testing"], 1800)
        products = args.derived_data / "Build/Products"
        platform = "iphonesimulator" if args.target == "simulator" else "iphoneos"
        app = products / ("Debug-" + platform) / "CatRobot.app"
        run("verify-signature", ["codesign", "--verify", "--deep", "--strict", str(app)], 30)
        receipt["appExecutableSHA256"] = hashlib.sha256((app / "CatRobot").read_bytes()).hexdigest()
        test_binary = app / "PlugIns/CatRobotTests.xctest/CatRobotTests"
        run("verify-test-signature", ["codesign", "--verify", "--strict", str(test_binary.parent)], 30)
        receipt["testExecutableSHA256"] = hashlib.sha256(test_binary.read_bytes()).hexdigest()
        if args.target == "device":
            fresh_device_and_lan()
            run("install", ["xcrun", "devicectl", "--timeout", "120", "device", "install", "app", "--device", args.udid, str(app)], 150)
        else:
            run("install", ["xcrun", "simctl", "install", args.udid, str(app)], 120)
        # Credential material never enters evidence, even if this process is force-killed.
        bootstrap_directory = tempfile.TemporaryDirectory(prefix=".hermes-conversation-", dir=args.credentials.resolve().parent)
        bootstrap = Path(bootstrap_directory.name) / "hermes-conversation-bootstrap.json"
        receipt.update(write_bootstrap(args.credentials, metadata, bootstrap, run_id, args.endpoint))
        if args.target == "device":
            receipt["deviceBootstrapMayRemain"] = True
            run("bootstrap-copy", ["xcrun", "devicectl", "--timeout", "30", "device", "copy", "to", "--device", args.udid,
                                   "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE, "--source", str(bootstrap),
                                   "--destination", "Documents/hermes-conversation-bootstrap.json"], 45)
        candidates = list(products.glob("CatRobot_" + platform + "*.xctestrun"))
        if len(candidates) != 1:
            raise ValueError("expected one matching generated xctestrun")
        run_file = products / ("HermesConversation-" + run_id + ".xctestrun")
        run_file.write_bytes(configure_xctestrun(candidates[0].read_bytes(), run_id=run_id, source_hash=before["sha256"],
                                                bootstrap=bootstrap if args.target == "simulator" else None))
        receipt["tlsBeforeTest"] = inspect_tls(metadata, args.endpoint)
        if args.target == "device":
            fresh_device_and_lan()
        test_error = None
        try:
            run("test", ["xcodebuild", "-xctestrun", str(run_file), "-destination", destination, "-parallel-testing-enabled", "NO",
                         "-collect-test-diagnostics", "never", "-test-timeouts-enabled", "YES",
                         "-maximum-test-execution-time-allowance", "600", "-resultBundlePath", str(args.out / "test.xcresult"),
                         "test-without-building"], 900)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            test_error = error
        result = args.out / "results.json"
        if args.target == "device":
            run("export", ["xcrun", "devicectl", "--timeout", "30", "device", "copy", "from", "--device", args.udid,
                           "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                           "--source", f"Documents/HermesConversation/{run_id}/results.json", "--destination", str(result)], 45)
        else:
            container = subprocess.check_output(["xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"], timeout=30).decode().strip()
            shutil.copy2(Path(container) / "Documents/HermesConversation" / run_id / "results.json", result)
        observed = json.loads(result.read_bytes())
        receipt["deviceBootstrapMayRemain"] = args.target == "device" and observed.get("bootstrapRemoved") is not True
        if test_error:
            raise test_error
        validate_result(observed, run_id=run_id, source_hash=before["sha256"], target=args.target)
        receipt["outcome"], code = "success", 0
    except Exception as error:
        receipt["failureType"] = type(error).__name__  # Never serialize request/exception/secret values.
    finally:
        try:
            if bootstrap is not None:
                bootstrap.unlink(missing_ok=True)
            if bootstrap_directory is not None:
                bootstrap_directory.cleanup()
            if run_file is not None:
                run_file.unlink(missing_ok=True)
            receipt["localBootstrapRemoved"] = True
        except OSError:
            receipt["outcome"], receipt["failureType"], code = "failed", "LocalCleanupError", 1
        try:
            after = snapshot(repo)
            (args.out / "after.json").write_text(json.dumps(after, indent=2))
            receipt["sourceUnchanged"] = before == after
            if before != after:
                receipt["outcome"], code = "invalid-source-changed", 66
            receipt["finishedAt"] = timestamp()
            temp = args.out / "receipt.tmp"
            temp.write_text(json.dumps(receipt, indent=2) + "\n")
            temp.replace(args.out / "receipt.json")
        except Exception:
            receipt["outcome"], code = "invalid-evidence", 66
    print(json.dumps({"outcome": receipt["outcome"], "evidence": str(args.out), "runID": run_id}))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
