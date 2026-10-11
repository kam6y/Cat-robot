# Claude 会話エンジンの検証記録

2026-10-11、Task 9 の自動検証を実施した。実 API の Simulator スモークは利用者の指定により実行していない。App Attest の Debug 予備確認は同日に実機で実施し、結果を Task 10 の節に記した。Apple Intelligence 非対応機、実機遅延、VoiceOver / Dynamic Type の受入は未実施で、Task 10 で結果を追記する。

鍵、認証トークン、client ID の実値、会話本文はこの記録に含めない。

## 対象と環境

- ブランチ: `feature/claude-conversation-engine`。
- Task 9 の BASE: `6d8d05f301121e176a43d91275b971ca85dce3c7`。検証対象はその上の Task 9 の変更。
- Xcode 27.0（27A266a）、Swift 6 strict concurrency（complete）、deployment target iOS 27.0。
- Simulator: iPhone 17 Pro / iOS 27.0、UDID `80F1BF36-5242-4067-A1D9-99399B852120`。
- `xcodeproj` 1.27.0、ClaudeForFoundationModels 0.2.3、ONNX Runtime 1.24.2。依存は `Package.resolved` の固定版。
- Supertonic 3 の資産は既存の Git 管理外ディレクトリを使用。認証キーのファイルは空のままで、統合の client ID も未設定のまま。

## Task 9 Step 4: 自動検証

新規テストは `AppCompositionTests.testLiveCompositionIsLazyAndWiresClaudeRoles` の 1 件。製品変更より前に追加し、RED を確認してから実装した。実 API には接続していない。

| 検証 | 結果 | ログ |
|---|---|---|
| テスト追加後の project 生成・契約 | PASS | `task9-generate-red.log` |
| RED: AppCompositionTests | `ConversationComposition` 未定義と、それに伴う型推論エラー。exit 65、TEST FAILED | `task9-red.log` |
| 実装後の project 生成・契約 | PASS | `task9-generate-green.log` |
| AppCompositionTests + VoiceSettingsIntegrationTests | 18 件、失敗 0。exit 0、TEST SUCCEEDED | `task9-green.log` |
| Python スクリプトの unittest | 3 ファイルの 9 件、失敗 0。exit 0 | `task9-python.log` |
| 全回帰 | 418 件、既存 skip 1、失敗 0。exit 0、TEST SUCCEEDED | `task9-full.log` |

ログは作業環境の `/private/tmp/cat-claude-engine/` に保存した。全回帰の xcresult は `simulator/Logs/Test/Test-CatRobot-2026.10.11_20-14-57-+0900.xcresult`。skip は既存の `SupertonicIntegrationDeviceTests.testSelectedStage` で、明示的な iPhone 実行を必要とする。

最終確認では、staged index から取り出した project・2 つの scheme・`Package.resolved` が再生成結果とバイト一致し、生成契約も PASS（`task9-generate-final.log`）。`git diff --cached --check` は通過し、未ステージの差分はない。Task 9 の GREEN / 全回帰ログの Swift 警告は既存の 8 種類で、新規 0。AppIntents の metadata extraction 通知を含む警告メッセージ全体にも新規差分はない（`task9-warnings.txt`）。README の旧エンジン・旧テスト用環境変数の記述は 0 件で、保持するよう指定された 3 節とローカルリンクも確認した。

実行したコマンド:

