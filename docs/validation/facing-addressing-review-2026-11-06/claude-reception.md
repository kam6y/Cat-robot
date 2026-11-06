# issue #22 — Claude 相互受け止め（superpowers:receiving-code-review）

作成: claude_issue25 2026-11-06 12:2xZ。読み取り専用。ソース・git・Xcode・実機・新 agent なし。本ファイル保存前に自分の初回報告 `claude-simplify.md`（87 行、sha256 a1e66e19…）を保存済み。

## 1. 受け止めた入力

| ファイル | 行 | sha256 先頭 | 内容 |
|---|---|---|---|
| `native-code-review.md` | 68 | a2ebd5dd | codex 独立初回。Critical/Important/Minor 0/0/0、Ready to merge: Yes |
| `native-reception.md` | 49 | 1bbfb919 | codex native による私の 4 角度報告の受け止め。S1 文言 Important 採用、S9 Minor 採用、A3 Minor 任意、他は defer/reject |
| `root-reception-draft.md` | 24 | af465836 | codex root の技術的採否（下書き） |
| codex agmsg 12:14Z / 12:17Z | — | — | root の採否要約。S9 採用・S1 原文復元は docs のみ、C1/C6/C8 は記録済み tradeoff として維持、C2/C4/C5/C7/C9〜C17 は defer/reject、利用者が iPhone で顔を向けた名前無し質問に返答を確認 |

手順: 全文を読む → 要求を自分の言葉で言い直す → code で検証 → 評価 → 回答。性能主張は測定が無い限りしない、を双方の前提とする。

## 2. native 初回報告の主張を code で検証

| native の主張 | 検証 | 結果 |
|---|---|---|
| `beginClosingCapture` は listening を離れずに recognizer 停止と consumer を await、`performTurn` はその後で顔を読む（VM :892/:912/:959） | `closingTask` が `recognizer.stop()` → `consumer?.value` → `finishClosingCapture`（:899-907）。`performTurn` は :952 で期限切れ pending を消し、:959 `isFacingScreen()`、:960-966 `route(...)`。間に await 無し。`.classifying` 遷移は :982、`.thinking` は `generateReply` 内 :1086 | 一致。「同期なので query と policy の間で環境は変わらない」も成立 |
| 期限切れの確認は routing 前に消える | :953-956 `if let pendingClarification, timestamp >= expiresAt { clearPendingClarification() }` | 一致 |
| 3 需要を一括 reconcile、追尾停止や listening 離脱で look 要求を止めない（Camera :176, :246） | `reconcile()` guard は `attentionRequested || trackingGeneration != nil || pending != nil`（:177）。`receive` は `physicalGeneration` 一致 → `recordAttention` → `trackingGeneration` があれば再スタンプして yield（:247-253） | 一致 |
| camera/追尾の両権限待ちを inactive/foreground guard に含む（AppCoordinator :54/:154/:183/:235） | `isAwaitingCameraPermission` = OR（:54-56）、`completeConversationStartIfEligible` の追尾要求→`.notDetermined` なら camera 要求（:161-164）、`resumeListeningIfNeeded` guard（:185）、inactive 側 `if isAwaitingCameraPermission { return }`（:238） | 一致 |
| 入力 digest `e9f1628f…` が freeze.json と一致 | `freeze.json inputSourceDigest = e9f1628fbeeff11ba440eb82746b35ef5dd598ed241c2422c997877b598661f2` | 一致 |
| 顔での受理は hard deadline を再 arm、engagement のみの継続は refresh | :975 `isFacingScreen \|\| !wasEngaged ? .arm : .refresh` | 一致 |
| 0/0/0 | 私の simplify も correctness 欠陥は見ていない。ただし docs の S1 基準緩和（私の角度外付記 / native 自身が reception で Important に改訂）と README :11 の矛盾（C3）は docs 欠陥として採用済み | native の改訂に同意 |

