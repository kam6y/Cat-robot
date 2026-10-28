# jpreprocessによる読み変換の検証

2026-10-28。`feature/jpreprocess-pronunciation`。基点は `def7573`、実装本体は `64c952a`。この記録は検証中で、完了済みの項目と未確認の項目を分ける。

## 変更と範囲

旧 `SpeechPronunciationNormalizer` と旧処理へ戻す経路を削除した。jpreprocess 0.15.0、固定NAIST辞書、Rust 1.90.0の静的ライブラリを使い、専用actorが一度読み込んだ辞書を再利用する。文単位の読みだけをSupertonicに渡し、表示・記憶する原文は保持する。モデル、声、8推論ステップ、先読み1文、同時推論1件は変えない。

URL・メール・バッククォート区間、未知語を含む安全に対応づけられない区間は原文を保持する。これは変換層の契約であり、既存Supertonic内部で記号がすべて保持されることや、未知語の発音を保証しない。辞書・変換エラーと文字数超過は音声エラーにし、未変換の全文で再試行しない。

## 自動検証

- 変更前の発話関連: 23 tests、0 failures (`baseline.log`)。
- Rust: 14 tests、0 failures（実辞書10、C ABI 4）。`native-final-all.log`。
- 資産取得・検査: Python 7 tests、0 failures。実資産のハッシュ・ネイティブのソース/成果物receipt検査も成功。
- プロジェクト生成: xcodeproj 1.27.0の決定性・契約テスト成功 (`generator-swift.log`)。
- Swift関連: 43 tests、0 failures (`swift-green-2.xcresult`)。原文保存、発話・顔・動作の既存検証を含む。
- 全Simulatorテスト: 847件中845件合格、実機専用2件skip、0 failures (`full-suite.xcresult`)。実行約123秒、xcodebuild exit 0。
- 実機の音声・性能: 未実施。
- 最終コードレビュー: 未実施。

RED→GREEN: 名前・演算子・数字の実辞書テスト、C ABI入力/所有権、破損/不足資産、Swift接続とエラー経路。変換中の停止では、停止後に合成と監査通知が進む失敗を確認し、変換直後の取消確認で解消した。`iPhoneとBluetooth`のように文脈により既知名が未知語になる例は、同じ辞書への単語単位の再照会で解消し、回帰テストを追加した。

## 実機比較の条件

専用runnerの `pronunciation` 段階で、`+ボタンを押してね。`、`YouTubeを見よう。`、`3人で25個を分けるよ。`、`こんにちは。今日も一緒に遊ぼうね。`を固定する。原文と変換文を同じF1・8ステップで合成し、WAVと入力・処理後文字列を保存する。これらの原文に旧2語置換は作用しないため、原文は旧方式でモデルに渡した文字列に相当する。乱数状態の同一性は保証しない。

音声サンプルを生成できたことと、聴いて発音・自然さが良いと判断したことは別に扱う。聴取評価は未確認。辞書の初回ロード、短文の通常変換、実機のprocess footprintの前後、アプリのバンドルサイズを記録する。process footprintは同一プロセス中の差であり、辞書だけの厳密なメモリ占有量ではない。

## 実装時に決めたこと

- ユーザーの「完全に置き換え」に従い、失敗時に旧処理へ戻さない。上限超過・初期化失敗では発話が失敗するという影響がある。
- XCFrameworkが公開するCモジュールの経路を使う。重複する手動のSwift検索経路は削除し、実際のapp/testコンパイルとgenerator契約で確認した。異なるXcodeで自動公開が変わる場合は、ビルドエラーとして検出される。

## 証跡

この端末の `/private/tmp/cat-jpreprocess-implementation-20261028/` にログ・xcresult・入力/出力・source hashを保存する。辞書archive SHA-256: `8a930bbc57bf4adcf521d53544c7dc9ab8ab3aa997a591b1b1608dc5539017b8`。固定ソース・依存ライセンスと再作成手順は [PROVENANCE](../../CatRobot/Vendor/JPreprocess/PROVENANCE.md) と [README](../../README.md#日本語の読み変換の準備) を参照。