```bash
ruby scripts/generate_project.rb
ruby scripts/test_generate_project.rb
python3 -m unittest discover -s scripts -p 'test_*.py'

xcodebuild test \
  -project CatRobot.xcodeproj -scheme CatRobot \
  -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' \
  -derivedDataPath /private/tmp/cat-claude-engine/simulator \
  -clonedSourcePackagesDirPath /private/tmp/cat-claude-engine/packages \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

対象テストの GREEN では同じコマンドに `-only-testing:CatRobotTests/AppCompositionTests -only-testing:CatRobotTests/VoiceSettingsIntegrationTests` を付けた。RED は AppCompositionTests だけを指定した。

## 配線と遅延性

`ConversationComposition` が声・モデル設定・長期メモ・利用量を保持し、`CatRobotApp` が同じインスタンスを `AppRootView` に渡す。返答と可用性確認は同じ `OnDeviceFallbackReplyGenerator`、記憶管理はその primary である `ClaudeConversationService`、宛先判定は `RoutedAddressClassifier` に接続する。利用量計と設定の取得クロージャは Claude と代替返答の両方で共有する。

構築時にはネットワーク、マイク・音声の稼働、端末内モデルの生成・availability 照会、記憶データの読み書きを行わない。既存の `FileConversationMemoryStore.defaultDirectory()` は `create: true` で Application Support のルートだけを作る可能性がある。これは冪等で会話データを伴わない既存挙動として、navigator の確認を受けて維持した。会話ディレクトリ、`current.json`、`facts.json` は保存時まで作らない。モデルの記述子とファイルの URL を保持する処理は構築時に行う。

新規テストは役割の型、`.sentencePrefetch`、認証未設定時の `.claudeCredentialMissing` を確認する。既存の root 構築テストはマイク要求・可用性確認・音声準備・認識開始・音声セッション有効化・wake lock が始まらないことを確認する。ディレクトリ作成の有無を固定するテストは追加していない。

## Task 9 Step 5: 利用者による Simulator スモーク

**2026-10-11 に利用者が実機で実施し、全項目 OK**。Simulator ではなく iPhone 16 Pro の Debug ビルド（キーなし、App Attest 認証、Wi-Fi）で行った。試験用の設定（1 日の上限 10 回、モデル変更）は確認後に元へ戻した。以下の手順は自動検証時点の記述で、自動検証で通ったとは扱わない。キーの設定・実 API 呼び出し・ネットワーク状態の変更も行っていない。

1. 利用者が開発用 API キーを用意し、[README の認証手順](../../README.md#claude-の認証)に従って Debug 実行の環境変数か Git 管理外のキーのファイルに設定する。キーをこの記録やログへ貼り付けない。
2. [Simulator のビルド手順](../../README.md#simulatorでビルドテスト)で Debug アプリをビルドし、対象 Simulator にインストールして起動する。
3. 下表を確認し、結果・日時・構成・失敗の種別だけを追記する。会話本文や鍵・トークンは記録しない。
4. 日次上限などの試験用設定を元に戻す。共有環境へ置いた開発用キーは利用者が片付ける。

| 手動確認 | 状態 |
|---|---|
| 文字入力への Claude の返答と逐次字幕 | OK（2026-10-11、利用者報告） |
| remember による長期メモ登録と設定画面への表示 | OK（2026-10-11、利用者報告）。一覧からのスワイプ削除も確認 |
| 通信断で端末内モデルへ切り替え、使えなければ会話不可を表示 | OK（2026-10-11、利用者報告）。機内モードで期待どおりの表示になり、解除後に通常へ戻った |
| モデル変更後も現在のセッションを維持し、新しい会話で変更が反映 | OK（2026-10-11、利用者報告） |
| 日次上限到達後の代替返答または会話不可（T-COST-1） | OK（2026-10-11、利用者報告）。上限を 10 回に下げて到達させた |

## Task 10: 実機受入の残項目

| 項目 | 状態・追記する内容 |
|---|---|
| App integration 登録・ワークスペース支出上限 | 登録済み（2026-10-11）。利用者が Console で App integration を作り、client ID を `CatRobot/Resources/claude-integration.json` に設定してプロジェクトを再生成した。ワークスペースの月間支出上限も利用者が設定した（同日）。Step 1 完了 |
| App Attest の Debug 予備確認 | 成功（2026-10-11、App Attest 環境 `development`、iPhone 16 Pro）。詳細は下記 |
| T-AUTH-1: TestFlight の認証 | 未実施。Release 構成・キーなしでの認証と会話成立を確認する |
| T-AUTH-2: 統合の取り消し | 未実施。取り消しは恒久なので、検証用の別統合で失効時の案内を確認する |
| T-DEV-1 / T-DEV-2 | 未実施（2026-10-11、利用者判断）。Apple Intelligence 非対応の iPhone が手元に無い。README の動作要件を「Apple Intelligence 対応機で検証済み。非対応機は未検証」とした |
| T-LAT-1 | 簡易版（20 ターン）を 2026-10-12 に実施。高速経路の最初の字幕 中央値 2.21 秒（目標 1.5 秒）、読み上げ開始 中央値 3.19 秒（目標 2.5 秒）で **未達**（下記）。要件の 50 ターン受入は前提条件を固定して別に記録する |
| VoiceOver / Dynamic Type | OK（2026-10-11、利用者報告）。VoiceOver で設定シートの各コントロールと長期メモの一覧、新しい会話の操作が日本語の名前と現在値で読まれ、最大のアクセシビリティサイズで文字欠けなし、視差効果を減らす設定で崩れなし |

### 2026-10-11: 実機の初回ビルドと App Attest の Debug 予備確認

環境: iPhone 16 Pro（Apple Intelligence 対応機、USB-C 接続、Developer Mode 有効）、Xcode 27.0（27A266a）、構成 Debug、Automatic Signing、team `VUB4VP6453`、bundle ID `com.kamby.CatRobot`。ビルドは README の実機手順（`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`）、インストールと起動は `xcrun devicectl` で行った。

1. client ID を `claude-integration.json` に設定し、`ruby scripts/generate_project.rb && ruby scripts/test_generate_project.rb` を実行した（契約テスト PASS）。生成後の Info.plist は `CatRobotClaudeClientID` に `clid_` 接頭辞の値を持つ。
2. 初回のビルドは署名で停止した。エラーは「PLA Update available」と「Provisioning profile doesn't include the App Attest capability / `com.apple.developer.devicecheck.appattest-environment` entitlement」の 3 件。原因は Apple Developer アカウントで最新の Program License Agreement が未同意だったことで、プロジェクト側（entitlements、`CODE_SIGN_ENTITLEMENTS`、環境値）の不足ではない。
3. 利用者が PLA に同意した後、同じコマンドで再ビルドしたところ、Xcode が App Attest を含む「iOS Team Provisioning Profile: com.kamby.CatRobot」を自動生成し、ビルドが成功した。Developer ポータルでの手動の capability 追加は不要だった。
4. 開発用キーを同梱した Debug ビルドをインストール・起動した。この回は認証経路がキーなので App Attest の確認には数えない。
5. `CatRobot/LocalAssets/claude-api-key.txt` を 0 バイトにして再ビルドし、バンドル内のキーのファイルが 0 バイトであること、`CatRobotClaudeClientID` が設定されていることを確認してからインストール・起動した。環境変数 `ANTHROPIC_API_KEY` は設定していない。App Attest 環境は Debug 既定の `development`。
6. 利用者が「会話を始める」から自己紹介を依頼し、Claude の返答が返った。Claude Console の Usage に利用量が記録されたことを利用者が確認した。

判定: App Attest の Debug 予備確認は成功（`development` 環境で認証と会話が成立）。要件 T-AUTH-1 の判定は計画どおり TestFlight（Release 構成、`production` 環境、キーなし）で別途行う。字幕、口の動き、読み上げ、聞き取り再開の詳細と、Task 9 Step 5 の表の項目は未確認のままとする。

### 2026-10-11: 遅延の簡易計測（途中）

iPhone 16 Pro、Wi-Fi、キーなし Debug ビルドで、利用者が呼び名付きの短い質問を話し、`sudo log collect --device-udid <UDID> --last 30m` で取得したアーカイブから `subsystem == "com.kamby.CatRobot" AND category == "ConversationLatency"` の signpost を抽出した。`log show --style json` の出力は末尾にアーカイブ名の見出しが付くので、JSON 配列の終端までを読む。

取れたのは 2 ターン分（22:39〜22:40）で、20 ターンの発話がこの窓より前だったと思われる。参考値は次のとおりで、判定には使わない。

| 区間 | n | 中央値 | 最大 |
|---|---|---|---|
| FastPathFirstCaption（発話境界 → 最初の字幕、目標 1.5 秒） | 2 | 2.50 秒 | 3.09 秒 |
| FastPathSpeechStart（発話境界 → 読み上げ開始、目標 2.5 秒） | 2 | 3.84 秒 | 4.23 秒 |

2026-10-12 に `--last 3h` で取り直したが、やはり直近 2 ターン分（00:27:55〜00:28:26）しか入っていなかった（参考値: FastPathFirstCaption 中央値 1.37 秒・最大 1.66 秒、FastPathSpeechStart 中央値 2.50 秒・最大 2.55 秒、いずれも n=2）。signpost は端末のメモリ上のリングバッファ（約 30 秒）にしか残らず、ログの保存領域には書かれないため、`log collect` の範囲を広げても回収できない。Instruments（`xcrun xctrace record --template 'Logging' --device <UDID> --attach CatRobot`）も試したが、Xcode 27.0 では `xctrace list devices` で iPhone が「Devices Offline」に分類され、`devicectl` では有線・ペアリング済み・DDI 利用可と見えていても接続できなかった。

対処として、区間の終了ごとに同じ数値（区間名・turnID・`elapsedFromBoundary`・`elapsedFromASR`・結果コード、すべて `privacy: .public`、会話本文は含めない）を `Logger.notice`（default レベル。端末のログ保存領域に永続化される）で 1 行出すようにした（`ConversationLatency.swift` の `OSConversationLatencySignposter.end`）。全テスト 432 件通過。以後の手順は、利用者が 20 ターン話した後に `sudo log collect --device-udid <UDID> --last 1h --output <archive>` で取得し、`/usr/bin/log show --archive <archive> --style json --signpost --info --predicate 'subsystem == "com.kamby.CatRobot" AND category == "ConversationLatency"'` の出力から `eventMessage` が `latency metric=` で始まる `logEvent` を集計する（signpost の終了イベントも同じ集計で読めるので、両方ある turnID は logEvent を優先）。百分位は最近傍順位法。

### 2026-10-12: 遅延の簡易計測（20 ターン、T-LAT-1 の簡易版）

永続ログ版の Debug ビルド（bffc8d5 相当、キーなし・App Attest development）を iPhone 16 Pro（Wi-Fi）に入れ、利用者が呼び名付きの短い質問を話した。`sudo log collect --device-udid <UDID> --last 1h` のアーカイブに 00:50:27〜00:56:41（JST）の 21 ターン分が全て入っており、永続ログ行による回収は機能した。内訳は高速経路 18 ターン、宛先判定経路 2 ターン、応答なし（outcome=2、呼び名が取れなかったと思われる）1 ターン（turnID 14）。モデル・考える深さは利用者の設定のまま（NFR-PERF-1 の前提は Opus 5.5・effort low）。

| 区間 | n | 中央値 | p90 | 最小 | 最大 | 目標内の回数 |
|---|---|---|---|---|---|---|
| FastPathFirstCaption（発話境界 → 最初の字幕、NFR-PERF-1 目標 中央値 1.5 秒） | 18 | 2.21 秒 | 3.96 秒 | 1.15 秒 | 4.44 秒 | 4 |
| FastPathSpeechStart（発話境界 → 読み上げ開始、NFR-PERF-2 目標 中央値 2.5 秒） | 18 | 3.19 秒 | 5.06 秒 | 2.10 秒 | 5.28 秒 | 4 |
| ClassifiedFirstCaption（別集計、目標なし） | 2 | 4.60 秒 | 4.67 秒 | 4.53 秒 | 4.67 秒 | 0 |
| ClassifiedSpeechStart（別集計、目標なし） | 2 | 5.41 秒 | 5.43 秒 | 5.40 秒 | 5.43 秒 | 0 |

**判定: 簡易版では NFR-PERF-1/2 とも未達。** 高速経路の字幕は中央値 2.21 秒（目標 1.5 秒）、読み上げ開始は中央値 3.19 秒（目標 2.5 秒）。ターン間のばらつきが大きく（字幕 1.15〜4.44 秒）、速いターンは目標内に入るので、支配要因は Claude の最初のトークンまでの時間と考えられる。字幕から読み上げ開始までは一貫して約 1 秒。経過秒は発話境界（無音区切りの確定時点）からの値で、最後の認識活動からだと多くのターンでさらに約 1.2 秒（区切り間隔）長い。

ターンごとの値（秒、発話境界から。— は該当なし）:

| turnID | 時刻 | 経路 | 最初の字幕 | 読み上げ開始 |
|---|---|---|---|---|
| 1 | 00:50:27 | 宛先判定 | 4.67 | 5.40 |
| 2 | 00:50:46 | 高速 | 3.36 | 4.24 |
| 3 | 00:51:01 | 高速 | 1.15 | 2.10 |
| 4 | 00:51:21 | 高速 | 2.02 | 2.96 |
| 5 | 00:51:41 | 高速 | 2.15 | 3.04 |
| 6 | 00:51:57 | 高速 | 1.19 | 2.10 |
| 7 | 00:52:10 | 高速 | 1.43 | 2.48 |
| 8 | 00:52:34 | 高速 | 2.82 | 3.92 |
| 9 | 00:52:51 | 高速 | 3.96 | 5.06 |
| 10 | 00:53:11 | 高速 | 2.58 | 3.45 |
| 11 | 00:53:32 | 高速 | 2.35 | 3.41 |
| 12 | 00:54:06 | 高速 | 1.22 | 2.29 |
| 13 | 00:54:28 | 高速 | 2.27 | 3.32 |
| 14 | 00:54:45 | 応答なし | — | — |
| 15 | 00:54:55 | 高速 | 4.44 | 5.28 |
| 16 | 00:55:17 | 高速 | 2.60 | 3.30 |
| 17 | 00:55:33 | 高速 | 1.96 | 3.02 |
| 18 | 00:55:50 | 宛先判定 | 4.53 | 5.43 |
| 19 | 00:56:09 | 高速 | 1.99 | 3.08 |
| 20 | 00:56:28 | 高速 | 1.85 | 2.78 |
| 21 | 00:56:41 | 高速 | 2.73 | 4.02 |

次の手: 要件の 50 ターン受入（T-LAT-1 本番）は、モデルと考える深さを NFR の前提（Opus 5.5・effort low）に固定し、同じ手順で取る。未達が続く場合の対策候補は計画の範囲外として別途判断する（短期記憶の前置き分量、モデル、効果の小さい指示文の削減など）。

### 2026-10-11: 実機確認で受けた UI と動作の変更

Task 9 Step 5 と Task 10 の実機確認で利用者から出た意見を、計画 4 に回すもの（顔、常駐、オンボーディング）と、この計画の範囲で直すものに分けた。以下は後者で、利用者の合意を得て同日に実装した。鍵・ID・会話本文は含めない。

| # | 変更 | 理由と仕様 |
|---|---|---|
| 1 | 下部の「聞き取りを再開 / 一時停止」と「文字で入力」のボタンを撤去し、会話画面が前面にある間は自動で聞き取る | 画面を開いたら聞いている前提の方が自然。前面復帰、設定を閉じた後、新しい会話の後に自動で再開する。要件 FR-RUN-4（計画 4 予定）の前倒し。マイク許可の待ちなど開始が進行中なら重ねない |
| 1b | 猫をタップすると一時停止、もう一度タップで再開 | 止める手段を 1 つ残す。計画 3 以降で猫の顔が大きくなるので操作面としても良い。VoiceOver では猫が「聞き取りを一時停止 / 再開」のボタンになり、値は「聞き取り中 / 一時停止中」 |
| 2 | 文字入力は「…」→「文字で話しかける」で開き、送信後も閉じない | 続けて打てる方が使いやすい。閉じるのは入力欄の閉じるボタン |
| 3 | 「会話を忘れる」を会話画面から撤去し、設定の「覚えていること」に「すべて削除」を置く | 「新しい会話を始める」との違いが分かりにくかった。「すべて削除」は確認の後に覚えていることと会話の要約の両方を消す（従来の「会話を忘れる」と同じ範囲）。シートを開いたまま実行でき、閉じると聞き取りを再開する |
| 3b | 設定で事実を 1 つ消したら、次の返答の前にセッションを作り直す | 従来は生きているセッションが消した事実を知り続け、「新しい会話を始める」か再起動まで反映されなかった。作り直しでは要約と直近の往復を引き継ぐので会話は途切れない。覚えたときは作り直さない（長期メモの削除世代をセッションに記録して比較する） |
| 4 | 設定の見出し「Claude」→「AI モデル」 | 将来 Claude 以外を使う可能性に備える |
| 5 | 「新しい会話を始めました」「会話の記憶を削除しました」は 5 秒後か、次に話しかけた時点で消える | 表示が残り続けるのが気になるとの意見。待ち時間は差し替え可能にしてテストで固定した |
| 6 | プロンプトキャッシュは追加実装なし | ClaudeForFoundationModels 0.2.3 が全リクエストに最上位の `cache_control` を付けており、公式ドキュメントの自動プロンプトキャッシュに当たる。アプリ側は固定部（人格、ツール説明）を指示文の先頭に置き、費用の概算もキャッシュ読み取り前提。Console の Usage で cache read が出ていれば効いている |
| 7 | 短期記憶の上限を 4,000 → 12,000 文字、要約後に残す直近を 1,200 → 4,000 文字、要約の長さを 600 → 1,200 文字に拡大 | 現行モデルの枠は 1M トークン（公式一覧で確認）で余裕がある一方、キャッシュは 5 分で切れるため、5 分以上空いた後の 1 回目は文脈を書き直す費用がかかる。Opus 5.5（入力 $4/M、キャッシュ読み 5%、書き 1.25 倍）で 1 文字 1 トークンの保守的な見積もりだと、12,000 文字で冷間開始 1 回 $0.06、会話中 1 ターン $0.0024、1 日 20 回の冷間開始 + 100 ターンで約 $1.4。利用量の概算に使うキャッシュ済み前置きの想定も 3,000 → 8,000 トークンに更新した |

README の「動作要件」「設定」「会話の記憶」「iPhoneでビルド・実行」の該当文も合わせて直した。codex のレビューで自動再開の取りこぼしが 2 件見つかり（設定を開く途中で前面に戻ったとき、削除中にシートを閉じたとき）、開く処理の取消後と削除完了後にも再開を評価するよう直して境界テストを 5 件足した。さらに「保存を再試行」が猫タップの一時停止を解いてしまう指摘を受け、再試行後の再開は削除失敗からの復旧に限定して回帰テストを 2 件足した。単体テストは 432 件 / 既存 skip 1 / 失敗 0。

実機での再確認（2026-10-12 未明、iPhone 16 Pro、キーなし Debug ビルド、利用者報告）: 起動直後から聞き取り、猫タップの一時停止と再開、バックグラウンドからの自動再開、メニューからの文字入力と送信後の入力欄の維持、新しい会話の通知の消去と自動再開、見出し「AI モデル」と設定を閉じた後の自動再開、事実の個別削除が次の返答から反映されること、「すべて削除」後の一覧と自動再開の 8 項目すべて OK。追加の要望として、通知の表示位置を本文側から「…」ボタンの左へ移した。

App Attest と取り消しの仕様は [Anthropic の公式手順](https://platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models#app-attest)を参照する。
