"""relay / bridge 共通の小さな HTTP 補助。"""
from __future__ import annotations

import json

from starlette.requests import Request
from starlette.responses import JSONResponse


def error(status: int, message: str, **extra) -> JSONResponse:
    return JSONResponse({"error": message, **extra}, status_code=status)


def not_found(request: Request, exc: Exception) -> JSONResponse:
    return error(404, "not found")


async def read_body(request: Request, limit: int) -> bytes | None:
    """request body を limit まで読む。超過（Content-Length でもストリームでも）は None。"""
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > limit:
        return None
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            return None
        chunks.append(chunk)
    return b"".join(chunks)


async def read_json_object(request: Request, limit: int) -> dict | None:
    """JSON object の body だけを dict で返す。それ以外（超過・不正・配列）は None。"""
    body = await read_body(request, limit)
    if body is None:
        return None
    try:
        value = json.loads(body)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None