native 初回が S1 緩和を見落とし reception で自己訂正した点は、記録として透明で妥当。私の初回も S1 を「角度外付記」に置いた（simplify の範囲外のため）。

## 3. 採否表（私の C-ID ↔ codex の採否）

| ID | 私の初回 | codex root / native | 私の最終立場 |
|---|---|---|---|
| S1 基準緩和（角度外） | 「意図的なら理由が要る」 | Important、原文行を**そのまま**復元（docs のみ） | 同意。base :35 と HEAD :35 を比較済み。「呼びかけから」→「発話終了から」と「話し始める」→「目標とする」の 2 点が緩和。復元後は差分外 |
| C3 / S9 README | Minor | Minor 採用。:11 を「それ以外の発話…」、:278-281 を顔あり名前無し／30 秒内の横向き継続／期限後の横向きに書き直し。「返答が出た」だけで bypass は証明できないので trace か「観察可能な挙動」と明記 | 同意。native の追記（返答だけでは経路を証明できない）は正しい。手動確認の記載は「観察できる挙動」に留めるのが安全 |
| C4 / A3 補正 UI 文言 | Minor | native: 任意採用・defer 可。root: defer/reject 予定 | defer を受け入れる。理由は「production ソース（SettingsPane.swift）に触ると testedPatchSha256 と normal build digest が無効になり再ビルド・再試験が要る」こと。ハード無し利用者が本 issue の主対象なので、別 issue か次回の production 変更に同乗させることを要望 |
| C1 / E1 発話ごとの session 再構築 | Important（機構 V・効果 P、D-listening-only と衝突） | 記録済み tradeoff として維持。測定無しに camera 寿命を広げない。`.classifying` まで延ばす案は別の capture/query 需要状態が要る | 受け入れる。私の初回も (b) には reset の edge 分離が要ると書いた。測定無しで Important の実効は主張しない。**要望（docs 精度）**: validation :15「追尾オフでは**返答ごと**に再起動する場合がある」は過小。再起動は**宛先判定に進んだ発話ごと**（分類器が別の相手と判定して返答しない場合も含む）。利用者に見える形: TV や同席者のいる部屋では、猫が答えない文でもカメラ indicator が点灯→消灯を繰り返す。これは測定不要の観察可能事象なので一文の修正を求める。あわせて実機確認に「却下された発話の直後に画面を向いて質問し、省略が効くか（冷起動の隙）」を任意で追加 |
| C8 / E2 look の warm teardown | Minor | 同上。base も look は冷起動 | 同意。追加コストは teardown と直列化のみ、C1(a) 以外では消えない。defer |
| C6 / E3 captureFailed の listening 入りリセット | Minor（loop V・頻度 P） | 維持。無入力の即時 loop ではなく新 owner edge 単位、一過性失敗の復帰に必要。操作回数から paid/電池の回帰を推論しない | 同意。私の初回も「設計判断寄り」「環境 edge のみにすると復帰が遅れる」と書いた。持続失敗の頻度は実機観察待ち |
| C2 / S1(simplification) `speakAndResume` 死んだ引数 | Minor | verified、defer。`.none` 腕の削除も要る。口の動きのテストは generated reply 経由に移行 | 同意（単一呼び出しは base :984/:1038 → HEAD :1017 で確認済み）。production 変更になるので今回の docs-only パスには乗せない |
| C5 / S6 旧パーサ名のテスト | Minor | defer（挙動は有効、名前だけ古い） | 同意、defer |
| C7 / R2/R4/S8 harness 重複・層混在 | Minor | defer。facing harness が追尾需要を持つのは listening 境界越しの保持を試すため意図的。追尾オフ試験を消さない | 同意。私の「11 件が追尾オフを走らない」は副作用の指摘で、追尾オフは別 2 件が担うと書いた通り |
| C9 / R1/S4 ガード写し | Nit（維持推奨） | defer（許容差・下限・不正時の cache 効果が違う） | 同意、維持 |
| C10/C11 / S2/S3/R5 含意ガード | Nit | reject（契約の可読性、live authorization は残す） | 同意。初回で「一貫性のため維持も妥当」と書いた |
| C12 / S5/A1 未使用 harness 引数 | Nit | verified、defer | 同意、defer。「将来の gated real-camera テストの seam」には YAGNI の留保を付けるが争点にしない |
| C13 / S7 重複テスト | Nit | defer | 同意、defer |
| C14 / R6 selectFace 境界の再検証 | Nit（「1 ケースで十分」） | reject blanket deletion: camera テストは有効な顔→不正/複数/不明へ更新して cache 失効を検証しており、幾何テストでは証明できない | **部分撤回**。`testLatestEmptyOrTurnedFaceRevokes…`・`testMultipleFacesAndUnknownOrMalformed…` は更新挙動の契約で重複ではない。重複と呼べるのは厳密境界値（例 25°/26°）の反復のみ。初回の表現「1 ケースで十分」は広すぎた |
| C15 / R3 権限テストが FaceAppHarness の流れを再構築 | Nit [P] | reject equivalent-substitution: `FaceAppHarness` は追尾あり camera なし（:17-19 で camera 引数無しを確認）、新テストは camera あり追尾なし。`isAwaitingCameraPermission` の OR の別側 | **撤回**。等価な置換は存在しない。共有するなら両構成を保つ必要がある |
| C16 / A2 predicate の置き場・古い doc | Nit | defer。型コメントに attention を一言足す程度 | 同意。doc 一文の追記は docs-only パスで可能なら望ましいが必須ではない（Swift コメントなので production ファイル。defer 可） |
| C17 / S10 5 重記載 | Nit | defer | 同意 |
| native の任意テスト（real camera + gated recognizer stop） | — | root: 件数のために足さない | 同意。code の順序（:899-907 → :959）とユニットの鮮度テストで意図は支持されている |

