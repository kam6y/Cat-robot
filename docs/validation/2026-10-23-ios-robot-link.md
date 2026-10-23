# iOS 首の接続・動作・校正 検証記録

- 日付: 2026-10-23（JST）
- 対象実装SHA: ホストレビュー修正 `a2b09d8e8dcebb669a864b95ae4c48a85d42a671`、操作方向の修正 `42898401c5fee2dbd2cbed802401dbc3cd20cff7`、待機微動・自動復帰の低速化 `2ce83c57436f5a2d0d0f51da8d367452638bd083`、PWM維持を含む最終実装 `178e3a6e83eb043197a16baefa7b50ae6586461f`。文書だけの追記コミットは対象実装を変更しない。
- 承認済み設計: [iOSロボット接続設計](../superpowers/specs/2026-10-23-ios-robot-link-design.md)
- 実装計画: [10タスクの計画](../superpowers/plans/2026-10-23-ios-robot-link.md)
- 環境: macOS 26.6.2、Xcode 27.1（27A9275）、iPhoneOS/iPhoneSimulator SDK 27.1、iOS 27.0 Simulator（iPhone 17 Pro）、Swift 6、Ruby `xcodeproj` 1.27.0。SPMは`Package.resolved`の固定版を使用。
- ホスト検証では実機操作・実API生成を行わず、BLEはFakeTransport、音声・生成はテスト実装を使用した。後続の利用者在席での実機確認は末尾に記録する。CoreBluetoothテストは遅延生成・利用理由・エラー分類を確認し、本物のcentralを起動していない。

## ホストで確認したこと

| 設計の節 | 実装・観測 | 自動試験・確認 |
|---|---|---|
| 3 / 4: 値型境界とプロトコル | 9コマンド、4種のRead、deci整数、LE、長さ・版数・不正値の拒否 | `RobotProtocolTests`、FWの既存golden bytesとの照合 |
| 4: 接続と世代 | 既知UUID取得、サービス限定検索、Info→暗号化Status→Notify→Calibration→Limits、取消終端待ち・manager破棄後の再試行、ロボットごとの初回ペアリング待ち、認証情報消失後の明示再試行、接続待ちのキャンセル | `RobotLinkTests`、`CoreBluetoothRobotTransportTests` |
| 4: PING・フロー制御 | 1Hz、古いStatusと新しいPING echoの回復確認、期限付き送信、最新1件、STOP/PING優先、inactive未送信動作破棄 | `RobotLinkTests`、`RobotLifecycleIntegrationTests` |
| 5.1: ターンスコープ | 同じSDKセッションを使った2ターン、スコープなし、取消後の古いTool.call、固定IDの生成終了通知 | `MotionTurnContextTests`、`MoveHeadToolTests`、`MotionReplyGeneratorTests` |
| 5.1: 発話同期と切り替え | voice/typed共通run、3文先読み、最初のspeechStartedだけ解放、失敗したprimaryの予約をsecondaryより前に失効 | `MotionPlaybackIntegrationTests`、`OnDeviceFallbackReplyGeneratorTests` |
| 5.2 / 5.3: 予算と波形 | 1サイクルずつ送信、初回完走、次の予測合計≤4秒、実測超過後の残り破棄、寄せ時間、左右交互tilt、Read確認した速度欄だけ更新。完了待ちは予測+2秒/最大20秒、Status Readで再同期、動作中のままなら切断・再接続 | `GestureTimingTests`、`MotionCoordinatorTests` |
| 5.4: 自動動作 | 4〜10秒間隔、±3°/±2°、3〜4秒のC²目標列・speed 10（実機の指摘で変更）、20Hz以下、0→−5°→0の約0.6秒MOVE列、古い列を再生しない | 偽時計で送信目標・時刻・優先順位を確認。実機の追従時間は未実施 |
| 5.5 / 5.6: 所有権と停止 | settings/inactiveでは波形完走、明示停止・新会話・真の合成失敗は停止、backgroundはSTOPを送らず切断、待機微動オンではPWM維持、オフ時のみACTIVE静止2秒の低優先度PWM停止と古いticket失効 | `RobotLifecycleIntegrationTests`、`MotionCoordinatorTests` |
| 6: 校正 | 静止待ち、新しいRead、10Hzプレビュー、保存ACK・saved・意図値照合、req折り返し、同req3回、全体2回、dirtyなentry復元、旧応答と切断後ドラフトの失効 | `RobotCalibrationSessionTests`、`RobotSettingsModelTests` |
| 7 / 8: 画面と記録 | 同じLink/Motionの注入、未接続でも会話継続、3種の接続表示だけを投影、角度通知で再アナウンスしない、本文・引数全文を記録しない | `RobotStatusPresentationTests`、既存会話・アクセシビリティ試験、ログ呼び出しの確認 |
| 7: レイアウト | Fakeのみの接続・校正画面の上下、会話ヘッダーを横向きの通常文字/最大Dynamic Typeで画像化。最大文字は1列。停止は上部に固定。接続キャンセルも通常/最大文字で確認 | XCTest添付PNGを目視。スライダーの度数、反転、方向、停止、戻る、保存のラベルを確認。実機VoiceOverの操作受入は未実施 |

