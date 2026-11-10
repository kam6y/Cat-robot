"""模擬端末ツール境界（契約 r3 §2.5 / §3）: binding 状態機械と /bridge/* routes。

状態: none → bound(gen=1) → submitting → running → (terminal → drained →) none、例外経路 → quarantined。
relay は Hermes の鍵を持たないので、stop / terminal 確認は認証済 bridge request の Bearer でだけ行う。
MCP 側（鍵なし）で失効を見たときは pending を error にして quarantined で閉じる（fail closed）。
"""
from __future__ import annotations

import asyncio
import json
import secrets
import uuid
from dataclasses import dataclass
from typing import Any, Callable

from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from relay.admission import TERMINAL, is_valid_id, json_object
from relay.config import RelayConfig
from relay.httputil import error, read_json_object
from relay.upstream import Upstream, UpstreamError

RECEIPT_TTL_SECONDS = 600.0
MAX_LONG_POLL_SECONDS = 10.0
# 契約 r3 §2.5: 端末の submit 要求予算 60 s（HermesBridgeClient）の内側で必ず応答する総合 deadline。
# 既定の capabilities 15 s + run 作成 15 s × 2（同一 Idempotency-Key 再送 1 回）= 45 s に処理余裕 5 s。
SUBMIT_DEADLINE_SECONDS = 50.0
ACTIVE_STATES = ("bound", "submitting", "running")


class BridgeError(Exception):
    """MCP tool error へ写す失敗。message は tool の isError 本文になる。"""


@dataclass
class Binding:
    binding_id: str
    device_id: str
    generation: int
    expires_at: float
    run_id: str | None = None
    session_id: str | None = None


@dataclass
class Call:
    call_id: str
    tool: str
    arguments: dict[str, str]
    expires_at: float
    future: asyncio.Future
    binding_id: str
    run_id: str | None
    generation: int
    delivered: bool = False

    def wire(self, binding: Binding) -> dict[str, Any]:
        call = {"bindingID": self.binding_id, "runID": self.run_id, "generation": self.generation,
                "callID": self.call_id, "tool": self.tool, "arguments": self.arguments, "expiresAt": self.expires_at}
        if binding.session_id is not None:
            call["sessionID"] = binding.session_id
        return call


@dataclass
class _SubmitProgress:
    """submit が deadline を越えたとき、この要求自身が予約を取った後かどうかを判定する進捗。"""
    binding: Binding | None = None
    reserved: bool = False


@dataclass(frozen=True)
class Receipt:
    binding_id: str
    run_id: str | None
    generation: int
    outcome: str
    finished_at: float


