"""relay 起動（契約 r3 §3）: `python -I -m relay --config <path>`（または環境変数 HERMES_PROBE_RELAY_CONFIG）。

同一 event loop で uvicorn server を複数動かす: relay は relayListen の各 IPv4:port に HTTPS（cert/key は設定から）、
MCP は mcpListen（Tailscale IF）に HTTP。全 listener が started になったら標準出力へ 1 行だけ非秘密の ready JSON を出す。
uvicorn の signal 捕捉は server ごとに上書きし合うので無効化し、SIGINT/SIGTERM は自前で両 server の should_exit に写す。
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys

import uvicorn

from relay.app import build_relay_app
from relay.config import RelayConfig
from relay.mcpserver import build_mcp_app


class QuietServer(uvicorn.Server):
    """signal を自分で捕まえない uvicorn.Server（複数 server を 1 つの loop で止めるため）。"""

    def capture_signals(self):  # type: ignore[override]
        import contextlib
        return contextlib.nullcontext()


def _server(app, host: str, port: int, *, cert: str | None = None, key: str | None = None) -> QuietServer:
    config = uvicorn.Config(app, host=host, port=port, ssl_certfile=cert, ssl_keyfile=key, lifespan="on",
                            log_level="warning", access_log=False, server_header=False, date_header=False)
    return QuietServer(config)


def build_servers(config: RelayConfig):
    relay_app = build_relay_app(config)
    servers = [_server(relay_app, host, port, cert=config.cert, key=config.key) for host, port in config.relay_listen]
    if not config.conversation_mode:
        mcp_app = build_mcp_app(config, bridge=relay_app.state.bridge)
        servers.append(_server(mcp_app, *config.mcp_listen))
    return servers


def ready_line(config: RelayConfig) -> dict:
    if config.conversation_mode:
        return {"event": "ready", "pid": os.getpid(), "relayListen": [f"https://{h}:{p}" for h, p in config.relay_listen],
                "tools": [], "config": config.public()}
    host, port = config.mcp_listen
    return {"event": "ready", "pid": os.getpid(), "relayListen": [f"https://{h}:{p}" for h, p in config.relay_listen],
            "mcpURL": f"http://{host}:{port}/mcp", "mcpServerName": "mockbridge", "tools": ["echo"], "config": config.public()}


async def serve(config: RelayConfig, out=sys.stdout) -> int:
    servers = build_servers(config)
    loop = asyncio.get_running_loop()
    stop = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    tasks = [asyncio.create_task(server.serve()) for server in servers]
    while not all(server.started for server in servers):
        if any(task.done() for task in tasks) or stop.is_set():
            break
        await asyncio.sleep(0.05)
    if all(server.started for server in servers) and not stop.is_set():
        print(json.dumps(ready_line(config), ensure_ascii=False), file=out, flush=True)
        waiter = asyncio.create_task(stop.wait())
        await asyncio.wait([waiter, *tasks], return_when=asyncio.FIRST_COMPLETED)
        waiter.cancel()
    for server in servers:
        server.should_exit = True
    results = await asyncio.gather(*tasks, return_exceptions=True)
    failures = [r for r in results if isinstance(r, BaseException) and not isinstance(r, asyncio.CancelledError)]
    for failure in failures:
        logging.getLogger("relay").error("server task failed: %s", type(failure).__name__)
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -I -m relay", description="Cat Robot Hermes probe relay (diagnostic use only)")
    parser.add_argument("--config", default=os.environ.get("HERMES_PROBE_RELAY_CONFIG"), help="0600 JSON config path")
    args = parser.parse_args(argv)
    if not args.config:
        parser.error("--config or HERMES_PROBE_RELAY_CONFIG is required")
    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    config = RelayConfig.load(args.config)
    return asyncio.run(serve(config))


if __name__ == "__main__":
    sys.exit(main())
