# Hermes 移行①: 接続プローブ（文字往復・取消・模擬端末ツール）

基点: `4bda92b44340267d605aea4143250dd6b1a6fd60`（②の確定コミット、PR #34）。ブランチ: `feat/hermes-connection-probe`。①のPRは②に依存するstacked PRとして親が作成し、mainへのmergeは行わない。実装契約は共有scratchの`windows-probe-contract-final.md`（r3）。

この記録は3種類の結果を区別する。(1) Simulator単体試験と Mac上のrelay単体/公式MCP client統合試験は完了し成功。(2) 実機は署名付きDebug build-for-testingまで成功、install/launch/非通信host試験は本文末尾の「最終候補の検証」に記す。(3) Windows Hermes実エージェントとの実通信（lifetime 1/2）は未実施で、Macへの受信許可待ちのため**pending**。既定でskipされる試験を統合の合格とは扱わない。

## 変更範囲

- 起動分岐: `CatRobot/App/CatRobotApp.swift`。DEBUGの`init(environment:)`で`HERMES_PROBE=1`のとき会話composition（camera/mic/BLE/音声）を生成せず、静的な`HermesProbeHostView`だけを表示する。Release経路は不変で、Release artifactにHermes symbol・`HERMES_PROBE`文字列・開発キー資源は含まれない（R7 artifact checks）。
- iPhone側 `CatRobot/Hermes/`: `HermesProbeTypes`（設定・資格情報・HTTP型・固定エラー）、`HermesServerTrustPolicy`（DER SHA-256 pin、SecTrust評価、拒否理由はOSStatus codeのみ）、`PinnedURLSessionTransport`（redirect非追従、challengeはpin評価、Basic等は既定）、`HermesCredentialStore`（Keychain actor、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、service `com.kamby.CatRobot.hermes-probe`）、`HermesBootstrapImporter`（0600 bootstrapの鍵をKeychainへ保存し、ファイル削除（2回試行）が成功した後に非秘密設定を保存する。削除に失敗したら保存した鍵を削除してrollbackし、呼出元は停止する）、`HermesRunClient`（capabilities / createRun / state / stop / awaitTerminal）、`HermesBridgeClient`（bind / submitRun / pollCalls(wait) / process / revoke / cancel）、`MockDeviceToolExecutor`（`echo`のみ、純粋関数）、`HermesProbeHostView`。
- 試験 `CatRobotTests/Hermes/`（8クラス、fake transport、ネットワーク無し）と `CatRobotTests/Device/HermesProbeDeviceTests.swift`（opt-in専用。`HERMES_PROBE=1`と有効な`HERMES_PROBE_RUN_ID`/`HERMES_PROBE_STAGE`が無ければXCTSkip）。
- Mac側 `tools/hermes-probe-relay/`: `relay`パッケージ（config / upstream / admission / bridge / mcpserver / `__main__` / runner）、`tests/`、`pyproject.toml`、`uv.lock`（mcp 1.30.0 / uvicorn 0.54.0 / httpx 0.28.1 / starlette 1.10.0、hatchling 1.27.0）。運用手順は`tools/hermes-probe-relay/README.md`。
- 実機runner `scripts/run_hermes_probe_device_test.py` と `scripts/test_run_hermes_probe_device_test.py`（stdlibのみ。relay/gatewayの起動・再起動はしない）。
- R7: `CatRobot/Resources/Info.plist`に`NSLocalNetworkUsageDescription`、`scripts/test_generate_project.rb`に文言のassert、`README.md`に開発専用診断の説明。
- 共有scratch `cat-impl-20261110/step1/`に全段階のreceipt（command、HEAD、入力manifest前後のSHA-256、exit、ログ）。失敗・中断・除外したattemptも別名で保存し、上書きしていない（例外: `relay-rest-green`以前の2回の中断/失敗attemptはraw receiptが残っておらず、`progress.md`の記述のみ。後述）。

## 境界

- 秘密: 専用APIキーは0600 bootstrapから端末Keychainへ入り、ファイルは取り込み後に削除される。`mcpBridgeKey`はMac/Windowsだけが持ち端末へ渡さない。relayは端末の`Authorization`をそのままWindowsへ転送し、鍵・hash・tokenを保持しない。receiptには`key_present`等の真偽値だけを書き、例外本文は固定文または例外型名に限る。
- TLS: relay証明書はnamed-curve P-256、有効2日、SANは`IP:192.168.0.202`・`IP:127.0.0.1`・`DNS:localhost`（`tls-named/`、pinは`tls/public-metadata.json`が正本。`openssl x509 -ext subjectAltName`で実測）。端末は同一接続でDER pinを照合し、不一致は接続しない。
- 実機は非駆動: probe hostは会話composition・camera・mic・BLE・音声を生成しない。実機runnerはxctestrunの`EnvironmentVariables`で起動前に`HERMES_PROBE=1`を注入する（既存の`scripts/run_supertonic_integration_device_test.sh`と同じ方式）。
- relay admission: `maxRunsPerProcess=1`、bindingは`none→bound→submitting→running→(terminal→drained)→none`、不明状態は`quarantined`で停止。再検証はrelayと隔離gatewayの再起動。

