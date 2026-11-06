# issue #26: 再生音量0の警告チップ

2026-11-06 JST。[issue #26](https://github.com/kam6y/Cat-robot/issues/26)に対応。main `ce72201dca73c289de95085fa79f67bef7bf4b16` から `codex/issue-26-muted-audio-warning` を作成した。

ユーザーの最終訂正により、検出対象は再生音量0だけ。消音モードでも現行アプリは再生するため、その検出は不要と指示された。既存の橙色警告チップへ「音量が0です」を追加し、正の音量へ戻ると消す。会話・録音・読み上げやユーザーの音量は変更しない。[設計](../superpowers/specs/2026-11-06-muted-audio-warning-design.md)を参照。

## 実装と検証

既存のaudio driver/KVO/event hub/VM/status chip経路を再利用。初回snapshotとactivate成功後の再読取で初期0・復帰を覆う。eventは値を運ばず受信時の現在値を読む。実controllerのgetterは非隔離・同期で、ブロック中のactivateのactor queueを待たない。既存の遅延observerがKVOを1個所有し、破棄時にinvalidateする。通知は表示flagだけを更新し、awaitの前後でshutdown/cancellationを確認する。

| 段階 | 実行結果 |
|---|---|
| 変更前 | 関連78件成功 |
| 初期0のRED | 既存78件成功、新規1件が警告の断定で失敗（buildは成功） |
| 初期の最小実装 | 関連79件成功 |
| KVO/復帰のRED | 未接続の監視・activate更新・共有・寿命に関する4テストで5断定が想定どおり失敗 |
| typed fixture訂正 | 別の追加テストが音声startedを送っておらずthinkingのままだった。製品変更なしで入力イベントだけ直し、単独1件成功 |
| 監視接続後 | 関連84件成功、SwiftUI表示2件成功 |
| 全体 | **983件成功、失敗0、skip0**（専用実音声/ロボット2クラスは事前に明示除外） |
| 生成器/契約/Simulator build | 成功、deterministic contract PASS |
| 通常署名アプリ | 2b453e4からbuild/codesign/モデル8資産/混入XCTest0を検証。実機へインストールし、テスト引数なしの通常起動とprocess10119を確認 |

Xcode27.2、iPhone18Pro/iOS27.0 Simulator。既存 `SUPER_INTEGRATION_TESTS=1` でライブcompositionを抑制した。実API・収録・ロボット試験ではない。controllerの試験はOSの音量入力のみを制御し、Foundationの実KVO token、実controller/event hub、実VMとSwiftUIを検証する。0↔正（最小正Floatも含む）、音声制御への副作用なし、started後のtyped返答、読み取り待ちshutdown、共有観測と解放を確認した。

正常表示ではチップ全体が見え、最大アクセシビリティ文字と240ptのtyped画面では既存のスクロールで内容へ到達できる。メニューや入力欄との重なりはgeometry/AXの断定で検証した。Simulator画像6枚のhashも保存し、通常・大きい文字のスクロール後・typed上下を目視した。実機VoiceOverの操作受入を意味しない。

[結果と入力hash](data/2026-11-06-muted-audio-warning/results.json)を保存する。初回の固定レビューは `ce72201..2b453e4`、diff SHA-256 `33044186324b18e011791a750a0b65f5f71e7fca5f0cfd3129c23edab473708c`。84関連/2表示のビルド入力は本番・テスト・project差分 `0b3af2e779817f16f3b78a12d67403dfdfa07c3bf835f5098bd50df32d90bce4`、その内容が固定コミットと一致することを確認し、983全体はcleanな2b453e4で実行した。

## 相互レビュー

Codexを単一writerとし、agmsgのClaudeが実際の `/simplify` で再利用・簡素化・効率・変更箇所の深さの4担当をread-onlyで並行実行した。別の独立サブエージェントが `superpowers:requesting-code-review` で同じ凍結差分を確認。双方の初回保存まで相手の報告は読まず、その後、双方が `superpowers:receiving-code-review` で実コード・証跡を照合した。追加fanoutは行っていない。

独立レビューは指摘なし。ClaudeはImportant0、Minor4、Nit7で、統合ブロッカーなし。親が全項目を評価して下表の小変更を反映し、双方が5ファイルの修正差分を再確認した。

| ID | 採否 | 理由・反映 |
|---|---|---|
| C1 | 維持 | missing-read回帰で無期限に待たないよう、上限付き待機とtest-only入口カウンタを残す |
| C2 | 部分採用 | 既存allChipsへ音量0と期待配列を追加。専用listening/最大文字/解除の検証も維持 |
| C3 | 採用 | Boolが同じならviewStateへ再代入せず、不要な観測通知を避ける。macOSの小さなObservation probeで同じnested Bool代入は通知1、guard時0を双方が確認。iOS描画時間やコストは未計測 |
| C4 | 採用 | live/fake KVOで捨てていたnew-value取得optionを除去。変更通知と現在値の再読取は維持 |
| C5/C6/C7 | 維持 | 明示のTask取消/終了ガード、初期handler呼出し、同じ所有境界のKVO invalidateを残す。初期呼出しはOS通知を偽造しない |
| C8 | 採用 | typed fixtureコメントのチップ数を3から4へ訂正 |
| C9 | 維持 | 実adapterが音声をdeactivateしないtripwireを残す。VMのfake controllerではこの境界を覆えない |
| C10 | 採用 | fakeの観測metadataを既存lock/Stateへ移し、weakを維持。KVO登録そのものはlock外 |
| C11 | 部分採用 | READMEの再開時確認の一文だけ短縮。利用者向け情報と、旧UI仕様の条件警告の例外は維持して矛盾を避ける |
| D1/D2 | 再設計なし | async domain getterや、既存event/current-read経路を維持。別stream/taskやIF変更を正当化する観測障害はない |

Claudeは相互確認で、初期dispatcher呼出しを「OSイベント捏造」とした表現と、adapterのisActive断定に回帰検出価値がないかのような表現を訂正した。双方の最終差分確認で未解消のCritical/Important/Minorはない。修正差分のSHA-256は `1930b46d5f20bd1d39970c116dc020bfdb9e7fad19931e80d19ac4cf378b9ff6`。修正後の最終入力は `2b453e4` + 本番/テスト/project差分 `65f93a063fa1d3c32223de5039b4905aeb1de8e061c2c6536f3f26682a0340fd`、当初mainからの集約差分は `944210b2a16aea8d4f8a8929a13ec4a9975ea457ac3bdd2204617de53330380c`。

最終再検証: 関連84件成功、表示3件成功、全体983件成功（失敗0）。生成契約とSimulator buildも成功。

## 実機と限界

ユーザーが実機の聞き取り中に音量0→正を操作し、「表示され、音量を上げると消えた」と確認した。対象版は2b453e4（整理前の固定版）。以後の本体変更は同値通知と不要なKVO payload取得の抑止のみで、警告の条件・解除・音声制御は変更していない。通常起動・プロセス確認とは別の、実OS/音量操作による検証として記録する。

OSが非active中のKVO通知を止める場合、その間の即時更新は保証せず、次のactivate成功時に再確認する。警告のためだけにsessionをactivateしない。実際のspeaker/Bluetooth各経路・inactive時の通知配信は制御したKVO sourceだけでは証明しない。モデル・Smart Turn・effort・会話履歴の仕様は変更しておらず、継承機能は再監査せず全体回帰で検証した。

レビュー・xcresult・画像・通常署名版の証跡は `/tmp/cat-issue26-muted-audio-20261106/` に保持する。最終統合/remote一致は `integration.json`、統合版の実機更新は `main-normal/normal-verification.json` に保存する。
