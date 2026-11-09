"""relay 設定（repo 外 0600 JSON、`HERMES_PROBE_RELAY_CONFIG`）。契約 r3 §3。

`mcpBridgeKey` は repr/str/public() に出さない。未知キーと形の崩れは fail closed で拒否する。
"""
from __future__ import annotations

import ipaddress
import json
import math
import stat
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping
from urllib.parse import urlsplit

_REQUIRED = ("hermesBase", "relayListen", "cert", "key", "mcpListen", "mcpBridgeKey")
_DEFAULTS: dict[str, Any] = {
    "upstreamTimeoutSeconds": 15,
    "callTimeoutSeconds": 30,
    "bindingTTLSeconds": 600,
    "maxRequestBytes": 65_536,
    "maxResponseBytes": 1_048_576,
    "maxRunsPerProcess": 1,
    # 契約外の運用値（決定）: revoke/TTL 失効後に terminal を確認する poll 回数と間隔。
    "drainPollAttempts": 5,
    "drainPollIntervalSeconds": 1.0,
}


def _text(values: Mapping[str, Any], key: str) -> str:
    value = values[key]
    if not isinstance(value, str) or not value:
        raise ValueError(f"{key} must be a non-empty string")
    return value


_TAILSCALE = ipaddress.ip_network("100.64.0.0/10")


def _lan_or_loopback(address: ipaddress.IPv4Address) -> bool:
    return not address.is_unspecified and (address.is_loopback or address.is_private) and address not in _TAILSCALE


def _tailscale(address: ipaddress.IPv4Address) -> bool:
    return address in _TAILSCALE


def _listen(value: Any, key: str, allowed: Callable[[ipaddress.IPv4Address], bool], policy: str) -> tuple[str, int]:
    """'host:port' を解析し、IPv4 リテラルかつ policy を満たすものだけ受け付ける（0.0.0.0 / IPv6 / hostname は拒否）。
    証明書 SAN は IPv4 のみなので IPv6 は扱わない。"""
    if not isinstance(value, str) or value.count(":") != 1:
        raise ValueError(f"{key} must be 'ipv4:port'")
    host, _, port = value.partition(":")
    if not host or not port.isdigit() or not 1 <= int(port) <= 65_535:
        raise ValueError(f"{key} must be 'ipv4:port' with a port in 1..65535")
    try:
        address = ipaddress.IPv4Address(host)
    except ValueError:
        raise ValueError(f"{key} must use an IPv4 literal, not a hostname or IPv6 address") from None
    if not allowed(address):
        raise ValueError(f"{key} must bind {policy}; got {host}")
    return host, int(port)


def _positive_number(values: Mapping[str, Any], key: str, *, allow_zero: bool = False) -> float:
    value = values[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{key} must be a finite number")
    if value < 0 or (value == 0 and not allow_zero):
        raise ValueError(f"{key} must be {'>= 0' if allow_zero else '> 0'}")
    return value


def _positive_int(values: Mapping[str, Any], key: str) -> int:
    value = values[key]
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValueError(f"{key} must be an integer >= 1")
    return value


@dataclass(frozen=True)
class RelayConfig:
    hermes_base: str
    relay_listen: tuple[tuple[str, int], ...]
    cert: str
    key: str
    mcp_listen: tuple[str, int]
    mcp_bridge_key: str = field(repr=False)
    upstream_timeout_seconds: float
    call_timeout_seconds: float
    binding_ttl_seconds: float
    max_request_bytes: int
    max_response_bytes: int
    max_runs_per_process: int
    drain_poll_attempts: int
    drain_poll_interval_seconds: float

    @classmethod
    def from_mapping(cls, values: Mapping[str, Any]) -> "RelayConfig":
        if not isinstance(values, Mapping):
            raise ValueError("relay config must be a JSON object")
        missing = [key for key in _REQUIRED if key not in values]
        if missing:
            raise ValueError("missing required config key(s): " + ", ".join(missing))
        unknown = sorted(set(values) - set(_REQUIRED) - set(_DEFAULTS))
        if unknown:
            raise ValueError("unknown config key(s): " + ", ".join(unknown))
        merged = {**_DEFAULTS, **values}

        hermes_base = _text(merged, "hermesBase")
        parts = urlsplit(hermes_base)
        if parts.scheme not in ("http", "https") or not parts.netloc or parts.path or parts.query or parts.fragment:
            raise ValueError("hermesBase must be http(s)://host[:port] without path, query or fragment")

        listen = merged["relayListen"]
        if not isinstance(listen, list) or not listen:
            raise ValueError("relayListen must be a non-empty list of 'host:port'")
        relay_listen = tuple(_listen(item, "relayListen", _lan_or_loopback, "a loopback or private LAN address") for item in listen)

        return cls(
            hermes_base=hermes_base,
            relay_listen=relay_listen,
            cert=_text(merged, "cert"),
            key=_text(merged, "key"),
            mcp_listen=_listen(merged["mcpListen"], "mcpListen", _tailscale, "a Tailscale (100.64.0.0/10) address"),
            mcp_bridge_key=_text(merged, "mcpBridgeKey"),
            upstream_timeout_seconds=_positive_number(merged, "upstreamTimeoutSeconds"),
            call_timeout_seconds=_positive_number(merged, "callTimeoutSeconds"),
            binding_ttl_seconds=_positive_number(merged, "bindingTTLSeconds"),
            max_request_bytes=_positive_int(merged, "maxRequestBytes"),
            max_response_bytes=_positive_int(merged, "maxResponseBytes"),
            max_runs_per_process=_positive_int(merged, "maxRunsPerProcess"),
            drain_poll_attempts=_positive_int(merged, "drainPollAttempts"),
            drain_poll_interval_seconds=_positive_number(merged, "drainPollIntervalSeconds", allow_zero=True),
        )

    @classmethod
    def load(cls, path: str | Path) -> "RelayConfig":
        path = Path(path)
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            raise ValueError(f"relay config {path.name} must be mode 0600 (owner only); found {mode:04o}")
        try:
            values = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise ValueError(f"relay config {path.name} is not valid JSON: {error.msg}") from None
        return cls.from_mapping(values)

    def public(self) -> dict[str, Any]:
        """receipt / ログ向けの非秘密ビュー。鍵は在否の真偽値だけ。"""
        return {
            "hermesBase": self.hermes_base,
            "relayListen": [f"{host}:{port}" for host, port in self.relay_listen],
            "cert": self.cert,
            "key": self.key,
            "mcpListen": f"{self.mcp_listen[0]}:{self.mcp_listen[1]}",
            "mcpBridgeKey_present": bool(self.mcp_bridge_key),
            "upstreamTimeoutSeconds": self.upstream_timeout_seconds,
            "callTimeoutSeconds": self.call_timeout_seconds,
            "bindingTTLSeconds": self.binding_ttl_seconds,
            "maxRequestBytes": self.max_request_bytes,
            "maxResponseBytes": self.max_response_bytes,
            "maxRunsPerProcess": self.max_runs_per_process,
            "drainPollAttempts": self.drain_poll_attempts,
            "drainPollIntervalSeconds": self.drain_poll_interval_seconds,
        }
