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

宛先条件、例の強調、複数人の説明を更新し、他の会話・記憶・待機・読み上げ仕様を維持した。版表示はissue #28対応版、コード参照はmainへのリンクとし、旧基点コミットが新仕様を含むような表示は避けた。HTMLのmetaには上記の実装入力digestを記録した。

隔離Chromeで、オフライン表示、6図の切替、描画済み条件の「1人以上」、経路強調、図からの詳細移動、キーボード、拡大縮小・全体表示、全図印刷、スマホ幅でページが横にはみ出さないこと、直接リンクを確認した。JavaScriptエラー0、外部リクエスト0。最後に7箇所の参照行だけを修正し、逆変換するとブラウザ確認済みHTMLのSHA256へ戻ることを検証した。図・CSS・操作スクリプトはその後変更していない。[図の検証記録](multiple-facing-review-2026-11-07/diagram-verification.json)参照。

README、要件表FR-CONV-2、新設計と旧#22設計への追記も、1人以上の条件へそろえた。

## 後続の確認・統合

この候補はソースと自動検証を確定した時点の記録。Claudeの実際の`/simplify`4観点と独立1名のレビュー、双方の受領評価、通常署名版の実機での複数人条件の確認は、この後に行い結果を追記する。これらを完了したとは扱わない。

最新mainが基点と一致することを確認し、featureと全treeが一致する1コミットへsquashする。通常署名の最終main版を実機へ入れ、試験用引数・XCTestなしでの起動と資産を確認してからnon-force pushする。最終のcommit、remote hash、issue状態、実機PIDなどコミット後にのみ確定する実結果はtask-private `integration.json`と完了報告へ残す。管理されたhost worktreeとfeature branchを保持し、このplan所有の実行workspaceだけを保管して片付ける。
