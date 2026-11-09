"""契約 r3 §3: REST 転送 allowlist / header 制限 / サイズ上限 / redirect 非転送 / 単一 run admission（予約は await 前、未知は fail closed）。

ポートは開かない。relay も偽 Hermes もプロセス内。各 test は同一 event loop で動かす。
"""
import asyncio
import unittest

import httpx

from relay.app import build_relay_app
from tests.fakes import FakeHermes, make_config

AUTH = {"Authorization": "Bearer k"}
CREATE = {"Authorization": "Bearer k", "Content-Type": "application/json"}


class RestProxyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.hermes = FakeHermes()
        self.config = make_config()
        self.app = build_relay_app(self.config, upstream_transport=self.hermes.transport())
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://relay.test")

    async def asyncTearDown(self):
        await self.client.aclose()

    async def create(self, text="a", key="k1"):
        return await self.client.post("/v1/runs", content=('{"input":"%s"}' % text).encode(), headers={**CREATE, "Idempotency-Key": key})

    async def test_capabilities_is_forwarded_with_only_the_allowed_headers(self):
        self.hermes.respond("GET", "/v1/capabilities", 200, {"name": "hermes"})
        response = await self.client.get("/v1/capabilities", headers={
            **AUTH, "X-Forwarded-For": "1.2.3.4", "Cookie": "a=b", "User-Agent": "probe", "Accept": "text/html"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"name": "hermes"})
        sent = self.hermes.requests[0]
        self.assertEqual((sent.method, sent.url.path), ("GET", "/v1/capabilities"))
        self.assertEqual(sent.headers.get("authorization"), "Bearer k")
        self.assertEqual(set(sent.headers) - {"host", "authorization"}, set(), dict(sent.headers))

    async def test_upstream_cookies_are_never_replayed(self):
        self.hermes.respond("GET", "/v1/capabilities", 200, {"ok": True}, headers={"Set-Cookie": "session=abc; Path=/"})
        await self.client.get("/v1/capabilities", headers=AUTH)
        await self.client.get("/v1/capabilities", headers=AUTH)
        self.assertNotIn("cookie", self.hermes.requests[1].headers)

    async def test_create_run_forwards_body_content_type_and_idempotency_key(self):
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_a1", "status": "started", "replayed": False})
        response = await self.client.post("/v1/runs", content=b'{"input":"hi"}', headers={
            **CREATE, "Idempotency-Key": "11111111-1111-4111-8111-111111111111"})
        self.assertEqual(response.status_code, 202)
        sent = self.hermes.requests[0]
        self.assertEqual(sent.content, b'{"input":"hi"}')
        self.assertEqual(sent.headers.get("content-type"), "application/json")
        self.assertEqual(sent.headers.get("idempotency-key"), "11111111-1111-4111-8111-111111111111")

    async def test_stop_is_forwarded_as_post_and_its_status_is_returned(self):
        self.hermes.respond("POST", "/v1/runs/run_a1/stop", 202, {"run_id": "run_a1", "status": "stopping"})
        response = await self.client.post("/v1/runs/run_a1/stop", headers=AUTH)
        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json()["status"], "stopping")
        self.assertEqual((self.hermes.requests[0].method, self.hermes.requests[0].url.path), ("POST", "/v1/runs/run_a1/stop"))

    async def test_paths_outside_the_allowlist_are_404_and_never_forwarded(self):
        for method, path in [("GET", "/v1/runs"), ("DELETE", "/v1/runs/run_a1"), ("GET", "/v1/skills"), ("POST", "/v1/capabilities"),
                             ("GET", "/api/sessions"), ("POST", "/v1/runs/run_a1/resume"), ("GET", "/v1/capabilities/extra"),
                             ("GET", "/v1/runs/run_a1/stop"), ("GET", "/healthz"), ("GET", "/"), ("GET", "/mcp")]:
            response = await self.client.request(method, path, headers=AUTH)
            self.assertEqual(response.status_code, 404, f"{method} {path}")
        self.assertEqual(self.hermes.requests, [])

    async def test_run_ids_outside_the_allowlist_are_rejected_before_forwarding(self):
        for bad in ["a%2Fb", "a%20b", "x" * 129, "run.1", "run%00"]:
            response = await self.client.get(f"/v1/runs/{bad}", headers=AUTH)
            self.assertEqual(response.status_code, 404, bad)
        self.assertEqual(self.hermes.requests, [])

    async def test_implicit_head_and_slash_redirects_are_outside_the_allowlist(self):
        for method, path in [("HEAD", "/v1/capabilities"), ("HEAD", "/v1/runs/run_a1"),
                             ("GET", "/v1/capabilities/"), ("POST", "/v1/runs/"),
                             ("GET", "/v1/runs/run_a1/"), ("POST", "/v1/runs/run_a1/stop/")]:
            with self.subTest(method=method, path=path):
                response = await self.client.request(method, path, headers=AUTH)
                self.assertEqual(response.status_code, 404)
                self.assertNotIn("location", response.headers)
        self.assertEqual(self.hermes.requests, [])

    async def test_upstream_redirects_are_not_followed_and_not_forwarded_as_redirects(self):
        self.hermes.respond("GET", "/v1/capabilities", 302, {}, headers={"Location": "https://attacker.invalid/"})
        response = await self.client.get("/v1/capabilities", headers=AUTH)
        self.assertEqual(response.status_code, 502)
        self.assertNotIn("location", {k.lower() for k in response.headers})
        self.assertEqual(len(self.hermes.requests), 1)

    async def test_request_bodies_over_64_kib_are_rejected_without_forwarding(self):
        response = await self.client.post("/v1/runs", content=b"x" * (65_536 + 1), headers=CREATE)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.hermes.requests, [])

    async def test_upstream_bodies_over_1_mib_become_502(self):
        self.hermes.respond_raw("GET", "/v1/capabilities", 200, b"x" * (1_048_576 + 1))
        response = await self.client.get("/v1/capabilities", headers=AUTH)
        self.assertEqual(response.status_code, 502)

    async def test_upstream_timeout_becomes_504(self):
        self.hermes.hold("GET", "/v1/capabilities")
        response = await self.client.get("/v1/capabilities", headers=AUTH)
        self.assertEqual(response.status_code, 504)

    async def test_a_second_run_is_refused_with_409_busy_until_the_first_is_terminal(self):
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_a1", "status": "started", "replayed": False})
        self.assertEqual((await self.create("a", "k1")).status_code, 202)
        second = await self.create("b", "k2")
        self.assertEqual(second.status_code, 409)
        self.assertEqual(second.json().get("reason"), "busy")
        self.assertEqual(len(self.hermes.requests_to("POST", "/v1/runs")), 1, "the busy run is not forwarded")
        self.hermes.respond("GET", "/v1/runs/run_a1", 200, {"run_id": "run_a1", "status": "running"})
        await self.client.get("/v1/runs/run_a1", headers=AUTH)
        self.assertEqual((await self.create("b2", "k2b")).status_code, 409, "a non-terminal poll keeps the slot")
        self.hermes.respond("GET", "/v1/runs/run_a1", 200, {"run_id": "run_a1", "status": "completed", "output": "x"})
        self.assertEqual((await self.client.get("/v1/runs/run_a1", headers=AUTH)).status_code, 200)
        self.assertEqual((await self.create("c", "k3")).status_code, 202, "terminal observed through the relay frees the admission slot")

    async def test_concurrent_creates_reserve_the_slot_before_awaiting_upstream(self):
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_a1", "status": "started", "replayed": False})
        self.hermes.hold("POST", "/v1/runs")
        first = asyncio.create_task(self.create("a", "k1"))
        await asyncio.sleep(0.02)
        second = await self.create("b", "k2")
        self.assertEqual(second.status_code, 409)
        self.assertEqual(len(self.hermes.requests_to("POST", "/v1/runs")), 1, "only one create reaches Hermes")
        self.hermes.release("POST", "/v1/runs")
        self.assertEqual((await first).status_code, 202)

    async def test_create_timeout_or_unparsable_acceptance_keeps_the_slot_fail_closed(self):
        self.hermes.hold("POST", "/v1/runs")
        self.assertEqual((await self.create("a", "k1")).status_code, 504)
        self.assertEqual((await self.create("b", "k2")).status_code, 409, "an unknown outcome keeps admission busy")
        self.assertEqual(len(self.hermes.requests_to("POST", "/v1/runs")), 1)

        fresh = FakeHermes()
        fresh.respond_raw("POST", "/v1/runs", 202, b"not json")
        app = build_relay_app(make_config(), upstream_transport=fresh.transport())
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
            accepted = await client.post("/v1/runs", content=b'{"input":"a"}', headers={**CREATE, "Idempotency-Key": "k1"})
            self.assertEqual(accepted.status_code, 202)
            refused = await client.post("/v1/runs", content=b'{"input":"b"}', headers={**CREATE, "Idempotency-Key": "k2"})
            self.assertEqual(refused.status_code, 409, "an acceptance without a readable run_id keeps admission busy")

    async def test_a_definite_4xx_rejection_releases_the_slot(self):
        self.hermes.respond("POST", "/v1/runs", 400, {"error": "bad input"})
        self.assertEqual((await self.create("a", "k1")).status_code, 400)
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_a2", "status": "started", "replayed": False})
        self.assertEqual((await self.create("b", "k2")).status_code, 202)

    async def test_a_5xx_acceptance_failure_keeps_the_slot_fail_closed(self):
        self.hermes.respond("POST", "/v1/runs", 503, {"error": "overloaded"})
        self.assertEqual((await self.create("a", "k1")).status_code, 503)
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_a2", "status": "started", "replayed": False})
        self.assertEqual((await self.create("b", "k2")).status_code, 409, "a 5xx does not prove the run was not created")
        self.assertEqual(len(self.hermes.requests_to("POST", "/v1/runs")), 1)

    async def test_a_terminal_report_for_a_different_or_malformed_run_does_not_free_the_slot(self):
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_a1", "status": "started", "replayed": False})
        self.assertEqual((await self.create("a", "k1")).status_code, 202)
        for payload in [{"run_id": "run_other", "status": "completed"}, {"run_id": "run_a1", "status": ["completed"]},
                        {"run_id": "run_a1", "status": {"state": "completed"}}, {"status": "completed"}]:
            self.hermes.respond("GET", "/v1/runs/run_a1", 200, payload)
            self.assertEqual((await self.client.get("/v1/runs/run_a1", headers=AUTH)).status_code, 200, payload)
            self.assertEqual((await self.create("b", "k2")).status_code, 409, payload)

    async def test_access_log_never_contains_authorization_values(self):
        self.hermes.respond("GET", "/v1/capabilities", 200, {"ok": True})
        with self.assertLogs("relay.access", "INFO") as logs:
            await self.client.get("/v1/capabilities", headers={"Authorization": "Bearer super-secret"})
            await self.client.get("/v1/capabilities")
        text = "\n".join(logs.output)
        self.assertIn("GET /v1/capabilities 200", text)
        self.assertIn("auth_present=true", text)
        self.assertIn("auth_present=false", text)
        self.assertNotIn("super-secret", text)


if __name__ == "__main__":
    unittest.main()
