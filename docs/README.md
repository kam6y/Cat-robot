# 文書の索引

この索引は `docs/` に残っている文書の案内です。「現役の仕様」はこの版の振る舞いの基準です。「日付つきの検証記録」は、その日にその版で確かめたことの記録で、今の状態を保証するものではありません。

構成と非同期処理の約束事は [アーキテクチャ](architecture.md) にまとめています。ビルド・テスト・プロジェクト生成の手順は [README](../README.md) を見てください。

## 過去の資料を取り出す

2026-10-28 の整理で、次の資料をリポジトリから外しました（719 ファイル）。

- 完了した実装計画
- 途中の顔レンダ round と iOS 撮影
- 旧 Gemma / MVP 期の仕様と検証データ
- UI 再編・相互レビュー・look の当時の画像
- 完了したエージェント作業記録

これらは基準コミット `69c2a229ac10f410d3101de468e198ad2fa60944` に変更されずに残っているので、次のように取り出せます。

```bash
git show 69c2a229ac10f410d3101de468e198ad2fa60944:<path>                        # 中身を表示
git restore --source 69c2a229ac10f410d3101de468e198ad2fa60944 -- <path>        # 作業ツリーへ戻す
git ls-tree -r --name-only 69c2a229ac10f410d3101de468e198ad2fa60944 -- docs/   # 当時の一覧
```

外したファイルの一覧・サイズは[削除記録](maintenance/2026-10-28-removed-files.json)にあります。残した文書から外した資料への Markdown リンクは、基準コミットの GitHub URL に書き換えました。本文中のパス表記（`renders/round-N/` や計画のパスなど）は、上の基準コミットで開いてください。

## 現役の仕様（`superpowers/specs/`）

| 文書 | 対象 |
|---|---|
| [2026-10-11 要件定義](superpowers/specs/2026-10-11-cat-robot-claude-neck-requirements.md) | 全体要件（Claude 対話＋2 軸の首、iPhone で完結する構成）。版 1.1 |
| [2026-10-23 iOS 首接続](superpowers/specs/2026-10-23-ios-robot-link-design.md) | BLE 接続・校正・自動動作・安全な停止 |
| [2026-10-23 XIAO ファームウェア](superpowers/specs/2026-10-23-xiao-firmware-ble-design.md) | プロトコル v1、安全状態機械、ペアリング |
| [2026-10-24 顔追尾](superpowers/specs/2026-10-24-face-tracking-design.md) | 前面カメラによる顔追尾と首の調停 |
| [2026-10-24 照準補正の設定](superpowers/specs/2026-10-24-face-aim-setting-design.md) | ヨー補正（初期値 8.5°、0〜20°、0.5° 刻み） |
| [2026-10-24 表情](superpowers/specs/2026-10-24-face-expression-design.md) | 表情の種類・`express` tool・自動表情 |
| [2026-10-26 カメラを左に固定](superpowers/specs/2026-10-26-fixed-left-camera-design.md) | 前面カメラを画面左、充電端子を右にした横向き固定 |
| [2026-10-26 待機と寝顔](superpowers/specs/2026-10-26-idle-sleeping-design.md) | 無操作のときの待機・寝顔・停止・復帰 |
| [2026-10-26 look](superpowers/specs/2026-10-26-look-design.md) | `look` tool による撮影と画像の寿命 |
| [2026-10-27 顔サイズ調整ツール](superpowers/specs/2026-10-27-face-size-tuner-design.md) | 別アプリの顔サイズ調整（80% を採用） |
| [2026-10-27 UI 再編](superpowers/specs/2026-10-27-ui-reorganization-design.md) | 設定の階層と会話画面の構成 |
| [2026-10-27 UI 仕上げ](superpowers/specs/2026-10-27-ui-polish-design.md) | UI の仕上げ |
| [2026-10-28 main の整理](superpowers/specs/2026-10-28-main-refactor-design.md) | 今回の責務整理・旧経路の退役・文書とブランチの整理 |
| [2026-10-28 顔の向きによる追尾条件](superpowers/specs/2026-10-28-face-facing-gate-design.md) | 顔の向き（Vision の yaw/pitch）で追尾する顔を絞る条件。左右の判定中心は照準補正に連動 |
| [2026-10-28 日本語の読み変換](superpowers/specs/2026-10-28-jpreprocess-pronunciation-design.md) | jpreprocessによる読み変換と旧2語置換の廃止 |
| [2026-10-29 話し始めるまでの短縮](superpowers/specs/2026-10-29-response-latency-design.md) | モデル・声を維持し、短い一文目の音声を確定待ち中に準備 |

