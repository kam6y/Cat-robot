"""relay 起動 runner（契約 r3 §3 / §5）: `python -I -m relay.runner --secrets … --tls-metadata … --out …`

- `probe-secrets.json`（0600、apiKey / mcpBridgeKey）と `tls/public-metadata.json` を programmatic に読み、attempt dir（0700 排他）に
  `relay-config.json`（0600 排他、mcpBridgeKey のみ）を生成する。端末 bootstrap は device runner だけが生成・配送・削除する。
  秘密の値は print / log / 例外 repr に出さない。
- relay を子 process（新 session）で起動し、ready 行を有限時間待つ。
- readiness: 同一 TLS 接続で metadata の証明書 + hostname を検証 → DER pin 照合 → `GET /v1/capabilities`（鍵なし → 401 期待）、
  公式 mcp client で initialize / tools/list / tools/call echo（binding 無し → isError "no bound device"）。
  期待値が 1 つでも外れたら exit 1 で自分が起動した子だけ止める。成功時は relay を常駐させ PID を記録する。
- receipt / stdout は秘密文字列を含まないことを書く前に検査し、鍵は在否の真偽値だけを残す。
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import http.client
import json
import os
import ssl
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Mapping

READINESS_EXPECTATIONS: dict[str, Any] = {
    "tlsPinMatches": True,
    "capabilitiesWithoutAuthStatus": 401,
    "mcpServerName": "mockbridge",
    "mcpTools": ["echo"],
    "mcpEchoWithoutBindingIsError": True,
    "mcpEchoErrorMentionsNoBoundDevice": True,
}


class ReadinessError(Exception):
    """readiness の実測が期待と違う。message に秘密は含めない。phase は失敗した手順名（固定文字列）。"""

    def __init__(self, message: str, *, phase: str | None = None):
        super().__init__(message)
        self.phase = phase


def read_owner_only_json(path: Path) -> dict:
    mode = path.stat().st_mode & 0o777
    if mode & 0o077:
        raise ReadinessError(f"{path.name}: must be mode 0600, found {mode:04o}")
    with path.open("rb") as handle:  # 内容は変数に留め、出力しない
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ReadinessError(f"{path.name}: must be a JSON object")
    return value


def build_relay_config(secrets: Mapping[str, Any], metadata: Mapping[str, Any], *, hermes_base: str,
                       relay_listen: list[str], mcp_listen: str) -> dict:
    return {"hermesBase": hermes_base, "relayListen": list(relay_listen), "cert": metadata["certificate"],
            "key": metadata["privateKeyPath"], "mcpListen": mcp_listen, "mcpBridgeKey": secrets["mcpBridgeKey"]}


def write_owner_only_json(path: Path, payload: Mapping[str, Any]) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        json.dump(payload, handle, ensure_ascii=False)


def create_attempt_dir(out: Path, now: Callable[[], float]) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    attempt = out / time.strftime("attempt-%Y%m%dT%H%M%SZ", time.gmtime(now()))
    attempt.mkdir(mode=0o700)  # 既存なら FileExistsError: 以前の attempt を上書きしない
    os.chmod(attempt, 0o700)
    return attempt


def readiness_problems(observed: Mapping[str, Any]) -> list[str]:
    return [f"{key}: expected {expected!r}, observed {observed.get(key)!r}"
            for key, expected in READINESS_EXPECTATIONS.items() if observed.get(key) != expected]


def assert_no_secrets(text: str, secret_values: list[str]) -> None:
    for value in secret_values:
        if value and value in text:
            raise ValueError("a secret value would be written; refusing")


def _tls_context(cafile: str) -> ssl.SSLContext:
    context = ssl.create_default_context(cafile=cafile)
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def pinned_capabilities(host: str, port: int, cafile: str, expected_pin: str, *, connection_factory=None) -> dict:
    """1 本の TLS 接続で 証明書/hostname 検証 → DER pin 照合 → GET /v1/capabilities（鍵なし）。pin 不一致なら request を送らない。
    connection_factory は接続 I/O の差し替えだけで、TLS context は常に実 cafile から作る。"""
    context = _tls_context(cafile)
    connection = (connection_factory or http.client.HTTPSConnection)(host, port, context=context, timeout=10)
    try:
        connection.connect()
        der = connection.sock.getpeercert(binary_form=True)
        if hashlib.sha256(der).hexdigest() != expected_pin:
            raise ReadinessError("relay TLS pin does not match tls/public-metadata.json")
        connection.request("GET", "/v1/capabilities")
        response = connection.getresponse()
        response.read()
        return {"tlsVerifiedAgainstMetadataCert": True, "tlsPinMatches": True, "capabilitiesWithoutAuthStatus": response.status}
    finally:
        connection.close()


def default_http_client(headers: Mapping[str, str], timeout: float):
    import httpx
    return httpx.AsyncClient(headers=dict(headers), timeout=timeout, trust_env=False, follow_redirects=False)


async def mcp_probe(url: str, host_header: str, bridge_key: str, *, http_client_factory=None, timeout: float = 20.0) -> dict:
    """公式 SDK client で実 listener に initialize / tools/list / tools/call(echo) を往復する。鍵は header にだけ載せる。"""
    from mcp import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    factory = http_client_factory or default_http_client
    headers = {"Authorization": f"Bearer {bridge_key}", "Host": host_header}
    async with asyncio.timeout(timeout):
        async with factory(headers, timeout) as http:
            async with streamable_http_client(url, http_client=http) as (read, write, _):
                async with ClientSession(read, write) as session:
                    init = await session.initialize()
                    tools = await session.list_tools()
                    call = await session.call_tool("echo", {"text": "runner-readiness"})
                    texts = [getattr(item, "text", "") or "" for item in call.content]
                    return {"mcpInitializeOK": True, "mcpServerName": init.serverInfo.name,
                            "mcpTools": [tool.name for tool in tools.tools], "mcpEchoWithoutBindingIsError": bool(call.isError),
                            "mcpEchoErrorMentionsNoBoundDevice": any("no bound device" in text for text in texts)}


def probe_readiness(*, relay_listen: list[str], mcp_listen: str, cafile: str, expected_pin: str, bridge_key: str,
                    pinned=None, mcp=None, run=asyncio.run) -> dict:
    """手順 tls-capabilities → mcp-probe を順に実測する。失敗は ReadinessError(phase=手順名) に写し、message は
    ReadinessError ならその固定文、それ以外は例外の型名だけ（鍵などが混ざる repr を残さない）。"""
    pinned = pinned or pinned_capabilities
    mcp = mcp or mcp_probe
    observed: dict[str, Any] = {"phase": "tls-capabilities"}
    host, port = relay_listen[0].split(":")
    try:
        observed.update(pinned(host, int(port), cafile, expected_pin))
    except ReadinessError as failure:
        raise ReadinessError(str(failure), phase="tls-capabilities") from None
    except Exception as failure:
        raise ReadinessError(type(failure).__name__, phase="tls-capabilities") from None
    observed["phase"] = "mcp-probe"
    mcp_host, mcp_port = mcp_listen.split(":")
    try:
        observed.update(run(mcp(f"http://{mcp_host}:{mcp_port}/mcp", mcp_listen, bridge_key)))
    except Exception as failure:
        raise ReadinessError(type(failure).__name__, phase="mcp-probe") from None
    observed["phase"] = "complete"
    return observed


def wait_ready_line(stdout_path: Path, timeout: float) -> dict | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if stdout_path.exists():
            for line in stdout_path.read_text(errors="replace").splitlines():
                try:
                    payload = json.loads(line)
                except ValueError:
                    continue
                if isinstance(payload, dict) and payload.get("event") == "ready":
                    return payload
        time.sleep(0.2)
    return None


def stop_own_child(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(10)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -I -m relay.runner", description="start the Hermes probe relay and record readiness (diagnostic use only)")
    parser.add_argument("--secrets", required=True, type=Path)
    parser.add_argument("--tls-metadata", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--hermes-base", default="http://100.66.5.53:18642")
    parser.add_argument("--mcp-listen", default="100.102.164.56:18643")
    parser.add_argument("--relay-listen", nargs="+", default=["192.168.0.202:18644", "127.0.0.1:18644"])
    parser.add_argument("--ready-timeout", type=float, default=30.0)
    args = parser.parse_args(argv)

    metadata = json.loads(args.tls_metadata.read_text())
    attempt = create_attempt_dir(args.out, time.time)
    secrets = read_owner_only_json(args.secrets)
    secret_values = [str(v) for v in secrets.values() if isinstance(v, str)]
    write_owner_only_json(attempt / "relay-config.json", build_relay_config(
        secrets, metadata, hermes_base=args.hermes_base, relay_listen=args.relay_listen, mcp_listen=args.mcp_listen))
    bridge_key = secrets["mcpBridgeKey"]
    receipt: dict[str, Any] = {"startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "attemptDir": str(attempt),
                               "mcpBridgeKey_present": bool(bridge_key), "tlsPublicMetadata": str(args.tls_metadata),
                               "relayListen": args.relay_listen, "mcpListen": args.mcp_listen}
    del secrets

    def finish(ok: bool, extra: dict[str, Any]) -> int:
        receipt.update(extra)
        text = json.dumps(receipt, indent=1, ensure_ascii=False)
        assert_no_secrets(text, secret_values)
        (attempt / "relay-start-receipt.json").write_text(text)
        summary = json.dumps({"ok": ok, "attemptDir": str(attempt), **{k: receipt.get(k) for k in ("pid", "failure", "failedPhase", "problems")}}, ensure_ascii=False)
        assert_no_secrets(summary, secret_values)
        print(summary, flush=True)
        return 0 if ok else 1

    stdout_path = attempt / "relay.stdout.log"
    with open(stdout_path, "ab") as stdout, open(attempt / "relay.stderr.log", "ab") as stderr:
        process = subprocess.Popen([sys.executable, "-I", "-m", "relay", "--config", str(attempt / "relay-config.json")],
                                   stdout=stdout, stderr=stderr, start_new_session=True)
    try:
        ready = wait_ready_line(stdout_path, args.ready_timeout)
        if ready is None:
            raise ReadinessError("relay did not report ready within the timeout (see relay.stderr.log)", phase="ready")
        receipt.update({"ready": True, "pid": process.pid, "readyLine": ready})
        observed = probe_readiness(relay_listen=args.relay_listen, mcp_listen=args.mcp_listen, cafile=metadata["certificate"],
                                   expected_pin=metadata["pin"], bridge_key=bridge_key)
        problems = readiness_problems(observed)
        if problems:
            stop_own_child(process)
            return finish(False, {**observed, "problems": problems, "failure": "readiness expectations not met", "failedPhase": "expectations"})
    except BaseException as failure:  # 自分が起動した子だけ止める。例外 repr は書かない（秘密混入防止）。
        stop_own_child(process)
        if isinstance(failure, ReadinessError):
            return finish(False, {"failure": str(failure), "failedPhase": failure.phase or "unknown"})
        return finish(False, {"failure": type(failure).__name__, "failedPhase": "unknown"})
    finally:
        del bridge_key
    (attempt / "relay.pid").write_text(str(process.pid))
    return finish(True, {**observed, "problems": []})  # relay は常駐。停止は relay.pid へ SIGTERM。


if __name__ == "__main__":
    sys.exit(main())