## 4. 撤回・修正（私の側）

- C15（R3）: 「`FaceAppHarness` の流れの再構築」という含意を撤回。両 fixture は `isAwaitingCameraPermission` の異なる側を試す。
- C14（R6）: 「1 ケースで十分」を「厳密境界値の反復のみ任意で削減可、更新・失効の契約は保持」に狭める。
- C1 の severity: 「Important」は D-listening-only との衝突と範囲（ハード無し全 session）に基づく格付けで、測定された遅延・電力の欠陥ではない。codex の「documented unmeasured tradeoff」という分類に異存なし。

## 5. 要望（ブロッカーではない。全て docs／記録のみ）

1. validation :15 の「返答ごとに再起動」を「宛先判定に進んだ発話ごと（返答しない場合も含む）に再起動」へ。カメラ indicator の点滅として利用者に見える。
2. 実機確認に任意で「却下された発話の直後に画面を向いて質問→省略されるか」を加え、冷起動の隙を観察として記録（測定主張はしない）。
3. 最終記録で 2 つの digest の定義を明記: `freeze.inputSourceDigest e9f1628f…`（app+test+project）と normal build の `sourceDigest 7fc67a24…`（`review-normal/normal-verification.json`, `user-device-check.json`、`gitCommit e6cbe28c`）。同じ commit を指すが値が異なるため、読む人が不一致と誤認しないように。
4. C4（補正 UI 文言）と C2（死んだ引数）は次の production 変更に同乗、または issue 化。

## 6. 準備状況

- S1 原文復元と README（:11 と手動確認）の docs 修正後、統合可と判断する。native の "Ready to merge after S1 + README" に同意。
- docs のみの修正なら code/test/project パッチ SHA `7b47dddc…` と normal build digest `7fc67a24…` は不変のはずで、全件再実行は不要。修正後の fixes delta（docs の差分 + 再計算した code/test/project パッチ SHA の一致）を受け取れば、#26 と同じ手順で確認する。
- 利用者の実機確認（顔を向けた名前無し質問に返答）は codex 経由の報告として記録。私は観察していない。