## 自律判断と理由

| 不明点・選択 | 決定 | 理由 / 証拠 |
|---|---|---|
| `mcp` SDKの版 | 1.30.0に固定 | 2.xは`FastMCP→MCPServer`改名・`streamablehttp_client`削除などAPIが変わり未検証（`step1/relay-env/receipt.json`） |
| Pythonランタイム | 既存の`~/.local/bin/python3.12`（3.12.11）+ uv 0.8.7、venvとcacheはtask scratch | `/usr/bin/python3`は3.9.6でSDK要件を満たさない。ユーザーグローバルへ追加しない |
| `/healthz` | 置かない | 契約の「allowlist外は全て404」を優先。readinessはrunnerの手順実測（`failedPhase`）で代替 |
| TTL失効 | 認証成功後・body読取前の時計でbinding TTLをlazy判定し、body待ち後は再評価しない（callの`expiresAt`はresult受理時に別途検査） | relayは鍵を持たずtimerでstopできない。MCP側で失効を見たらpendingをerrorにしてquarantined。絶対期限の保証ではない（親cycle1 RELAY-S01、非blocking） |
| call timeout / MCP callerのcancel / 期限切れresult | bindingをquarantined | 通信不明はfail closed。契約の"device timeout" tool errorより強い側へ倒す。期限切れresultも同じ扱い（親cycle1 RELAY-001） |
| submitの外側予算 | relayは認証+run作成2回を50 sの非同期deadlineで打ち切り、端末はsubmit要求だけ60 s（他のbridge要求は15 s） | 親cycle1 RELAY-002。端末15 sに対しrelayが最大45 s要し、端末がinvalidateした後にrelayだけrunningへ進む不整合を解消。`upstreamTimeoutSeconds`に依存しない固定上限で、許容設定の穴を残さない |
| run作成失敗時の予約 | 4xxの明示拒否だけ解放 | 5xx/3xx/transport/読めない2xxはrunが作られていないと言えない（races受領） |
| `revoke`の応答 | 200 `{state}` | 端末が結果を記録できるように |
| listen形式 | IPv4リテラルのみ、relayはloopback/private、MCPは100.64/10 | 証明書のIP SAN（192.168.0.202 / 127.0.0.1）に合わせ、端末はIPリテラルで接続する設計判断。hostname/IPv6/0.0.0.0は拒否 |
| `drainPollAttempts` / `drainPollIntervalSeconds` | 設定キー追加（既定5 / 1.0） | revoke/TTL後のterminal確認回数を有限にする |
| R7の置き場所 | 共有`Info.plist`（Releaseにも宣言）+ READMEに開発専用の説明 | `GENERATE_INFOPLIST_FILE=NO`のためDebug限定build settingは生成`.app/Info.plist`に反映されないことを両構成で実測（`r7-*-setting-artifact`）。契約§4.4のfallbackを採用し、不活性な設定とそのassertは削除 |
| Keychain試験の署名 | Simulatorでも`CODE_SIGNING_ALLOWED=YES`（ad-hoc） | 未署名では`-34018 missing entitlement`（`credentials-red`→`credentials-signed-red`） |
| iOS TLS fixture | 有効期間300日のv2 fixtureへ更新 | 10年fixtureは`-67901 errSecCertificateValidityPeriodTooLong`（`tls-ios-diagnosis`）。日数の限度は断定しない |
| 実機の資格情報受け渡し | `devicectl device copy to`でDocumentsへ0600 bootstrap、app側で取り込み後に削除 | 端末へはbootstrap経由のみ。Mac側のコピーはrunnerの`finally`で削除。残った可能性は`deviceBootstrapMayRemain`として記録し、認証や既存データに影響するapp uninstallはしない |
| 実機runの外側timeout | 600 s/test、900 s/command | 内部deadline（capabilities 15 s×3、plain 120 s、bound submit 60 s、call 60 s、boundTerminal 120 s）の総和を超える値 |
| 旧Cat_robotの保存メモ/履歴 | 触らない | 削除は許可だが必須ではなく、①の範囲外 |

## TDDと受領記録（Simulator / Mac）

専用Simulator: `32623B53-C27C-480C-8478-3F277BAE8431`（iPhone 17 Pro / iOS 27.0）。各段階はstubで意味のある失敗（assertion）を先に実測し、最小実装でGREENにした。各xcodebuild/unittestの前後で入力manifestのSHA-256が不変であることをreceiptに記録している。表の数値は該当receiptの実測値。

