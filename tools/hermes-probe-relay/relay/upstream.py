"""Windows Hermes への転送クライアント。契約 r3 §3: hermesBase 固定、redirect 非追従、応答 ≤ maxResponseBytes、全体 timeout。

httpx.Request を直接組んで client.send するので、client の既定ヘッダや cookie jar は upstream へ付かない。
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass

import httpx

from relay.config import RelayConfig

FORWARDED_HEADERS = ("authorization", "content-type", "idempotency-key")


@dataclass(frozen=True)
class UpstreamResponse:
    status: int
    content_type: str | None
    body: bytes


class UpstreamError(Exception):
    """relay が client へ返す 502/504。upstream の Location 等は含めない。"""

    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class Upstream:
    def __init__(self, config: RelayConfig, transport: httpx.AsyncBaseTransport | None = None):
        self._base = config.hermes_base
        self._limit = config.max_response_bytes
        self._timeout = config.upstream_timeout_seconds
        self._client = httpx.AsyncClient(transport=transport, trust_env=False, follow_redirects=False,
                                         timeout=config.upstream_timeout_seconds)

    @staticmethod
    def forwardable(headers) -> dict[str, str]:
        return {name: headers[name] for name in FORWARDED_HEADERS if name in headers}

    async def request(self, method: str, path: str, headers: dict[str, str], body: bytes | None = None) -> UpstreamResponse:
        request = httpx.Request(method, httpx.URL(self._base + path), headers=headers, content=body)
        try:
            # httpx の per-operation timeout に加え、往復全体にも同じ上限を掛ける（transport 差し替え時も有効）。
            async with asyncio.timeout(self._timeout):
                response = await self._client.send(request, stream=True)
                try:
                    if 300 <= response.status_code < 400:
                        raise UpstreamError(502, "upstream redirect not followed")
                    chunks: list[bytes] = []
                    size = 0
                    async for chunk in response.aiter_bytes():
                        size += len(chunk)
                        if size > self._limit:
                            raise UpstreamError(502, "upstream response exceeds maxResponseBytes")
                        chunks.append(chunk)
                finally:
                    await response.aclose()
        except (TimeoutError, httpx.TimeoutException):
            raise UpstreamError(504, "upstream timeout") from None
        except httpx.HTTPError as failure:
            raise UpstreamError(502, "upstream request failed: " + type(failure).__name__) from None
        return UpstreamResponse(response.status_code, response.headers.get("content-type"), b"".join(chunks))

    async def aclose(self) -> None:
        await self._client.aclose()
