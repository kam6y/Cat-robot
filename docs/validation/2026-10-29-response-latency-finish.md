# 2026-10-29 高速化の仕上げと相互レビュー

読み上げ修正済みmain `2fa4ae7` を `feature/response-latency` に取り込み、現在の日本語を残す方式で再検証した。実装・全体試験・実機の対象版は `76a8a9b321bee6a1d46296153d13bbdb9be443b1`。旧全文カナ化での[前回記録](2026-10-29-response-latency.md)とは独立した受け入れ判定である。今回の利用者指示で、旧計画のmain統合禁止は解除され、確認後のスカッシュマージとpushが指定された。

## 相互レビューと変更

agmsgで既存Claudeに実際の `/simplify` を実行させ、4観点のレビューを集約した。同じbase→headをfresh subagentが独立にレビューし、双方が `superpowers:receiving-code-review` で相手の指摘をコードと照合した。rootが唯一のwriterとして採否を判断した。

[Claude simplify](data/2026-10-29-response-latency-finish/claude-simplify.md)、[独立レビュー](data/2026-10-29-response-latency-finish/fresh-code-review.md)、[Claude受領](data/2026-10-29-response-latency-finish/claude-reception.md)、[subagent受領](data/2026-10-29-response-latency-finish/subagent-reception.md)、[最終採否と保留](data/2026-10-29-response-latency-finish/review-reception.md)。

確定後にもう一度読み補正し、一致する声・入力のPCMだけを使う契約、取消後のjoin、確定前に再生しない条件を維持した。モデル/effort/声は実機の現在設定、8steps/speed1.05/CPU2、無音区切り1.2秒を維持。自然な読み上げ修正を戻していない。行のsteps/threads/speedは宣言値で、実行時エンジンの観測値ではない。集計は宣言の整合性を検査する。実際のspeaker呼出8steps、CPU loader/thread2、tts.callのspeed既定値1.05は[対象ソースの確認](data/2026-10-29-response-latency-finish/inference-source-check.json)とhashで対応を取った。voiceは実際の選択値を記録する。

## 現在の方式での実機判定

iPhone17,1/iOS27.2、USB、声 `F1`。11固定snapshot×2モード×3反復、66試行がすべてforegroundで成功。順番は交互。遅延700–900msは人工的な確定待ちで、実会話の分布ではない。同じビルドの事前準備無効/有効を比べた。時刻はrequest→PCM再生callbackで、音響的な発音開始ではない。

漢字が多い16文字の `東京特許許可局許可局長今日出勤。` の変更では毎回1回先行合成し、既存カタカナ16文字境界も残した。`YouTubeで猫を観よう。` は `ユーチューブで猫を観よう。` へのLatin語だけの補正を確認し、遅延後の命中を要求した。長すぎる候補は推論0回。原文の連結はすべて生成結果に一致し、確定前の再生と命中時の再合成は0件。

差は有効−無効（ms）。負は短縮。p95は3組の最大値で、母集団のp95ではない。全fixtureで退行100ms以下、必須命中fixtureで3/3採用・中央値短縮を要求し、基準合格。

| fixture | 中央値の差ms | p95の差ms | 先行合成 | 採用 | 判定 |
|---|---:|---:|---:|---:|---|
| changed | -31.56 | +1.71 | 3 | 0 | 合格 |
| changed-boundary | +14.26 | +14.66 | 3 | 0 | 合格 |
| changed-kanji-boundary | -28.04 | -19.92 | 3 | 0 | 合格 |
| changed-long | +3.58 | +9.18 | 0 | 0 | 合格 |
| delayed | -413.85 | -404.59 | 3 | 3 | 合格 |
| delayed-mixed | -505.63 | -501.27 | 3 | 3 | 合格 |
| immediate | -1.81 | +6.24 | 0 | 0 | 合格 |
| punctuation | -10.40 | -6.47 | 3 | 0 | 合格 |
| quoted | -432.96 | -425.90 | 3 | 3 | 合格 |
| two-sentence | -228.58 | -222.34 | 3 | 3 | 合格 |
| whitespace | -403.01 | -330.34 | 3 | 3 | 合格 |

[生データ](data/2026-10-29-response-latency-finish/paired.json)、[集計](data/2026-10-29-response-latency-finish/paired-metrics.json)、[XCTest結果](data/2026-10-29-response-latency-finish/paired-test-summary.json)。熱状態/待機時間/footprintは生データとモード別集計に保存。長期の発熱・電力や硬い取消期限の保証ではない。

## 現モデルの配線確認と制約

隔離したテスト専用記憶/usage、ロボット/カメラはno-opで、現在モデル `claude-haiku-5-5` / effort `low` の固定質問3件を実行し、すべてforegroundで再生成功。先行合成0件、採用0件。[生データ](data/2026-10-29-response-latency-finish/cloud.json)、[集計](data/2026-10-29-response-latency-finish/cloud-metrics.json)。通常会話一般の改善率、実音声のASR末尾/境界からの待ち時間、聴取による全文章の品質は未測定。入力・記憶の私的な履歴や音声をこの証跡に含めていない。

## 検証とソースの対応

- Swift全体: 863件、861成功、2明示的な実機専用skip、失敗0。[結果](data/2026-10-29-response-latency-finish/full-suite-summary.json)。
- Python: 29成功。xcodeproj1.27.0の生成契約成功。Supertonic資産とjpreprocess辞書/3architectureのnative receipt整合性成功。
- Nativeの修正はmainからの統合のみ。直前の修復で22テスト成功したnativeソース/成果物のreceiptと今回の一致を検証し、同じnativeテストを再実行していない。
- [全263対象ファイルのSHA-256](data/2026-10-29-response-latency-finish/source-hashes.json)が全体試験・実機・最終実装で一致。[版とrunID](data/2026-10-29-response-latency-finish/source.json)、[native receipt](data/2026-10-29-response-latency-finish/native-build-receipt.json)。
- [通常起動のPID確認](data/2026-10-29-response-latency-finish/normal-launch-check.json)で、テスト用SUPER環境変数なしでの再起動を確認した。全体の音声品質保証を意味しない。

再集計:

```bash
python3 scripts/summarize_supertonic_integration.py docs/validation/data/2026-10-29-response-latency-finish/paired.json --require-latency-acceptance
```