| 段階（Swift） | RED | GREEN |
|---|---|---|
| 配線・起動分岐（`red1`/`green1`、`wire-runtime-red`/`wire-green`） | 期待assertion failure | exit 0 |
| run clientのterminal判定順序（`terminal-order-red-2`） | 17 tests / 1 failure（deadlineExceeded(lastStatus: completed)） | `terminal-order-green` |
| TLS pin / SecTrust（`tls-policy-red`） | 8 tests / 7 failures | `tls-policy-green` 25/25 |
| pinned transport（`transport-red`） | 7 tests / 6 failures | `transport-green` 32/32 |
| Keychain（`credentials-red`: 未署名で-34018 → `credentials-signed-red`） | 4 tests / 7 failures | `credentials-green` 4/4 |
| bootstrap取り込み（`bootstrap-red`） | 8 tests / 29 failures | `bootstrap-green` |
| mock executor（`mock-red`） | 3 tests / 5 failures | `foundation-green` 47/0/0 |
| host seam（`host-red`） | 3 tests / 3 failures | `host-green` 50/0 |
| bridge client（`swift-bridge-red` 12/46、順序試験追加 `swift-bridge-order-red` 13/50） | — | `swift-bridge-green`はコンパイルエラーで除外、`swift-bridge-green2` 13/0 |
| 統合aggregate | — | `bridge-host-foundation-frozen-green` 63/0/0（`bridge-host-foundation-green`はgenerator並走のため除外） |
| 実機harness stub（`diagnostic-host-red`） | 1 test / 1 failure、exit 65（起動前envを注入した専用Simulatorで明示未実装） | `hermes-offline-harness-compile` 64 tests / 1 skipped（opt-in無しのHermesProbeDeviceTests）/ 0 failures |

| 段階（Python relay、`tools/hermes-probe-relay`） | RED | GREEN |
|---|---|---|
| config + REST proxy（`relay-rest-red`） | 17 tests / 15 failures | `relay-rest-green` 17/0 |
| bridge状態機械（`relay-bridge-red`） | 45 / 29 failures + 1 error | `relay-bridge-green` 45/0 |
| Navigator指摘の回帰（`relay-bridge2-red`） | 48 / 4 failures + 1 error | `relay-bridge2-green` 48/0 |
| 競合・境界（`relay-races-red`、Codex） | 55 / 9 failures | `relay-races-green` 55/0、`relay-boundary-green` 55/0 |
| MCP server + 公式client（`relay-mcp-red`、attempt 1〜3は別名保存） | 8 / 7 failures / 0 errors | `relay-mcp-green` 8/0、`relay-all-green` 63/0 |
| launcher（`relay-main-red`） | 2 / 2 failures | `relay-main-green` 2/0、`relay-all-green2` 65/0 |
| runner（`relay-runner-red`） | 9 / 8 failures + 1 error | `relay-runner-green` 9/0、`relay-runner-green2` 11/0 |
| runnerの手順記録（`relay-runner-phase-red`） | 10 / 1 failure | `relay-runner-phase-green` 10/0、`relay-all-green5` 75/0/0（入力 `a2b71a6b…`） |

| 段階（実機runner / R7） | RED | GREEN |
|---|---|---|
| `scripts/run_hermes_probe_device_test.py`（`device-runner-red`） | 6 / 6 failures | `device-runner-green` 6/0 |
| bootstrap後始末・`bootstrapRemoved`必須（`device-bootstrap-cleanup-red`） | 7 / 2 failures | `device-bootstrap-cleanup-green` 7/0 |
| R7 generator（`r7-generator-red`） | contract exit 1 | `r7-generator-green` exit 0 |
| R7 artifact実測（`r7-debug-setting-artifact` / `r7-release-setting-artifact`） | 両構成とも生成`.app/Info.plist`にkey無し | fallback `r7-fallback-red`→`r7-fallback-green`、`r7-debug-final-artifact` / `r7-release-final-artifact`に文言あり、`r7-artifact-checks.json`でReleaseにHermes symbol/`HERMES_PROBE`文字列/開発キー資源が無いこと、`r7-final-contract` exit 0 |

早期2回の中断/失敗attempt（`relay-rest-green`以前: hang、User-Agent漏れ）はraw receiptが残っていない（`progress.md`の記述のみ）。以後の全attemptは別名で保存している。

## 契約§6の仮定と実測

1. Hermes MCP client ↔ 公式SDK FastMCP streamable-httpの相互運用: 公式`mcp` 1.30.0のclientでinitialize / tools/list / tools/callを確認（`relay-mcp-green`、runnerの`mcp-probe`手順）。Windows gatewayからの接続と「起動時1回tools/list」の仮定は親のMCP登録後まで未確認。
2. SimulatorからLAN IPへの接続はローカルネットワーク許可の対象外という仮定は未検証（実通信未実施）。実機には許可ダイアログが要る前提で`NSLocalNetworkUsageDescription`を置いた。
3. `/bridge`認証は毎requestのcapabilities転送のみで、鍵/hash/tokenを保存しない（`relay-bridge-green`、`test_bridge.py`）。
4. `maxRunsPerProcess=1`と2 lifetime構成を実装（`relay-races-green`）。
5. Python: `/usr/bin/python3`は3.9.6のため、既存の`~/.local/bin/python3.12`（3.12.11、uv管理）を使用。Homebrew python3は採用しなかった。
6. 変更ファイルは契約の見込みどおり。実機runnerはshellでなくstdlib Pythonにした（xctestrunのplist編集と受領検証を単体試験するため）。

