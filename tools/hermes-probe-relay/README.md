# hermes-probe-relay（開発専用診断、Mac）

iPhoneの接続プローブ（`HERMES_PROBE=1`のDebug test host）とWindows上の隔離Hermes agent APIの間に置くHTTPS relayと、Hermesへ登録する模擬端末ツール`echo`のMCP server（公式`mcp` SDK、Streamable HTTP）。実装契約は共有scratchの`windows-probe-contract-final.md` §3、検証記録は`docs/validation/2026-11-10-hermes-connection-probe.md`。

## 前提

- Python 3.12（`mcp` SDKは3.10+が必要。macOS付属の3.9.6は使えない）と uv 0.8.7。
- 依存は`uv.lock`で固定: mcp 1.30.0 / uvicorn 0.54.0 / httpx 0.28.1 / starlette 1.10.0。2.x系の`mcp`はAPIが変わるため未検証。
- venvとcacheはリポジトリ外（task scratch）に置く。

```sh
cd tools/hermes-probe-relay
UV_CACHE_DIR=<scratch>/uv-cache UV_PROJECT_ENVIRONMENT=<scratch>/venv-relay uv sync --locked
<scratch>/venv-relay/bin/python -I -m unittest discover -s tests -t .   # ポートは開かない
```

## 設定ファイル（JSON、mode 0600 必須）

`hermesBase`（http(s)、pathなし）、`relayListen`（IPv4 `host:port` の配列。loopback/private のみ、`0.0.0.0`/hostname/IPv6 不可）、`cert` / `key`（PEMのpath）、`mcpListen`（100.64.0.0/10 の IPv4 `host:port`）、`mcpBridgeKey`、`upstreamTimeoutSeconds`、`callTimeoutSeconds`、`bindingTTLSeconds`、`maxRequestBytes`、`maxResponseBytes`、`maxRunsPerProcess`、`drainPollAttempts`、`drainPollIntervalSeconds`。未知のキーは拒否する。`mcpBridgeKey`はログ・ready行・receiptに出ない（`mcpBridgeKey_present`のみ）。

## 起動（runner経由を推奨）

```sh
<scratch>/venv-relay/bin/python -I -m relay.runner \
  --secrets <0600 probe-secrets.json> --tls-metadata <tls/public-metadata.json> \
  --out <evidence dir> \
  [--hermes-base http://100.66.5.53:18642] [--relay-listen 192.168.0.202:18644 127.0.0.1:18644] \
  [--mcp-listen 100.102.164.56:18643] [--ready-timeout 30]
```

runnerは秘密ファイルをprogrammaticに読み（表示しない）、`attempt-<UTC>/`（0700）に`relay-config.json`（0600、端末APIキーを含まない）を書き、`python -I -m relay --config …`を子プロセスとして起動する。端末用bootstrapは`scripts/run_hermes_probe_device_test.py`だけが生成・配送・削除する。ready行（JSON: `pid`、`relayListen`、`mcpURL`、`mcpServerName`、`tools`、非秘密`config`）を待った後、次の手順を順に実測して`relay-start-receipt.json`に記録する。

1. `tls-capabilities`: 同一接続で証明書DERのSHA-256をmetadataのpinと照合し、`GET /v1/capabilities`（鍵なし）が401（relayとWindowsの到達）。
2. `mcp-probe`: 公式clientでinitialize（server名`mockbridge`）、tools/list（`echo`のみ）、binding無しの`echo`がtool error（"no bound device"）。
3. `expectations`: 期待値との照合。

失敗した手順は`failedPhase`（`ready` / `tls-capabilities` / `mcp-probe` / `expectations` / `unknown`）として記録し、例外本文は固定文か例外型名だけを書く。成功時はrelayを起動したままにし`relay.pid`を書く。停止は`kill -TERM $(cat relay.pid)`。runnerが停止するのは自分が起動した子だけ。

直接起動する場合: `python -I -m relay --config <0600 JSON>`（または環境変数`HERMES_PROBE_RELAY_CONFIG`）。

## Hermes側へ登録する値（親が実施）

MCP URL `http://<mcpListen>/mcp`（例 `http://100.102.164.56:18643/mcp`）、`Host`は`<mcpListen>`と一致させる（DNS rebinding保護、Originは拒否）、`Authorization: Bearer <mcpBridgeKey>`、server名`mockbridge`、tool `echo(text: string) -> string`。binding中の端末が無いときは`echo`はtool errorを返す。

## 挙動の要点

- REST: `GET /v1/capabilities`、`POST /v1/runs`、`GET /v1/runs/{id}`、`POST /v1/runs/{id}/stop`のみ転送（他は404）。転送するヘッダは`Authorization` / `Content-Type` / `Idempotency-Key`。request 64 KiB、response 1 MiB、上流15 s、redirectは502。
- 同時run: `maxRunsPerProcess`（既定1）。予約はawait前に取り、4xxの明示拒否だけ解放する。
- run作成で一度でも応答を失った場合、同じキーでの再試行が4xxでも予約を保持して`quarantined`になる。最初の要求の結果が確定したとは扱わない。
- `/bridge/*`: 毎requestの`Authorization`をcapabilities転送で検証し、鍵を保持しない。binding状態は`none → bound → submitting → running → (terminal → drained) → none`。call timeoutやMCP callerのcancelなど通信不明は`quarantined`で停止し、relayと隔離gatewayの再起動まで新しいbindは409。
- 現行bindingへの空のpollは、`quarantined`を含む非running状態でも指定された`wait`まで待つ。access logは標準loggingへ出力し、全行のメモリ内コピーは保持しない。
- `/bridge/bindings/{id}/run`（submit）は認証・body・run作成（timeout時の同一`Idempotency-Key`再送1回）を合わせた非同期処理のdeadlineを50 sとし、超えた時点で応答する（プロセス停止や同期処理の遅延は対象外）。超過時、送信済みの予約は結果不明として`quarantined`に残し、認証やbody待ちで超えた要求は状態を変えない。端末のsubmit要求予算60 s（他のbridge要求は15 s）の内側に収め、`upstreamTimeoutSeconds`を大きくしてもこの上限は変わらない（既定15 sなら再送まで予算内）。
- 期限切れbindingの後始末（stop送信とterminal確認）がsubmitのdeadlineなどで取り消された場合、その後始末が進めた`revoking`遷移を持ち主のないまま残さず、予約を保持したまま`quarantined`で閉じる（terminal未確認のfail closed）。取消はそのまま呼び出し元へ伝播し、別の持ち主に替わったbindingには触れない。
- 期限切れのresultはcall timeoutと同じ通信不明として扱う。そのcallは`expired`として記録し、残りのpending callを失効させて`quarantined`で停止する。
- TTL失効はrelayがtimerでstopできないため、認証成功後・body読取前の時計でbinding TTLをlazyに判定し、body待ち後はbinding TTLを再評価しない（絶対期限の保証ではない。callの`expiresAt`はresult受理時に別途検査する）。

## 既知事項

- 今回の実relay（PIDが一致するmacOS Application FirewallのALFログ）では、ad-hoc署名のpython3.12への受信が許可promptの応答待ちとして保留され、LAN/Tailscale宛の接続はTCP handshake後に止まった（loopbackは到達）。ユーザーがAllowした後の再検証は未実施。pairはfirewall設定を変更しない。
- `mcp` SDKはclientがsessionをDELETEで終了すると"Error in standalone SSE writer / anyio.ClosedResourceError"をログに出す（正常終了時）。
- `/healthz`は無い（allowlist外は404）。readinessはrunnerの手順記録で確認する。
