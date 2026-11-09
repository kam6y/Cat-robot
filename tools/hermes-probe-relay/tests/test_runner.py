"""runner の設定生成、端末キー非保存、0600/0700 排他作成、readiness の全条件 hard-fail、同一接続 pin 照合、公式 client probe、秘密非出力。"""
import asyncio
import contextlib
import hashlib
import io
import json
import os
import stat
import ssl
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import httpx

from relay.app import build_relay_app
from relay.config import RelayConfig
from relay.mcpserver import build_mcp_app
from relay import runner
from tests.fakes import FakeClock, FakeHermes, make_config

SECRETS = {"apiKey": "api-secret-value", "mcpBridgeKey": "bridge-secret-value"}
METADATA = {"pinKind": "certificateDER-SHA256-hex", "pin": "ab" * 32, "endpoints": ["https://192.168.0.202:18644", "https://127.0.0.1:18644"],
            "certificate": "/parent/tls-named/relay-cert.pem", "privateKeyPath": "/parent/tls-named/relay-key.pem"}
GOOD = {"tlsPinMatches": True, "capabilitiesWithoutAuthStatus": 401, "mcpServerName": "mockbridge", "mcpTools": ["echo"],
        "mcpEchoWithoutBindingIsError": True, "mcpEchoErrorMentionsNoBoundDevice": True}


