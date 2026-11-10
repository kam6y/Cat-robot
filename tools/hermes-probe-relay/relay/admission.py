"""単一 run admission（契約 r3 §3）。relay を通る全 run（plain / bound）を追跡し、terminal 未確認の run があれば busy。

予約は upstream を await する前に取り、結果不明（timeout / 読めない 202）は解放しない（fail closed）。
"""
from __future__ import annotations

import json
import re
import uuid

RUN_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
TERMINAL = frozenset({"completed", "cancelled", "failed"})
UNTRACKED = "<unparsed run id>"


def is_valid_id(value) -> bool:
    return isinstance(value, str) and RUN_ID.fullmatch(value) is not None


def json_object(body: bytes) -> dict | None:
    try:
        value = json.loads(body)
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


class RunAdmission:
    def __init__(self) -> None:
        self.active: set[str] = set()

    @property
    def busy(self) -> bool:
        return bool(self.active)

    def reserve(self) -> str:
        token = f"<reserved {uuid.uuid4()}>"
        self.active.add(token)
        return token

    def release(self, token: str) -> None:
        self.active.discard(token)

    def commit(self, token: str, status: int, body: bytes) -> str | None:
        """POST /v1/runs の確定応答。4xx の明示拒否だけ予約を解放。2xx は run_id を追跡し、5xx / 読めない 2xx は
        run が作られていないと言えないので sentinel を追跡したまま（fail closed）。"""
        self.active.discard(token)
        if 400 <= status < 500:
            return None
        payload = json_object(body)
        run_id = payload.get("run_id") if payload else None
        tracked = run_id if is_valid_id(run_id) else UNTRACKED
        self.active.add(tracked)
        return tracked

    def observe_state(self, run_id: str, status: int, body: bytes) -> str | None:
        """GET /v1/runs/{id} の応答。terminal を観測した run を admission から外す。"""
        if status != 200:
            return None
        payload = json_object(body)
        if payload is None or payload.get("run_id") != run_id:
            return None  # 要求した run の報告でなければ何も観測しない
        state = payload.get("status")
        if not isinstance(state, str):
            return None
        if state in TERMINAL:
            self.active.discard(run_id)
        return state

    def discard(self, run_id: str) -> None:
        self.active.discard(run_id)
