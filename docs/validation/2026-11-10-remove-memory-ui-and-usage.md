# Hermes 移行②: 記憶管理画面と利用量処理の撤去

基点: `173356054790fd62b74f061b25e9193c8e6a8d92`。ブランチ: `refactor/remove-memory-ui-and-usage`。初回候補の全Simulatorテストは成功。独立レビューと親の追加確認はCritical/Importantなし。レビュー後の修正はコメントと検証記録の保証範囲の訂正に限定した。

## 変更範囲

設定の「記憶」「利用量」、長期メモ一覧・削除、日次上限の設定と返答抑止を撤去した。会計の計測・保存、概算トークン数・USDの算出、専用meter/decorator/画面モデルと依存注入も削除した。`MotionReplyGenerator`はClaudeのサービスを直接呼び、prewarmも日次上限で止めない。

現在の会話・宛先判定・短期/長期記憶エンジン・音声・カメラ・顔追尾・BLE・校正は継続する。認証、文脈/返答長、タイムアウトと物理安全制限は保持した。Hermesへの通常経路の切替は今回の対象外。

## 自律判断と理由

| 不明点・選択 | 決定 | 理由 |
|---|---|---|
| 旧メモ/履歴と旧UserDefaultsキー | 起動時削除・移行処理を追加しない | 削除は許可されているが必須ではなく、今回残すエンジンの新しい会話データを消さないため。親も承認済み |
| 設定の削除操作の内部API | UI専用coordinator関数を削除し、view model/serviceの忘却・復旧経路は保持 | 記憶エンジンの全撤去は後続段階のため |
| `CachedSession.model`とcompositionの長期メモプロパティ | 集計専用のモデル保持とUI注入専用プロパティを削除 | 残すサービス自身が必要なセッション・記憶を保持するため |
| 過去spec/検証/分岐HTML | 日付付きの過去記録を保存、現行README/architecture/索引/初回説明を更新 | 静的スナップショットを現在の仕様と誤認させないため |
| 検証用の開発キー資源 | 新worktreeの空ファイルだけ作成 | 既存Debugビルドが必要とするplaceholder。秘密値の読取・コピーはしない |

## TDDと生成project

専用Simulator: `32623B53-C27C-480C-8478-3F277BAE8431`、iPhone 17 Pro / iOS 27.0。既存booted端末は変更していない。詳細ログは共有scratchの`cat-impl-20261110/step2/`に保存。

| 段階 | 結果 | 候補のtracked diff SHA-256 |
|---|---|---|
| RED1: 設定カテゴリ/識別子、旧日次設定、live composition | 4 tests、7期待assertion failures、exit 65 | `f0bb926f3f845918d29baa7aa015a496a475f4a3334db252a78b26307446d638` |
| RED2: 上限到達時も返答を期待、会計非保存を期待 | 2 tests、2 failures、exit 65。実際にdailyLimitReachedをthrow、旧会計データは25→138 bytesへ変化 | `4d2bf2b82fdd8e986bfc7419608a67c55e8871212d22ade84c9992f1522c5bd0` |
| GREEN1: 上記6件、撤去後APIに合わせた同じ成功/記憶期待 | 6 tests、0 failures、exit 0 | `1618d3c57a305c7be3249636415ea730e9f2cdb8a6c37fbb8633839b66ddfae7` |
| `ruby scripts/generate_project.rb`と`ruby scripts/test_generate_project.rb` | exit 0、deterministic project contract PASS | GREEN1と同じ生成project |
| 全Simulator suite（初回説明の文言変更も含む） | 1044 tests、4 skipped、0 failures、exit 0 | `b06eea8231f5dfa71cd785a142c0d2268b4c6559c56539e37842b91aa5c9c96c` |

各xcodebuildの前後でtracked diff不変を確認し、HEAD・全コマンド・時刻・exitを各段階の`receipt.json`に保存した。RED1の初回はキーplaceholder欠落、RED2の初回はテスト内のUserDefaults参照をactorへ共有したSwift 6診断でコンパイル失敗。どちらも期待したREDとは数えず、原因を直して実測し直した。RED2のthrowはXCTest上ではunexpectedに分類されるが、エラー値が撤去対象の日次上限であることをログで確認した。

