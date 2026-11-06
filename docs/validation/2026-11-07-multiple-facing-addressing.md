# issue #28: 複数人の顔向きによる宛先判定省略

対象: [issue #28](https://github.com/kam6y/Cat-robot/issues/28)。main `b59f0b9dc93d97ee79204e824961bafdd390cb19`から`codex/issue-28-multiple-facing`を作成した。

## 実装と検証済みの範囲

`ConversationCamera.hasFreshFacingFace`の「検出した顔がちょうど1人」の拒否条件だけを外し、既存`FaceTrackingGeometry.selectFace`が有効でこちら向きの顔を選べるかで判断する。複数人中の1人でも条件を満たせば宛先分類を省略し、発話全文を返答生成へ渡す。空配列や全員横向きでは候補がなく、顔による省略を使わない。

0.4秒未満の鮮度、許可・会話前面・聞き取り中・世代・熱・不正値、左右補正と頭の向きの範囲、カメラ共有、首の追尾対象選択を維持する。顔と声の人物の対応付けはしない。15秒の確認待ちの肯定・否定、30秒／最大5分の継続ルールは変更せず、複数人中の顔向きでも従来の開始・更新を行う。モデル・声・数値の読み・履歴保存は変更していない。

## Driver / Navigatorの実際の交代

agmsgで既存のClaudeペインを使った。複数の実装者が同時に書き込まず、役割と対象ファイルをメッセージで明示し、テストの区切りで交代した。

1. **Codex Driver／Claude Navigator:** Claudeが既存selectorの再利用、RED観点、文書の残存条件を確認。Codexが実カメラ→実会話VMを通る回帰テストを書き、実装を変える前にREDを実行した。Navigatorは差分とテスト選択名を確認した。
2. **Claude Driver／Codex Navigator（ACK 17:55:56 UTC）:** Claudeが`ConversationCamera.swift`を実際に編集。Codexがlive diffを読み、鮮度等のguardとselectorが残ることを確認してGREEN実行を提案した。Claude自身がSimulatorビルドと関連テストを実行した。
3. **Codex Driver／Claude Navigator（RELEASE 17:57:53 UTC）:** GREEN後に編集権を戻し、Codexが文書・分岐図を更新。Claudeは人数条件の残る要件表FR-CONV-2と図の参照行を指摘し、Codexがその範囲を修正した。過去の#22レビュー・検証報告は書き換えず、設計文書へ更新先を明示した。
4. **Claude Driver／Codex Navigator（ACK 18:28:53 UTC）:** 独立初回レビューと双方の受領評価を保存してから、図の旧人数表記とsnapshotの位置付けを修正。Codexが実差分、図・CSS・操作JavaScriptの不変と入力digestを照合してGOを送り、Claude自身が隔離Chromeの旧版失敗／新版成功を確認した。RELEASE 18:34:47 UTCで編集権を戻し、Codexが検証・レビュー記録をまとめた。

各交代で旧Driverはソース編集を停止し、新DriverがACKしてから編集した。ビルド・試験中は双方ともコード入力を固定した。実際のNavigator報告とClaudeのGREEN実行記録は[レビュー記録](multiple-facing-review-2026-11-07/)に保存した。

## 自動検証

- 変更前の顔向き・カメラ・geometry **54件PASS、失敗0・skip0**。
- 追加・拡張した3メソッドを実装変更前に実行し、**3件RED・15個の意図したassertion失敗、想定外0**。実際に分類器が呼ばれ返答されないこと、複数人の鮮度・live compositionで顔向きがfalseになることを確認した。
- Claude Driverによる最小修正後、カメラ・顔選択・追尾・宛先・会話の関連 **94件PASS、失敗0・skip0**。
- 最終コードを固定して`task-done`経由で全XCTestを実行し、**1,004件PASS、失敗0・skip0**。専用の実ハードウェア／有料API2クラスは従来どおり通常suiteから除外した。

新しい実カメラ→会話VMのテストは、正面＋横向きの両順序、異なる位置の正面2人、大きな中央の横向き＋端の正面、左右補正で範囲外の顔＋範囲内の顔、不正矩形＋有効な正面を検証する。元の単一顔拒否を戻すと分類器呼び出しと返答内容のassertionが失敗する。全員横向き・無効な顔・新しい否定観測・古い観測での復活防止、複数顔の0.399秒／0.400秒境界、ハード未接続・追尾OFFのlive wiringも確認した。

最終code/test/project/native/scripts入力digestは`4e99d6b42c5cf3684b7e1d02c9e74ee51f6504aa95490d88f9033973a4f8494f`、基点HEAD上の同範囲の差分SHA256は`c0adc6f415321c3f063a2289bde60b4c5244829cc7689b2235262261e68e87cc`。native receipt SHA256は既存の`2ee2883ca23745dc8729e88a780264d32a270c3b1d3faa4de42e657fe555d0ca`。ネイティブソース・辞書・生成物を変更しておらず、Rust再構築や同じnative試験の再実行はしていない。

試験controllerはビルド・試験前後の実入力と差分の不変を検証した。Task1完了時の基点HEAD上の検証済み作業差分と、後のfeature commit／等treeのsquashの対応は、コミット後に実行記録へ追加する。

## 分岐図と文書

[HTML図](../application-flow.html)の以前の非追跡コピーがworktreeに存在しなかったため、直前に提供したtask-privateの保存済みHTMLと生成元から復元し、今回初めて追跡対象へ加える。既存Mermaid12.3.0で6図を事前にSVGへ生成した。HTML内の`diagram-definitions`に図の元定義を残し、実行時は外部ライブラリ・ネット接続を必要としない。

宛先条件、例の強調、複数人の説明を更新し、他の会話・記憶・待機・読み上げ仕様を維持した。図は**2026-11-07（issue #28対応時点）の静的スナップショット**として保存する。READMEと索引も日付を明記し、現役仕様の一覧とは分けた。参照は現在の実装を探すためのmainのファイルリンクで、図の時点から変わり得ると明記し、行番号はhref・表示・embedded refsの31件すべてから外した。HTMLのmetaには上記の実装入力digestを記録した。

初回の隔離Chromeで、オフライン表示、6図の切替、描画済み条件の「1人以上」、経路強調、図からの詳細移動、キーボード、拡大縮小・全体表示、全図印刷、スマホ幅でページが横にはみ出さないこと、直接リンクを確認した。JavaScriptエラー0、外部リクエスト0。その後の7箇所の参照行修正は、逆変換で初回確認済みHTMLへ戻ることを検証した。[初回の証拠](multiple-facing-review-2026-11-07/diagram-verification.json)は変更せず保存した。

独立レビューで、聞き返し後の「別の発話」の説明だけに旧「顔が1人」が残ることを発見した。上記snapshot・リンク修正とともに直し、Claude Driverが実DOMの当該行・日付表示・31リンクの行番号なしを検査へ追加した。旧版は旧人数表記で失敗、人数表記だけを直したprobeはsnapshot表示で失敗、両方直したprobeは行番号で失敗し、最終HTMLは全検査に成功した。既存の6図・オフライン操作・PC／スマホ幅の確認も再実行し、JavaScriptエラー0・外部リクエスト0。Codexはreceiptと実画像を、同じ独立レビュアーは修正文書と構造を照合した。

最終HTML SHA256は`dcf5c78969b05a780302817356806c46d5b05fc4861e81492decf33012874ead`。図6件と印刷icon6件のSVG、style8ブロック、操作JavaScriptは初回候補とバイト一致し、embedded定義はrefs以外不変。[最終図の証拠](multiple-facing-review-2026-11-07/diagram-final-verification.json)と[ブラウザ結果](multiple-facing-review-2026-11-07/diagram-final-browser-check.json)を保存した。アプリ・テスト入力は変わっておらず、文書修正のために全1,004件を繰り返してはいない。

HTMLそのものが保存対象で、embedded定義は図の編集補助でありページ全体の唯一の生成元ではない。確認待ちの行や例は定義外にある。今回task-privateのbuilderは補正したがrepoへ永続化しないため、repoだけから同じHTMLを再生成できるとは約束しない。将来の改版時に生成元を管理するか、新しい日付の図を作るかを選ぶ保守上の制約が残る。

README、要件表FR-CONV-2、新設計と旧#22設計への追記も、1人以上の条件へそろえた。

## 独立レビューと相互受領

アプリ入力を固定した候補`07363aaae506ebe153b7580c7efbae7610e5ef46`に、実際のClaude `/simplify --report-only`を4観点で独立実行し、Codexは別の新規レビュアー1名へwhole-branchレビューを依頼した。互いの報告を読む前の初回をhash付きで保存し、その後双方が`receiving-code-review`に従って相手の指摘を検証した。[初回hash](multiple-facing-review-2026-11-07/first-review-sha256.json)、[Claude初回統合](multiple-facing-review-2026-11-07/claude-simplify-first-combined.md)、[独立初回](multiple-facing-review-2026-11-07/native-code-review-first.md)、[Codex受領](multiple-facing-review-2026-11-07/root-receiving.md)、[Claude受領](multiple-facing-review-2026-11-07/claude-receiving-native-first.md)、[独立レビュアー受領](multiple-facing-review-2026-11-07/native-receiving-claude-first.md)を残した。

独立初回はCritical0／Important0／Minor1。Claudeは重複整理後Important2／Minor5／Nit5で、Importantは旧人数表記C1と図の保守・位置付けC2。両者ともproduction変更は求めていない。C1の重要度差は保存し、C1/C2を合意した文書限定修正で対応した。同じ独立レビュアーの[限定確認](multiple-facing-review-2026-11-07/native-review-resolution.md)で双方の解消を確認した。

SVG圧縮・文書集約・fixture整理・JS整理は実害が確認されず延期。実camera→VMの回帰観点を弱めるテスト削減やselector分離は採らなかった。UUIDのUserDefaults suiteの後始末欠如は既存由来のMinorとして事実を認め、固定入力を維持する今回の文書修正に混ぜず延期した。各採否と技術的根拠は受領記録に残した。

## 通常署名版と残る実機受入・統合

候補の通常署名版を実機へインストールし、通常起動と実プロセスを確認した（PID11428）。codesign検証成功、XCTestプラグイン0、試験用引数なし、SmartTurn資産8件のhash一致。実装入力は全1,004件を実行したものと同じ。[preview記録](multiple-facing-review-2026-11-07/preview-normal-verification.json)参照。

**人による複数人条件の実機確認は回答待ちで、受入成功とは扱わない。** 「新しい会話」で2人の顔を映し、片方だけが猫へ顔を向け、呼び名なしの質問へ聞き返しなく返答するかを依頼した。Simulatorの合成観測や署名版の起動成功は、この実際のVision条件の確認を代替しない。mainへの統合・pushはまだ行っていない。

最新mainが基点と一致することを確認し、featureと全treeが一致する1コミットへsquashする。通常署名の最終main版を実機へ入れ、試験用引数・XCTestなしでの起動と資産を確認してからnon-force pushする。最終のcommit、remote hash、issue状態、実機PIDなどコミット後にのみ確定する実結果はtask-private `integration.json`と完了報告へ残す。管理されたhost worktreeとfeature branchを保持し、このplan所有の実行workspaceだけを保管して片付ける。
