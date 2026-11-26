"""relay ASGI app（契約 r3 §3）: REST allowlist 転送、単一 run admission、/bridge、access log。allowlist 外は全て 404。"""
from __future__ import annotations

import contextlib
import hmac
import logging
import time
from typing import Callable
from urllib.parse import urlencode

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import Response
from starlette.routing import Route

from relay.admission import RunAdmission, is_valid_id
from relay.bridge import Bridge, bridge_routes
from relay.config import RelayConfig
from relay.httputil import error, not_found, read_body
from relay.upstream import Upstream, UpstreamError

logger = logging.getLogger("relay.access")


class AccessLog:
    """method / path / status / 所要時間 / auth_present だけを記録する純 ASGI middleware。"""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        started = time.monotonic()
        status = {"code": 0}

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                status["code"] = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            auth_present = any(name == b"authorization" for name, _ in scope.get("headers", []))
            line = (f"{scope['method']} {scope['path']} {status['code']} {int((time.monotonic() - started) * 1000)}ms "
                    f"auth_present={'true' if auth_present else 'false'}")
            logger.info(line)


class ClientAuthentication:
    """Task-only conversation fixture: authenticate before forwarding the fixed upstream key."""

    def __init__(self, app, client_key: str):
        self.app = app
        self._bearer = ("Bearer " + client_key).encode("ascii")

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            values = [v for k, v in scope.get("headers", []) if k.lower() == b"authorization"]
            if len(values) != 1 or not hmac.compare_digest(values[0], self._bearer):
                await error(401, "unauthorized")(scope, receive, send)
                return
        await self.app(scope, receive, send)


def proxied(response) -> Response:
    return Response(response.body, status_code=response.status, media_type=response.content_type)


def build_relay_app(config: RelayConfig, *, upstream_transport: httpx.AsyncBaseTransport | None = None,
                    clock: Callable[[], float] = time.time) -> Starlette:
    upstream = Upstream(config, upstream_transport)
    admission = RunAdmission()
    bridge = Bridge(config, upstream, admission, clock)

    async def forward(request: Request, method: str, path: str, body: bytes | None = None) -> Response:
        try:
            return proxied(await upstream.request(method, path, Upstream.forwardable(request.headers), body))
        except UpstreamError as failure:
            return error(failure.status, failure.message)

    async def capabilities(request: Request) -> Response:
        return await forward(request, "GET", "/v1/capabilities")

    async def create_run(request: Request) -> Response:
        body = await read_body(request, config.max_request_bytes)
        if body is None:
            return error(413, "request body exceeds maxRequestBytes")
        if config.conversation_mode:
            # Hermes already durably deduplicates keyed POSTs and queues session turns.
            # This text-only fixture has no device bridge; a stale probe slot must not trap recovery.
            return await forward(request, "POST", "/v1/runs", body)
        if admission.busy or bridge.state_name != "none":
            return error(409, "busy", reason="busy")
        token = admission.reserve()  # upstream を待つ前に予約。結果不明なら解放しない（fail closed）。
        try:
            response = await upstream.request("POST", "/v1/runs", Upstream.forwardable(request.headers), body)
        except UpstreamError as failure:
            return error(failure.status, failure.message)
        admission.commit(token, response.status, response.body)
        return proxied(response)

    async def get_run(request: Request) -> Response:
        run_id = request.path_params["run_id"]
        if not is_valid_id(run_id):
            return error(404, "not found")
        if config.conversation_mode:
            return await forward(request, "GET", f"/v1/runs/{run_id}")
        try:
            response = await upstream.request("GET", f"/v1/runs/{run_id}", Upstream.forwardable(request.headers))
        except UpstreamError as failure:
            return error(failure.status, failure.message)
        bridge.observe_run_state(run_id, admission.observe_state(run_id, response.status, response.body))
        return proxied(response)

    async def stop_run(request: Request) -> Response:
        run_id = request.path_params["run_id"]
        if not is_valid_id(run_id):
            return error(404, "not found")
        return await forward(request, "POST", f"/v1/runs/{run_id}/stop")

    async def session_messages(request: Request) -> Response:
        session_id = request.path_params["session_id"]
        if not is_valid_id(session_id):
            return error(404, "not found")
        try:
            limit = int(request.query_params.get("limit", "100"))
        except ValueError:
            return error(400, "invalid history limit")
        order = request.query_params.get("order", "latest")
        if not 1 <= limit <= 500 or order not in ("latest", "oldest"):
            return error(400, "invalid history pagination")
        query = urlencode({"order": order, "limit": limit, "inline_images": "false"})
        return await forward(request, "GET", f"/api/sessions/{session_id}/messages?{query}")

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        try:
            yield
        finally:
            await upstream.aclose()

    routes = [
        Route("/v1/capabilities", capabilities, methods=["GET"]),
        Route("/v1/runs", create_run, methods=["POST"]),
        Route("/v1/runs/{run_id}", get_run, methods=["GET"]),
        Route("/v1/runs/{run_id}/stop", stop_run, methods=["POST"]),
        *([Route("/api/sessions/{session_id}/messages", session_messages, methods=["GET"])] if config.conversation_mode else []),
        *(bridge_routes(bridge) if not config.conversation_mode else []),
    ]
    for route in routes:
        route.methods.discard("HEAD")  # Starlette が GET に付ける暗黙の HEAD は契約の allowlist 外。
    app = Starlette(routes=routes, exception_handlers={404: not_found, 405: not_found}, lifespan=lifespan)
    app.router.redirect_slashes = False
    app.state.config = config
    app.state.upstream = upstream
    app.state.admission = admission
    app.state.bridge = bridge
    if config.conversation_mode:
        app.add_middleware(ClientAuthentication, client_key=config.client_key)
    app.add_middleware(AccessLog)
    return app