class RunnerPureTests(unittest.TestCase):
    def test_relay_config_is_built_from_metadata_and_bridge_key_only_and_validates(self):
        config = runner.build_relay_config(SECRETS, METADATA, hermes_base="http://100.66.5.53:18642",
                                           relay_listen=["192.168.0.202:18644", "127.0.0.1:18644"], mcp_listen="100.102.164.56:18643")
        self.assertEqual(config["cert"], METADATA["certificate"])
        self.assertEqual(config["key"], METADATA["privateKeyPath"])
        self.assertEqual(config["mcpBridgeKey"], SECRETS["mcpBridgeKey"])
        self.assertNotIn("api-secret-value", json.dumps(config), "the device API key never enters the relay config")
        self.assertEqual(RelayConfig.from_mapping(config).mcp_listen, ("100.102.164.56", 18643))

    def test_relay_start_never_writes_a_device_api_key_copy_on_success_or_failure(self):
        for ready in ({}, None):
            with self.subTest(ready=ready), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                secrets = root / "secrets.json"
                runner.write_owner_only_json(secrets, SECRETS)
                metadata = root / "metadata.json"
                metadata.write_text(json.dumps(METADATA))
                child = mock.Mock(pid=1234)
                child.poll.return_value = None
                with mock.patch.object(runner.subprocess, "Popen", return_value=child), \
                     mock.patch.object(runner, "wait_ready_line", return_value=ready), \
                     mock.patch.object(runner, "probe_readiness", return_value=GOOD), \
                     contextlib.redirect_stdout(io.StringIO()):
                    code = runner.main(["--secrets", str(secrets), "--tls-metadata", str(metadata),
                                        "--out", str(root / "attempts")])
                self.assertEqual(code, 0 if ready is not None else 1)
                attempt, = (root / "attempts").iterdir()
                self.assertFalse((attempt / "hermes-probe-bootstrap.json").exists(), "only the device runner owns bootstrap delivery")
                for output in attempt.iterdir():
                    self.assertNotIn(SECRETS["apiKey"], output.read_text(), output.name)

    def test_owner_only_json_is_0600_and_never_overwrites(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "relay-config.json"
            runner.write_owner_only_json(path, {"a": 1})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(json.loads(path.read_text()), {"a": 1})
            with self.assertRaises(FileExistsError):
                runner.write_owner_only_json(path, {"a": 2})
            self.assertEqual(json.loads(path.read_text()), {"a": 1})

    def test_attempt_directories_are_0700_unique_and_exclusive(self):
        with tempfile.TemporaryDirectory() as directory:
            clock = FakeClock(1_800_000_000.0)
            first = runner.create_attempt_dir(Path(directory) / "relay-run", clock)
            self.assertTrue(first.is_dir())
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o700)
            self.assertTrue(first.name.startswith("attempt-"), first.name)
            with self.assertRaises(FileExistsError):
                runner.create_attempt_dir(Path(directory) / "relay-run", clock)
            clock.advance(1)
            second = runner.create_attempt_dir(Path(directory) / "relay-run", clock)
            self.assertNotEqual(first, second)

    def test_readiness_requires_every_expected_observation(self):
        self.assertEqual(runner.readiness_problems(GOOD), [])
        for key, bad in [("tlsPinMatches", False), ("capabilitiesWithoutAuthStatus", 200), ("mcpServerName", "stub"),
                         ("mcpTools", ["echo", "move"]), ("mcpTools", []), ("mcpEchoWithoutBindingIsError", False),
                         ("mcpEchoErrorMentionsNoBoundDevice", False)]:
            problems = runner.readiness_problems({**GOOD, key: bad})
            self.assertEqual(len(problems), 1, (key, bad, problems))
            self.assertIn(key, problems[0])
        missing = dict(GOOD)
        del missing["mcpTools"]
        self.assertTrue(any("mcpTools" in problem for problem in runner.readiness_problems(missing)))

    def test_secret_values_are_detected_in_text_destined_for_receipts_or_stdout(self):
        runner.assert_no_secrets('{"apiKey_present": true}', list(SECRETS.values()))
        with self.assertRaises(ValueError):
            runner.assert_no_secrets('{"x": "api-secret-value"}', list(SECRETS.values()))
        with self.assertRaises(ValueError):
            runner.assert_no_secrets("prefix bridge-secret-value suffix", list(SECRETS.values()))
        runner.assert_no_secrets("anything", [])

    def test_pinned_capabilities_checks_the_pin_on_the_same_connection_before_requesting(self):
        der = b"certificate-der-bytes"
        events: list[str] = []

        class FakeSock:
            def getpeercert(self, binary_form=False):
                return der

        class FakeResponse:
            status = 401

            def read(self):
                return b'{"error":"unauthorized"}'

        class FakeConnection:
            def __init__(self, host, port, context=None, timeout=None):
                events.append(f"connect-args {host}:{port} cafile={getattr(context, 'cafile', None)} check_hostname={getattr(context, 'check_hostname', None)}")
                self.sock = None

            def connect(self):
                events.append("connect")
                self.sock = FakeSock()

            def request(self, method, path):
                events.append(f"request {method} {path}")

            def getresponse(self):
                return FakeResponse()

            def close(self):
                events.append("close")

        class FakeContext:
            def __init__(self, cafile):
                self.cafile = cafile
                self.check_hostname = False
                self.verify_mode = ssl.CERT_NONE

        created: list[FakeContext] = []

        def fake_create_default_context(*, cafile=None, **_):
            created.append(FakeContext(cafile))
            return created[-1]

        pin = hashlib.sha256(der).hexdigest()
        with mock.patch.object(runner.ssl, "create_default_context", fake_create_default_context):
            observed = runner.pinned_capabilities("192.168.0.202", 18644, "/parent/relay-cert.pem", pin, connection_factory=FakeConnection)
        self.assertEqual(observed, {"tlsVerifiedAgainstMetadataCert": True, "tlsPinMatches": True, "capabilitiesWithoutAuthStatus": 401})
        self.assertEqual(events[1:], ["connect", "request GET /v1/capabilities", "close"])
        self.assertEqual((created[-1].cafile, created[-1].check_hostname, created[-1].verify_mode), ("/parent/relay-cert.pem", True, ssl.CERT_REQUIRED),
                         "the production context trusts only the metadata certificate and verifies the hostname")
        self.assertIn("check_hostname=True", events[0])

        events.clear()
        with mock.patch.object(runner.ssl, "create_default_context", fake_create_default_context):
            with self.assertRaises(runner.ReadinessError):
                runner.pinned_capabilities("192.168.0.202", 18644, "/parent/relay-cert.pem", "00" * 32, connection_factory=FakeConnection)
        self.assertNotIn("request GET /v1/capabilities", events, "a pin mismatch never sends the request")
        self.assertIn("close", events)

    def test_probe_readiness_names_the_phase_of_each_failure_without_leaking_the_key(self):
        tls_ok = {"tlsVerifiedAgainstMetadataCert": True, "tlsPinMatches": True, "capabilitiesWithoutAuthStatus": 401}
        mcp_ok = {"mcpInitializeOK": True, "mcpServerName": "mockbridge", "mcpTools": ["echo"],
                  "mcpEchoWithoutBindingIsError": True, "mcpEchoErrorMentionsNoBoundDevice": True}
        seen: list[tuple] = []

        def pinned(host, port, cafile, pin):
            seen.append(("tls", host, port, cafile, pin))
            return dict(tls_ok)

        async def mcp(url, host_header, key):
            seen.append(("mcp", url, host_header))
            return dict(mcp_ok)

        common = dict(relay_listen=["192.168.0.202:18644", "127.0.0.1:18644"], mcp_listen="100.102.164.56:18643",
                      cafile="/parent/relay-cert.pem", expected_pin="ab" * 32, bridge_key="bridge-secret-value")
        observed = runner.probe_readiness(pinned=pinned, mcp=mcp, **common)
        self.assertEqual(observed, {**tls_ok, **mcp_ok, "phase": "complete"})
        self.assertEqual(seen, [("tls", "192.168.0.202", 18644, "/parent/relay-cert.pem", "ab" * 32),
                                ("mcp", "http://100.102.164.56:18643/mcp", "100.102.164.56:18643")])
        self.assertEqual(runner.readiness_problems(observed), [])

        def tls_timeout(host, port, cafile, pin):
            raise TimeoutError("handshake")

        with self.assertRaises(runner.ReadinessError) as caught:
            runner.probe_readiness(pinned=tls_timeout, mcp=mcp, **common)
        self.assertEqual((getattr(caught.exception, "phase", None), str(caught.exception)), ("tls-capabilities", "TimeoutError"))

        def pin_mismatch(host, port, cafile, pin):
            raise runner.ReadinessError("relay TLS pin does not match tls/public-metadata.json")

        with self.assertRaises(runner.ReadinessError) as caught:
            runner.probe_readiness(pinned=pin_mismatch, mcp=mcp, **common)
        self.assertEqual(getattr(caught.exception, "phase", None), "tls-capabilities")
        self.assertIn("pin does not match", str(caught.exception))

        async def mcp_leaks(url, host_header, key):
            raise RuntimeError(f"server said no to {key}")

        with self.assertRaises(runner.ReadinessError) as caught:
            runner.probe_readiness(pinned=pinned, mcp=mcp_leaks, **common)
        self.assertEqual((getattr(caught.exception, "phase", None), str(caught.exception)), ("mcp-probe", "RuntimeError"))
        self.assertNotIn("bridge-secret-value", str(caught.exception))

    def test_default_http_client_ignores_proxies_and_redirects(self):
        client = runner.default_http_client({"Authorization": "Bearer x"}, 20)
        try:
            self.assertFalse(client.trust_env)
            self.assertFalse(client.follow_redirects)
        finally:
            asyncio.run(client.aclose())


