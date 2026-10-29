# 2026-10-29 話し始めるまでの待ち時間

`feature/response-latency`。実装・実機試験の版は `91ceca49b3aefdeb188a0e48b38c82c2e908b464`、起点は main `7733e20`。[設計](../superpowers/specs/2026-10-29-response-latency-design.md)と[計画](../superpowers/plans/2026-10-29-response-latency.md)。

短い一文目の音声を、従来の文確定を待つ間に準備する方式を実装した。固定snapshotの比較は54試行すべて再生成功し、100msの退行基準を含む受け入れ判定に合格した。**これは人工的な確定待ちを持つ比較の結果で、実会話一般の改善量は未実証**。現モデルの3回のsmokeでは再利用0件だった。

## 動作と比較の範囲

- 現在のモデル `claude-haiku-5-5`、effort `low`、声 `F1` を維持。TTSは8steps、speed1.05、CPU2threads。無音区切り1.2秒、ASR停止、生成・記憶保存・usage・forgetの順序を変更していない。
- 安定prefixを保証する生成器のordinal0だけを対象に、既存解析器が引用符・URL・コードを保護した上で候補を出す。前後空白を除いた原文が75ms安定し、読み変換後のcanonical入力が16文字以下のときだけ、最大1回準備する。
- 従来の確定条件を満たすまで再生・発話開始・動作予約の解放をしない。確定文を再変換し、声とcanonical入力が等しい場合だけ検証済みPCMを使う。不一致・取消・失敗では先行推論を取り消し、完了を待つ。同時推論は1件。長い確定文も全文を通常合成する。
- baselineは**同じ最終ビルドで事前準備だけを無効化した比較**であり、元のmainバイナリではない。両側とも入力前後のtrim、再生直前のonInput監査、推論step間の取消確認、noticeの時刻ログを含む。原文・字幕・記憶はtrimしない。
- `firstSentence` は最終flushでも記録するようになった。旧traceの同名点との直接比較には使わない。本文をOSの時刻ログに記録しない。

## 固定snapshotの実機比較

iPhone 16 Pro（iPhone17,1）、iOS27.2、USB、前面表示。直前の実行が高温の冷却待ち上限に達したため、利用者が送風して冷やすと回答した後の実行。冷却条件を含むこの実行での値として扱う。各fixtureで同じsnapshot・到着時刻を2モードに与え、順番を反転しながら3反復。runID `BC6921D6-AE21-4C8F-8D06-99BCC65A5711`。

起点はreply要求、終点はPCMPlayerが実際のrender進行を検出したspeechStarted。音響測定ではなく、話し終わり・ASR境界からの時間も含まない。単位ms、各モードは中央値 / p95、差は対応するprepared−baselineの中央値 / p95（負が短縮）。**3反復のp95は最大値であり、母集団のp95を推定する標本数ではない**。

| fixture | baseline 中央値 / p95 | prepared 中央値 / p95 | 対応差 中央値 / p95 | 再利用 / 先行合成 |
|---|---:|---:|---:|---:|
| immediate | 530.8 / 588.6 | 532.2 / 585.9 | -2.7 / +3.3 | 0 / 0 |
| delayed | 1324.0 / 1326.3 | 932.2 / 934.7 | -391.8 / -374.7 | 3 / 3 |
| two-sentence | 922.0 / 926.7 | 692.7 / 697.5 | -224.5 / -221.5 | 3 / 3 |
| quoted | 1579.3 / 1598.8 | 1139.8 / 1144.2 | -439.3 / -435.0 | 3 / 3 |
| whitespace | 1317.8 / 1323.1 | 920.7 / 923.0 | -402.4 / -393.6 | 3 / 3 |
| changed | 829.8 / 858.0 | 809.8 / 814.2 | -20.0 / +48.8 | 0 / 3 |
| punctuation | 817.3 / 822.5 | 801.8 / 805.7 | -20.6 / -11.5 | 0 / 3 |
| changed-boundary | 768.4 / 827.9 | 819.2 / 820.7 | -7.2 / +53.7 | 0 / 3 |
| changed-long | 827.9 / 833.1 | 830.6 / 831.2 | +3.3 / +62.4 | 0 / 0 |

即時終了・対象外の文で出る差は、再生開始のばらつきも含むため、準備による短縮とは解釈しない。

