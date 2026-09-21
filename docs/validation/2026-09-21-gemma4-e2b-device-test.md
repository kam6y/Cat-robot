# Gemma 4 E2B — iPhone 16 Proでの推論検証

## 結論

2026-09-21に、main `d3db63e5e4770d17fb4180e0d4a5baac56d4d051` から作成した `feature/gemma4-e2b-device-test` で実機検証した。

**Gemma 4 E2Bの日本語ストリーミング生成と、4Kを超える文脈からの情報取得に成功した。** 6往復の合成会話で飲み物の好みの訂正を保持し、別の新規セッションでは6,805入力トークンの冒頭に置いた合言葉を回収した。実機専用XCTestは1件実行、1件成功、スキップなし。

これは推論単体の検証用コードであり、製品への採用判定や猫アプリのGemma切り替え実装ではない。アプリ本体のソースはmainと同一。音声認識・宛先判定・読み上げ・UIまで含めたGemma会話は今回検証していない。

## 再現条件

| 項目 | 値 |
| --- | --- |
| 実機 | iPhone 16 Pro、USB接続 |
| OS | iOS 27.2（24B5084k） |
| ビルド環境 | Xcode 27.0（27A266a）、macOS 26.6.2 |
| Swift package | 公式 `google-ai-edge/LiteRT-LM` 0.17.1 |
| package revision | `5e58e9a0aef7abf7091207a8b1d1063a1c800f08` |
| iOS binary | packageが参照する公式0.17.0の `CLiteRTLM.xcframework` |
| binary ZIP SHA-256 | `c94fc12aa0403cb47208e419cc3bfe258214ea17035f7a63c16de536869f2186` |
| モデル | `litert-community/gemma-4-E2B-it-litert-lm` の `gemma-4-E2B-it.litertlm` |
| モデルサイズ | 2,588,147,712 bytes |
| モデル SHA-256 | `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c` |
| 同一ファイルを取得できるモデルrevision | `b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1` |
| 推論 | GPU、最大8,192トークン、出力上限160、thinking無効 |
| サンプリング | topK 1 / topP 1 / temperature 0 |
| 初期化 | 7.801秒（新規の0.17.1専用cacheディレクトリ） |

端末上にあったモデルをストリーミングSHA-256で確認して再利用した。旧PoCのソース・履歴は取り込んでいない。旧 `feature/gemma4-foundationmodels-poc` は削除済み。未コミット変更のあった旧worktreeはdetached HEADで保全し、ほかの比較・記憶ブランチは変更していない。GitHubには当該PoCブランチは存在しなかった。

今回の配布モデルの説明にある対応文脈長は32K。モデルファミリー全体の128K仕様と混同しない。本検証は8K設定までで、16K/32Kは未測定。

## 実測結果

時間はテキストをモデルに渡してからの経過で、モデル初期化・音声認識・読み上げは含まない。

| ケース | 入力token（そのターン） | 最初の非空テキスト | 生成完了 | decode token/s |
| --- | ---: | ---: | ---: | ---: |
| 初回・自己紹介 | 54 | 0.839秒 | 1.217秒 | 19.9 |
| 励まし | 19 | 0.208秒 | 0.569秒 | 40.2 |
| 家での遊び | 19 | 0.184秒 | 0.684秒 | 44.2 |
| 麦茶が好きと伝える | 19 | 0.188秒 | 0.425秒 | 46.4 |
| ほうじ茶へ訂正する | 24 | 0.176秒 | 0.484秒 | 45.7 |
| 好きな飲み物を質問 | 15 | 0.172秒 | 0.360秒 | 47.1 |
| 長文の冒頭の合言葉 | 6,805 | 8.439秒 | 8.599秒 | 42.3 |

短い会話は同一セッションの履歴を再利用。初回を除く5ターンの返答開始中央値は0.184秒。長文は別の新規セッションで全文を処理しているため、この8.439秒を「長い会話での毎ターンの待ち時間」とは解釈しない。

プロセスのピークresident memory（`getrusage.ru_maxrss`）は1,746,894,848 bytes（約1.63 GiB）。これはプロセス単位のhigh-water markであり、モデル単体のRAMやGPUメモリの厳密な内訳ではない。記録したthermal stateはすべてnominal。表の数値は初回測定。再実行も成功したが、いずれも短い試験であり、長時間使用時の発熱・電池消費は評価していない。