進行中の計画は [2026-10-28 main の整理](superpowers/plans/2026-10-28-main-refactor.md) です。顔の向きによる追尾条件の実装計画は [2026-10-28 顔の向き](superpowers/plans/2026-10-28-face-facing-gate.md) にあります。

## 採用済みのデザイン資料（`design/`）

- 猫の基準画: [cat-character-reference-v1.png](design/cat-character-reference-v1.png)（生成プロンプト: [prompt](design/cat-character-reference-v1.prompt.md)）
- 顔の採用原画（描画計測の基準）:
  - [neutral-b.png](design/face-expression-2026-10-26/neutral-b.png) と [happy-b.png](design/face-expression-2026-10-26/happy-b.png)（各 `.prompt.txt` つき）
  - 比較と最終レビュー: [visual-comparison](design/face-expression-2026-10-26/visual-comparison.md)、[visual-review-final](design/face-expression-2026-10-26/visual-review-final.md)
- 寝顔の採用下書き: [sleeping-draft.png](design/sleeping-2026-10-26/sleeping-draft.png)（[prompt](design/sleeping-2026-10-26/sleeping-draft.prompt.txt)、[visual-comparison](design/sleeping-2026-10-26/visual-comparison.md)）
- 採用したときの iOS 実描画の証跡:
  - 顔: `design/face-expression-2026-10-26/ios/round-8/`（幾何テキスト・provenance）
  - 寝顔: `design/sleeping-2026-10-26/ios/final/`（幾何・iOS と Mac の比較・provenance）

`scripts/render_face.sh` は上の採用原画 3 枚（neutral-b・happy-b・sleeping-draft）を読みます。この 3 枚を動かしたり消したりすると計測が止まります。

**レンダ round の番号は使い回しません。** 過去の round は基準コミットに残っています。次は顔が round-9 から、寝顔が round-3 から使ってください。round のディレクトリが空だと上書き防止が効かないので、番号は手で守る必要があります。

## 日付つきの検証記録（`validation/`）

各記録はその日の版での結果です。「未実施」「未確認」「未達」とされた項目は、後の記録で実施されていない限り、今も成立を確認していません。ここに挙げたのは、各記録に書かれている残りの項目の要約です。正確な条件は本文を見てください。