class RunnerMCPProbeTests(unittest.IsolatedAsyncioTestCase):
    async def test_mcp_probe_observes_the_real_mockbridge_app_through_the_official_client(self):
        hermes = FakeHermes()
        hermes.respond("GET", "/v1/capabilities", 200, {"name": "hermes"})
        config = make_config()
        relay = build_relay_app(config, upstream_transport=hermes.transport(), clock=FakeClock())
        mcp = build_mcp_app(config, bridge=relay.state.bridge)

        def factory(headers, timeout):
            return httpx.AsyncClient(transport=httpx.ASGITransport(app=mcp), base_url="http://100.102.164.56:18643", headers=dict(headers), timeout=timeout)

        try:
            async with mcp.router.lifespan_context(mcp):
                observed = await runner.mcp_probe("http://100.102.164.56:18643/mcp", "100.102.164.56:18643", "test-mcp-key",
                                                  http_client_factory=factory, timeout=10)
        except BaseExceptionGroup as group:
            leaf: BaseException = group
            while isinstance(leaf, BaseExceptionGroup) and len(leaf.exceptions) == 1:
                leaf = leaf.exceptions[0]
            raise leaf from None
        self.assertEqual(observed, {"mcpInitializeOK": True, "mcpServerName": "mockbridge", "mcpTools": ["echo"],
                                    "mcpEchoWithoutBindingIsError": True, "mcpEchoErrorMentionsNoBoundDevice": True})
        self.assertEqual(runner.readiness_problems({**observed, "tlsPinMatches": True, "capabilitiesWithoutAuthStatus": 401}), [])


if __name__ == "__main__":
    unittest.main()