## relayの到達性とMac受信許可

実listenerを`relay.runner`で起動すると、ready行（PID、listen先、`mcpURL`、server名`mockbridge`、tool `echo`、非秘密設定）が出て、loopbackのhttpsはHermes経由で401、DER pinは`tls/public-metadata.json`と一致した。一方LAN `192.168.0.202:18644`とTailscale `100.102.164.56:18643`へはTCP handshake後にアプリケーションデータが流れず、cross-processのaccept()が未配送になることをraw asyncio / uvicorn http / uvicorn https / 任意portで再現した（`step1/relay-run/diag-20261109T195134Z-inbound/RESULTS.md`）。親が読んだ構造化ALFログは実relayのPIDと一致し、`python3.12`への許可prompt応答待ちでflowが保留されていることを示した（`parent-alf-runtime-evidence.json`）。初期診断の「allow list未掲載で遮断」という表現は`CORRECTION.md`で置き換えた。pairはfirewall無効化・SSH制限変更・TLS弱体化・転送迂回を行わず、当該pythonへの限定的な受信許可はユーザーの判断に委ねている。許可後の到達性は未検証。

## 完成判断と未確認事項

- Simulator単体・relay単体/公式client統合: 本文の表のとおり成功。最終候補の全suite結果と入力digestは末尾の「最終候補の検証」に記す。
- 実機: 署名付きDebug build-for-testingは成功（`physical-offline-build`、`physical-codesign-check-trusted`。sandbox内のcodesign検証は`CSSMERR_TP_NOT_TRUSTED`で、通常環境での再検証がexit 0。keychain/証明書は変更していない）。install/launch/非通信host試験の結果は末尾に追記する。
- Windows実エージェントとの往復（lifetime 1/2）: 未実施。Mac受信許可 → `mcp-ready` → 親のMCP登録とready ACK → 実行、の順。許可が得られない場合は親の指示どおり、明示的に未完了のDraft PRとし、検証済みと主張しない。
- commit/push/PR: 親のWindows ghが②依存のstacked PRとして作成する。pairはgh認証に触れない。mainへのmergeは行わない。

## 最終候補の検証（2026-11-09T20:14Z〜20:23Z）

入力manifestは「git管理下と未追跡の非ignoreファイル全部（開発キー資源`CatRobot/LocalAssets/claude-api-key.txt`のみ除外）」のSHA-256。各段階は逐次実行し、前後でmanifestが不変であることをreceiptに記録した（`step1/final-*/receipt.json`）。本節と「独立レビューと採否」の追記は文書のみの変更で、文書（`docs/`、`README.md`、`tools/hermes-probe-relay/README.md`）を除いたcode-scope digest `e603cd137b939b74d6788f32a6409e73ca12b7e6337f3471d02c2fa0e0b2949a`は以下の全段階で同一である。凍結manifest（全体digest、変更/未追跡ファイル一覧、tracked diffのSHA-256、receipt一覧）は`step1/candidate-freeze.json`。

| 段階 | 入力manifest | 結果 |
|---|---|---|
| `final-generator-contract`: `ruby scripts/test_generate_project.rb` | `391af6d0…` | PASS、exit 0、前後一致 |
| `final-relay-suite`: `python -I -m unittest discover -s tests -t .`（mcp 1.30.0 venv） | `391af6d0…` | 75 tests OK、exit 0 |
| `final-runner-unit`: `scripts/test_run_hermes_probe_device_test.py` | `391af6d0…` | 7 tests OK、exit 0 |
| `final-swift-suite`: 全Simulator suite、`CODE_SIGNING_ALLOWED=YES`、Simulator `32623B53-…`（20:15:34〜20:18:52Z） | `391af6d0…` | 1108 tests、5 skipped、0 failures、exit 0 |
| 文書のみの訂正（importer順序、SAN実測、初期attempt例外、ALF記述）→ 入力 `a51168e7…`（942 files） | — | code-scope digest不変、差分は本書とrelay READMEの2ファイル |
| `final-physical-build`: Debug device `build-for-testing`、物理 `00008140-000610311A90801C` | `a51168e7…` | exit 0、built Info.plistに文言あり。`codesign --verify --deep --strict` exit 0（Apple Development → WWDR → Apple Root、`final-physical-codesign.json`） |
| `final-device-offline-host`: 実機でinstall/launch、xctestrun `EnvironmentVariables`に`HERMES_PROBE=1`のみ注入、`OnlyTestIdentifiers`=HermesProbeHostTests 3 + MockDeviceToolExecutorTests 3（20:20:51〜20:21:33Z） | `a51168e7…` | 6 tests、0 failures、exit 0。iOS 27.3、tunnel connected/paired、DDI true、developer mode enabled。install前後とも`com.kamby.CatRobot` 1.0の開発ビルド1件（uninstallなし）。秘密・relay・gateway不使用 |
| `final-release-artifact`: Release Simulator `build`（`CODE_SIGNING_ALLOWED=NO`） | `a51168e7…` | exit 0。artifact check（`final-artifact-checks/release-simulator.json`）: Hermes symbol 0、`HERMES_PROBE`文字列なし、開発キー資源なし、`NSLocalNetworkUsageDescription`あり |
| Debug artifact check（Simulator / device） | 同上 | Hermes symbolは`CatRobot.debug.dylib`（419）とテストバンドルのみ、主実行ファイルは0。`HERMES_PROBE`文字列あり、開発キー資源は空のplaceholder（0 bytes）、文言あり |