`delayed`/`whitespace` は700ms、`quoted` は900msの確定待ちを人工的に挿入する。二文は300msで二文目が届く。即時終了・200msでの文変更・句読点変更も含む。16文字の境界候補は3回とも先行合成し、長文候補は0回であることを実機XCTestでも確認した。命中時の一文目の再合成は0件、確定前再生なし、全54件で入力原文の連結と返答が一致した。

全54件でthermalStateは開始・終了ともfairだった。同じ端末の短い試験での観測値。温度の連続測定や長時間の消費電力評価は行っていない。 試験用setupのAVAudioSession同期有効化とQoS優先度逆転についてXCTestの診断警告が出た。警告解消は今回の対象外。 冷却待ちはrequest前の待機を次の試行へ記録したもので、比較の開始時間には含めない。試験前の温度や前試行の発熱も含むため、モード別の冷却時間を発熱量・通常会話の待ち時間の差とは解釈しない。

| モード | 試行内最大footprintの中央値 / p95 | serious/critical終了 | 冷却待ち合計 |
|---|---:|---:|---:|
| baseline | 555.2 / 573.3 MiB | 0 | 30.015664 s |
| prepared | 555.3 / 573.0 MiB | 0 | 0.000074 s |

参考として再生完了までの全体時間と、二文fixtureの文間隔も記録する。文間隔は各モード3観測のみ。

| モード | request→finished 中央値 / p95 | 文間隔 中央値 / p95 |
|---|---:|---:|
| baseline | 2.477 / 4.197 s | 0.125 / 0.214 s |
| prepared | 2.392 / 3.961 s | 0.126 / 0.214 s |

## 最初の有効比較で見つかった退行

制限前の版b47d2a8での48試行は全件正常再生したが、`changed-long` の対応差p95 **+107.74ms** が100ms基準を超えた。合格として扱わず、[生データ](data/2026-10-29-response-latency/failed-gate.json)と[区間分解](data/2026-10-29-response-latency/failed-gate-decomposition.json)を残す。

最悪ペアの差は request→enqueue +4.99ms、enqueue→確定合成開始 +15.87ms、確定合成 −21.26ms、合成終了→PCM開始 +108.14ms。取消drainは約16〜25msで、差の主成分は音声開始側にある。長文推論だけが原因と断定しない。合成総時間÷8もencoder・duration predictor・vocoderを含み、denoiseの1step時間ではない。

対象を、既に重なりを確認した6/13文字程度の入力に近い**正規化後16文字以下**へ絞った。無駄なネイティブ処理を抑える保守的な選択であり、100msの数学的保証ではない。長い候補に効く機会を減らす代償がある。新runIDと境界fixtureを追加した54試行で、基準を変えず検証した。同じコードを成功するまで繰り返した結果ではない。

それ以前の実機試行1はbackground状態とAVAudioEngine561015905で全件不成立。試行2は47行で最後にinactiveとなり、最終ペアを欠いてXCTestがskipした。双方を受け入れ値から除外した。試験fixtureだけにforeground待機、音声sessionの再有効化、表示assertionの更新、元の失敗原因の保持を追加した。 修正後の試行4も42行で冷却待ち600秒の上限に達し、`modelBusy`で試験失敗。42行の再生は全件成功・foregroundだったが、12行欠落のため受け入れから除外した。[途中結果](data/2026-10-29-response-latency/thermal-incomplete.json)を保存し、利用者の送風冷却の回答後、コードを変えず新runで54行を揃えた。run間の行は合成していない。途中で打ち切られた最後の600秒待ちは試行行に記録されず、モード別cooldown合計にも含まれない。

## 現在のClaudeを使う配線確認

同じ最終版、runID `708F5226-A491-40FA-BBCF-2CEB7BFCAAFF`。`claude-haiku-5-5` / `low` / `F1` の定型質問3件。テスト専用memory/usageを使い、robot/cameraはnoop。通常の実機音声再生と原文一致を確認したが、通常のロボット操作や利用者の記憶保存を試験したものではない。