Swift側の予算用予測は、標準上限・中立でnod large 1.52秒、shake large 2.08秒、tilt large 2.48秒、look large 4.06秒（±20ms）を既存FWのホスト基準と照合した。これは実機の運動時間の再測定ではない。サーボのPlannerをSwiftに複製せず、完了はStatusで判定する。

## 自動検証の結果

| 項目 | 結果 |
|---|---|
| 初回ホストレビュー修正後の全Simulator試験（`a2b09d8`） | 564件実行、1件skip、失敗0（21.680秒。Xcode起動・ビルド時間を除く） |
| 左右操作修正後の全Simulator試験（`4289840`） | 564件実行、1件skip、失敗0（32.713秒）。4方向の回帰試験のRED→GREEN、画面説明の通常文字・最大文字の画像も確認 |
| 低速化後の全Simulator試験（`2ce83c5`） | 565件実行、1件skip、失敗0（39.298秒）。遠い手動姿勢からの確認動作4条件と、微動の速度・時間のRED→GREEN |
| PWM維持修正後の全Simulator試験（`178e3a6`） | 568件実行、1件skip、失敗0（31.755秒）。設定経由のPWM維持、オンで旧停止の失効、オフで新しい2秒待機の3試験で、修正前6 assertionの失敗→修正後成功を確認 |
| skip | `SupertonicIntegrationDeviceTests`。Simulator条件で`Explicit iPhone integration test required`により明示的skip。専用iPhone runnerを使う既存の音声受入試験 |
| プロジェクト生成と契約試験 | PASS。再生成でproject/schemeの追加差分なし |
| generic iOS unsigned build | BUILD SUCCEEDED（レビュー修正後のアプリソース、iPhoneOS SDK 27.1、署名・インストール・起動なし） |
| `git diff --check` | PASS |
| 新しい担当によるブランチレビュー | 初回Critical 0 / Important 3 / Minor 0。3件を修正し、再現試験と全回帰で確認。詳細は末尾。ホストPASSを実機受入として扱わない |

実行は`xcodebuild test -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=80F1BF36-5242-4067-A1D9-99399B852120' -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO`（only-testingなし、専用DerivedDataと固定SPMキャッシュを指定）。ビルドは`xcodebuild build -project CatRobot.xcodeproj -scheme CatRobot -destination 'generic/platform=iOS' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO`。生成は`ruby scripts/generate_project.rb`と`ruby scripts/test_generate_project.rb`。

## NFR-PERF-3の計測境界

Tool.callは即時に予約を返し、発話開始が実行の最早時刻になる。300msの目標は、発話開始済みで前サイクルの完走・静止・必要な速度設定の確認を終え、実行可能になった時刻から、Statusで開始を観測するまでとする。

