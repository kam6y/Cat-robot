"""Conversation relay contracts. In-process only; credentials are test strings."""
import json
import unittest

import httpx

from relay.app import build_relay_app
from relay.__main__ import build_servers, ready_line
from tests.fakes import FakeHermes, make_config


class ConversationProxyTests(unittest.IsolatedAsyncioTestCase):
    def conversation_config(self, **overrides):
        values = {"conversationMode": True, "clientKey": "phone-client-k", "upstreamKey": "windows-api-k"}
        values.update(overrides)
        return make_config(**values)

    async def test_history_forwards_only_bounded_display_query_and_bearer(self):
        hermes = FakeHermes()
        hermes.respond("GET", "/api/sessions/cat-session/messages", 200,
                       {"session_id": "cat-session", "data": [{"role": "user", "content": "hi"}]})
        app = build_relay_app(self.conversation_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            response = await client.get("/api/sessions/cat-session/messages",
                                        params={"order": "latest", "limit": "7", "inline_images": "true", "arbitrary": "drop"},
                                        headers={"Authorization": "Bearer phone-client-k", "Cookie": "drop"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["session_id"], "cat-session")
        self.assertEqual(len(hermes.requests), 1)
        sent = hermes.requests[0]
        self.assertEqual(dict(sent.url.params), {"order": "latest", "limit": "7", "inline_images": "false"})
        self.assertEqual(sent.headers.get("authorization"), "Bearer windows-api-k")
        self.assertNotIn("cookie", sent.headers)

    async def test_bad_session_ids_never_reach_upstream(self):
        hermes = FakeHermes()
        app = build_relay_app(self.conversation_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            for session in ("bad%2Fid", "bad%20id", "bad.id", "x" * 129):
                response = await client.get(f"/api/sessions/{session}/messages", headers={"Authorization": "Bearer phone-client-k"})
                self.assertEqual(response.status_code, 404)
                self.assertIsInstance(response.json().get("error"), str)
        self.assertEqual(hermes.requests, [])

    async def test_conversation_mode_checks_client_auth_before_contacting_hermes(self):
        hermes = FakeHermes()
        hermes.respond("GET", "/v1/capabilities", 200, {"ok": True})
        app = build_relay_app(self.conversation_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            for headers in ({}, {"Authorization": "Bearer wrong"}):
                response = await client.get("/v1/capabilities", headers=headers)
                self.assertEqual(response.status_code, 401)
        self.assertEqual(hermes.requests, [])

    async def test_client_key_is_replaced_by_fixed_upstream_key(self):
        hermes = FakeHermes()
        hermes.respond("GET", "/v1/capabilities", 200, {"ok": True})
        app = build_relay_app(self.conversation_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            response = await client.get("/v1/capabilities", headers={"Authorization": "Bearer phone-client-k"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(hermes.requests[0].headers.get("authorization"), "Bearer windows-api-k")

    async def test_every_conversation_route_uses_only_the_upstream_key(self):
        hermes = FakeHermes()
        paths = [("GET", "/v1/capabilities"), ("POST", "/v1/runs"), ("GET", "/v1/runs/run-a"),
                 ("POST", "/v1/runs/run-a/stop"), ("GET", "/api/sessions/cat-session/messages")]
        for method, path in paths:
            hermes.respond(method, path, 202 if path == "/v1/runs" else 200, {"run_id": "run-a", "status": "completed"})
        app = build_relay_app(self.conversation_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            for method, path in paths:
                response = await client.request(method, path, headers={"Authorization": "Bearer phone-client-k"}, content=b"{}")
                self.assertLess(response.status_code, 300)
        self.assertEqual(len(hermes.requests), len(paths))
        self.assertTrue(all(r.headers.get("authorization") == "Bearer windows-api-k" for r in hermes.requests))

    async def test_default_probe_does_not_gain_a_history_route(self):
        hermes = FakeHermes()
        hermes.respond("GET", "/api/sessions/cat-session/messages", 200, {"data": []})
        app = build_relay_app(make_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            response = await client.get("/api/sessions/cat-session/messages", headers={"Authorization": "Bearer k"})
        self.assertEqual(response.status_code, 404)
        self.assertIsInstance(response.json().get("error"), str, "a relay refusal must not invent a Hermes error code")
        self.assertEqual(hermes.requests, [])

    async def test_lost_acceptance_reaches_the_same_server_ledger_without_another_side_effect(self):
        requests = []
        ledger = {}

        async def server(request):
            requests.append(request)
            key = request.headers.get("idempotency-key")
            if key not in ledger:
                ledger[key] = "run-original"
                raise httpx.ReadTimeout("test receipt loss", request=request)
            return httpx.Response(202, json={"run_id": ledger[key], "status": "completed", "replayed": True})

        app = build_relay_app(self.conversation_config(), upstream_transport=httpx.MockTransport(server))
        headers = {"Authorization": "Bearer phone-client-k", "Idempotency-Key": "turn-key", "Content-Type": "application/json"}
        body = b'{"input":"hi","session_id":"cat-session"}'
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            lost = await client.post("/v1/runs", content=body, headers=headers)
            replay = await client.post("/v1/runs", content=body, headers=headers)
        self.assertEqual(lost.status_code, 504)
        self.assertEqual(replay.status_code, 202)
        self.assertEqual(replay.json()["run_id"], "run-original")
        self.assertEqual(len(ledger), 1)
        self.assertEqual(len(requests), 2)
        self.assertEqual([r.content for r in requests], [body, body])
        self.assertEqual([r.headers.get("idempotency-key") for r in requests], ["turn-key", "turn-key"])
        self.assertEqual([r.headers.get("authorization") for r in requests], ["Bearer windows-api-k"] * 2)

    async def test_conversation_turn_queue_is_owned_by_hermes_not_a_stale_probe_slot(self):
        hermes = FakeHermes()
        hermes.respond("POST", "/v1/runs", 202, {"run_id": "run-queued", "status": "started"})
        app = build_relay_app(self.conversation_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            for key in ("old-turn", "next-turn"):
                response = await client.post("/v1/runs", json={"input": key, "session_id": "cat-session"},
                                             headers={"Authorization": "Bearer phone-client-k", "Idempotency-Key": key})
                self.assertEqual(response.status_code, 202)
        self.assertEqual(len(hermes.requests), 2)

    async def test_conversation_mode_has_no_device_bridge_routes(self):
        hermes = FakeHermes()
        app = build_relay_app(self.conversation_config(), upstream_transport=hermes.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            response = await client.post("/bridge/bindings", json={"deviceID": "not-a-device"},
                                         headers={"Authorization": "Bearer phone-client-k"})
        self.assertEqual(response.status_code, 404)
        self.assertEqual(hermes.requests, [])

    def test_conversation_mode_starts_no_mcp_listener_and_reports_no_tools_or_secrets(self):
        config = self.conversation_config()
        self.assertEqual(len(build_servers(config)), len(config.relay_listen))
        line = ready_line(config)
        self.assertEqual(line["tools"], [])
        self.assertNotIn("mcpURL", line)
        text = json.dumps(line) + repr(config)
        self.assertNotIn("phone-client-k", text)
        self.assertNotIn("windows-api-k", text)

    def test_conversation_mode_requires_two_nonempty_keys_and_a_boolean_mode(self):
        for values in ({"clientKey": ""}, {"upstreamKey": ""}, {"conversationMode": "yes"},
                       {"clientKey": "bad\nkey"}, {"upstreamKey": "bad\rkey"}, {"upstreamKey": "phone-client-k"}):
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.conversation_config(**values)
