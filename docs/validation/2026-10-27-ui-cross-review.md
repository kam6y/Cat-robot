# UI整理の相互レビューと修正

2026-10-27。対象は `9ee8dacbe31e2bc3295eaa8f623049cc771bfb64` → `90e98c2f011c027eeb88f2d6f29d080411515cb7`、修正コードは `94eef6308f73cdda8932a71819700402b17ed9a9`（`feature/ui-reorganization`）。

Claude に `/simplify`、Codex の独立したサブエージェントに `requesting-code-review` を依頼し、結果を交換して双方が `receiving-code-review` で検証した。重要な指摘は1件で、再現して修正した。コード整理は6件を全部または一部採用した。その他の提案は理由を記録して見送った。

- [Codex の独立レビュー](ui-cross-review-2026-10-27/codex-review.md): Critical 0、Important 1、Minor 0。
- [Claude の /simplify](ui-cross-review-2026-10-27/claude-simplify.md): 再利用・簡略化・効率・抽象化の4観点。C1 は Codex の指摘を受けて確認したもので、独立発見として二重に数えない。
- [Codex による指摘の検証と採否](ui-cross-review-2026-10-27/codex-reception.md)、[Claude による指摘の検証と採否](ui-cross-review-2026-10-27/claude-reception.md)。

## 修正した問題

文字入力中にエラーまたは記憶カードが表示・解除されると、画面の分岐によって別の `TypedInputView` が生成されていた。その結果、選択範囲が末尾へ移り、エラー表示中の送信ではフォーカスと消去済みの下書きが戻った。

上側の内容だけを切り替え、入力欄を共通の構造内に1つだけ置く形に修正した。余白の違いは同じ修飾子の値で表し、入力欄の同一性を維持する。

修正前の試験では、カードの4遷移で12箇所、送信後の状態で3箇所の検証が失敗した。修正後はすべて通過し、従来の画面サイズ変更・警告の重なり・顔の大きさの試験も通過した。[修正前後の記録](ui-cross-review-2026-10-27/regression-evidence.txt)。

送信試験は実際の SwiftUI 画面と送信ボタンを、Simulator の window scene に載せて操作している。送信後の状態は試験用のコールバックで更新し、音声や外部モデルを呼び出していない。選択範囲の試験は模擬 viewport と safe area を使う。実機の日本語入力・変換操作まで試験したという意味ではない。

## コード整理の判断

| 指摘 | 対応 |
|---|---|
| C2 メニューと寸法の重複 | メニュー表示を共通化し、ボタン寸法と余白からチップの空間を計算。汎用のスクロール修飾子は作らない。 |
| C3 不要になった表示用の派生値 | 4つを削除。古い字幕の試験を、look のチップと待機中の返答アクセスの試験へ更新。元の字幕・認識結果・状態の保存値は保持。 |
| C4 未使用のアクセシビリティ値 | `assistantStatus` と代入を削除。使用中のマイク表示と活動状態の通知は保持。 |
| C5 再接続の文言 | 既存の文言を再利用。表示条件は混同しない。 |
| T1 スクロールの探索 | 同一の補助処理を既存のテスト支援ファイルへ移動。 |
| T2 描画の重複 | 描画を確定する補助から画像を返し、撮影と画素計測で再利用。 |

設定のヘッダー変更（C6）、依存の異なる fixture の統合（T3）、準備完了を保証しない待ち時間の短縮（T4/T5）は採用しない。テスト用の非公開アクセシビリティ記号への依存（T6）は既存の診断とともに制約として記録する。

## 校正画面の追加確認

標準文字で校正を開き、最大アクセシビリティ文字サイズを経て標準文字へ戻しても、同じ校正セッションとナビゲーションを保つことを確認した。アプリが指定するラベルで戻るボタンを操作し、未保存の変更に対する確認が開き、取消後も編集が続くことを検証した。校正の製品コードは変更していない。

初期の試験は短いラベル「戻る」を探していたが、それがアプリの戻るボタン内の UIKit 要素であると確認した。最終試験はアプリ側のラベル「ロボットの設定へ戻る」を使う。確認ダイアログは NavigationStack 内の presenter から取得する。Popover の取消ボタンが省略される場合は公開 API `accessibilityPerformEscape()` で取消操作を行う。Popover での取消表示は [Apple の confirmationDialog の説明](https://developer.apple.com/documentation/swiftui/view/confirmationDialog%28_%3AisPresented%3AtitleVisibility%3Aactions%3A%29)に従う。[調査と最終試験の記録](ui-cross-review-2026-10-27/calibration-evidence.txt)。

確認ダイアログ単体の添付画像は描画が黒くなったため、目視確認の証拠には採用していない。確認の表示・取消と編集状態の維持は、実際の操作、window への接続、ナビゲーションと状態の検証結果に基づく。

大きい文字のカテゴリ詳細から校正を開き、その後文字サイズを変える逆経路は未検証として残す。具体的な不具合は確認されていない。

## 最終検証

- 全体 XCTest: **832件、成功830件、スキップ2件、失敗0件**。
- スキップは操作する人が必要な実機試験 `RobotMotionIntegrationDeviceTests.testSelectedStage` と `SupertonicIntegrationDeviceTests.testSelectedStage`。
- Simulator: iPhone 18 Pro / iOS 27.0。試験中およびコミット後に223ファイルの検証対象が同じ内容であることをハッシュで確認した。
- [テスト概要](ui-cross-review-2026-10-27/full-test-summary.json)、[実行条件](ui-cross-review-2026-10-27/verification.json)、[検証対象のハッシュ](ui-cross-review-2026-10-27/final-source.json)、[確認画像とハッシュの一覧](ui-cross-review-2026-10-27/image-manifest.json)。

| 確認対象 | 画像 |
|---|---|
| エラー表示中も選択範囲を維持 | [エラーと入力欄](ui-cross-review-2026-10-27/images/typed-card-error-appears.png) |
| 記憶警告が出ても選択範囲を維持 | [記憶カードと入力欄](ui-cross-review-2026-10-27/images/typed-card-memory-warning-appears.png) |
| 送信後の下書き消去とフォーカス解除 | [送信後](ui-cross-review-2026-10-27/images/typed-error-send-focus.png) |
| 文字サイズを変えても校正を維持 | [最大文字の校正](ui-cross-review-2026-10-27/images/settings-calibration-text-size-accessibility5.png) |

2026-10-27、ユーザーの依頼でレビュー後の `b11b1e2` の版を iPhone 16 Pro へ更新インストールした。実機向けビルド、コード署名、埋め込んだソース版、端末上のインストール先の一致を確認した。223ファイルの検証対象も最終試験時から変わっていない。[今回の配布記録](ui-cross-review-2026-10-27/device-deployment.json)。通常起動や動作確認は行っていない。実機の音声・カメラ・首の併用、VoiceOver の実音声、日本語キーボードの変換は今回も未確認。