skipped 5件は明示opt-inが必要な`ClarificationHistoryModelTests.testAcceptanceMatrix`、`HaikuAddressingModelTests.testAcceptanceMatrix`、`RobotMotionIntegrationDeviceTests.testSelectedStage`、`SupertonicIntegrationDeviceTests.testSelectedStage`と、本変更の`HermesProbeDeviceTests.testSelectedStage`（relay/Windowsの実通信がないためskip）。skipを統合の合格とは扱わない。

実機の結果は「署名付きDebug test hostのbuild・install・起動と、非通信の6件」の確認である。`HERMES_PROBE`環境変数は起動前にxctestrunで注入し、host seam試験はcomposition=nilの分岐を確認した。Windows Hermes実エージェントとの往復（契約§4.3 lifetime 1/2）と、Mac受信許可後のrelay到達性は未実施のままである。

## 独立レビューと採否（修正後候補）

初回候補`583db6d5…`に対し、Codexの新しい独立レビュアー1名と、実際のClaude `/simplify` report-onlyの4観点（再利用・簡素化・効率・Altitude）を実施した。初回本文とhashは`step1/review/`に保存し、修正で上書きしない。Codex初回はCritical 0 / Important 1 / Minor 2。Claudeの重複を整理したImportant指摘は5系統。全指摘の採否・重複・理由は`step1/review/codex-receiving.md`と`claude-receiving.md`に記録した。

| 指摘 | 採用した修正 |
|---|---|
| run作成のtimeout後、同じキーでの再試行が4xxだと予約を解放していた | 最初の要求の結果不明を保持し、再試行の4xxでは予約を解放せずquarantine。400/401/409/429、遅延echo、次のplain/bound拒否を試験。初回の明確な4xx拒否での解放と、replayed 202での回収は維持 |
| relay runnerが未使用の端末APIキーbootstrapを作成していた | 生成処理・`--device-id`・receiptのbootstrap欄を削除。端末runnerだけが生成・配送・削除する。過去のtask-owned未使用コピー1件も内容の読取・hash化をせず削除し、元receiptと注記を保持。元の秘密ファイルは保持 |
| quarantined後の空pollが即時に返り、端末が再pollを連打する | 現行bindingへの空pollは非running状態でも指定waitを守る。r3の空200応答は維持 |
| access log全件のメモリ内保持 | 標準loggingだけを使用。既存の秘密非出力試験を`assertLogs`で出力に対して実行し、refactor前後の成功を確認 |
| Starlette既定のHEAD受理と末尾slash redirect | 暗黙HEADを除き、slash redirectを無効化。allowlist外は404、上流へ転送しない |

Swiftの共通sender抽出とadmission状態の全面統合は、現在の不具合を示す指摘ではなく保守提案と評価し、今回は採用しなかった。初回レビュー当時は両clientの実効timeoutが15秒で同一、slash escapeの違いはJSONの値として等価、statusやqueryの違いは操作ごとの契約による。RunAdmissionの全run占有とBridgeの端末binding状態は別の責務として維持し、確認できた回復判定の問題を局所修正した。

残るMinorとして、Swiftの1 MiB制限は**全受信後の受理上限**であり、転送量やメモリ使用量を1 MiBに抑える仕組みではない。relayは転送するREST応答を制限するが、bridgeが生成するcalls応答は別途サイズ制限していない。現在の隔離・pin付き診断とUUID echoの範囲では受信中の制限導入を延期し、この限界を残す。実機でメモリ上限を検証したとは主張しない。

修正はrelayとその試験・運用文書に限定した。`review-boundaries-red`は80 tests / 12 assertion failures / 0 errors（production未変更）、`review-boundaries-green`は79 tests / 0 failures（旧bootstrap生成の試験1件を削除）、ログrefactor後の`review-relay-final`も79 / 0。`review-generator-contract`はexit 0、`review-device-runner-unit`は7 / 0。すべて逐次実行し入力前後一致。Swift・Xcode project・端末runner・関連資産の入力が先の全suite/実機/Release試験から不変であることは`step1/review-scope-equivalence.json`に記録し、それらの試験を再実行したとは扱わない。修正後manifestは`step1/candidate-review-fixes-freeze.json`。