`RobotMotion`ログの`eligible`→`startObserved`を測り、`speechStarted`→`startObserved`の発話からの実測値と、`previousCycleWait`の前サイクル待ちを別記する。`sent`の`speechToSend`は発話から送信までで、実際の運動開始時間の代用にはしない。予約/発話開始/実行可能/送信/開始観測/完了はターンID・サイクルID・単調時刻・enum結果で結ぶ。本文・引数全文はログに出さない。

実機の文字入力からの1回の頷きで、eligible→startObservedは73.104ms、speechStarted→startObservedは73.344ms、previousCycleWaitは0msだった。この1回は300ms以内。全強さ・複数サイクル・連続ターンを含む性能保証や分位点の測定とは扱わない。正面付近での確認頷きの約0.6秒は実機未計測。待機微動は実機で速いとの指摘を受けて目標列を3〜4秒へ変更し、利用者が滑らかさを確認した。

## 利用者在席で残る実機受入

| 項目 | 状態 | 実施時に残す条件・観測 |
|---|---|---|
| iPhone初回検索・ペアリング・暗号化Read | PASS（手動で60秒窓を開いた条件） | iPhone/OS/FW/ビルドSHA、起動後60秒窓、許可ダイアログ、初回操作 |
| 既知UUIDの再接続 | PASS（利用者の約5秒以内という観測） | 通常5秒目標。権限・ペアリング待ちは別記し、重複centralを起動しない |
| 2台目centralの60秒窓外拒否 | 未実施 | 既存T-FW-9の残り。iPhoneとMac BLE toolsを同時接続で競合させない |
| 校正保存と電源再投入後の保持 | PASS（6.5° / 0.0°、invert 2） | ACK、Calibration Read、saved、意図値、再起動後の実際の値 |
| 7動作×3強さ、方向・振幅・上限 | 手動4方向はPASS。7種×3強度は未実施 | 低速の1方向確認から開始。tool intensityと全体の強さを区別 |
| 発話同期・前サイクル待ち | 単発の頷きはPASS（73.104ms）。前サイクル待ちは未実施 | 上記3区間、送信とStatus開始の時刻、必要に応じ動画 |
| 動作中の切断からFW安全復帰 | 未実施 | 先にSTOPを送らない。FW RETURNING/RELAX_WAITと中立への復帰 |
| 再接続時に旧予約・MOVE・校正を再送しない | 手動MOVEはPASS。予約・校正中断の全条件は未実施 | 新接続epoch、古いコマンド不在、Readしてから明示操作 |
| 校正専有と停止・離脱 | 手動停止・戻る・保存はPASS。全条件の実機受入は未完了 | 動作終了待ち、自動動作不在、停止、保存/戻す/編集継続 |
| 待機微動オンでPWM維持、オフで静止2秒後に停止 | オンで跳ねなし、オフでPWM停止、次動作の復帰はPASS。送信回数は実機未計測 | PING継続、TORQUE0一度、古い停止ticket不在、保持状態。電源断や保持電流低下を保証しない |
| 横向き・最大文字・実機VoiceOver | 未実施 | 操作ラベル・値・保存状態・接続失敗を色だけに依存せず確認 |
| 実アプリの生成からのmove_head | PASS（利用者の文字入力で単発の頷き） | 本番compositionのClaude経路で予約、読み上げ開始、BLE送信、開始観測、完了を同一IDで確認。音声入力と複数サイクルは別項目 |

利用者が首を見られる状態を確認してから実施する。後述の実機確認ではBLE接続・校正保存・電源再投入を行った。未実施の行をホスト試験の結果からPASSにしない。

## レビューと追記

別コンテキストの `gpt-6-astra` が、基点 `2f2677273cd16ddfd0f9ea8c8701ac0778029ec3` から文書コミット `d3420b186f241f8a7edf38577843176dff379631` までの全差分を読み取り専用で確認した。初回判定は **With fixes**、Critical 0 / Important 3 / Minor 0。以下の3件を `a2b09d8` で修正し、実装者が再現試験のRED→GREENと全体回帰で確認した。

