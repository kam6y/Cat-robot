"""契約 r3 §2.5 / §3: /bridge の毎 request 認証、binding 状態機械、call 配送と結果の照合、revoke / TTL / quarantine / exhausted。

relay も偽 Hermes もプロセス内、同一 event loop。MCP 側の echo は relay 内部 API（enqueue_echo）で代用し、MCP 往復は test_mcp_echo.py が担う。
"""
import asyncio
import re
import unittest

import httpx

from relay.app import build_relay_app
from relay.bridge import BridgeError
from tests.fakes import FakeClock, FakeHermes, make_config

AUTH = {"Authorization": "Bearer k"}
ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
CALL_KEYS = {"bindingID", "runID", "generation", "callID", "tool", "arguments", "expiresAt"}


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.hermes = FakeHermes()
        self.hermes.respond("GET", "/v1/capabilities", 200, {"name": "hermes"})
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_b1", "status": "started", "replayed": False, "session_id": "s1"})
        self.hermes.respond("GET", "/v1/runs/run_b1", 200, {"run_id": "run_b1", "status": "running", "session_id": "s1"})
        self.hermes.respond("POST", "/v1/runs/run_b1/stop", 202, {"run_id": "run_b1", "status": "stopping"})
        self.clock = FakeClock()
        self.config = make_config()
        self.app = build_relay_app(self.config, upstream_transport=self.hermes.transport(), clock=self.clock)
        self.bridge = self.app.state.bridge
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://relay.test")

    async def asyncTearDown(self):
        await self.client.aclose()

    async def bind(self, device="d1"):
        response = await self.client.post("/bridge/bindings", json={"deviceID": device}, headers=AUTH)
        self.assertEqual(response.status_code, 201, response.text)
        return response.json()

    async def submit(self, bid):
        return await self.client.post(f"/bridge/bindings/{bid}/run", json={"input": "use echo"}, headers=AUTH)

    async def poll(self, bid, generation=1, wait=0):
        return await self.client.get(f"/bridge/bindings/{bid}/calls?generation={generation}&wait={wait}", headers=AUTH)

    async def post_result(self, bid, call_id, **body):
        payload = {"runID": "run_b1", "generation": 1, "ok": True, "text": "x", **body}
        return await self.client.post(f"/bridge/bindings/{bid}/calls/{call_id}/result", json=payload, headers=AUTH)

    async def running_binding_with_one_call(self, text="x"):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.submit(bid)).status_code, 202)
        echo_task = asyncio.create_task(self.bridge.enqueue_echo(text))
        await asyncio.sleep(0.01)
        call = (await self.poll(bid)).json()["calls"][0]
        return bid, call, echo_task

    # --- auth ---

    async def test_every_bridge_request_is_authenticated_against_capabilities_without_caching(self):
        await self.client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)
        await self.client.post("/bridge/bindings/x/revoke", headers=AUTH)
        self.assertEqual(self.hermes.capabilities_calls, 2, "one upstream capabilities check per bridge request")
        self.assertEqual(self.hermes.requests[0].headers.get("authorization"), "Bearer k")

    async def test_bridge_requests_without_a_valid_key_are_401_and_change_nothing(self):
        missing = await self.client.post("/bridge/bindings", json={"deviceID": "d1"})
        self.assertEqual(missing.status_code, 401)
        self.assertEqual(self.hermes.capabilities_calls, 0, "no Authorization → refused before any upstream call")
        self.hermes.respond("GET", "/v1/capabilities", 401, {"error": "unauthorized"})
        response = await self.client.post("/bridge/bindings", json={"deviceID": "d1"}, headers={"Authorization": "Bearer wrong"})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.bridge.state_name, "none")

    # --- binding lifecycle ---

    async def test_bind_returns_binding_id_generation_and_expiry(self):
        binding = await self.bind()
        self.assertEqual(set(binding), {"bindingID", "generation", "expiresAt"})
        self.assertRegex(binding["bindingID"], ID)
        self.assertEqual(binding["generation"], 1)
        self.assertEqual(binding["expiresAt"], self.clock.now + 600)
        self.assertEqual(self.bridge.state_name, "bound")

    async def test_second_bind_while_bound_is_409_busy(self):
        await self.bind()
        response = await self.client.post("/bridge/bindings", json={"deviceID": "d2"}, headers=AUTH)
        self.assertEqual(response.status_code, 409)
        self.assertEqual(response.json()["reason"], "busy")

    async def test_bind_rejects_malformed_bodies(self):
        for body in [b"", b"[]", b'{"deviceID": ""}', b'{"deviceID": 5}', b'{"device": "d1"}']:
            response = await self.client.post("/bridge/bindings", content=body, headers={**AUTH, "Content-Type": "application/json"})
            self.assertEqual(response.status_code, 400, body)
        self.assertEqual(self.bridge.state_name, "none")

    async def test_submit_run_moves_to_running_and_calls_are_delivered_only_then(self):
        bid = (await self.bind())["bindingID"]
        self.hermes.hold("POST", "/v1/runs")
        submit_task = asyncio.create_task(self.submit(bid))
        await asyncio.sleep(0.01)
        self.assertEqual(self.bridge.state_name, "submitting")
        echo_task = asyncio.create_task(self.bridge.enqueue_echo("hello"))
        await asyncio.sleep(0.01)
        self.assertEqual((await self.poll(bid)).json()["calls"], [], "nothing is delivered while submitting")
        self.hermes.release("POST", "/v1/runs")
        response = await submit_task
        self.assertEqual(response.status_code, 202, response.text)
        self.assertEqual(response.json(), {"runID": "run_b1", "sessionID": "s1", "status": "started"})
        self.assertEqual(self.bridge.state_name, "running")
        delivered = (await self.poll(bid)).json()["calls"]
        self.assertEqual(len(delivered), 1)
        call = delivered[0]
        self.assertEqual(set(call) - {"sessionID"}, CALL_KEYS)
        self.assertEqual((call["bindingID"], call["runID"], call["generation"], call["tool"], call["arguments"]),
                         (bid, "run_b1", 1, "echo", {"text": "hello"}))
        self.assertRegex(call["callID"], ID)
        self.assertEqual(call["expiresAt"], self.clock.now + self.config.call_timeout_seconds)
        self.assertEqual((await self.poll(bid)).json()["calls"], [], "a delivered call is not delivered twice")
        result = await self.post_result(bid, call["callID"], text="hello")
        self.assertEqual((result.status_code, result.json()), (200, {"accepted": True}))
        self.assertEqual(await echo_task, "hello")
        duplicate = await self.post_result(bid, call["callID"], text="hello")
        self.assertEqual((duplicate.status_code, duplicate.json()), (200, {"accepted": False, "duplicate": True}))

    async def test_submit_forwards_json_input_with_a_relay_generated_idempotency_key_and_shares_admission(self):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.submit(bid)).status_code, 202)
        sent = self.hermes.requests_to("POST", "/v1/runs")[0]
        self.assertEqual(sent.content, b'{"input": "use echo"}')
        self.assertEqual(sent.headers.get("content-type"), "application/json")
        self.assertEqual(sent.headers.get("authorization"), "Bearer k")
        self.assertRegex(sent.headers.get("idempotency-key", ""), r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
        plain = await self.client.post("/v1/runs", content=b'{"input":"other"}',
                                       headers={**AUTH, "Content-Type": "application/json", "Idempotency-Key": "k9"})
        self.assertEqual((plain.status_code, plain.json()["reason"]), (409, "busy"))
        self.assertEqual((await self.submit(bid)).status_code, 409, "a bound run is submitted once")

    async def test_submit_timeout_retries_once_with_the_same_key_then_quarantines(self):
        bid = (await self.bind())["bindingID"]
        self.hermes.hold("POST", "/v1/runs")
        echo_task = asyncio.create_task(self.bridge.enqueue_echo("early"))
        response = await self.submit(bid)
        self.assertEqual(response.status_code, 504)
        posts = self.hermes.requests_to("POST", "/v1/runs")
        self.assertEqual(len(posts), 2, "exactly one idempotent retry")
        self.assertEqual(posts[0].headers["idempotency-key"], posts[1].headers["idempotency-key"])
        self.assertEqual(self.bridge.state_name, "quarantined")
        with self.assertRaises(BridgeError):
            await echo_task
        again = await self.client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)
        self.assertEqual((again.status_code, again.json()["reason"]), (409, "quarantined"))
        plain = await self.client.post("/v1/runs", content=b'{"input":"x"}', headers={**AUTH, "Content-Type": "application/json"})
        self.assertEqual(plain.status_code, 409, "the unknown run keeps admission busy")

    async def relay_with(self, **config_overrides):
        """別設定の relay へ差し替える（同じ偽 Hermes と時計を共有）。"""
        self.config = make_config(**config_overrides)
        self.app = build_relay_app(self.config, upstream_transport=self.hermes.transport(), clock=self.clock)
        self.bridge = self.app.state.bridge
        await self.client.aclose()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://relay.test")

    async def test_submit_deadline_defaults_to_the_contract_budget_inside_the_device_timeout(self):
        # 契約 r3 §2.5: 端末の submit 要求予算は 60 s。relay は capabilities 15 s + run 作成 15 s × 2 = 45 s に処理余裕 5 s を
        # 足した 50 s で必ず応答する。定数を変えたら端末側の予算（HermesBridgeClient）も一緒に見直す。
        from relay.bridge import SUBMIT_DEADLINE_SECONDS
        self.assertEqual(SUBMIT_DEADLINE_SECONDS, 3 * 15 + 5)
        self.assertEqual(self.bridge.submit_deadline_seconds, SUBMIT_DEADLINE_SECONDS)
        self.assertLess(SUBMIT_DEADLINE_SECONDS, 60, "the relay answers before the device gives up")

    async def test_submit_stops_at_its_outer_deadline_even_when_upstream_timeouts_exceed_it(self):
        # 端末の外側予算より長い upstream timeout が設定されても、submit は固定の総合 deadline で止まり fail closed に閉じる。
        await self.relay_with(upstreamTimeoutSeconds=0.6)
        self.bridge.submit_deadline_seconds = 0.2
        bid = (await self.bind())["bindingID"]
        self.hermes.hold("POST", "/v1/runs")
        echo = asyncio.create_task(self.bridge.enqueue_echo("early"))
        loop = asyncio.get_running_loop()
        started = loop.time()
        response = await self.submit(bid)
        elapsed = loop.time() - started
        self.assertEqual(response.status_code, 504, response.text)
        self.assertLess(elapsed, 0.5, "the outer deadline, not the upstream timeout, bounds the request")
        self.assertEqual(self.bridge.state_name, "quarantined")
        self.assertTrue(self.app.state.admission.busy, "the run may exist upstream, so the reservation is kept")
        with self.assertRaises(BridgeError):
            await echo
        again = await self.client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)
        self.assertEqual((again.status_code, again.json()["reason"]), (409, "quarantined"))
        self.hermes.release("POST", "/v1/runs")

    async def test_submit_deadline_during_authentication_leaves_the_binding_and_admission_untouched(self):
        # 認証段階で deadline を越えた要求は run を送っていないので、自分の binding も他の状態も失効させない。
        self.bridge.submit_deadline_seconds = 0.05
        bid = (await self.bind())["bindingID"]
        self.hermes.hold("GET", "/v1/capabilities")
        loop = asyncio.get_running_loop()
        started = loop.time()
        response = await self.submit(bid)
        self.assertEqual(response.status_code, 504, response.text)
        self.assertLess(loop.time() - started, 0.15, "the deadline fires before the 0.2 s upstream timeout")
        self.assertEqual(self.bridge.state_name, "bound")
        self.assertFalse(self.app.state.admission.busy)
        self.assertEqual(self.hermes.requests_to("POST", "/v1/runs"), [])
        self.hermes.release("GET", "/v1/capabilities")
        response = await self.submit(bid)
        self.assertEqual(response.status_code, 202, "the same binding can still submit once authentication answers")
        self.assertEqual(self.bridge.state_name, "running")

    async def test_a_stalled_submit_for_a_running_binding_hits_its_deadline_without_disturbing_the_run(self):
        # coverage（GREEN 後に追加）: 認証待ちで deadline を越えた重複 submit は、既に running の binding・pending call・予約を壊さない。
        bid, call, echo = await self.running_binding_with_one_call()
        self.bridge.submit_deadline_seconds = 0.05
        self.hermes.hold("GET", "/v1/capabilities")
        response = await self.submit(bid)
        self.assertEqual((response.status_code, response.json().get("state")), (504, "running"), response.text)
        self.assertEqual(self.bridge.state_name, "running")
        self.assertEqual(self.app.state.admission.active, {"run_b1"})
        self.assertIn(call["callID"], self.bridge.pending)
        self.assertFalse(echo.done())
        self.hermes.release("GET", "/v1/capabilities")
        self.assertEqual((await self.post_result(bid, call["callID"], text="x")).json(), {"accepted": True})
        self.assertEqual(await echo, "x")

    async def test_auth_deadline_does_not_quarantine_another_requests_submission(self):
        # Post-fix coverage: A expires during authentication after B has reserved the binding.
        # A never owned that reservation, even though the shared bridge is now submitting.
        authenticating = asyncio.Event()
        posting = asyncio.Event()
        release_post = asyncio.Event()
        original = self.hermes._handle

        async def transport(request):
            if request.headers.get("authorization") == "Bearer stalled":
                authenticating.set()
                await asyncio.Event().wait()
            if request.method == "POST" and request.url.path == "/v1/runs":
                posting.set()
                await release_post.wait()
            return await original(request)

        self.app = build_relay_app(self.config, upstream_transport=httpx.MockTransport(transport), clock=self.clock)
        self.bridge = self.app.state.bridge
        await self.client.aclose()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://relay.test")
        bid = (await self.bind())["bindingID"]
        self.bridge.submit_deadline_seconds = 0.05
        first = asyncio.create_task(self.client.post(f"/bridge/bindings/{bid}/run", json={"input": "A"},
                                                    headers={"Authorization": "Bearer stalled"}))
        tasks = [first]
        try:
            await asyncio.wait_for(authenticating.wait(), 1)
            self.bridge.submit_deadline_seconds = 0.5  # A's already-started deadline remains 0.05 s.
            second = asyncio.create_task(self.submit(bid))
            tasks.append(second)
            await asyncio.wait_for(posting.wait(), 1)
            self.assertEqual((await first).status_code, 504)
            self.assertEqual(self.bridge.state_name, "submitting")
            self.assertTrue(self.app.state.admission.busy)
            self.assertEqual(self.bridge.binding.binding_id, bid)
            release_post.set()
            accepted = await second
            self.assertEqual((accepted.status_code, accepted.json().get("runID")), (202, "run_b1"))
            self.assertEqual(self.bridge.state_name, "running")
            self.assertEqual(self.app.state.admission.active, {"run_b1"})
        finally:
            release_post.set()
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def test_submit_deadline_covers_waiting_for_the_request_body(self):
        # coverage（GREEN 後に追加）: body が届かない要求も deadline で 504 になり、run を送っていないので binding は bound のまま。
        self.bridge.submit_deadline_seconds = 0.05
        bid = (await self.bind())["bindingID"]
        stalled = asyncio.Event()

        async def receive():
            await stalled.wait()  # body は決して届かない
            return {"type": "http.disconnect"}

        sent = []

        async def send(message):
            sent.append(message)

        path = f"/bridge/bindings/{bid}/run"
        scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "POST", "scheme": "https",
                 "path": path, "raw_path": path.encode(), "query_string": b"", "root_path": "",
                 "headers": [(b"host", b"relay.test"), (b"authorization", b"Bearer k"),
                             (b"content-type", b"application/json"), (b"content-length", b"20")],
                 "client": ("127.0.0.1", 1234), "server": ("relay.test", 443)}
        loop = asyncio.get_running_loop()
        started = loop.time()
        await asyncio.wait_for(self.app(scope, receive, send), 1)
        self.assertLess(loop.time() - started, 0.15)
        self.assertEqual(next(m for m in sent if m["type"] == "http.response.start")["status"], 504)
        self.assertEqual(self.bridge.state_name, "bound")
        self.assertFalse(self.app.state.admission.busy)
        self.assertEqual(self.hermes.requests_to("POST", "/v1/runs"), [])
        stalled.set()

    async def test_submit_recovers_a_lost_acceptance_with_the_same_key_within_the_outer_deadline(self):
        # regression: 遅い認証 + 初回 run 作成の応答喪失（upstream timeout まで待つ）+ 同一 Idempotency-Key の再送 202 が、
        # 外側 deadline（認証 1 回 + run 作成 2 回 + 余裕）の内側で runID を端末へ返す。
        original = self.hermes._handle

        async def transport(request):
            if request.method == "GET" and request.url.path == "/v1/capabilities":
                await asyncio.sleep(0.05)
            response = await original(request)
            if request.method == "POST" and request.url.path == "/v1/runs" and len(self.hermes.requests_to("POST", "/v1/runs")) == 1:
                await asyncio.sleep(self.config.upstream_timeout_seconds + 0.5)  # 初回の受理は届かない
            return response

        self.app = build_relay_app(self.config, upstream_transport=httpx.MockTransport(transport), clock=self.clock)
        self.bridge = self.app.state.bridge
        await self.client.aclose()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://relay.test")
        budget = 3 * self.config.upstream_timeout_seconds + 0.1
        self.bridge.submit_deadline_seconds = budget
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_b1", "status": "started", "replayed": True})
        bid = (await self.bind())["bindingID"]
        loop = asyncio.get_running_loop()
        started = loop.time()
        response = await self.submit(bid)
        elapsed = loop.time() - started
        self.assertEqual((response.status_code, response.json()["runID"]), (202, "run_b1"), response.text)
        self.assertGreaterEqual(elapsed, self.config.upstream_timeout_seconds, "the first attempt really waited out the upstream timeout")
        self.assertLess(elapsed, budget)
        posts = self.hermes.requests_to("POST", "/v1/runs")
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[0].headers["idempotency-key"], posts[1].headers["idempotency-key"])
        self.assertEqual(self.bridge.state_name, "running")
        self.assertEqual(self.app.state.admission.active, {"run_b1"})

    # --- RELAY-003: submit の deadline が期限切れ binding の tear-down を取り消す境界 ---

    async def assert_interrupted_teardown_is_quarantined(self, bid, echo, response):
        self.assertEqual(response.status_code, 504, response.text)
        self.assertEqual(self.bridge.state_name, "quarantined", "an interrupted teardown must not strand an ownerless revoking state")
        self.assertEqual(response.json().get("state"), "quarantined")
        with self.assertRaises(BridgeError):
            await echo
        self.assertEqual(self.bridge.pending, {})
        self.assertEqual(self.app.state.admission.active, {"run_b1"}, "terminal outcome unknown, so admission is retained")
        again = await self.client.post("/bridge/bindings", json={"deviceID": "d2"}, headers=AUTH)
        self.assertEqual((again.status_code, again.json()["reason"]), (409, "quarantined"))

    async def test_submit_deadline_during_expiry_stop_wait_quarantines_instead_of_stranding_revoking(self):
        # 期限切れ running binding の tear-down が stop 待ちで submit の deadline に取り消される境界。
        bid, call, echo = await self.running_binding_with_one_call()
        self.bridge.submit_deadline_seconds = 0.05
        self.hermes.hold("POST", "/v1/runs/run_b1/stop")
        self.clock.advance(self.config.binding_ttl_seconds)
        response = await asyncio.wait_for(self.submit(bid), 1)
        self.assertEqual(len(self.hermes.requests_to("POST", "/v1/runs/run_b1/stop")), 1, "the deadline fired while stop was awaited")
        await self.assert_interrupted_teardown_is_quarantined(bid, echo, response)
        self.hermes.release("POST", "/v1/runs/run_b1/stop")
        await asyncio.sleep(0.02)
        self.assertEqual(self.bridge.state_name, "quarantined", "no abandoned task resumes the interrupted teardown")

    async def test_submit_deadline_during_expiry_terminal_confirmation_quarantines_instead_of_stranding_revoking(self):
        # stop は 202 で即応答し、terminal 確認の GET が deadline をまたぐ境界。
        bid, call, echo = await self.running_binding_with_one_call()
        self.bridge.submit_deadline_seconds = 0.05
        self.hermes.hold("GET", "/v1/runs/run_b1")
        self.clock.advance(self.config.binding_ttl_seconds)
        response = await asyncio.wait_for(self.submit(bid), 1)
        self.assertEqual(len(self.hermes.requests_to("POST", "/v1/runs/run_b1/stop")), 1)
        self.assertEqual(len(self.hermes.requests_to("GET", "/v1/runs/run_b1")), 1, "the deadline fired while terminal confirmation was awaited")
        await self.assert_interrupted_teardown_is_quarantined(bid, echo, response)
        self.hermes.release("GET", "/v1/runs/run_b1")
        await asyncio.sleep(0.02)
        self.assertEqual(self.bridge.state_name, "quarantined")

    async def test_submit_deadline_during_expiry_drain_interval_quarantines_instead_of_stranding_revoking(self):
        # 非 terminal の status 応答の後、次の確認までの sleep 中に deadline をまたぐ境界。
        await self.relay_with(drainPollAttempts=2, drainPollIntervalSeconds=0.5)
        bid, call, echo = await self.running_binding_with_one_call()
        self.bridge.submit_deadline_seconds = 0.05
        self.clock.advance(self.config.binding_ttl_seconds)
        response = await asyncio.wait_for(self.submit(bid), 1)
        self.assertEqual(len(self.hermes.requests_to("GET", "/v1/runs/run_b1")), 1, "the deadline fired during the drain interval")
        await self.assert_interrupted_teardown_is_quarantined(bid, echo, response)

    async def test_interrupted_teardown_quarantines_its_own_revoking_transition_and_propagates_cancellation(self):
        # seam: _tear_down を直接取り消す。所有中の revoking 遷移は quarantined になり、取消は呼び出し元へ伝播する。
        bid, call, echo = await self.running_binding_with_one_call()
        self.hermes.hold("POST", "/v1/runs/run_b1/stop")
        self.clock.advance(self.config.binding_ttl_seconds)
        teardown = asyncio.create_task(self.bridge._tear_down(AUTH, "binding expired", "expired"))
        await asyncio.sleep(0.01)
        self.assertEqual(self.bridge.state_name, "revoking")
        teardown.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(teardown, 1)
        self.assertEqual(self.bridge.state_name, "quarantined")
        with self.assertRaises(BridgeError):
            await echo
        self.assertEqual(self.app.state.admission.active, {"run_b1"})
        self.hermes.release("POST", "/v1/runs/run_b1/stop")

    async def test_interrupted_teardown_leaves_a_transition_it_no_longer_owns_alone(self):
        # coverage（修正後・既存 pass）: 所有権の 3 軸（binding identity / generation / revoking state）を 1 つずつ失わせる。
        # どの軸が欠けても取消時に何も quarantine せず、取消だけを呼び出し元へ伝播する。
        from relay.bridge import Binding

        async def lose_identity(binding):
            self.bridge.binding = Binding("otherbinding", "d9", binding.generation, self.clock() + 600)
            return "revoking"

        async def lose_generation(binding):
            binding.generation += 1
            return "revoking"

        async def lose_state(binding):
            self.bridge.state = "bound"
            return "bound"

        for name, mutate in (("identity", lose_identity), ("generation", lose_generation), ("state", lose_state)):
            with self.subTest(lost=name):
                await self.relay_with()
                bid, call, echo = await self.running_binding_with_one_call()
                binding = self.bridge.binding
                self.hermes.hold("POST", "/v1/runs/run_b1/stop")
                self.clock.advance(self.config.binding_ttl_seconds)
                seen = len(self.hermes.requests_to("POST", "/v1/runs/run_b1/stop"))
                teardown = asyncio.create_task(self.bridge._tear_down(AUTH, "binding expired", "expired"))

                async def stop_arrived():
                    while len(self.hermes.requests_to("POST", "/v1/runs/run_b1/stop")) <= seen:
                        await asyncio.sleep(0)

                await asyncio.wait_for(stop_arrived(), 0.5)
                self.assertEqual(self.bridge.state_name, "revoking")
                expected_state = await mutate(binding)
                expected_binding, expected_generation = self.bridge.binding, self.bridge.binding.generation
                teardown.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await asyncio.wait_for(teardown, 1)
                self.assertEqual(self.bridge.state_name, expected_state, f"lost {name}: the transition is left alone")
                self.assertIs(self.bridge.binding, expected_binding)
                self.assertEqual(self.bridge.binding.generation, expected_generation)
                self.assertEqual(self.app.state.admission.active, {"run_b1"})
                with self.assertRaises(BridgeError):
                    await echo
                self.hermes.release("POST", "/v1/runs/run_b1/stop")

    async def fresh_relay(self, method, path, status, payload):
        fresh = FakeHermes()
        fresh.respond("GET", "/v1/capabilities", 200, {})
        fresh.respond(method, path, status, payload)
        app = build_relay_app(make_config(), upstream_transport=fresh.transport(), clock=self.clock)
        client = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test")
        self.addAsyncCleanup(client.aclose)
        return app, client

    async def test_rejected_recovery_after_timeout_keeps_unknown_run_and_calls_quarantined(self):
        for status in (400, 401, 409, 429):
            with self.subTest(recovery_status=status):
                hermes = FakeHermes()
                hermes.respond("GET", "/v1/capabilities", 200, {})
                hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_lost", "status": "started"})
                first_post = asyncio.Event()
                lose_response = asyncio.Event()

                async def transport(request):
                    response = await hermes._handle(request)
                    if request.method == "POST" and request.url.path == "/v1/runs" and len(hermes.requests_to("POST", "/v1/runs")) == 1:
                        first_post.set()
                        await lose_response.wait()
                        raise httpx.ReadTimeout("first acceptance was lost")
                    return response

                app = build_relay_app(make_config(), upstream_transport=httpx.MockTransport(transport), clock=self.clock)
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://relay.test") as client:
                    bid = (await client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)).json()["bindingID"]
                    submit = asyncio.create_task(client.post(f"/bridge/bindings/{bid}/run", json={"input": "echo"}, headers=AUTH))
                    await asyncio.wait_for(first_post.wait(), 1)
                    echo = asyncio.create_task(app.state.bridge.enqueue_echo("from the original run"))
                    await asyncio.sleep(0)
                    hermes.respond("POST", "/v1/runs", status, {"error": "retry rejected"})
                    lose_response.set()
                    response = await submit
                    with self.assertRaises(BridgeError):
                        await echo
                    self.assertEqual(response.status_code, 502)
                    self.assertEqual(app.state.bridge.state_name, "quarantined")
                    posts = hermes.requests_to("POST", "/v1/runs")
                    self.assertEqual(len(posts), 2)
                    self.assertEqual(posts[0].headers["idempotency-key"], posts[1].headers["idempotency-key"])
                    self.assertTrue(app.state.admission.busy)
                    self.assertEqual((await client.post("/bridge/bindings", json={"deviceID": "d2"}, headers=AUTH)).status_code, 409)
                    self.assertEqual((await client.post("/v1/runs", json={"input": "next"}, headers=AUTH)).status_code, 409)
                    with self.assertRaises(BridgeError):
                        await app.state.bridge.enqueue_echo("late original call")
                    self.assertEqual(len(hermes.requests_to("POST", "/v1/runs")), 2)

    async def test_timeout_recovery_with_a_known_acceptance_tracks_the_replayed_run(self):
        original = self.hermes._handle

        async def transport(request):
            response = await original(request)
            if request.method == "POST" and request.url.path == "/v1/runs" and len(self.hermes.requests_to("POST", "/v1/runs")) == 1:
                raise httpx.ReadTimeout("acceptance lost")
            return response

        self.app = build_relay_app(self.config, upstream_transport=httpx.MockTransport(transport), clock=self.clock)
        self.bridge = self.app.state.bridge
        await self.client.aclose()
        self.client = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="https://relay.test")
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_b1", "status": "started", "replayed": True})
        bid = (await self.bind())["bindingID"]
        response = await self.submit(bid)
        self.assertEqual((response.status_code, response.json()["runID"]), (202, "run_b1"))
        self.assertEqual(self.bridge.state_name, "running")
        self.assertEqual(self.app.state.admission.active, {"run_b1"})

    async def test_malformed_or_5xx_acceptance_quarantines_but_a_4xx_rejection_releases_the_binding(self):
        bid = (await self.bind())["bindingID"]
        self.hermes.respond_raw("POST", "/v1/runs", 202, b"not json")
        self.assertEqual((await self.submit(bid)).status_code, 502)
        self.assertEqual(self.bridge.state_name, "quarantined")

        app, client = await self.fresh_relay("POST", "/v1/runs", 503, {"error": "overloaded"})
        bid = (await client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)).json()["bindingID"]
        self.assertEqual((await client.post(f"/bridge/bindings/{bid}/run", json={"input": "x"}, headers=AUTH)).status_code, 502)
        self.assertEqual(app.state.bridge.state_name, "quarantined", "a 5xx does not prove the run was not created")
        again = await client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)
        self.assertEqual((again.status_code, again.json()["reason"]), (409, "quarantined"))

        app, client = await self.fresh_relay("POST", "/v1/runs", 400, {"error": "bad"})
        bid = (await client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)).json()["bindingID"]
        self.assertEqual((await client.post(f"/bridge/bindings/{bid}/run", json={"input": "x"}, headers=AUTH)).status_code, 502)
        self.assertEqual(app.state.bridge.state_name, "none", "a definite 4xx rejection releases the binding")
        self.assertEqual((await client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)).status_code, 201)

    async def test_a_terminal_report_for_a_different_or_malformed_run_does_not_end_the_binding(self):
        bid, call, echo_task = await self.running_binding_with_one_call()
        for payload in [{"run_id": "run_other", "status": "completed"}, {"run_id": "run_b1", "status": ["completed"]},
                        {"status": "cancelled"}]:
            self.hermes.respond("GET", "/v1/runs/run_b1", 200, payload)
            self.assertEqual((await self.client.get("/v1/runs/run_b1", headers=AUTH)).status_code, 200, payload)
            self.assertEqual(self.bridge.state_name, "running", payload)
            self.assertFalse(echo_task.done(), payload)
        plain = await self.client.post("/v1/runs", content=b'{"input":"x"}', headers={**AUTH, "Content-Type": "application/json"})
        self.assertEqual(plain.status_code, 409, "the bound run still occupies admission")
        echo_task.cancel()

    async def test_results_with_mismatched_identity_are_409_unknown_404_expired_410(self):
        bid, call, echo_task = await self.running_binding_with_one_call()
        self.assertEqual((await self.post_result(bid, call["callID"], generation=2)).status_code, 409)
        self.assertEqual((await self.post_result(bid, call["callID"], runID="run_other")).status_code, 409)
        self.assertEqual((await self.post_result(bid, "nope")).status_code, 404)
        self.assertEqual((await self.post_result("otherbinding", call["callID"])).status_code, 404)
        self.assertEqual((await self.post_result(bid, call["callID"], ok="yes")).status_code, 400)
        self.assertFalse(echo_task.done(), "rejected results do not resolve the pending echo")
        self.clock.advance(self.config.call_timeout_seconds)
        expired = await self.post_result(bid, call["callID"])
        self.assertEqual(expired.status_code, 410)
        with self.assertRaises(BridgeError) as caught:
            await echo_task
        self.assertIn("expired", str(caught.exception))
        self.assertEqual((await self.post_result(bid, call["callID"])).status_code, 410, "an expired call stays expired")
        self.assertEqual(self.bridge.state_name, "quarantined", "an expired result is a communication failure like a timeout")
        with self.assertRaises(BridgeError):
            await self.bridge.enqueue_echo("after the expired result")

    async def test_an_expired_result_quarantines_like_a_timeout_and_fails_the_other_pending_calls(self):
        # 順序: relay の時計が期限を越えてから result が届き、enqueue_echo 側の event-loop timer はまだ発火していない。
        bid, first, first_echo = await self.running_binding_with_one_call("first")
        second_echo = asyncio.create_task(self.bridge.enqueue_echo("second"))
        await asyncio.sleep(0.01)
        second = (await self.poll(bid)).json()["calls"][0]
        self.clock.advance(self.config.call_timeout_seconds)
        expired = await self.post_result(bid, first["callID"], text="first")
        self.assertEqual(expired.status_code, 410)
        self.assertEqual(self.bridge.state_name, "quarantined")
        self.assertEqual(expired.json().get("state"), "quarantined")
        with self.assertRaises(BridgeError) as caught:
            await first_echo
        self.assertIn("expired", str(caught.exception))
        with self.assertRaises(BridgeError):
            await second_echo
        first_receipt, second_receipt = self.bridge.receipts.get(first["callID"]), self.bridge.receipts.get(second["callID"])
        self.assertEqual(first_receipt.outcome if first_receipt else None, "expired")
        self.assertEqual(second_receipt.outcome if second_receipt else None, "failed")
        self.assertEqual((await self.post_result(bid, second["callID"], text="second")).status_code, 410,
                         "a result for a call failed by the quarantine is no longer accepted")
        self.assertEqual((await self.poll(bid)).json(), {"calls": []})
        with self.assertRaises(BridgeError):
            await self.bridge.enqueue_echo("later")
        again = await self.client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)
        self.assertEqual((again.status_code, again.json()["reason"]), (409, "quarantined"))

    async def test_device_error_results_resolve_the_echo_as_a_tool_error(self):
        bid, call, echo_task = await self.running_binding_with_one_call()
        result = await self.post_result(bid, call["callID"], ok=False, text=None, error="textTooLong")
        self.assertEqual(result.json(), {"accepted": True})
        with self.assertRaises(BridgeError) as caught:
            await echo_task
        self.assertIn("textTooLong", str(caught.exception))

    async def test_echo_times_out_when_the_device_never_answers(self):
        bid, call, echo_task = await self.running_binding_with_one_call()
        with self.assertRaises(BridgeError) as caught:
            await echo_task
        self.assertIn("timed out", str(caught.exception))
        self.assertEqual((await self.post_result(bid, call["callID"])).status_code, 410)

    async def test_revoke_discards_pending_calls_and_drains_through_stop_and_terminal(self):
        bid, call, echo_task = await self.running_binding_with_one_call()
        self.hermes.respond("GET", "/v1/runs/run_b1", 200, {"run_id": "run_b1", "status": "cancelled"})
        revoke = await self.client.post(f"/bridge/bindings/{bid}/revoke", headers=AUTH)
        self.assertEqual(revoke.status_code, 200, revoke.text)
        self.assertEqual(revoke.json(), {"state": "none"})
        with self.assertRaises(BridgeError) as caught:
            await echo_task
        self.assertIn("revoked", str(caught.exception))
        stops = self.hermes.requests_to("POST", "/v1/runs/run_b1/stop")
        self.assertEqual(len(stops), 1)
        self.assertEqual(stops[0].headers.get("authorization"), "Bearer k", "stop uses the revoking request's key")
        self.assertEqual(self.bridge.state_name, "none")
        self.assertEqual((await self.poll(bid, generation=2)).status_code, 404)
        late = await self.post_result(bid, call["callID"])
        self.assertIn(late.status_code, (404, 410))
        plain = await self.client.post("/v1/runs", content=b'{"input":"x"}', headers={**AUTH, "Content-Type": "application/json"})
        self.assertEqual(plain.status_code, 202, "a confirmed terminal frees admission")

    async def test_unconfirmed_terminal_after_revoke_quarantines_and_refuses_new_bindings(self):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.submit(bid)).status_code, 202)
        revoke = await self.client.post(f"/bridge/bindings/{bid}/revoke", headers=AUTH)
        self.assertEqual((revoke.status_code, revoke.json()), (200, {"state": "quarantined"}))
        self.assertEqual(self.bridge.state_name, "quarantined")
        again = await self.client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)
        self.assertEqual((again.status_code, again.json()["reason"]), (409, "quarantined"))
        with self.assertRaises(BridgeError):
            await self.bridge.enqueue_echo("later")

    async def test_revoking_an_unknown_or_old_binding_does_not_touch_the_current_one(self):
        old = (await self.bind())["bindingID"]
        self.assertEqual((await self.client.post(f"/bridge/bindings/{old}/revoke", headers=AUTH)).json(), {"state": "none"})
        current = (await self.bind())["bindingID"]
        self.assertNotEqual(current, old)
        self.assertEqual((await self.client.post(f"/bridge/bindings/{old}/revoke", headers=AUTH)).status_code, 404)
        self.assertEqual((await self.client.post("/bridge/bindings/unknown/revoke", headers=AUTH)).status_code, 404)
        self.assertEqual((await self.poll(old)).status_code, 404)
        self.assertEqual(self.bridge.state_name, "bound")

    async def test_bound_run_without_a_submitted_run_revokes_straight_to_none(self):
        bid = (await self.bind())["bindingID"]
        revoke = await self.client.post(f"/bridge/bindings/{bid}/revoke", headers=AUTH)
        self.assertEqual((revoke.status_code, revoke.json()), (200, {"state": "none"}))
        self.assertEqual(self.hermes.requests_to("POST", "/v1/runs/run_b1/stop"), [], "nothing to stop")

    async def test_terminal_observed_through_the_relay_ends_the_binding(self):
        bid, call, echo_task = await self.running_binding_with_one_call()
        self.hermes.respond("GET", "/v1/runs/run_b1", 200, {"run_id": "run_b1", "status": "completed", "output": "ok"})
        self.assertEqual((await self.client.get("/v1/runs/run_b1", headers=AUTH)).status_code, 200)
        self.assertEqual(self.bridge.state_name, "none")
        with self.assertRaises(BridgeError):
            await echo_task
        self.assertEqual((await self.poll(bid)).status_code, 404)

    async def test_max_runs_per_process_is_exhausted_after_one_bound_run(self):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.submit(bid)).status_code, 202)
        self.hermes.respond("GET", "/v1/runs/run_b1", 200, {"run_id": "run_b1", "status": "completed", "output": "ok"})
        await self.client.get("/v1/runs/run_b1", headers=AUTH)
        again = await self.client.post("/bridge/bindings", json={"deviceID": "d1"}, headers=AUTH)
        self.assertEqual((again.status_code, again.json()["reason"]), (409, "exhausted"))

    async def test_ttl_expiry_is_applied_on_the_next_authenticated_request(self):
        bid, call, echo_task = await self.running_binding_with_one_call()
        self.clock.advance(600)
        self.hermes.respond("GET", "/v1/runs/run_b1", 200, {"run_id": "run_b1", "status": "cancelled"})
        response = await self.poll(bid)
        self.assertEqual(response.status_code, 410)
        with self.assertRaises(BridgeError) as caught:
            await echo_task
        self.assertIn("expired", str(caught.exception))
        self.assertEqual(len(self.hermes.requests_to("POST", "/v1/runs/run_b1/stop")), 1)
        self.assertEqual(self.bridge.state_name, "none")

    async def test_ttl_expiry_without_a_confirmed_terminal_quarantines(self):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.submit(bid)).status_code, 202)
        self.clock.advance(600)
        self.assertEqual((await self.submit(bid)).status_code, 410)
        self.assertEqual(self.bridge.state_name, "quarantined")

    async def test_ttl_expiry_seen_from_the_mcp_side_quarantines_without_a_key(self):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.submit(bid)).status_code, 202)
        self.clock.advance(600)
        with self.assertRaises(BridgeError) as caught:
            await self.bridge.enqueue_echo("late")
        self.assertIn("expired", str(caught.exception))
        self.assertEqual(self.bridge.state_name, "quarantined")
        self.assertEqual(self.hermes.requests_to("POST", "/v1/runs/run_b1/stop"), [], "no key is available to stop from the MCP side")

    async def test_echo_without_a_running_binding_is_refused(self):
        with self.assertRaises(BridgeError) as caught:
            await self.bridge.enqueue_echo("hi")
        self.assertIn("no bound device", str(caught.exception))
        await self.bind()
        with self.assertRaises(BridgeError):
            await self.bridge.enqueue_echo("hi")

    async def test_poll_validates_binding_generation_and_wait(self):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.poll("unknown")).status_code, 404)
        self.assertEqual((await self.poll(bid, generation=2)).status_code, 409)
        self.assertEqual((await self.client.get(f"/bridge/bindings/{bid}/calls?generation=x", headers=AUTH)).status_code, 400)
        self.assertEqual((await self.client.get(f"/bridge/bindings/{bid}/calls?generation=1&wait=99", headers=AUTH)).status_code, 400)
        self.assertEqual((await self.poll(bid)).json(), {"calls": []}, "bound but not running delivers nothing")

    async def test_long_poll_returns_as_soon_as_a_call_is_enqueued(self):
        bid = (await self.bind())["bindingID"]
        self.assertEqual((await self.submit(bid)).status_code, 202)
        poll_task = asyncio.create_task(self.poll(bid, wait=5))
        await asyncio.sleep(0.01)
        echo_task = asyncio.create_task(self.bridge.enqueue_echo("now"))
        response = await asyncio.wait_for(poll_task, 1)
        self.assertEqual(response.json()["calls"][0]["arguments"], {"text": "now"})
        echo_task.cancel()

    async def test_an_unused_binding_also_reserves_admission_against_plain_runs(self):
        await self.bind()
        plain = await self.client.post("/v1/runs", json={"input": "other"}, headers=AUTH)
        self.assertEqual(plain.status_code, 409)
        self.assertEqual(self.hermes.requests_to("POST", "/v1/runs"), [])
        self.assertEqual(self.bridge.state_name, "bound")

    async def wait_for_stop_request(self):
        async def observed():
            while not self.hermes.requests_to("POST", "/v1/runs/run_b1/stop"):
                await asyncio.sleep(0)
        await asyncio.wait_for(observed(), 0.5)

    async def test_revoke_refuses_new_echo_before_the_stop_request_finishes(self):
        bid = (await self.bind())["bindingID"]
        await self.submit(bid)
        self.hermes.hold("POST", "/v1/runs/run_b1/stop")
        self.hermes.respond("GET", "/v1/runs/run_b1", 200, {"run_id": "run_b1", "status": "cancelled"})
        revoke = asyncio.create_task(self.client.post(f"/bridge/bindings/{bid}/revoke", headers=AUTH))
        late = None
        try:
            await self.wait_for_stop_request()
            late = asyncio.create_task(self.bridge.enqueue_echo("arrived during revoke"))
            done, _ = await asyncio.wait([late], timeout=0.03)
            self.assertTrue(done, "revoke must reject a new echo immediately, before its network await completes")
            with self.assertRaises(BridgeError):
                await late
            self.assertEqual((await self.poll(bid, generation=2)).json(), {"calls": []})
            self.assertEqual((await self.client.post("/bridge/bindings", json={"deviceID": "other"}, headers=AUTH)).status_code, 409)
        finally:
            self.hermes.release("POST", "/v1/runs/run_b1/stop")
            await revoke
            if late is not None:
                late.cancel()
                await asyncio.gather(late, return_exceptions=True)

    async def test_a_delayed_old_submit_body_cannot_start_a_new_binding(self):
        old = (await self.bind())["bindingID"]
        body_started, body_released = asyncio.Event(), asyncio.Event()

        async def body():
            body_started.set()
            yield b'{"input":'
            await body_released.wait()
            yield b'"old request"}'

        submit = asyncio.create_task(self.client.post(f"/bridge/bindings/{old}/run", content=body(), headers=AUTH))
        try:
            await asyncio.wait_for(body_started.wait(), 0.5)
            self.assertEqual((await self.client.post(f"/bridge/bindings/{old}/revoke", headers=AUTH)).status_code, 200)
            new = (await self.bind())["bindingID"]
            body_released.set()
            self.assertIn((await submit).status_code, (404, 409))
            self.assertEqual(self.bridge.state_name, "bound")
            self.assertEqual((await self.poll(new)).status_code, 200)
            self.assertEqual(self.hermes.requests_to("POST", "/v1/runs"), [])
        finally:
            body_released.set()
            await asyncio.gather(submit, return_exceptions=True)

    async def test_duplicate_results_still_require_the_original_run_and_generation(self):
        bid, call, echo = await self.running_binding_with_one_call()
        self.assertEqual((await self.post_result(bid, call["callID"])).json(), {"accepted": True})
        self.assertEqual(await echo, "x")
        for mismatch in [{"runID": "other-run"}, {"generation": 2}]:
            with self.subTest(mismatch=mismatch):
                self.assertEqual((await self.post_result(bid, call["callID"], **mismatch)).status_code, 409)
        self.assertEqual((await self.post_result(bid, call["callID"])).json(), {"accepted": False, "duplicate": True})

    async def test_revoked_call_receipts_cannot_acknowledge_old_or_forged_generations(self):
        bid, call, echo = await self.running_binding_with_one_call()
        self.hermes.hold("POST", "/v1/runs/run_b1/stop")
        self.hermes.respond("GET", "/v1/runs/run_b1", 200, {"run_id": "run_b1", "status": "cancelled"})
        revoke = asyncio.create_task(self.client.post(f"/bridge/bindings/{bid}/revoke", headers=AUTH))
        try:
            await self.wait_for_stop_request()
            with self.assertRaises(BridgeError):
                await echo
            for generation in (1, 2):
                with self.subTest(generation=generation):
                    self.assertIn((await self.post_result(bid, call["callID"], generation=generation)).status_code, (409, 410))
        finally:
            self.hermes.release("POST", "/v1/runs/run_b1/stop")
            await revoke

    async def test_echo_timeout_quarantines_instead_of_accepting_more_device_work(self):
        bid, call, echo = await self.running_binding_with_one_call()
        with self.assertRaises(BridgeError):
            await echo
        self.assertEqual(self.bridge.state_name, "quarantined")
        with self.assertRaises(BridgeError):
            await self.bridge.enqueue_echo("later")
        self.assertEqual((await self.post_result(bid, call["callID"])).status_code, 410)

    async def test_cancelled_mcp_caller_quarantines_and_clears_pending_work(self):
        bid, call, echo = await self.running_binding_with_one_call()
        echo.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await echo
        self.assertEqual(self.bridge.state_name, "quarantined")
        self.assertEqual((await self.poll(bid)).json(), {"calls": []})
        self.assertEqual((await self.post_result(bid, call["callID"])).status_code, 410,
                         "a cancelled caller never accepted a device result; it is not a duplicate acknowledgement")
        with self.assertRaises(BridgeError):
            await self.bridge.enqueue_echo("later")

    async def test_quarantined_binding_honors_poll_wait_instead_of_spinning(self):
        bid, call, echo = await self.running_binding_with_one_call()
        echo.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await echo
        poll = asyncio.create_task(self.poll(bid, wait=0.1))
        try:
            await asyncio.sleep(0.02)
            self.assertFalse(poll.done(), "an empty quarantined poll must honor the requested wait")
            response = await asyncio.wait_for(poll, 0.5)
            self.assertEqual((response.status_code, response.json()), (200, {"calls": []}))
        finally:
            if not poll.done():
                poll.cancel()
            await asyncio.gather(poll, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