同じCodex独立レビュアーとClaude Navigatorが修正後候補を限定再確認し、Importantの解消と新規Critical/Importantなしを確認した（`step1/review/codex-followup.md`、`claude-reverify.md`）。Claudeの追加Minorであるrelay runner冒頭の古いCLI/bootstrap説明も訂正し、`review-relay-doc-final`で79 / 0を再確認した。最終の提出manifestとpatchは`step1/candidate-review-ready-freeze.json`と`step1/review-ready-candidate.patch`。

Windows実エージェントとの実通信は引き続きpendingである。親の最終gateを経て、受信許可待ちのままなら未完了のDraft PRとして提出する。

## 親の最終独立レビュー（cycle 1）と修正

親の独立レビュー（`parent-independent-review-fix-cycle1.md`、`parent-independent-relay-verdict.json`）はSwift/project側26 fileを静的にpassとし、relayにP2の論理不具合2件を確定した。候補`0adefa43…`（patch `3a33cf0f…`）を基線に、いずれも本番コードを変える前にlocked Mac（`step1/relay-env/venv-relay`、Simulator `32623B53…`）で挙動のREDを実測してから最小修正した。親のWindows補助テスト（Python 3.14 / starlette 1.9）はcanonicalな合格とは扱わない。

| 指摘 | RED（本番未変更） | 修正 | GREEN |
|---|---|---|---|
| RELAY-001: 期限切れresultの処理順でquarantineを回避し、後続callを配送していた | `cycle1-r001-red`: 2 tests / 2 failures（`'running' != 'quarantined'`）/ 0 errors。FakeClockで2件pending→期限超過→1件目のresultの決定順序 | `post_result`の期限切れ分岐で、そのcallを`expired`として記録した後にcall timeoutと同じ`_quarantine("device timed out")`を呼び、残りのpendingを`failed`で失効、410応答に`state`を付加 | `cycle1-r001-green` 2 / 0、`cycle1-r001-full` 80 / 0 |
| RELAY-002: 端末のsubmit要求15 sに対し、relayは認証15 s + run作成15 s × 2を要し、端末がinvalidateした後にrelayだけrunningへ進む | relay `cycle1-r002-relay-red`: 3 tests / 2 failures（外側deadline 1.21 s not < 0.5、認証段階 0.20 s not < 0.15）/ 0 errors。`cycle1-r002-contract-red`は新定数のImportError 1 error（挙動REDとは別記録）。Swift `cycle1-r002-swift-red`: HermesBridgeClientTests 14 tests / 2 failures（submit timeout 15 ≠ 60、50超でない）、exit 65、入力不変 | relay: `SUBMIT_DEADLINE_SECONDS = 50`（認証15 + run作成15 × 2 + 余裕5）。`submit`は認証・body・run作成を`asyncio.timeout`の非同期deadlineで囲み、`_SubmitProgress`でこの要求が予約した後だけ`quarantined`（予約保持）、認証/body段階の超過は状態不変で504。`upstreamTimeoutSeconds`に依存しない固定上限。Swift: `HermesBridgeClient.submitRequestTimeout = 60`をsubmitRunだけに渡し、他のbridge要求は15 sを維持 | relay: `cycle1-r002-relay-green` 4 / 0、`cycle1-r002-relay-full` 84 / 0、Navigator要望のcoverage 2件（running bindingを壊さない重複submit、body待ちもdeadline内）追加後`cycle1-r002-relay-coverage` 86 / 0。Swift: `cycle1-swift-clean-green` 14 tests / 0 failures、exit 0、入力`73ead884…`不変 |
| RELAY-S01（非blocking）: binding TTLの意味 | — | 現行のlazy判定を明文化: 認証成功後・body読取前の時計でbinding TTLを判定し、body待ち後は再評価しない（callの`expiresAt`はresult受理時に別途検査）。絶対期限を保証したとは書かない。実装変更なし | — |

遅延同一`Idempotency-Key`回復のregression（遅い認証 + 初回run作成をupstream timeoutまで遅延 + 再送202がdeadline内でrunIDを返す）は修正前後とも通過する監視試験として追加した。契約r3には§2.3の15 s例外（submitのみ60 s）と§3のsubmit 50 s deadlineをr3.1として追補した。

自己発見の残余（非blocking・未修正）: plain REST経路（`POST /v1/runs`の転送、再送なし）は端末`HermesRunClient`の15 sとrelayのupstream 15 sが同値で、受理が15 s直後に届くと端末はrunIDを得られずrelayのadmissionはterminal観測までbusyのまま残り得る。今回は親のscope（bridge submit）外として事実とscope外の理由だけを記録し、実通信未確認とは区別する。区別すべき点として、runIDが判明している場合は端末またはrelay経由の`GET /v1/runs/{id}`でterminalを観測すればrelayのadmissionは解放されるが、runIDの無い未確定の予約（応答喪失や読めない受理）はその経路では解放できず、relayと隔離gatewayの協調再起動が必要である。端末側のrunnerはplain段階の失敗で停止し、成功と報告したり別のrunを盲目的に投入したりしない（親CYCLE1-S01）。