| 指摘 | 修正と確認 |
|---|---|
| 開始済みサイクルに完了待ち期限がない | 送信から予測+2秒、最大20秒で待ちと予約を失効。新しいStatus Readが静止を示すまで動作受付を再開せず、まだ動作中/Read失敗ならSTOPを送らず切断・再接続。予測期限、20秒上限、settings/inactive、background後の古いRead、回復後の新ターンを4テストで確認。最初の3テストは10 assertion、追加の動作中Readは2 assertionのREDを観測 |
| 初回ペアリング猶予が全ロボット共通 | 暗号化Readの成功履歴をUUIDごとに保持。認証情報消失時はそのUUIDの履歴を失効。A→未ペアリングB、認証失敗後の明示再試行で6 assertionのREDを観測し修正。既知UUIDの通常5秒期限も維持 |
| 接続待ち・再接続をUIから中断できない | connecting/preparing/reconnectingでは「接続をキャンセル」、connectedでは「接続を切る」、中断後は明示接続。4状態のモデル操作から実際のLinkを確認し、9 assertionのREDを観測。中断後20秒とresumeで再試行/PINGが出ず、明示操作で再開することを確認 |

最初の修正後全体試験は564件・1 skip・失敗0。その後の画像追加を含む全体試験では、既存の `ConversationRecoveryTests.testPauseDuringFailureCleanupCannotEraseQueuedResumeOwnership` が後処理開始のポーリング前提で1回失敗した。テスト内の発話送出にも1秒の待機があり、後処理開始の1秒ポーリングと競合し得るため、既存の音声deactivate gateへの到達を直接待つようにした。後処理回数と全ての再開所有権のassertionは維持し、会話の製品コードは変更していない。最終の全体試験では同テスト0.019秒、**564件・1 skip・失敗0**（21.680秒）。真に後処理が進まない場合、この待ち合わせ自体は長く待つ可能性がある。

接続キャンセルの横向き画像は通常文字・最大Dynamic Typeで確認し、最大文字ではスクロール途中の操作位置も確認した。生成プロジェクトの契約、署名なしgeneric iOS build、差分チェックもPASS。Minorの繰り越しはなし。

レビューで範囲外としたカメラ追尾/対象を見失った挙動は承認済みサブ計画4のまま、FW変更/サーボ調整は既存の契約を使用する。追尾が使えることや物理特性をホスト検証から推定しない。このホストレビュー終了時点では実機受入は未実施だった。後続の実機確認を以下に追記する。マージ・push・配布はこの記録とは別の統合操作として扱う。


## 利用者在席での実機確認（2026-10-23 夜、JST）

利用者が首を目の前で確認できると回答した状態で実施した。iPhone 16 Pro / iOS 27.2、XIAO ESP32C3 / FW 0.1.0 / protocol 1 / E17。初回は署名済み `4d998b7`、方向の修正後は `4289840` を同じiPhoneへ更新インストールし、各ビルドの埋め込みSourceRevisionを確認した。その後、低速化版 `2ce83c5` も同じ端末へ更新した。PWM維持版 `178e3a6` もSourceRevisionを照合して更新した。4版とも署名ビルド・インストール・起動が成功。アプリのデータを消去する操作は行っていない。

MacからはシリアルのSTATUS / INFO / WATCHで観測し、iPhoneを唯一のBLE centralとした。WATCHは約200msごとで、角度はFWの指令値。機械の向き・引っ掛かり・異音は利用者の目視・聴覚による。初期のiPhone受入ではシリアルから動作コマンドやPINGを送っていない。後述の原因切り分けでは、利用者在席で範囲を限定したシリアルMOVEを使った。USBシリアルのopen/closeは既存のDTR/RTS保持処理を使用した。

