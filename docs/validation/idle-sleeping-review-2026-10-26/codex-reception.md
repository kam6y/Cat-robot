# Codex receiving-code-review: Claude C1–C12

対象は scope.json の未コミット差分。Claude の統合報告を全文読み、関連する実装・呼出箇所・テストと照合した。採否はコード量ではなく、動作保持と責務の違いで判断した。ここまで製品コードは未変更。

| ID | 判定 | 根拠と採用範囲 |
|---|---|---|
| C1 | 採用（保守性の整理。実行時の重大バグとは区別） | enterSleeping / forwardPauseIfNeeded の開始取消・VM無効化・非同期pause生成が一致する。共有するが、standby専用の字幕消去を共有関数に入れて背景時の字幕まで消すことはしない。呼出側のscene/permission旗も維持する。 |
| C2 | 採用 | 部分結果とsegmenter解放通知はphase変更でないのにcamera/trackingの環境更新を通る。onPendingSpeechChangeを分離し受け側はupdateInactivityだけにする。synchronize後の二重通知はreturnで除く。transition/publishの同相通知は残し、ignore経路を回帰で確認する。VMのdidSetやbool反転だけの通知へは変えない。 |
| C3 | 見送り | R2修正後、失敗は待機期限の対象だがsleepy顔よりエラー顔を優先するため、2つの集合は意図的に異なる。共通のcountsTowardInactivityを顔にも使うと表示仕様が変わる。evaluateはbusyを網羅列挙し、表示は既存のidle/listening/pausedを維持する。pausedは手動一時停止や文字専用の待機状態なのでsleepy対象として設計文書を明確にする。 |
| C4 | 部分採用 | sleepy/sleepingの範囲をSettingsのstatic定数としてsetter/init/Stepperで共有し、SettingsViewのidleSettingsを必須引数にする。既定5/10はinit内の各1か所のみ。単一normalizedペア関数は採らない: sleepyを上げたときはsleepingを押し上げ、sleepingを下げたときはsleepyを下げるという編集側優先の非対称性がある。 |
| C5 | 採用 | 製品のsettingsDidChange呼出は0、製品の反映はclose→setMonitoring。APIを除き、単体テストもsetMonitoringで駆動する。 |
| C6 | 部分採用 | typed入力表示・provisional表示・マイク記号をViewStateへ集約、待機文言を共有、Accessibilityの.wakeでprivate旗を除く。allowsTypedSubmissionの!isSleepingは残す: 合成されたViewStateの入力可否として正しい契約であり、VMがこの状態を持たないことはcoordinatorでの実行ガードの必要性を示すだけ。captionのsleeping分岐も単独fixtureの表示契約として維持する。 |
| C7 | 部分採用 | 前面/設定閉の共通述語を命名して監視・wake lock・顔可視・開始条件に使用する。awake↔sleepyの環境更新は不要（参照されない）で、wakeのupdateRobotSceneは既に存在するのでonStateChangeはsleep進入だけにする。launchActionのawait前後ガードとlaunchStartの最終ガードは維持。mode順序の変更は採らない: setApplicationMode/settingsDidOpen/Closeは即座にnotifyControlMode→serviceを起こし、順序は観測可能。今回の動作保持整理としては変更せず、追加述語や2か所だけの文字入力helperも増やさない。 |
| C8 | 部分採用 | evaluateのclock.nowを1回だけ取得する。generation取消は既存の非同期所有権保護として維持。armedDeadlineという可変状態追加はC2後の低頻度な再評価に見合う実測利益がなく採らない。3行本体2か所のためだけのrestart helperも増やさない。 |
| C9 | 部分採用（Claude担当） | Measureの鼻/口/ひげ抽出、Renderのround既存確認と比較描画、sleeping参照パスを小さい共通helperにする。描画手順・stdout・計測値を維持して比較する。別CLI間の二重計測をなくすためのcache/実行統合は採らない。Measureの0.9/0.95表示ずれは固定scope前に訂正済みで追加修正不要。 |
| C10 | 部分採用 | 新規inactivityテストのUserDefaults suiteを後始末し、条件付きの主要assertionを明示する。手順の大きな共通helper化はしない。幾何/express/segmenterの重複断言は異なる経路・説明を守っており、一律削除しない。条件付きassertionの直前には既にXCTAssertEqualがあるため「全テストが黙って成功する」問題ではなく明瞭さの整理。 |
| C11 | 見送り | clipにより中間の不可視点は表示されず、端点と補間画像は検証済み。提案の幾何置換は未検証で1µs未満の計算削減に見合わず、承認済みの顔のパスへ手を広げない。 |
| C12 | 見送り | @Guideのリテラルは既存のschema慣習。ソース文字列を解析するテストは実動作を検証しない。expressibleの受理/拒否とsleeping→neutralの実ツール回帰が既にあり、今回新たな文字列同期テストは追加しない。 |

## Codex指摘に対するClaude受入の再照合

- R1/R2/R4は採用。R1はvoice成功旗を待機監視から外す。beginConversationの明示開始をrecordActivityで起点とし、監視は会話画面の前面可視性だけで制御する。これなら「hasRecordedActivity OR voice成功」や新しいmutable旗は不要で、カメラ許可/追尾に使う既存hasStartedConversationの意味も変えない。マイク拒否直後に何も入力しない場合も含める。初回preflight中も経過時間は数えるが、busy中に寝ない既存規則は維持する。
- R2はfailedを待機可とし、cleanup中の同期通知から一度だけ寝ること、タップで再開できることを回帰で確認する。失敗画面はsleepyよりsorryを優先し、期限で寝たときは既存pauseがエラー表示を終える。
- R4はstandby専用のVMメソッドでcaptionのみ消し、入力下書きと会話記憶を維持する。UIのsleeping射影も維持する。
- R3はreviewer自身が「20秒はsegmentation境界でfinalization全体の保証ではない」と訂正した。文書はその範囲を明記する。期限付きgraceful stopは既存recognizer全体の改善として別項目に残す。単にpendingを偽にする修正は行わない。コード上の無期限待ちは否定していないが、今回追加した20秒保証違反とは扱わず、本差分の必須修正から外す。
- 物理端末の再操作と未変更firmware全体の再監査を今回のread-onlyレビューで行わない判断を受け入れる。ユーザーの「いい感じ」は一般的な実機印象として記録し、個別の停止/復帰測定結果へ広げない。

## 修正と検証の分担

Codex: R1/R2/R4の失敗する統合回帰を先に実行し、その後1件ずつ修正。C1/C2/C4/C5/C6/C7/C8/C10の上記範囲を整理し、関連テストと全Simulator suiteを実行する。Claude: C9のみ、scripts/face-render/Measure.swiftとRender.swiftを編集。製品の顔3ファイル・Xcode project・実機は両者とも変更しない。C9は変更前後の計測とPNGを一時ディレクトリで比較する。
