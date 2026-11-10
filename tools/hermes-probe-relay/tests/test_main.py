"""__main__: 設定からの server 構成（TLS は relay のみ、MCP は HTTP）と ready 行が非秘密であること。ポートは開かない。"""
import io
import json
import unittest

from relay.__main__ import build_servers, ready_line
from tests.fakes import make_config


class MainTests(unittest.TestCase):
    def test_servers_are_built_for_every_relay_listener_with_tls_and_one_plain_mcp_listener(self):
        config = make_config(relayListen=["192.168.0.202:18644", "127.0.0.1:18644"], cert="/c.pem", key="/k.pem")
        servers = build_servers(config)
        self.assertEqual([(s.config.host, s.config.port, s.config.ssl_certfile, s.config.ssl_keyfile) for s in servers],
                         [("192.168.0.202", 18644, "/c.pem", "/k.pem"), ("127.0.0.1", 18644, "/c.pem", "/k.pem"), ("100.102.164.56", 18643, None, None)])
        self.assertTrue(all(not s.config.access_log and not s.config.server_header and s.config.lifespan == "on" for s in servers))
        self.assertIs(servers[0].config.app.state.bridge, servers[-1].config.app.state.bridge, "relay and MCP share one bridge")
        self.assertIsNot(servers[0].config.app, servers[-1].config.app)

    def test_ready_line_names_the_mcp_url_and_tool_without_secrets(self):
        line = json.dumps(ready_line(make_config(mcpBridgeKey="super-secret")))
        self.assertIn('"mcpURL": "http://100.102.164.56:18643/mcp"', line)
        self.assertIn('"tools": ["echo"]', line)
        self.assertIn('"mcpServerName": "mockbridge"', line)
        self.assertNotIn("super-secret", line)
        self.assertIn('"mcpBridgeKey_present": true', line)


if __name__ == "__main__":
    unittest.main()