| 日付・対象 | 記録 | 残っている項目（記録の記述のまま。成功として扱わない） |
|---|---|---|
| 2026-09-26 Supertonic 音声 | [記録](validation/2026-09-26-supertonic-voice-integration.md)、[data](validation/data/2026-09-26-supertonic-voice-integration/) | 一文先読み（sentencePrefetch）を採用した根拠。ライフサイクル試験で、余分な権限確認を見逃す可能性が残る |
| 2026-10-11 Claude 会話エンジン | [記録](validation/2026-10-11-claude-conversation-engine.md) | T-AUTH-1 は合格（TestFlight）。T-AUTH-2 と T-DEV-1/2 は未実施。T-LAT-1 の簡易版は未達（字幕の中央値 2.21 秒、目標 1.5 秒／読み上げ開始の中央値 3.19 秒、目標 2.5 秒）で、50 ターンの受入は未実施 |
| 2026-10-23 XIAO ファームウェア | [記録](validation/2026-10-23-xiao-firmware.md) | 「未実施一覧」の 5 項目: 60 秒窓の外で未ペアを拒否、±60°/±30° の端、復帰中の PING を実機で、`pio device monitor` でリセットしないこと、tick の所要時間 |
| 2026-10-23 iOS 首接続 | [記録](validation/2026-10-23-ios-robot-link.md)、[動作 matrix](validation/2026-10-23-robot-motion-matrix-summary.json) | 2 台目の central を 60 秒窓の外で拒否、再接続時の予約と校正中断の全条件、校正専有の全条件、横向き＋最大文字＋実機 VoiceOver |
| 2026-10-24 表情 | [記録](validation/2026-10-24-face-expression.md) | 当時は、署名ビルド・実機での見た目・VoiceOver・キーボード・実音声・首と追尾の併用が未実施 |
| 2026-10-24 顔追尾 | [記録](validation/2026-10-24-face-tracking.md) | 反対向きの横向きと ±40° は未確認。複数の顔と 10 秒遮蔽は秒数を計測していない。校正画面の受入、500 ms 以下の遅延と PWM の跳ね、実温度＋Qi2 での 1 時間はいずれも未実施。**顔追尾の受入完了は宣言していない** |
| 2026-10-26 look | [記録](validation/2026-10-26-look.md) | 非鏡像の直接確認、OS 設定で権限を変えた後の復帰、取消の厳密なタイミング、熱・割り込み・起動速度、実 Claude での画像解釈とネットワーク上の扱いは未確認 |
| 2026-10-26 待機と寝顔 | [記録](validation/2026-10-26-idle-sleeping.md)、[レビュー](validation/2026-10-26-idle-sleeping-review.md) | 時間の境界と停止・復帰は Simulator の統合テストでしか確かめていない。レビュー後の修正は実機へ配っていない。R3 の制約（認識の終了処理が終わらないと待機が遅れる）が残る |
| 2026-10-26 相互レビュー | [記録](validation/2026-10-26-cross-review.md)、[詳細](validation/cross-review-2026-10-26/) | レビューの採否の記録 |
| 2026-10-27 顔サイズ調整 | [記録](validation/2026-10-27-face-size-tuner.md)、[詳細](validation/face-size-tuner-2026-10-27/) | 80% を採用して本体へ反映した記録 |
| 2026-10-27 UI 再編 | [記録](validation/2026-10-27-ui-reorganization.md) | 通常起動、実音声・カメラ・首の併用、実機 VoiceOver、キーボード表示時の配置は未確認。画像は基準コミットにある |
| 2026-10-27 UI 相互レビュー | [記録](validation/2026-10-27-ui-cross-review.md) | 最大文字でのカテゴリ詳細→校正→文字サイズ変更という逆の経路は未検証。配布後の通常起動と動作確認はしていない。画像は基準コミットにある |
| 2026-10-27 UI 仕上げ | [記録](validation/2026-10-27-ui-polish.md)、[詳細](validation/ui-polish-2026-10-27/) | 文字入力中は、聞き取り状態の切り替えで顔の高さが変わる場合がある（仕様として維持） |
| 2026-10-28 UI 最終レビュー | [記録](validation/2026-10-28-ui-final-review.md)、[詳細](validation/ui-final-review-2026-10-28/) | 最大文字の全画面キャプチャで顔が欠落した。原因は未確定 |
| 2026-10-28 顔の向き | [記録](validation/2026-10-28-face-facing-gate.md) | 実際の人の顔での判定（会話距離・画面端・眼鏡・照明、追尾の停止・約10秒での復帰・再開、閾値近くでの切り替わり、猫の顔を見たときに判定中心の -c 度付近になるか）、実際の Vision 推定値・サーボの挙動・消費電力・発熱は実機で未確認 |
| 2026-10-28 日本語の読み変換 | [記録](validation/2026-10-28-jpreprocess-pronunciation.md)、[計画](superpowers/plans/2026-10-28-jpreprocess-pronunciation.md) | 聴取による発音・自然さの評価は未確認。検証状況は記録を参照 |
| 2026-10-29 日本語読み変換の相互レビュー | [記録](validation/2026-10-29-jpreprocess-cross-review.md) | 双方の受領評価、補正漏れ/ビルド検査の修正、mmapの実機測定。発音・自然さの聴取評価は未確認 |
| 2026-10-29 話し始めるまでの短縮 | [記録](validation/2026-10-29-response-latency.md)、[計画](superpowers/plans/2026-10-29-response-latency.md) | 固定snapshot54試行は基準合格。実会話3件は再利用0件で、普段の会話の改善量・音声境界からの遅延・聴取評価は未確認 |

## 2026-10-28 main 整理の検証

[整理と検証の記録](validation/2026-10-28-main-refactor.md)に、テスト結果・退役したテストの理由・レビュー・ブランチ保全を記録します。
