"""契約 r3 §3: 公式 SDK の client で initialize / tools/list / tools/call を実際に往復する（プロセス内 ASGI、ポート無し）。

Bearer / Host / Origin の拒否、no bound device、往復、timeout、revoke を同一 event loop で実測する。
session manager（anyio task group）は入った task と同じ task で抜ける必要があるため、lifespan は各 test 本体の中で開く。
"""
import asyncio
import contextlib
import unittest

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from relay.app import build_relay_app
from relay.mcpserver import build_mcp_app
from tests.fakes import FakeClock, FakeHermes, make_config

HOST = "100.102.164.56:18643"
MCP_URL = f"http://{HOST}/mcp"
DEVICE_AUTH = {"Authorization": "Bearer k"}
RAW_HEADERS = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json"}
INITIALIZE = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe-test", "version": "0"}}}


class MCPEchoTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.hermes = FakeHermes()
        self.hermes.respond("GET", "/v1/capabilities", 200, {"name": "hermes"})
        self.hermes.respond("POST", "/v1/runs", 202, {"run_id": "run_m1", "status": "started", "replayed": False})
        self.hermes.respond("GET", "/v1/runs/run_m1", 200, {"run_id": "run_m1", "status": "running"})
        self.hermes.respond("POST", "/v1/runs/run_m1/stop", 202, {"run_id": "run_m1", "status": "stopping"})
        self.clock = FakeClock()
        self.config = make_config()
        self.relay = build_relay_app(self.config, upstream_transport=self.hermes.transport(), clock=self.clock)
        self.device = httpx.AsyncClient(transport=httpx.ASGITransport(app=self.relay), base_url="https://relay.test", headers=DEVICE_AUTH)

    async def asyncTearDown(self):
        await self.device.aclose()

    @contextlib.asynccontextmanager
    async def running_mcp(self):
        """MCP app を組み、lifespan（session manager）を test 本体と同じ task で開閉する。"""
        app = build_mcp_app(self.config, bridge=self.relay.state.bridge)
        try:
            async with app.router.lifespan_context(app):
                yield app
        except BaseExceptionGroup as group:  # anyio の task group（SDK server/client）が test の失敗を入れ子に包むので、単一の葉はそのまま報告する
            leaf: BaseException = group
            while isinstance(leaf, BaseExceptionGroup) and len(leaf.exceptions) == 1:
                leaf = leaf.exceptions[0]
            if isinstance(leaf, BaseExceptionGroup):
                raise
            raise leaf from None

    @staticmethod
    def http(app, key="test-mcp-key", host=HOST, origin=None):
        headers = {"Authorization": f"Bearer {key}", "Host": host}
        if origin:
            headers["Origin"] = origin
        return httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url=f"http://{HOST}", headers=headers)

    @contextlib.asynccontextmanager
    async def session(self):
        async with self.running_mcp() as app:
            async with self.http(app) as http:
                async with streamable_http_client(MCP_URL, http_client=http) as (read, write, _):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        yield session

    async def bound_running_binding(self):
        bid = (await self.device.post("/bridge/bindings", json={"deviceID": "d1"})).json()["bindingID"]
        self.assertEqual((await self.device.post(f"/bridge/bindings/{bid}/run", json={"input": "use echo"})).status_code, 202)
        return bid

    async def next_call(self, bid, deadline_seconds=3.0):
        """端末役: 配送を長 poll で待つ。期限内に来なければ失敗（無限待ちにしない）。"""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + deadline_seconds
        while loop.time() < deadline:
            calls = (await self.device.get(f"/bridge/bindings/{bid}/calls?generation=1&wait=1")).json()["calls"]
            if calls:
                return calls[0]
        raise AssertionError(f"no call was delivered to the device within {deadline_seconds}s")

    async def answer_next_call(self, bid):
        call = await self.next_call(bid)
        return await self.device.post(f"/bridge/bindings/{bid}/calls/{call['callID']}/result",
                                      json={"runID": call["runID"], "generation": call["generation"], "ok": True, "text": call["arguments"]["text"]})

    async def test_initialize_and_tools_list_expose_mockbridge_with_exactly_echo(self):
        async with self.running_mcp() as app, self.http(app) as http:
            async with streamable_http_client(MCP_URL, http_client=http) as (read, write, _):
                async with ClientSession(read, write) as session:
                    init = await session.initialize()
                    self.assertEqual(init.serverInfo.name, "mockbridge")
                    tools = await session.list_tools()
                    self.assertEqual([tool.name for tool in tools.tools], ["echo"])
                    schema = tools.tools[0].inputSchema
                    self.assertEqual(set(schema["properties"]), {"text"})
                    self.assertEqual(schema["required"], ["text"])
                    self.assertEqual((await session.list_resources()).resources, [])
                    self.assertEqual((await session.list_prompts()).prompts, [])

    async def test_wrong_or_missing_bearer_is_401_before_any_session_is_created(self):
        async with self.running_mcp() as app:
            for headers in ({"Authorization": "Bearer wrong"}, {"Authorization": "Bearer test-mcp-key-extra"}, {}):
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url=f"http://{HOST}") as http:
                    response = await http.post("/mcp", json=INITIALIZE, headers={**RAW_HEADERS, **headers})
                    self.assertEqual(response.status_code, 401, headers)
                    self.assertNotIn("mcp-session-id", response.headers)
                    self.assertNotIn("test-mcp-key", response.text)
        self.assertEqual(self.hermes.requests, [], "the bridge key is checked locally, never forwarded to Hermes")

    async def test_unexpected_host_or_origin_is_rejected(self):
        async with self.running_mcp() as app:
            async with self.http(app, host="evil.example:18643") as http:
                self.assertEqual((await http.post("/mcp", json=INITIALIZE, headers=RAW_HEADERS)).status_code, 421)
            async with self.http(app, origin="https://evil.example") as http:
                self.assertEqual((await http.post("/mcp", json=INITIALIZE, headers=RAW_HEADERS)).status_code, 403)

    async def test_echo_without_a_bound_device_is_a_tool_error(self):
        async with self.session() as session:
            result = await session.call_tool("echo", {"text": "hi"})
            self.assertTrue(result.isError)
            self.assertIn("no bound device", result.content[0].text)

    async def test_echo_round_trips_through_a_running_binding(self):
        bid = await self.bound_running_binding()
        async with self.session() as session:
            device = asyncio.create_task(self.answer_next_call(bid))
            result = await session.call_tool("echo", {"text": "nyan-1234 ねこ"})
            posted = await device
            self.assertEqual(posted.json(), {"accepted": True})
            self.assertFalse(result.isError, result.content)
            self.assertEqual(result.content[0].text, "nyan-1234 ねこ")

    async def test_echo_times_out_as_a_tool_error_when_the_device_never_answers(self):
        await self.bound_running_binding()
        async with self.session() as session:
            result = await session.call_tool("echo", {"text": "late"})
            self.assertTrue(result.isError)
            self.assertIn("timed out", result.content[0].text)

    async def test_revoke_resolves_a_pending_echo_as_a_tool_error(self):
        bid = await self.bound_running_binding()
        async with self.session() as session:
            pending = asyncio.create_task(session.call_tool("echo", {"text": "stuck"}))
            await self.next_call(bid)  # the device has seen the call but never answers
            self.hermes.respond("GET", "/v1/runs/run_m1", 200, {"run_id": "run_m1", "status": "cancelled"})
            revoke = await self.device.post(f"/bridge/bindings/{bid}/revoke")
            self.assertEqual((revoke.status_code, revoke.json()), (200, {"state": "none"}))
            result = await pending
            self.assertTrue(result.isError)
            self.assertIn("revoked", result.content[0].text)

    async def test_echo_arguments_are_validated_by_the_schema(self):
        async with self.session() as session:
            for arguments in ({}, {"text": 5}, {"text": None}, {"other": "x"}):
                result = await session.call_tool("echo", arguments)
                self.assertTrue(result.isError, arguments)
        self.assertEqual(self.relay.state.bridge.pending, {}, "invalid arguments never reach the bridge")


if __name__ == "__main__":
    unittest.main()
