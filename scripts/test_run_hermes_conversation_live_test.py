"""Offline checks of the live runner's credential and evidence boundaries."""
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

SPEC = importlib.util.spec_from_file_location("conversation_runner", Path(__file__).with_name("run_hermes_conversation_live_test.py"))
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
RUN_ID = "ec7319bd-f2e7-4698-b9a2-2c3c587249ff"
SOURCE = "a" * 64
ENDPOINT = "https://192.0.2.1:18644"


class ConversationLiveRunnerTests(unittest.TestCase):
    def test_only_the_client_key_reaches_an_exclusive_owner_only_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            credentials, output = root / "credentials.json", root / "bootstrap.json"
            credentials.write_text(json.dumps({"upstream_base": "http://upstream.test", "upstream_key": "dummy-upstream",
                                                "client_key": "dummy-phone"}))
            credentials.chmod(0o600)
            evidence = runner.write_bootstrap(credentials, {"endpoints": [ENDPOINT], "pin": "b" * 64}, output, RUN_ID, ENDPOINT)
            self.assertTrue(output.is_file(), "the client bootstrap was not written")
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(output.read_bytes()), {"endpoint": ENDPOINT, "pins": ["b" * 64],
                              "deviceID": "conversation-" + RUN_ID, "apiKey": "dummy-phone"})
            self.assertNotIn("dummy-upstream", output.read_text())
            self.assertNotIn("dummy-phone", json.dumps(evidence))
            with self.assertRaises(FileExistsError):
                runner.write_bootstrap(credentials, {"endpoints": [ENDPOINT], "pin": "b" * 64}, output, RUN_ID, ENDPOINT)

    def test_bad_credential_permissions_same_key_or_unapproved_endpoint_write_nothing(self):
        for mode, client, endpoint in ((0o644, "phone", ENDPOINT), (0o600, "upstream", ENDPOINT),
                                        (0o600, "phone\r\nInjected:x", ENDPOINT), (0o600, "phone", "https://other.test")):
            with self.subTest(mode=mode, endpoint=endpoint), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                secrets, output = root / "credentials.json", root / "bootstrap.json"
                secrets.write_text(json.dumps({"upstream_key": "upstream", "client_key": client}))
                secrets.chmod(mode)
                with self.assertRaises(ValueError):
                    runner.write_bootstrap(secrets, {"endpoints": [ENDPOINT], "pin": "b" * 64}, output, RUN_ID, endpoint)
                self.assertFalse(output.exists())

    def test_launch_selects_only_the_normal_conversation_fixture_and_an_inert_host(self):
        target = {"BlueprintName": "CatRobotTests", "TestBundlePath": "__TESTROOT__/CatRobotTests.xctest",
                  "EnvironmentVariables": {"untouched": "yes", "HERMES_PROBE": "1", "HERMES_PROBE_STAGE": "lifetime1"},
                  "SkipTestIdentifiers": ["HermesConversationLiveTests"]}
        for modern in (False, True):
            value = {"TestConfigurations": [{"TestTargets": [target]}]} if modern else {"CatRobotTests": target}
            actual = plistlib.loads(runner.configure_xctestrun(plistlib.dumps(value), run_id=RUN_ID,
                                  source_hash=SOURCE, bootstrap=Path("/tmp/bootstrap.json")))
            selected = actual["TestConfigurations"][0]["TestTargets"][0] if modern else actual["CatRobotTests"]
            self.assertEqual(selected.get("OnlyTestIdentifiers"), ["HermesConversationLiveTests/testNormalConversationLifecycle"])
            self.assertNotIn("SkipTestIdentifiers", selected)
            self.assertEqual(selected["EnvironmentVariables"], {"untouched": "yes", "HERMES_CONVERSATION_LIVE": "1",
                             "HERMES_CONVERSATION_RUN_ID": RUN_ID, "HERMES_CONVERSATION_SOURCE_SHA256": SOURCE,
                             "HERMES_CONVERSATION_BOOTSTRAP": "/tmp/bootstrap.json"})
            physical = plistlib.loads(runner.configure_xctestrun(plistlib.dumps(value), run_id=RUN_ID,
                                     source_hash=SOURCE, bootstrap=None))
            selected = physical["TestConfigurations"][0]["TestTargets"][0] if modern else physical["CatRobotTests"]
            self.assertNotIn("HERMES_CONVERSATION_BOOTSTRAP", selected["EnvironmentVariables"])

    def test_invalid_run_id_or_source_digest_cannot_select_a_test(self):
        for run_id, digest in (("../escape", SOURCE), (RUN_ID, "old")):
            with self.assertRaises(ValueError):
                runner.configure_xctestrun(plistlib.dumps({}), run_id=run_id, source_hash=digest, bootstrap=None)

    @staticmethod
    def result():
        return {"schemaVersion": 1, "runID": RUN_ID, "sourceInputSHA256": SOURCE, "target": "device", "outcome": "success",
                "normalComposition": True, "processRestart": False, "physicalOperations": False, "bootstrapRemoved": True, "taskStateRemoved": True,
                "twoTurns": {"contextMatched": True, "userRows": 2, "assistantRows": 2},
                "reconstruction": {"sameSession": True, "historyMatched": True},
                "cancellation": {"lateOutputRejected": True, "stopObserved": True, "gateTimedOut": False, "terminal": "completed"},
                "reconnect": {"fault": "accepted-response-loss", "droppedOnce": True, "sameKeyAndBody": True,
                              "replayed": True, "uniqueRunCount": 1, "userRows": 4, "assistantRows": 4}}

    def test_success_requires_every_scenario_and_actual_terminal_not_a_stop_ack(self):
        valid = self.result()
        runner.validate_result(valid, run_id=RUN_ID, source_hash=SOURCE, target="device")
        variants = []
        for section in ("twoTurns", "reconstruction", "cancellation", "reconnect"):
            missing = copy.deepcopy(valid)
            del missing[section]
            variants.append(missing)
        for section, key, value in (("cancellation", "terminal", "stopping"), ("cancellation", "lateOutputRejected", False),
                                    ("cancellation", "gateTimedOut", True), ("reconnect", "sameKeyAndBody", False),
                                    ("reconnect", "userRows", 5), ("reconnect", "uniqueRunCount", 2),
                                    ("twoTurns", "contextMatched", False)):
            invalid = copy.deepcopy(valid)
            invalid[section][key] = value
            variants.append(invalid)
        for invalid in variants:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                runner.validate_result(invalid, run_id=RUN_ID, source_hash=SOURCE, target="device")

    def test_stale_source_wrong_target_or_incomplete_cleanup_cannot_pass(self):
        for key, value in (("sourceInputSHA256", "b" * 64), ("target", "simulator"), ("outcome", "failed"),
                           ("normalComposition", False), ("processRestart", True), ("physicalOperations", True), ("bootstrapRemoved", False),
                           ("taskStateRemoved", False)):
            invalid = self.result()
            invalid[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                runner.validate_result(invalid, run_id=RUN_ID, source_hash=SOURCE, target="device")

    def test_final_candidate_must_match_current_inputs_and_file_count(self):
        runner.validate_candidate({"input_digest": SOURCE, "file_count": 2, "live_acceptance_ready": True},
                                  {"sha256": SOURCE, "files": {"a": "1", "b": "2"}})
        for manifest in ({"input_digest": "b" * 64, "file_count": 2, "live_acceptance_ready": True},
                         {"input_digest": SOURCE, "file_count": 1, "live_acceptance_ready": True},
                         {"input_digest": SOURCE, "file_count": 2}, {}):
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                runner.validate_candidate(manifest, {"sha256": SOURCE, "files": {"a": "1", "b": "2"}})

    def run_blocked_candidate(self, root, snapshots, receipt_failure=False):
        manifest = root / "candidate.json"
        manifest.write_text(json.dumps({"input_digest": SOURCE, "file_count": 1}))  # UI is still incomplete.
        args = ["runner", "--target", "device", "--udid", "dummy-device", "--out", str(root / "out"),
                "--credentials", str(root / "credentials.json"), "--tls-metadata", str(root / "tls.json"),
                "--candidate-manifest", str(manifest), "--backend-ready", str(root / "backend.json"),
                "--derived-data", str(root / "DD"), "--package-cache", str(root / "packages"), "--endpoint", ENDPOINT]
        stdout = io.StringIO()
        with patch("sys.argv", args), patch.object(runner, "snapshot", side_effect=snapshots), \
             patch.object(runner.subprocess, "run", side_effect=AssertionError("no Xcode/device action allowed")), \
             contextlib.redirect_stdout(stdout):
            if receipt_failure:
                with patch.object(Path, "replace", side_effect=OSError("receipt unavailable")):
                    status = runner.main()
            else:
                status = runner.main()
        return status, json.loads(stdout.getvalue())

    def test_ui_incomplete_candidate_stops_before_any_build_install_or_live_action(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = {"sha256": SOURCE, "files": {"a": "1"}}
            status, _ = self.run_blocked_candidate(root, [snapshot, snapshot])
            self.assertEqual(status, 1)
            receipt = json.loads((root / "out/receipt.json").read_bytes())
            self.assertEqual(receipt["failureType"], "ValueError")
            self.assertEqual(receipt["commands"], [])
            self.assertFalse((root / "out/hermes-conversation-bootstrap.json").exists())

    def test_source_change_or_unwritable_receipt_must_override_the_exit_status(self):
        before = {"sha256": SOURCE, "files": {"a": "1"}}
        for receipt_failure in (False, True):
            with self.subTest(receipt_failure=receipt_failure), tempfile.TemporaryDirectory() as directory:
                after = before if receipt_failure else {"sha256": "b" * 64, "files": {"a": "2"}}
                status, output = self.run_blocked_candidate(Path(directory), [before, after], receipt_failure)
                self.assertEqual(status, 66)
                self.assertEqual(output["outcome"], "invalid-evidence" if receipt_failure else "invalid-source-changed")

    def test_interrupted_device_copy_never_puts_a_key_in_evidence_and_cleans_runtime_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            credentials = root / "credentials.json"
            credentials.write_text(json.dumps({"upstream_key": "dummy-upstream", "client_key": "dummy-phone"}))
            credentials.chmod(0o600)
            for name, value in (("candidate", {"input_digest": SOURCE, "file_count": 1, "live_acceptance_ready": True}),
                                ("backend", {"profile": "catrobot-conversation-test", "apiToolsets": [], "effectiveToolNames": []}),
                                ("tls", {"endpoints": [ENDPOINT], "pin": "b" * 64})):
                (root / (name + ".json")).write_text(json.dumps(value))
            dd, output = root / "DD", root / "evidence"
            args = ["runner", "--target", "device", "--udid", "dummy-device", "--out", str(output),
                    "--credentials", str(credentials), "--tls-metadata", str(root / "tls.json"),
                    "--candidate-manifest", str(root / "candidate.json"), "--backend-ready", str(root / "backend.json"),
                    "--derived-data", str(dd), "--package-cache", str(root / "packages"), "--endpoint", ENDPOINT]
            observed = {}

            def external(command, **_):
                # Only external build/sign/device operations are faked; credential-file handling is real.
                if "build-for-testing" in command:
                    app = dd / "Build/Products/Debug-iphoneos/CatRobot.app"
                    tests = app / "PlugIns/CatRobotTests.xctest"
                    tests.mkdir(parents=True)
                    (app / "CatRobot").write_bytes(b"dummy-app")
                    (tests / "CatRobotTests").write_bytes(b"dummy-tests")
                if "--json-output" in command:
                    result = ({"passcodeRequired": False, "unlockedSinceBoot": True} if "lockState" in command else
                              {"connectionProperties": {"tunnelState": "connected", "pairingState": "paired"},
                               "deviceProperties": {"ddiServicesAvailable": True, "developerModeStatus": "enabled"}})
                    Path(command[command.index("--json-output") + 1]).write_text(json.dumps({"result": result}))
                if "copy" in command and "to" in command:
                    path = Path(command[command.index("--source") + 1])
                    observed.update(path=path, inEvidence=path.is_relative_to(output),
                                    parentMode=path.parent.stat().st_mode & 0o777,
                                    payload=json.loads(path.read_bytes()))
                    return runner.subprocess.CompletedProcess(command, 1)
                return runner.subprocess.CompletedProcess(command, 0)

            stdout = io.StringIO()
            snapshot = {"sha256": SOURCE, "files": {"a": "1"}}
            with patch("sys.argv", args), patch.object(runner, "snapshot", return_value=snapshot), \
                 patch.object(runner, "inspect_tls", return_value={"publicCertificateChecked": True}), \
                 patch.object(runner.subprocess, "run", side_effect=external), \
                 patch.object(runner.subprocess, "check_output", return_value=b"192.0.2.1\n"), contextlib.redirect_stdout(stdout):
                status = runner.main()
            self.assertEqual(status, 1)
            self.assertIn("path", observed, "the controlled failure must occur after bootstrap creation")
            self.assertFalse(observed["inEvidence"], "credential material must never enter the evidence directory")
            self.assertEqual(observed["parentMode"], 0o700)
            self.assertEqual(observed["payload"]["apiKey"], "dummy-phone")
            self.assertNotIn("dummy-upstream", json.dumps(observed["payload"]))
            self.assertFalse(observed["path"].exists())
            self.assertFalse(observed["path"].parent.exists())
            receipt = json.loads((output / "receipt.json").read_bytes())
            self.assertTrue(receipt["deviceBootstrapMayRemain"])
            self.assertNotIn("dummy-phone", stdout.getvalue() + json.dumps(receipt))


if __name__ == "__main__":
    unittest.main()
