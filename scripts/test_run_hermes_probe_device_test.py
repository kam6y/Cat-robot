"""Evidence and credential boundaries without Xcode or network."""
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("probe_runner", Path(__file__).with_name("run_hermes_probe_device_test.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
RUN_ID = "ec7319bd-f2e7-4698-b9a2-2c3c587249ff"


class ProbeRunnerTests(unittest.TestCase):
    def test_bootstrap_is_exclusive_owner_only_and_never_contains_the_bridge_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            secrets = root / "secrets.json"
            secrets.write_text(json.dumps({"apiKey": "dummy-api-key", "mcpBridgeKey": "dummy-bridge-key"}))
            secrets.chmod(0o600)
            output = root / "bootstrap.json"
            metadata = {"endpoints": ["https://127.0.0.1:18644"], "pin": "00"}
            receipt = runner.write_bootstrap(secrets, metadata, output, "simulator-test")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(output.read_bytes()), {"endpoint": metadata["endpoints"][0], "pins": ["00"],
                                                              "deviceID": "simulator-test", "apiKey": "dummy-api-key"})
            self.assertEqual(receipt, {"key_present": True, "bootstrapPath": str(output)})
            self.assertNotIn("dummy-api-key", json.dumps(receipt))
            self.assertNotIn("dummy-bridge-key", output.read_text())
            with self.assertRaises(FileExistsError):
                runner.write_bootstrap(secrets, metadata, output, "simulator-test")
            secrets.chmod(0o644)
            with self.assertRaises(ValueError):
                runner.write_bootstrap(secrets, metadata, root / "bad.json", "simulator-test")
            self.assertFalse((root / "bad.json").exists())

    def test_xctestrun_injects_probe_flags_before_launch_and_selects_only_the_probe(self):
        for modern in (False, True):
            target = {"BlueprintName": "CatRobotTests", "TestBundlePath": "__TESTROOT__/tests.xctest",
                      "EnvironmentVariables": {"unchanged": "value"}, "SkipTestIdentifiers": ["HermesProbeDeviceTests"]}
            value = {"TestConfigurations": [{"TestTargets": [target]}]} if modern else {"CatRobotTests": target}
            data = runner.configure_xctestrun(plistlib.dumps(value), run_id=RUN_ID, stage="lifetime1", source_hash="abc",
                                             bootstrap=Path("/tmp/bootstrap.json"))
            parsed = plistlib.loads(data)
            actual = parsed["TestConfigurations"][0]["TestTargets"][0] if modern else parsed["CatRobotTests"]
            self.assertEqual(actual.get("OnlyTestIdentifiers"), ["HermesProbeDeviceTests/testSelectedStage"])
            self.assertNotIn("SkipTestIdentifiers", actual)
            self.assertEqual(actual["TestBundlePath"], target["TestBundlePath"])
            self.assertEqual(actual["EnvironmentVariables"], {"unchanged": "value", "HERMES_PROBE": "1", "HERMES_PROBE_RUN_ID": RUN_ID,
                             "HERMES_PROBE_STAGE": "lifetime1", "HERMES_PROBE_SOURCE_SHA256": "abc",
                             "HERMES_PROBE_BOOTSTRAP": "/tmp/bootstrap.json"})
            physical = plistlib.loads(runner.configure_xctestrun(data, run_id=RUN_ID, stage="lifetime2", source_hash="abc", bootstrap=None))
            physical_target = physical["TestConfigurations"][0]["TestTargets"][0] if modern else physical["CatRobotTests"]
            self.assertNotIn("HERMES_PROBE_BOOTSTRAP", physical_target["EnvironmentVariables"])

    def test_invalid_selection_is_rejected_before_it_can_become_a_result_path(self):
        for run_id, stage in (("../escape", "lifetime1"), (RUN_ID, "unknown")):
            with self.assertRaises(ValueError):
                runner.configure_xctestrun(plistlib.dumps({}), run_id=run_id, stage=stage, source_hash="abc", bootstrap=None)

    def test_cached_disconnected_details_are_not_physical_readiness(self):
        details = {"result": {"connectionProperties": {"tunnelState": "connected", "pairingState": "paired"},
                              "deviceProperties": {"ddiServicesAvailable": True, "developerModeStatus": "enabled"}}}
        runner.validate_device_readiness(details)
        for group, key, value in (("connectionProperties", "tunnelState", "disconnected"),
                                  ("connectionProperties", "pairingState", "unpaired"),
                                  ("deviceProperties", "ddiServicesAvailable", False),
                                  ("deviceProperties", "developerModeStatus", "disabled")):
            changed = copy.deepcopy(details)
            changed["result"][group][key] = value
            with self.assertRaises(ValueError):
                runner.validate_device_readiness(changed)
        with self.assertRaises(ValueError):
            runner.validate_device_readiness({})

    @staticmethod
    def result(stage):
        return {"runID": RUN_ID, "stage": stage, "sourceInputSHA256": "abc", "target": "simulator", "outcome": "success",
                "physicalOperations": False, "compositionCreated": False, "key_present": True, "bootstrapRemoved": True, "records": []}

    def validate(self, result, stage):
        runner.validate_result(result, run_id=RUN_ID, stage=stage, source_hash="abc", target="simulator")

    def test_success_label_requires_all_auth_plain_and_bound_evidence(self):
        result = self.result("lifetime1")
        result["records"] = [{"operation": "capabilities", "credential": credential, "status": status}
                             for credential, status in (("absent", 401), ("wrong", 401), ("present", 200))]
        result["records"] += [{"operation": operation, "status": "completed", "nonceMatched": True}
                              for operation in ("plain", "boundTerminal")]
        result["records"].append({"operation": "mockEcho", "accepted": True})
        self.validate(result, "lifetime1")
        for index in range(len(result["records"])):
            incomplete = copy.deepcopy(result)
            incomplete["records"].pop(index)
            with self.assertRaises(ValueError):
                self.validate(incomplete, "lifetime1")
        for key, value in (("sourceInputSHA256", "old"), ("target", "device"), ("physicalOperations", True),
                           ("outcome", "failed"), ("bootstrapRemoved", False)):
            mismatch = copy.deepcopy(result)
            mismatch[key] = value
            with self.assertRaises(ValueError):
                self.validate(mismatch, "lifetime1")

    def test_cancellation_accepts_the_actual_terminal_but_requires_a_held_unexecuted_call(self):
        for terminal in ("completed", "cancelled", "failed"):
            result = self.result("lifetime2")
            result["records"] = [{"operation": "cancel", "status": terminal, "heldCallDiscarded": True,
                                  "mockExecuted": False, "revokeAccepted": True, "stopAccepted": False}]
            self.validate(result, "lifetime2")
            for key, value in (("status", "running"), ("heldCallDiscarded", False), ("mockExecuted", True), ("revokeAccepted", False)):
                invalid = copy.deepcopy(result)
                invalid["records"][0][key] = value
                with self.assertRaises(ValueError):
                    self.validate(invalid, "lifetime2")

    def test_failed_device_copy_removes_local_bootstrap_and_reports_possible_device_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            secrets = root / "secrets.json"
            secrets.write_text(json.dumps({"apiKey": "dummy-device-key"}))
            secrets.chmod(0o600)
            metadata = root / "metadata.json"
            metadata.write_text(json.dumps({"endpoints": ["https://127.0.0.1:18644"], "pin": "00"}))
            ready = root / "ready.txt"
            ready.write_text("dummy parent acknowledgement for this test")
            output = root / "evidence"
            args = ["probe", "--target", "device", "--udid", "test-device", "--stage", "lifetime1", "--out", str(output),
                    "--secrets", str(secrets), "--tls-metadata", str(metadata), "--derived-data", str(root / "DD"),
                    "--package-cache", str(root / "packages"), "--windows-ready-receipt", str(ready)]

            def fake_command(command, **_):
                # Xcode/device operations are faked; real local bootstrap creation/cleanup is exercised.
                if "--json-output" in command:
                    path = Path(command[command.index("--json-output") + 1])
                    path.write_text(json.dumps({"result": {
                        "connectionProperties": {"tunnelState": "connected", "pairingState": "paired"},
                        "deviceProperties": {"ddiServicesAvailable": True, "developerModeStatus": "enabled"}}}))
                failed = "copy" in command and "to" in command
                return runner.subprocess.CompletedProcess(command, 1 if failed else 0)

            stdout = io.StringIO()
            with patch("sys.argv", args), patch.object(runner, "snapshot", return_value={"files": {}, "sha256": "abc"}), \
                 patch.object(runner.subprocess, "run", side_effect=fake_command), contextlib.redirect_stdout(stdout):
                self.assertEqual(runner.main(), 1)
            self.assertFalse((output / "hermes-probe-bootstrap.json").exists())
            receipt = json.loads((output / "receipt.json").read_bytes())
            self.assertTrue(receipt["deviceBootstrapMayRemain"])
            self.assertNotIn("dummy-device-key", stdout.getvalue() + json.dumps(receipt))


if __name__ == "__main__":
    unittest.main()