Swift変更に伴い、先のfull suite・署名付き実機6件・Release artifactのreceiptを新入力の証拠として流用せず、以下のとおり再実行した。最終提出manifestは`step1/cycle1-candidate-freeze.json`、patchは`step1/cycle1-review-ready.patch`、変更ファイルのhash一覧は`step1/cycle1-patch-manifest.json`に記録する。

`cycle1-r002-swift-green`はdefault引数で`Self`を使ったコンパイルエラー（修正済み）、green2/green3/green4は既存framework削除scriptと増分CodeSignの順序によるbuild失敗で、いずれもテスト未実行。`cycle1-r002-contract-red`のImportErrorとともにsetup失敗として保持し、挙動RED/GREENには数えない。親の追加指示に従って作業用Simulator DerivedDataの`Build`だけを一度削除し（`cycle1-fresh-build-cleanup.json`）、同一ソースのfresh buildで14件のGREENを確認した。Logs/xcresult・SourcePackages・全証拠を保持し、generatorや署名要件は変更していない。既存の増分build順序問題を解決したとの主張はしない。

追加coverageとして、認証待ちの要求Aが期限切れになる時点で別の要求Bがsubmitting中でも、AがBの予約をquarantineせずBはrunIDを受け取れる試験を追加した。body待ち試験には、deadline処理の退行時にテスト全体が永久待機しないようテスト側の上限も設定した。これらは修正後の回帰監視であり、新たな挙動REDとは扱わない。


### cycle 1 最終検証

| 段階（`step1/`配下） | 結果 |
|---|---|
| `cycle1-relay-final` | locked Mac relay/MCP suite 87 tests、0 failures / 0 errors、exit 0。relay入力`0f6fb7d8…`前後一致 |
| `cycle1-generator-contract` | deterministic project契約 PASS、exit 0、生成前後の入力一致 |
| `cycle1-device-runner-unit` | 端末runner 7 tests、0 failures、exit 0 |
| `cycle1-swift-suite`（21:49:54〜21:53:05Z） | 全Simulator suite 1109 tests、5 opt-in skips、0 failures、exit 0。署名あり |
| `cycle1-physical-build`、`cycle1-physical-codesign.json` | 接続iPhone向けDebug build-for-testing、通常署名の検証ともにexit 0 |
| `cycle1-device-offline-host`（21:54:11〜21:54:28Z） | 修正後の署名付きtest hostをinstall/launch、host 3 + pure mock 3の6件が成功。iOS 27.3、connected/paired、DDIあり。起動前`HERMES_PROBE=1`のみ、秘密・relay・gateway不使用 |
| `cycle1-release-artifact` | Release Simulator build、exit 0 |
| `cycle1-artifact-checks/` | ReleaseはHermes symbol 0、`HERMES_PROBE`文字列・開発キー資源なし。Debug Simulator/deviceは診断コードあり、開発キーは0-byte placeholder。3成果物とも用途説明あり |

relay以外の上表コマンドの全入力manifestは`c45b00831e6d533999e8f2692c7d6fcd3b0e48234c6f345e3c2a7b2a16490123`で、各段階の前後一致を確認した。すべて直列実行し、本節の文書追記を除く最終候補との入力同一性は`cycle1-final-scope-equivalence.json`に記録する。前述の5件のskipは実通信の成功ではない。今回の実機6件も非通信host/mockの確認であり、Windows実エージェントとのlifetime 1/2は未実施のままである。

候補は親によるfocused再レビュー待ち。過去の独立初回レビュー・失敗試行・旧freezeは保持する。更新候補のpair限定追認は`step1/review/codex-cycle1-followup.md`と`claude-cycle1-reverify.md`に別保存する。commit/pushは親のGO後、PRは親が未完了Draftとして作成し、mergeしない。

## 親の独立再レビュー（cycle 2）と修正

cycle 1候補`19d357c3…`（patch `42f58176…`）に対する親の独立再レビュー（`parent-independent-review-fix-cycle2.md`、`parent-cycle1-independent-verdict.json`）は、RELAY-001と元のRELAY-002予算不整合を静的に解消と判定しつつ、新たなP2 RELAY-003で全体をFAILとした。security findingはない。これは自動fix cycleの2回目（最後）であり、次に未解決のblockerが出た場合は修正を続けず親の判断へ上げる。