| 確認 | 実際の条件・結果 |
|---|---|
| 初回接続 | 再起動の代わりにシリアル `PAIR OPEN` で60秒窓を開き、iPhoneから検索・選択・ペアリング。利用者が接続とFW 0.1.0表示を確認。FWのbondsは1→2、LINKと1HzのPING echoを観測。起動後の窓を利用した初回ペアリングとは条件を区別する |
| 手動再接続 | 「接続を切る」→5秒待つ→「このロボットに接続」。利用者が約5秒以内、ペアリング確認なしと回答。FWのLINK消失21:45:54.319、復帰21:46:01.320は操作待ち5秒も含むため、差分7秒を接続処理時間とは扱わない |
| 方向と停止 | 旧UIの「左端へ」はロボット自身の左で、利用者からは右になると指摘。`4289840`で校正の左右を向かい合った利用者基準へ変更し、説明を追加。更新後、利用者が左右の一致を確認。上下も表示どおり、引っ掛かり・異音なし。指令値はyaw ±60°、pitch ±30°まで観測。正面復帰と途中の停止も利用者が確認 |
| 校正保存 | 利用者の調整後、最終値はyaw offset 6.5° / pitch offset 0.0°、yaw invert false / pitch invert true。途中に反転やオフセットを試した記録はあるが、最終確認前にこの組を保存。22:08:13にsaveSeq 5、22:08:36のINFOで `cal=6.5,0.0 inv=0,1 saved=1`。画面も保存済み |
| 電源再投入 | 利用者がロボットの19VとUSBを両方外し、5秒後に戻した。iPhoneで再接続し校正画面を開き直して同値・保存済みを確認。22:13:07のINFOでも `reset=POWERON cal=6.5,0.0 inv=0,1 saved=1 bonds=2`、saveSeqは0、tick_droppedも0へ戻った |
| 待機時PWM停止 | 正面へ動かした後、停止ボタンを押さず校正から接続設定へ戻った。利用者が「待機中・PWM停止」を確認。22:13:58.484のACTIVE/TORQUEありから22:14:02.284のIDLE/TORQUEなしへ遷移。間隔3.8秒には画面から戻る操作も含むため、2秒の厳密な計測とは扱わない。その後22:14:19.485にMOVING/TORQUEありへの復帰を観測。実電流は未計測 |

左右変更は校正の手動方向だけを対象にし、FW・プロトコル座標・自律ジェスチャの意味を変更していない。回帰試験は実際のSession→Link→送信コマンドで、左−50° / 右+50° / 上+25° / 下−25°、speed 10、正面、STOPを確認した。旧実装では左右の符号だけが期待と異なる1 assertionのREDを確認し、修正後の全564件が成功した。

実機の生ログとxcresultはこの作業の `/private/tmp/cat-ios-link/attended/` に保存した。上表の観測結果は本書へ残す。発話同期、切断復帰、全ジェスチャ・強度の試験は以下の個別結果と未実施項目を区別する。


### 待機の速さについての実機フィードバック

利用者は会話画面へ戻ったときの正面復帰が速く、待機微動も「跳ねている感じ」なのでゆっくりにしたいと回答した。ここで戻った先は、確認の結果 **CatRobot内の猫の会話画面** であり、iPhoneのホーム画面ではなかった。この区間にFWのLINK消失、RETURNING、RELAX_WAITは記録されていないため、切断時の安全復帰の試験結果には数えない。

旧版のログでは校正操作中のyawは約12°/秒だが、22:18:05.886の−52.7°から22:18:06.085の−28.8°、22:18:06.285の−5.2°へ約120°/秒で復帰していた。アプリの確認頷きは開始姿勢にかかわらずyaw=0をspeed 100で送っており、この速い復帰と一致する。FWの切断復帰速度（yaw 90°/秒、pitch 60°/秒）を変更する事象ではない。

`2ce83c5`では、開始時の姿勢がyaw ±3° / pitch ±2°の外にある確認動作をspeed 10へ制限した。正面付近の短い確認頷きは維持する。待機微動は3〜4秒、speed 10とした。振幅±3°/±2°、4〜10秒の間隔、20Hz以下、期限切れ・中断後のMOVEを送らない条件は維持する。遠い姿勢からは低速復帰を優先するため、確認頷きが実際に約0.6秒で完了することは要求しない。

低速化版の22:34:54〜58のyaw復帰は約12°/秒となった。利用者は「左端から戻る時最初だけ跳ねる。そのあとは大丈夫そう。待機中の動いてるのは相変わらず跳ねてる」と回答。速度の改善と、始動時の跳ねが残ることを分けて記録する。

