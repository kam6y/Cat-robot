"""プロセス内の偽 Hermes（httpx.MockTransport）、制御可能な時計、relay 設定の組み立て。ポートを開かず、秘密は試験用文字列だけ。"""
import asyncio
import json
from dataclasses import dataclass, field

import httpx

from relay.config import RelayConfig


@dataclass
class Scripted:
    status: int
    body: bytes
    headers: dict = field(default_factory=dict)


class FakeHermes:
    """method+path → 応答。受け取った request を記録する。hold() した route は release() まで応答を返さない。"""

    def __init__(self):
        self.routes: dict[tuple[str, str], Scripted] = {}
        self.holds: dict[tuple[str, str], asyncio.Event] = {}
        self.requests: list[httpx.Request] = []
        self.capabilities_calls = 0

    def respond(self, method, path, status, payload, headers=None):
        self.routes[(method, path)] = Scripted(status, json.dumps(payload).encode(), dict(headers or {}))

    def respond_raw(self, method, path, status, body: bytes, headers=None):
        self.routes[(method, path)] = Scripted(status, body, dict(headers or {}))

    def hold(self, method, path) -> asyncio.Event:
        event = asyncio.Event()
        self.holds[(method, path)] = event
        return event

    def release(self, method, path):
        self.holds.pop((method, path)).set()

    def requests_to(self, method, path):
        return [r for r in self.requests if r.method == method and r.url.path == path]

    def transport(self) -> httpx.AsyncBaseTransport:
        return httpx.MockTransport(self._handle)

    async def _handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if request.method == "GET" and request.url.path == "/v1/capabilities":
            self.capabilities_calls += 1
        hold = self.holds.get((request.method, request.url.path))
        if hold is not None:
            await hold.wait()
        scripted = self.routes.get((request.method, request.url.path))
        if scripted is None:
            return httpx.Response(404, json={"error": "not scripted"})
        headers = {"Content-Type": "application/json", **scripted.headers}
        return httpx.Response(scripted.status, content=scripted.body, headers=headers)


class FakeClock:
    """relay に注入する時計。expiresAt / TTL / call 期限の実測に使う。"""

    def __init__(self, now: float = 1_800_000_000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def make_config(**overrides) -> RelayConfig:
    values = {
        "hermesBase": "http://hermes.test:18642",
        "relayListen": ["127.0.0.1:18644"],
        "cert": "/nonexistent/relay-cert.pem",
        "key": "/nonexistent/relay-key.pem",
        "mcpListen": "100.102.164.56:18643",
        "mcpBridgeKey": "test-mcp-key",
        "upstreamTimeoutSeconds": 0.2,
        "callTimeoutSeconds": 1.0,
        "bindingTTLSeconds": 600,
        "maxRequestBytes": 65_536,
        "maxResponseBytes": 1_048_576,
        "maxRunsPerProcess": 1,
        "drainPollAttempts": 1,
        "drainPollIntervalSeconds": 0,
    }
    values.update(overrides)
    return RelayConfig.from_mapping(values)