| 質問 | request→PCM開始 | firstCandidate→最初のenqueue | 再利用 / 先行合成 | 観測したtool開始 |
|---|---:|---:|---:|---|
| cloud-0 | 1.401 s | 候補なし | 0 / 0 | 記録なし |
| cloud-1 | 2.293 s | 候補なし | 0 / 0 | 記録なし |
| cloud-2 | 1.876 s | 候補なし | 0 / 0 | express |

75ms未満の候補窓、16文字超過、候補が確定時に変わる場合には、この最適化の効果は出ない。制限前の別smoke3件でも再利用0件だった（候補なし、13.5msの窓、express後に入力が変わり破棄）。そこで観測したexpress spanはSDK経由のTaskLocal伝播を裏づけるが、記録が空であることだけではtool不使用を証明しない。独立した全tool呼出監査は行っていない。

最終3件にはfirstCandidateの観測がなく、先行合成は始まらなかった。

3件のsmokeは配線確認であり、通常会話の分布、因果的なA/B改善、50ターンの遅延NFRの合格を示さない。サーバーの初文字待ち、無音1.2秒、ASR停止の直列待ち、tool往復は残る。実際の音声ターンのboundary→speechStarted、lastASR→speechStarted、captureBoundary→captureClosedは今回収集していない。聴取による発音・自然さ・音切れの評価、音響的な遅延は未確認。

## テスト・レビューと版の対応

| 検証 | 結果 |
|---|---|
| 最終Swift全体テスト | 862件、860成功、実機専用2skip、失敗0 |
| 長文対象制限のTDD | 変更前1テスト3assertion失敗 → 関連28テスト成功 |
| Pythonスクリプト試験 | 29成功 |
| project生成契約 | xcodeproj1.27.0で成功。以後generator変更なし |
| Supertonic資産 / jpreprocess辞書・native receipt | 成功。今回モデル・辞書・Rust変更なし |
| 最終実機比較 / cloud | 各XCTest 1成功、skip/失敗0 |

最初の全体実行で `ConversationRecoveryTests.testEmptyFinalShowsInlineRecoveryWhileCaptureKeepsRunning` に3assertion失敗。空のtranscriptが初期値と一致し、イベント処理前に試験が進む競合だった。実際のエラー表示を待つよう試験だけを直し、元のassertionを保持。39関連試験と全体試験を再実行した。製品のASR回復処理は変更していない。

[独立レビュー](data/2026-10-29-response-latency/independent-review.md)と[agmsg Claudeのレビュー](data/2026-10-29-response-latency/claude-review.md)はbase→8574958を確認。cooldown/hotEndsがモード間で混ざる指摘を重要な検証不具合として修正し、RED→GREENの回帰試験を追加した。最終の6行の短文guardはその後の実機ゲートに基づく変更で、動作テスト・全体試験・実機の境界/長文条件で検証し、許可済みの[Claude -pによる追加確認](data/2026-10-29-response-latency/claude-eligibility-review.md)でも重大な退行は見つからなかった。これは提供したguard周辺だけの確認で、全差分の再レビューではない。ローカルの`preparation`変数名がモデル準備Taskと重なる軽微な可読性指摘は保留。 長さで除外した候補も`preparationDiscarded`が出るので、このイベントは合成の取消回数だけを意味しない。先行合成の回数は`preparationStarted`で数える。除外前の正規化と確定時の再正規化の重複コストも残る。これら軽微な点への追加変更は保留した。

[受領評価と全判断](data/2026-10-29-response-latency/review-reception.md)、[実行履歴と判断の代償](data/2026-10-29-response-latency/execution-ledger.md)、[版・run・設定](data/2026-10-29-response-latency/source.json)、[263ファイルのSHA-256](data/2026-10-29-response-latency/source-hashes.json)、[全体試験結果](data/2026-10-29-response-latency/full-suite-summary.json)。全体試験と実機試験の全263対象ファイルは一致。後続の変更は検証文書だけで、mainにはマージしていない。

通常モードへの再起動は[PID確認](data/2026-10-29-response-latency/normal-launch-check.json)で確認した（テスト用SUPER環境変数なし）。

[判断の一覧と代償](data/2026-10-29-response-latency/rulings.md)、[保留した軽微な指摘](data/2026-10-29-response-latency/deferred-minors.md)。

再集計:

```bash
python3 scripts/summarize_supertonic_integration.py docs/validation/data/2026-10-29-response-latency/paired.json --require-latency-acceptance
```