校正画面を開いてPWMを維持した状態で、22:42:15〜37にシリアルMOVEでyaw 0°→+2°→−2°→0°、各区間3.5秒のS字補間、間に5秒の静止、speed 10の比較を実施した。常にLINK/TORQUE/ACTIVE、yaw ±3°・pitch ±1°以内を検査し、条件を外れたらSTOPする診断スクリプトを使用した。iPhoneのPINGは継続し、シリアルからPING、保存、校正変更は送っていない。利用者は「今回は跳ねずに動いた」と回答。これは連続PWMの診断結果であり、iOSの修正受入ではない。

続けて22:46:12〜42に同じ範囲・補間へ各区間前のTORQUE 0と2秒以上の停止を加え、停止/再開をStatusで確認した。利用者は「今回は動き出しが跳ねた」と回答。同じ小さな動きで連続PWMでは跳ねず、PWM停止・再開を挟むと跳ねることを確認した。FW設計§4.5にも再開時の位置合わせによる跳ねの制約があり、当初のiOSが待機微動の間も毎回2秒でPWMを止める制御を原因として修正する。パルス波形や実電流は測定していない。


`178e3a6`では待機微動オンの間は会話・設定画面ともPWMを維持する。オフにすると新しく2秒の静止を数え、低優先度のPWM停止を送る。オンへ戻した場合は未送信の停止を失効させる。明示STOPとbackground・切断のFW復帰は維持した。全568件のホスト試験は成功。更新したiPhoneで利用者が左端から会話へ戻り40秒ほど観察し、「どちらも跳ねず、ゆっくり動く」と回答。22:58:50.714〜22:59:51.394のStatusでもPWM継続を確認した。yaw −60°からの復帰と複数回の待機微動を含み、動作間のIDLE/PWM停止はなかった。続けて利用者が設定で待機微動をオフにし「待機中・PWM停止」になることを確認して、オンへ戻した。再開時の跳ねを防ぐための連続PWM方針と、オフ時の自動停止を実機で受け入れた。


### 発話と首の同期（178e3a6）

23:01:59〜23:02:02、利用者が文字入力で小さな1回の頷きと短い返答を要求した。利用者は「声とほぼ同時にうなずいた」と確認。iPhoneのRobotMotionログをmacOS Consoleでライブ取得した。対象ターン`E5E839C1-CC90-42EE-AF34-028527CE5345`、サイクル`394D4C61-99AF-49D7-AD26-819D905210B6`:

| イベント | 単調時刻（秒） |
|---|---:|
| reserved | 95469.694456 |
| speechStarted | 95471.528331 |
| eligible | 95471.528571 |
| sent | 95471.540048 |
| startObserved | 95471.601675 |
| completed / success | 95472.894039 |

eligibleから開始観測まで73.104ms、発話開始から開始観測まで73.344ms、発話から送信まで11.719ms、前サイクル待ちは0ms。シリアルにも23:02:01.055のGESTURE/MOVINGと、23:02:02.455の中立・静止が残った。約200msのシリアル観測を300ms判定の代わりには使っていない。Statusの開始観測はサーボの実測角や音響計測ではない。本文や認証情報をログへ追加する変更はしていない。


### ホーム画面への遷移と再接続（178e3a6）

利用者がiPhoneのアプリアイコンが並ぶホーム画面へ移り、CatRobotへ戻って「正面で止まり、戻っても古い動きは再開しない」と確認した。最初の試行では、23:04:24.215にyaw −60°で既に静止、23:04:24.415にLINKなし・RETURNING、23:04:25.415に中立・RELAX_WAIT、23:04:27.415にIDLE/PWM停止となった。切断の観測からPWM停止まで3.000秒（シリアル観測周期約200ms）。23:04:33.016に再接続し、その後も旧左端MOVEを再開せず中立のIDLEを保った。これは端で静止した直後の切断復帰であり、移動途中の切断と取り違えない。移動途中は別試行で確認する。
