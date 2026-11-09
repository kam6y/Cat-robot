"""契約 r3 §3: 設定の必須キー・既定値・形の検証、秘密（mcpBridgeKey）の非表示、0600 以外の設定ファイル拒否。"""
import json
import os
import tempfile
import unittest
from pathlib import Path

from relay.config import RelayConfig
from tests.fakes import make_config

REQUIRED = {
    "hermesBase": "http://100.66.5.53:18642",
    "relayListen": ["192.168.0.202:18644", "127.0.0.1:18644"],
    "cert": "/nonexistent/relay-cert.pem",
    "key": "/nonexistent/relay-key.pem",
    "mcpListen": "100.102.164.56:18643",
    "mcpBridgeKey": "test-bridge-key",
}


class RelayConfigTests(unittest.TestCase):
    def test_documented_defaults_apply_when_optional_keys_are_omitted(self):
        config = RelayConfig.from_mapping(REQUIRED)
        self.assertEqual((config.upstream_timeout_seconds, config.call_timeout_seconds, config.binding_ttl_seconds), (15, 30, 600))
        self.assertEqual((config.max_request_bytes, config.max_response_bytes, config.max_runs_per_process), (65_536, 1_048_576, 1))
        self.assertEqual((config.drain_poll_attempts, config.drain_poll_interval_seconds), (5, 1.0))
        self.assertEqual(config.hermes_base, "http://100.66.5.53:18642")
        self.assertEqual(config.relay_listen, (("192.168.0.202", 18644), ("127.0.0.1", 18644)))
        self.assertEqual(config.mcp_listen, ("100.102.164.56", 18643))
        self.assertEqual(config.mcp_bridge_key, "test-bridge-key")

    def test_each_missing_required_key_is_named_in_the_error(self):
        for key in REQUIRED:
            values = dict(REQUIRED)
            del values[key]
            with self.assertRaises(ValueError, msg=key) as caught:
                RelayConfig.from_mapping(values)
            self.assertIn(key, str(caught.exception))

    def test_invalid_shapes_are_rejected(self):
        cases = [("hermesBase", "ftp://100.66.5.53:18642"), ("hermesBase", "http://100.66.5.53:18642/api"),
                 ("hermesBase", "http://100.66.5.53:18642?x=1"), ("relayListen", []), ("relayListen", "127.0.0.1:18644"),
                 ("relayListen", ["127.0.0.1"]), ("mcpListen", "100.102.164.56"), ("mcpListen", "100.102.164.56:99999"),
                 ("mcpBridgeKey", ""), ("mcpBridgeKey", 123), ("upstreamTimeoutSeconds", 0), ("callTimeoutSeconds", -1),
                 ("bindingTTLSeconds", "600"), ("maxRequestBytes", 0), ("maxResponseBytes", 1.5), ("maxRunsPerProcess", 0),
                 ("drainPollAttempts", 0), ("drainPollIntervalSeconds", -0.1), ("upstreamTimeoutSeconds", float("inf")),
                 ("callTimeoutSeconds", float("nan"))]
        for key, value in cases:
            with self.assertRaises(ValueError, msg=f"{key}={value!r}"):
                RelayConfig.from_mapping({**REQUIRED, key: value})

    def test_listeners_are_restricted_to_lan_loopback_and_tailscale_addresses(self):
        for key, value in [("relayListen", ["0.0.0.0:18644"]), ("relayListen", ["[::]:18644"]), ("relayListen", ["8.8.8.8:18644"]),
                           ("relayListen", ["relay.example:18644"]), ("relayListen", ["[::1]:18644"]), ("relayListen", ["100.102.164.56:18644"]),
                           ("mcpListen", "0.0.0.0:18643"), ("mcpListen", "192.168.0.202:18643"), ("mcpListen", "127.0.0.1:18643"),
                           ("mcpListen", "[::]:18643"), ("mcpListen", "[fd7a::1]:18643")]:
            with self.assertRaises(ValueError, msg=f"{key}={value!r}"):
                RelayConfig.from_mapping({**REQUIRED, key: value})
        accepted = RelayConfig.from_mapping({**REQUIRED, "relayListen": ["10.0.0.5:18644", "127.0.0.1:18644"], "mcpListen": "100.64.0.1:18643"})
        self.assertEqual(accepted.relay_listen, (("10.0.0.5", 18644), ("127.0.0.1", 18644)))
        self.assertEqual(accepted.mcp_listen, ("100.64.0.1", 18643))

    def test_repr_str_and_public_view_never_contain_the_bridge_key(self):
        config = make_config(mcpBridgeKey="super-secret-bridge-key")
        for text in (repr(config), str(config), json.dumps(config.public())):
            self.assertNotIn("super-secret-bridge-key", text)
        public = config.public()
        self.assertIs(public["mcpBridgeKey_present"], True)
        self.assertEqual(public["hermesBase"], "http://hermes.test:18642")
        self.assertEqual(public["maxRunsPerProcess"], 1)

    def test_load_accepts_only_an_owner_only_json_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "relay.json"
            path.write_text(json.dumps(REQUIRED))
            os.chmod(path, 0o644)
            with self.assertRaises(ValueError) as caught:
                RelayConfig.load(path)
            self.assertIn("0600", str(caught.exception))
            os.chmod(path, 0o600)
            self.assertEqual(RelayConfig.load(path).mcp_bridge_key, "test-bridge-key")
            path.write_text("not json")
            with self.assertRaises(ValueError):
                RelayConfig.load(path)


if __name__ == "__main__":
    unittest.main()