## 出力の観察

- 自己紹介: 「にこにこ！私はあなたのための、ふわふわのAI猫だよ。😊」
- 好み訂正後の回答: 「ほうじ茶が一番好きだよ！😋✨」
- 長文の回答: 「『紫の風船』です。」（生データの表記はJSON参照）

日本語での応答、訂正後の語句保持、合言葉回収の機械チェックを通過した。一方、「家でできる遊びを一つ」という問いに読書と音楽の2案を挙げており、細かい指示遵守の改善余地がある。好みへの応答も猫自身の好みのように読めるため、主語の明確さは採用前に評価したい。大規模な品質評価や他モデルとの優劣は主張しない。

長文の妨害文は英語の反復レコードで、指示と合言葉は日本語。自然な日本語の長時間会話、複数話題、tool callingの性能を証明するテストではない。

## 既存テストとの比較

- 変更前mainを同じ実機で実行: 237件中228成功、9失敗。
- 追加後の通常CatRobot scheme: 238件中228成功、9失敗、Gemma実機専用1件スキップ。
- 失敗9件はすべて同一の `SpeechAudioConverterTests`。追加による新たな失敗はないが、全体のテストスイートはgreenではない。
- Simulatorの初回基準実行は起動待ちが進まず中断し、実機で確定した結果を採用した。
- プロジェクト生成の契約チェックは成功。

9件の名前とクラッシュ分類は [main-test-summary.json](gemma4-e2b-2026-09-21/main-test-summary.json) と [regression-test-summary.json](gemma4-e2b-2026-09-21/regression-test-summary.json) に記録。OS 27.2 / Xcode 27での既存音声テスト互換性は別途調査が必要。

## 再実行

ロック解除した実機のUDIDを `xcrun devicectl list devices` で確認する。

```bash
# このブランチのルートで実行。署名用のXcodeアカウントが必要。
scripts/run_gemma_device_test.sh '<iPhone UDID>'
```

モデルをまだ配置していない端末では、下記の固定URLからファイルを取得し、第2引数に渡す。スクリプトと実機テストの両方でSHA-256を検証する。モデルはリポジトリにコミットしない。

```text
https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/gemma-4-E2B-it.litertlm
```

```bash
scripts/run_gemma_device_test.sh '<iPhone UDID>' '/absolute/path/gemma-4-E2B-it.litertlm'
```

初回のpackage取得は時間がかかる。`GIT_LFS_SKIP_SMUDGE=1` はAppleで使用しないLFSバイナリを省くだけで、Apple用XCFrameworkは公式packageのチェックサムで検証される。

結果は `.build/gemma-device/<UTC日時>/` に保存される。`test.xcresult` が実行ごとの判定根拠で、成功時のみ便利な `results.json` を実機から回収する。失敗時は以前の実機JSONを成功証拠として回収しない。テスト中は端末をフォアグラウンドでロック解除したままにする。

上記スクリプトも、モデル配置済みの同じ実機で最後まで実行し、1件成功・失敗なし・スキップなしと結果JSONの回収を確認した。未配置端末へのモデル転送経路は未検証。

ソースを変更した際は `ruby scripts/test_generate_project.rb` でプロジェクトを再生成・検証する。パッケージ解決やビルドと同時に生成スクリプトを実行しない。

## 証拠と次の判断

- [実測データ（合成プロンプトと返答を含む）](gemma4-e2b-2026-09-21/results.json)
- [実機専用テスト結果](gemma4-e2b-2026-09-21/gemma-test-summary.json)
- [再実行スクリプトのテスト結果](gemma4-e2b-2026-09-21/runner-test-summary.json) / [再実行時の実測データ](gemma4-e2b-2026-09-21/runner-results.json)
- 元のxcresultとビルドログ: `/private/tmp/cat-gemma-20260921/`（一時ファイル）
- [公式LiteRT-LM 0.17.1](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.17.1)
- [今回の配布モデルの説明](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/blob/b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1/README.md)

小規模な日本語対話の返答エンジンとして検討を続けられる結果。次に採用判断をするなら、同一セッションで自然な日本語会話を長く続ける試験、キャンセル・再開、音声の最初の出力までの時間を確認する。長文を毎回再投入する方式の待ち時間は今回の結果から課題がある。