GREENの返答試験は`testReplyPipelineCompletesAndPersistsWithRetiredDailyLimitSetting`へ改名し、撤去されたUsageSpyの代わりに旧設定キーを残す。確認するのは旧キーが残った状態での1ターン目の応答、セッション数、`recentTurns`で読める確定記憶までであり、上限を超える複数ターンやstoreへの書込み自体はこの試験では観測していない。取消、保存と再試行、忘却との順序は既存のservice/persistence試験で扱う。

会計非保存試験のGREENが観測するのは、モデル設定に渡した指定UserDefaults suiteの旧キーと無関係な設定が変化しないことだけである。このsuiteはサービスの実保存先として渡されないため、会計保存全体の非実行や将来の`.standard`への保存再導入を保証しない。今回の会計保存撤去の根拠は、実meterが旧データを更新したRED2の記録と、meter/decorator/会計保存の実装・専用依存を削除した最終差分である。

全体試験は`xcodebuild -project CatRobot.xcodeproj -scheme CatRobot -destination 'platform=iOS Simulator,id=32623B53-C27C-480C-8478-3F277BAE8431' -derivedDataPath /private/tmp/cat-impl-codex-step2-dd CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO test`。2026-11-10 02:10〜02:13 JST、入力は前後不変。skipは明示opt-inが必要な`ClarificationHistoryModelTests.testAcceptanceMatrix`、`HaikuAddressingModelTests.testAcceptanceMatrix`、`RobotMotionIntegrationDeviceTests.testSelectedStage`、`SupertonicIntegrationDeviceTests.testSelectedStage`の4件。実モデル課金、実機の駆動・発声を伴う試験を成功とは扱わない。

設定と初回説明の標準サイズの生成画像を目視確認し、4カテゴリへの縮小と長期メモが残る説明の表示を確認した。大きい文字を含む4枚はscratchの`step2/visual/`へhash付きで保存。UIナビゲーション・Dynamic Type・校正シートの既存試験も全体試験に含まれる。

レビュー後のコメント修正を含む最終候補も、同じコマンドで2026-11-10 02:44〜02:47 JSTに再検証し、1044 tests、4 skipped、0 failures、exit 0だった。tracked/untrackedのソース・テスト・生成project・scripts/nativeを含む入力manifestは前後一致し、SHA-256は`105d10114f70e20e0ea55940df11a2cb16ae27b2988231f36ad034c1d6777c25`。詳細は`step2/final-suite/{before.json,after.json,receipt.json,xcodebuild.log}`。生成project contractと`git diff --check`も成功した。結果の追記後に実装入力は変更していない。

## 独立レビューと採否

Claudeの実際の`/simplify` report-onlyを再利用・簡素化・効率・責務の4つの新しい読取専用コンテキストで実施し、Codexも新しい独立レビュアー1名で同じ候補を確認した。双方の初回を保存した後に交換し、`receiving-code-review`で実コードと照合した。親の追加独立チェックも同じ初回候補を確認し、重大・重要指摘はなかった。

採用したのは、存在しない設定UIを説明していたコメントの訂正と、上記のテスト保証範囲の限定である。テスト削除・配線のインライン化・未使用テスト引数の整理は今回延期し、記憶エンジンの削除は後続範囲とした。`.task`のライフサイクル変更や未計測の性能説明も追加していない。初回本文・採否とhashは共有scratchの`step2/review/`、親の判断は`parent-step2-review-go.md`に保存している。

## 完成判断と未確認事項

- レビュー後の文言修正: 同じCodex独立レビュアーが軽微指摘の解消を確認し、Claude Navigatorも差分を照合した。最終候補の全Simulator suiteは上記のとおり成功。
- 実機: この段階では未実施。Simulatorの結果を実機確認とは扱わない。
- commit/push/PR: 必要修正の検証と相互確認後、②のみ進める親GOを受領済み。mainへのmergeは未承認。①の接続プローブPRは②の確定コミットを土台にする。