RELAY-003: submitの非同期deadlineは、この要求が予約を取る前に走る`_expire_if_due`→`_tear_down`も包んでいた。期限切れのrunning bindingでは`_tear_down`がgenerationを進め、pending callを失効させ、`revoking`にしてからstop送信とterminal確認をawaitする。そこでdeadlineに取り消されると、未予約のためsubmitの取消処理は何もせず504 `state=revoking`を返し、遷移を完了させるtaskが無いまま`revoking`が残る（revokeは即return、`observe_run_state`はrunningのみ扱い、新しいbindは`busy`のまま）。既定値でも認証→stop 15 s→遅いstatus pollで50 sに到達し得る。

| 項目 | 内容 |
|---|---|
| RED（本番未変更、locked Mac in-process） | `cycle2-r003-red`: 4 tests / 4 failures、すべて意図したassertion failure `'revoking' != 'quarantined'`、0 errors、harness timeoutなし（relay入力`4cef4f59…`）。境界: (a) stop送信をholdして待ち中、(b) stop 202後の`GET /v1/runs/{id}`をholdしてterminal確認待ち中、(c) `drainPollAttempts=2` / 0.5 sで非terminal応答後のsleep中（いずれもsubmit deadline 0.05 s、`wait_for(…, 1)`のbounded harness、期限切れrunning binding＋pending echo）、(d) `_tear_down`をtaskとして直接cancel（seam） |
| 修正 | `_tear_down`でrun IDとこのtear-downが進めたgenerationを捕捉し、stop送信とterminal確認のawaitを`asyncio.CancelledError`で捕捉する。`self.binding is binding`かつ`state == "revoking"`かつgeneration一致のとき（この要求が所有する遷移）だけ既存の`_quarantine("binding teardown interrupted")`で予約を保持したまま`quarantined`にし、必ず`raise`で取消を呼び出し元へ伝播する。別の持ち主に替わったbindingや既に閉じた状態には触れない。submit側の予約所有権判定（cycle 1）は不変 |
| GREEN | `cycle2-r003-green` 5 / 0（RED 4本＋所有権不一致coverage）、`cycle2-r003-full` 92 / 0（relay入力`e9d6ce94…`）。README追記後`cycle2-relay-final` 92 / 0（`29e18b1e…`）。coverageを3 subcaseへ分けた後`cycle2-r003-green2` 5 / 0、`cycle2-relay-final2` 92 / 0（relay入力`44ae1a4b…`、最終候補のrelay入力と一致） |
| 確認した性質 | 504＋`quarantined`、pending echoは`BridgeError`、`pending`空、terminal不明の`run_b1`はadmissionに保持、次のbindは409 `quarantined`、holdをreleaseしても放棄されたtaskが後始末を再開しない |
| coverage（修正後・既存pass、挙動REDではない） | `test_interrupted_teardown_leaves_a_transition_it_no_longer_owns_alone`: 所有権の3軸（binding identity / generation / revoking state）を1つずつ失わせ、いずれも取消時に何もquarantineせず`CancelledError`だけを伝播し、state・binding・generation・admissionが不変であることをsubTestで確認。cancel前の到達はsleepではなくstop requestの記録で待つ |

その他の再検証: `cycle2-generator-contract2` PASS、`cycle2-device-runner-unit2` 7 / 0（いずれも入力`186fadd6…`、最終候補との差は本節の文書追記のみ）。同じ検査をtest変更前にも実行し（`cycle2-generator-contract` / `cycle2-device-runner-unit`、入力`e60713d9…`）、結果は同じPASS / 7 / 0で、記録として保持する。

証拠区分（親CYCLE1-S02）: cycle 2で変更した入力は`relay/bridge.py`、`tests/test_bridge.py`、relay `README.md`、本文書の4 fileだけであり、Swift・Xcode project・scripts・資産の全入力はcycle 1の検証入力`c45b0083…`とper-fileで一致する（`cycle2-scope-equivalence.json`）。したがって`cycle1-swift-suite`（1109 / 5 skip / 0）、`cycle1-physical-build`・`cycle1-physical-codesign.json`、`cycle1-device-offline-host`（6 / 0）、`cycle1-release-artifact`・`cycle1-artifact-checks/`は**cycle 1の実行結果を同一入力の証拠として保持**したものであり、cycle 2で再実行してはいない。保持したCodeSign順序のsetup失敗と作業用Buildの一度の再生成は、既存の増分build問題が解決したことを示さない。Windows実エージェントとのlifetime 1/2と受信許可後の到達性は引き続き未実施である。

最終提出manifestは`step1/cycle2-candidate-freeze.json`、patchは`step1/cycle2-review-ready.patch`、変更ファイルのhash一覧は`step1/cycle2-patch-manifest.json`、旧2候補（`0adefa43…`、`19d357c3…`）との差分一覧は`step1/cycle2-scope-equivalence.json`に記録する。過去の候補・receipt・レビュー本文は上書きしない。pair限定追認は`step1/review/codex-cycle2-followup.md`と`claude-cycle2-driver-note.md`に保存し、review-readyは一度だけ通知する。commit/pushは親のGO後、PRは親が未完了Draftとして作成し、mergeしない。
