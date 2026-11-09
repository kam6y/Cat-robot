"""MCP server（契約 r3 §3）: 公式 mcp SDK 1.30.0 の FastMCP。server 名 mockbridge、tool は echo(text) のみ（resources/prompts/sampling 未登録）。

Streamable HTTP を /mcp に置き、Authorization: Bearer <mcpBridgeKey> を純 ASGI gate で必須化（lifespan は素通し）、
Host/Origin は SDK の TransportSecuritySettings（allowed_hosts=[mcpListen]、allowed_origins=[]）で検査する。
"""
from __future__ import annotations

import hmac
import json

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette

from relay.bridge import Bridge, BridgeError
from relay.config import RelayConfig


class BearerGate:
    """mcpBridgeKey の定数時間比較。失敗は 401（本文に鍵や理由の詳細を出さない）。"""

    def __init__(self, app, key: str):
        self.app = app
        self._expected = f"Bearer {key}".encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        provided = next((value for name, value in scope["headers"] if name == b"authorization"), b"")
        if not hmac.compare_digest(provided, self._expected):
            body = json.dumps({"error": "unauthorized"}).encode()
            await send({"type": "http.response.start", "status": 401, "headers": [
                (b"content-type", b"application/json"), (b"content-length", str(len(body)).encode()), (b"www-authenticate", b"Bearer")]})
            await send({"type": "http.response.body", "body": body})
            return
        await self.app(scope, receive, send)


def build_mcp_app(config: RelayConfig, *, bridge: Bridge) -> Starlette:
    host, port = config.mcp_listen
    server = FastMCP(
        name="mockbridge",
        instructions="Cat Robot connection probe. The only tool, echo(text), is executed by the bound probe device (mock executor) and returns the text it echoed.",
        host=host, port=port, streamable_http_path="/mcp",
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=True, allowed_hosts=[f"{host}:{port}"], allowed_origins=[]),
    )

    @server.tool(name="echo", description="Send text to the bound Cat Robot probe device; returns exactly the text the device echoed back.")
    async def echo(text: str) -> str:
        try:
            return await bridge.enqueue_echo(text)
        except BridgeError as failure:
            raise ToolError(str(failure)) from None

    app = server.streamable_http_app()  # routes: /mcp; lifespan: session_manager.run()
    app.add_middleware(BearerGate, key=config.mcp_bridge_key)
    app.state.server = server
    app.state.bridge = bridge
    return app