class Bridge:
    def __init__(self, config: RelayConfig, upstream: Upstream, admission, clock: Callable[[], float]):
        self.config = config
        self.upstream = upstream
        self.admission = admission
        self.clock = clock
        self.state = "none"
        self.binding: Binding | None = None
        self.pending: dict[str, Call] = {}
        self.receipts: dict[str, Receipt] = {}
        self.bound_runs = 0
        self.submit_deadline_seconds = SUBMIT_DEADLINE_SECONDS  # 契約定数。試験だけが短縮する。
        self._wakeup = asyncio.Event()

    @property
    def state_name(self) -> str:
        return self.state

    # ----- 内部 -----

    def _receipt(self, call: Call, outcome: str) -> None:
        self._receipt_prune()
        self.receipts[call.call_id] = Receipt(call.binding_id, call.run_id, call.generation, outcome, self.clock())

    def _fail_pending(self, message: str, outcome: str) -> None:
        for call in list(self.pending.values()):
            if not call.future.done():
                call.future.set_exception(BridgeError(message))
            self._receipt(call, outcome)
        self.pending.clear()
        self._wakeup.set()

    def _clear_binding(self) -> None:
        self.state = "none"
        self.binding = None
        self._wakeup.set()

    def _quarantine(self, message: str) -> None:
        self._fail_pending(message, "failed")
        self.state = "quarantined"

    def _current(self, binding_id: str) -> Binding | None:
        if self.binding is not None and is_valid_id(binding_id) and binding_id == self.binding.binding_id:
            return self.binding
        return None

    async def _authenticate(self, request: Request) -> JSONResponse | dict[str, str]:
        """毎 request、Authorization をそのまま GET /v1/capabilities に転送して 200 のときだけ受理。キャッシュしない。"""
        authorization = request.headers.get("authorization")
        if not authorization:
            return error(401, "missing Authorization")
        headers = {"Authorization": authorization}
        try:
            response = await self.upstream.request("GET", "/v1/capabilities", headers)
        except UpstreamError as failure:
            return error(failure.status, failure.message)
        if response.status == 200:
            return headers
        if response.status in (401, 403):
            return error(401, "unauthorized")
        return error(502, f"upstream capabilities returned {response.status}")

    async def _confirm_terminal(self, run_id: str, auth: dict[str, str]) -> bool:
        for attempt in range(self.config.drain_poll_attempts):
            if attempt:
                await asyncio.sleep(self.config.drain_poll_interval_seconds)
            try:
                response = await self.upstream.request("GET", f"/v1/runs/{run_id}", auth)
            except UpstreamError:
                continue
            if self.admission.observe_state(run_id, response.status, response.body) in TERMINAL:
                return True
        return False

    async def _tear_down(self, auth: dict[str, str], message: str, outcome: str) -> None:
        """revoke / TTL 失効: 世代を進めて pending を error、run があれば stop → terminal 確認 → none、未確認 → quarantined。"""
        binding = self.binding
        assert binding is not None
        previous_state = self.state
        if previous_state == "revoking":
            return
        binding.generation += 1
        self.state = "revoking"  # ネットワークを待つ前に、新しい MCP call と配送を止める。
        self._fail_pending(message, outcome)
        if previous_state == "bound":
            self._clear_binding()
            return
        if previous_state == "submitting" or binding.run_id is None:
            self.state = "quarantined"
            return
        run_id = binding.run_id
        generation = binding.generation
        try:
            try:
                await self.upstream.request("POST", f"/v1/runs/{run_id}/stop", auth)
            except UpstreamError:
                pass
            terminal = await self._confirm_terminal(run_id, auth)
        except asyncio.CancelledError:
            # 呼び出し元（submit の deadline など）に取り消されても、この tear-down が進めた revoking 遷移を持ち主のないまま
            # 残さない。terminal は未確認なので予約を保持したまま quarantined（fail closed）。別の持ち主に替わった binding や
            # 既に閉じた状態には触れず、取消はそのまま伝播させる。
            if self.binding is binding and self.state == "revoking" and binding.generation == generation:
                self._quarantine("binding teardown interrupted")
            raise
        if self.binding is not binding:
            return
        if terminal:
            self.admission.discard(run_id)
            self._clear_binding()
        else:
            self.state = "quarantined"

    def _expired(self) -> bool:
        return self.binding is not None and self.state in ACTIVE_STATES and self.clock() >= self.binding.expires_at

    async def _expire_if_due(self, auth: dict[str, str]) -> bool:
        if not self._expired():
            return False
        await self._tear_down(auth, "binding expired", "expired")
        return True

    # ----- MCP 側 -----

    async def enqueue_echo(self, text: str) -> str:
        if self._expired():
            self._quarantine("binding expired")
            raise BridgeError("binding expired")
        if self.state not in ("submitting", "running") or self.binding is None:
            raise BridgeError("no bound device")
        binding = self.binding
        call = Call(secrets.token_urlsafe(16), "echo", {"text": text}, self.clock() + self.config.call_timeout_seconds,
                    asyncio.get_running_loop().create_future(), binding.binding_id, binding.run_id, binding.generation)
        self.pending[call.call_id] = call
        self._wakeup.set()
        try:
            return await asyncio.wait_for(asyncio.shield(call.future), self.config.call_timeout_seconds)
        except TimeoutError:
            if self.pending.pop(call.call_id, None) is not None:
                call.future.cancel()
                self._receipt(call, "timeout")
                if self.binding is binding:
                    self._quarantine("device timed out")
            raise BridgeError("device timed out") from None
        except asyncio.CancelledError:
            if self.pending.pop(call.call_id, None) is not None:
                call.future.cancel()
                self._receipt(call, "unknown")
                if self.binding is binding:
                    self._quarantine("device communication lost")
            raise

    def observe_run_state(self, run_id: str, state: str | None) -> None:
        """REST 経由で観測した bound run の terminal で binding を終える（drained → none）。"""
        if self.binding is not None and self.state == "running" and run_id == self.binding.run_id and state in TERMINAL:
            self._fail_pending("run ended", "failed")
            self._clear_binding()

    # ----- 認証済 /bridge handlers -----

    async def bind(self, request: Request) -> JSONResponse:
        auth = await self._authenticate(request)
        if isinstance(auth, JSONResponse):
            return auth
        await self._expire_if_due(auth)
        body = await read_json_object(request, self.config.max_request_bytes)
        device_id = body.get("deviceID") if body else None
        if not isinstance(device_id, str) or not device_id:
            return error(400, "deviceID required")
        if self.state == "quarantined":
            return error(409, "quarantined", reason="quarantined")
        if self.state != "none" or self.admission.busy:
            return error(409, "busy", reason="busy")
        if self.bound_runs >= self.config.max_runs_per_process:
            return error(409, "exhausted", reason="exhausted")
        self.binding = Binding(secrets.token_urlsafe(16), device_id, 1, self.clock() + self.config.binding_ttl_seconds)
        self.state = "bound"
        return JSONResponse({"bindingID": self.binding.binding_id, "generation": 1, "expiresAt": self.binding.expires_at}, status_code=201)

    async def submit(self, request: Request) -> JSONResponse:
        """run 作成。認証・body・run 作成（timeout 時の同一 Idempotency-Key 再送 1 回を含む）を合わせて
        submit_deadline_seconds 内に必ず応答する。超過時、送信済みの予約は結果不明として quarantined に残す（fail closed）。
        認証や body の段階で越えた要求は run を送っていないので、binding も admission も変えない。"""
        progress = _SubmitProgress()
        try:
            async with asyncio.timeout(self.submit_deadline_seconds):
                return await self._submit(request, progress)
        except TimeoutError:
            if progress.reserved and self.binding is progress.binding and self.state == "submitting":
                self._quarantine("run submission outcome unknown")  # 予約は保持（fail closed）
            return error(504, "submit deadline exceeded", state=self.state)

    async def _submit(self, request: Request, progress: _SubmitProgress) -> JSONResponse:
        auth = await self._authenticate(request)
        if isinstance(auth, JSONResponse):
            return auth
        if await self._expire_if_due(auth):
            return error(410, "binding expired", state=self.state)
        binding = self._current(request.path_params["binding_id"])
        if binding is None:
            return error(404, "unknown binding")
        body = await read_json_object(request, self.config.max_request_bytes)
        text = body.get("input") if body else None
        if not isinstance(text, str):
            return error(400, "input required")
        if self.binding is not binding or self.state != "bound":
            return error(409, "not bound", reason="not bound")
        if self.admission.busy:
            return error(409, "busy", reason="busy")

        self.state = "submitting"
        token = self.admission.reserve()
        progress.binding, progress.reserved = binding, True
        headers = {**auth, "Content-Type": "application/json", "Idempotency-Key": str(uuid.uuid4())}
        payload = json.dumps({"input": text}).encode()
        response = failure = None
        for attempt in range(2):  # timeout は同一 Idempotency-Key で 1 回だけ再送（replayed 許容）
            try:
                response = await self.upstream.request("POST", "/v1/runs", headers, payload)
                break
            except UpstreamError as caught:
                failure = caught
                if caught.status != 504:
                    break
        if response is None:
            self._quarantine("run submission outcome unknown")  # 予約は保持（fail closed）
            return error(failure.status, failure.message, state=self.state)
        if failure is not None and 400 <= response.status < 500:
            # 再送の拒否は、応答を失った最初の要求が run を作らなかった証拠にはならない。
            self._quarantine("run submission outcome unknown")
            return error(502, "run recovery rejected", upstreamStatus=response.status, state=self.state)
        run_id = self.admission.commit(token, response.status, response.body)
        if 400 <= response.status < 500:  # 明示拒否: run は作られていないので binding を失効させて解放
            self._fail_pending("run rejected", "failed")
            self._clear_binding()
            return error(502, "upstream rejected run", upstreamStatus=response.status)
        if response.status >= 500:  # 作成有無が不明: 予約（sentinel）を保持して閉じる
            self._quarantine("run submission failed upstream")
            return error(502, "upstream failed to accept run", upstreamStatus=response.status, state=self.state)
        if self.state != "submitting":  # revoke / 失効が割り込んだ: run は追跡したまま閉じる
            self.state = "quarantined"
            return error(409, "binding ended during submission", state=self.state)
        if not is_valid_id(run_id):
            self._quarantine("run acceptance unreadable")
            return error(502, "upstream acceptance unreadable", state=self.state)
        accepted = json_object(response.body) or {}
        binding.run_id = run_id
        binding.session_id = accepted.get("session_id") if isinstance(accepted.get("session_id"), str) else None
        for call in self.pending.values():
            call.run_id = run_id
        self.bound_runs += 1
        self.state = "running"
        self._wakeup.set()
        reply = {"runID": run_id, "status": accepted.get("status")}
        if binding.session_id is not None:
            reply["sessionID"] = binding.session_id
        return JSONResponse(reply, status_code=202)

    async def poll(self, request: Request) -> JSONResponse:
        auth = await self._authenticate(request)
        if isinstance(auth, JSONResponse):
            return auth
        if await self._expire_if_due(auth):
            return error(410, "binding expired", state=self.state)
        binding = self._current(request.path_params["binding_id"])
        if binding is None:
            return error(404, "unknown binding")
        generation = request.query_params.get("generation", "")
        wait = request.query_params.get("wait", "0")
        try:
            wait_seconds = float(wait)
        except ValueError:
            wait_seconds = -1.0
        if not generation.isdigit() or not 0 <= wait_seconds <= MAX_LONG_POLL_SECONDS:
            return error(400, "generation must be an integer and wait within 0..10")
        if int(generation) != binding.generation:
            return error(409, "generation mismatch", reason="generation")
        loop = asyncio.get_running_loop()
        deadline = loop.time() + wait_seconds
        while self.binding is binding:
            # quarantined 等も空の long-poll は指定時間待ち、端末の即時再pollを防ぐ。
            ready = [call for call in self.pending.values() if not call.delivered] if self.state == "running" else []
            remaining = deadline - loop.time()
            if ready or remaining <= 0:
                break
            self._wakeup.clear()
            try:
                await asyncio.wait_for(self._wakeup.wait(), remaining)
            except TimeoutError:
                break
        if self.state != "running" or self.binding is not binding:
            return JSONResponse({"calls": []})
        ready = [call for call in self.pending.values() if not call.delivered]
        for call in ready:
            call.delivered = True
        return JSONResponse({"calls": [call.wire(binding) for call in ready]})

    async def post_result(self, request: Request) -> JSONResponse:
        auth = await self._authenticate(request)
        if isinstance(auth, JSONResponse):
            return auth
        if await self._expire_if_due(auth):
            return error(410, "binding expired", state=self.state)
        binding = self._current(request.path_params["binding_id"])
        call_id = request.path_params["call_id"]
        if binding is None or not is_valid_id(call_id):
            return error(404, "unknown binding or call")
        body = await read_json_object(request, self.config.max_request_bytes)
        if self.binding is not binding:
            return error(409, "binding changed", reason="mismatch")
        if (body is None or not isinstance(body.get("runID"), str) or isinstance(body.get("generation"), bool)
                or not isinstance(body.get("generation"), int) or not isinstance(body.get("ok"), bool)
                or not isinstance(body.get("text"), (str, type(None))) or not isinstance(body.get("error"), (str, type(None)))):
            return error(400, "result must carry runID, generation, ok and text|error")
        if body["generation"] != binding.generation or body["runID"] != binding.run_id:
            return error(409, "binding/run/generation mismatch", reason="mismatch")
        self._receipt_prune()
        receipt = self.receipts.get(call_id)
        if receipt is not None:
            if (receipt.binding_id != binding.binding_id or receipt.run_id != body["runID"]
                    or receipt.generation != body["generation"]):
                return error(409, "receipt identity mismatch", reason="mismatch")
            if receipt.outcome not in ("ok", "error"):
                return error(410, "call no longer active")
            return JSONResponse({"accepted": False, "duplicate": True})
        call = self.pending.get(call_id)
        if call is None:
            return error(404, "unknown call")
        if (call.binding_id != binding.binding_id or call.generation != body["generation"]
                or call.run_id != body["runID"]):
            return error(409, "binding/run/generation mismatch", reason="mismatch")
        if self.clock() >= call.expires_at:
            # 期限切れの result は call timeout と同じ通信不明。この call は expired のまま記録し、
            # 残りの pending を失効させて quarantined で閉じる（enqueue_echo 側の timer より先に届いた場合も同じ）。
            del self.pending[call_id]
            if not call.future.done():
                call.future.set_exception(BridgeError("call expired before the device answered"))
            self._receipt(call, "expired")
            self._quarantine("device timed out")
            return error(410, "call expired", state=self.state)
        if body["ok"]:
            if not isinstance(body.get("text"), str):
                return error(400, "ok results must carry text")
            outcome = "ok"
            if not call.future.done():
                call.future.set_result(body["text"])
        else:
            outcome = "error"
            if not call.future.done():
                call.future.set_exception(BridgeError("device error: " + (body.get("error") or "unspecified")))
        del self.pending[call_id]
        self._receipt(call, outcome)
        return JSONResponse({"accepted": True})

    def _receipt_prune(self) -> None:
        now = self.clock()
        for stale in [cid for cid, receipt in self.receipts.items() if now - receipt.finished_at > RECEIPT_TTL_SECONDS]:
            del self.receipts[stale]

    async def revoke(self, request: Request) -> JSONResponse:
        auth = await self._authenticate(request)
        if isinstance(auth, JSONResponse):
            return auth
        binding = self._current(request.path_params["binding_id"])
        if binding is None:
            return error(404, "unknown binding")
        if await self._expire_if_due(auth) or self.state == "quarantined":
            return JSONResponse({"state": self.state})
        await self._tear_down(auth, "binding revoked", "revoked")
        return JSONResponse({"state": self.state})


def bridge_routes(bridge: Bridge) -> list[Route]:
    return [
        Route("/bridge/bindings", bridge.bind, methods=["POST"]),
        Route("/bridge/bindings/{binding_id}/run", bridge.submit, methods=["POST"]),
        Route("/bridge/bindings/{binding_id}/calls", bridge.poll, methods=["GET"]),
        Route("/bridge/bindings/{binding_id}/calls/{call_id}/result", bridge.post_result, methods=["POST"]),
        Route("/bridge/bindings/{binding_id}/revoke", bridge.revoke, methods=["POST"]),
    ]
