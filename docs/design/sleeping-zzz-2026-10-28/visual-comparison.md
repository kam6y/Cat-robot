# sleeping の眠りの Z（参照 `sleeping-zzz-reference.png` と SwiftUI 描画）

担当: claude_sleep_zzz_1028 がベクター実装・試験・比較記録を担当。codex が参照画像の生成、画像の目視レビュー、iOS の targeted xcodebuild を担当。

> この後の追加で、Z を右へキャンバス幅の 3.5% 移した（末尾の「追加: 右へ移す・減光の削除」）。それまでの節は移す前の記録として残す
> （`renders/final/`）。Z を移した版の画像は `renders/shifted/`。
>
> さらにその後、listening 表情を廃止した（聞き取り中の顔は neutral。`FaceExpression.listening` と `CatFaceAppearance.listening` を削除）。sleeping のプリセットと
> Z の字形・位置・描画は変えていない。`renders/final/` と `renders/shifted/` の画像・`source.txt` の識別子・件数（`gallery.png` の
> 10 表情など）・試験の結果は、廃止前に撮った記録としてそのまま残す。今も採用しているのは shifted の Z の形と位置で、廃止後の全表情の
> gallery はここには保存していない。

## 対象
- 参照: `sleeping-zzz-reference.png`（1672×941。16:9 の全面がキャンバス、sha1 先頭 `99fea4d3829e`）。codex が image_gen で
  `../sleeping-2026-10-26/sleeping-draft.png` の右上に、青い Z を小・中・大の 3 つ右上がりに足したもの。顔の部分の数 px の揺らぎや
  わずかなテクスチャは追わず、既存の顔の形と色をそのまま保つ方針。
- 描画: `CatFaceAppearance.sleeping` の `sleepMarks = 1`（ほかの表情は 0）。形は `CatFaceGeometry.sleepMarks()`、色は
  `Palette.sleepMark`。Z は右目の黒いまぶた（局所 ±1.3 の矩形）と重なる位置にあるので、`CatFaceRenderer.draw` の最後（目より後）に塗る。
  `sleepMarks` は表情の補間に含まれ、ほかの表情との切り替えではフェードする（sleeping から抜ける 0.25 秒の間は、消えかけの Z が
  開いていく右目と重なる。Reduce Motion と非 active では補間しないので重ならない）。

## 参照の実測（キャンバス正規化。縁は被覆率 0.5 の補間）
| Z | x | y | 幅 × 高さ | 幅/高さ（実寸） | 上の棒の太さ | 下の棒の太さ | 斜めの棒の横幅 | 傾き dx/dy |
|---|---|---|---|---|---|---|---|---|
| 小 | 0.7438..0.7776 | 0.2644..0.3331 | 0.0338 × 0.0687 | 0.875 | 0.262 h | 0.264 h | 0.372 h | −0.874 |
| 中 | 0.7913..0.8381 | 0.1837..0.2787 | 0.0469 × 0.0949 | 0.877 | 0.257 h | 0.263 h | 0.366 h | −0.880 |
| 大 | 0.8544..0.9203 | 0.0830..0.2162 | 0.0659 × 0.1332 | 0.879 | 0.252 h | 0.260 h | 0.361 h | −0.874 |

- 3 つは同じ字形を拡大したもの（h は Z の高さ）。回転はない。外側の角は少し丸く（半径約 0.05 h）、横棒のうち斜めの棒から離れた端
  （上の棒の左下、下の棒の右上）は約 0.075 h とやや大きく丸い。斜めの棒と横棒が接する内側の角は尖る。
- 色: 縁から 2px 以上内側の中央値は小 #78BCFD、中 #76BBFD、大 #76BBFC。描画は #76BBFD。

## 字形（`CatFaceGeometry.sleepMark`）
- 単位は Z の高さで、x も実寸（キャンバスの x へは `aspectRatio` で割る）。幅 0.877、上の棒の下端 0.255、下の棒の上端 0.738、
  上の棒の左端 0.02。斜めの棒は上の棒の下端で中心 x 0.649、横幅 0.366、傾き 0.874（3 つの実測の平均）。
- 10 頂点の多角形の角を `roundedPolygon` で丸める（円弧に近い 3 次ベジェ）。各 Z は外接の左上と高さで置く（`sleepMarkBoxes`）。

## 経過（作業用の出力は /private/tmp/cat-sleep-zzz-20261028/）
- r1: 角の丸めを 2 次曲線（制御点 2/3）、cut 0.05 で一律。青マスク IoU 0.9848。下の棒の右上と上の棒の左下が参照より角張る。
- r2: その 2 つの角を 0.075 に。IoU 0.9870。codex の目視で、外側の角が参照よりやや四角く見えるとの指摘。
- r3（採用 = final）: 丸めを円弧近似（制御点 0.5523）に。検査用の `drawingPoints` は `sleepMarks > 0` のときだけ Z を含める。描画
  （`CatFaceRenderer.draw`）の条件は `> 0.001` で同じではないが、プリセットの値は 0 か 1 なので、どちらも sleeping だけを選ぶ。IoU 0.9877。
  codex が目視で採用。画素の細かな合わせはここで打ち切った。

## final の結果（`renders/final/measure.txt`。`compare_zzz.py` の出力）
- 参照を 1280×720 に縮小して比べた青マスク IoU: 全体 0.9877、小 0.9765、中 0.9898、大 0.9897。外接の差は 3 つとも上下左右 ±0px（1280×720）。
  この IoU は `compare_zzz.py` の指標（Pillow の Lanczos で縮小し、青を b>90・b>r+40・b>g+10 で判定）。XCTest の青の判定や
  Swift の harness の計測とは別の方法で、値をそのまま比べることはできない。
- 描画の Z の色（縁から 2px 以上内側の中央値）: #76BBFD。Z 領域（x 0.73..0.935、y 0.07..0.35）の外に青い画素はない。
- 顔は変わらない: sleeping のキャンバスで baseline と違う画素は 10615 個で、すべて Z 領域の中（Z 領域の外の差は 0）。
- ほかの表情: HEAD（bac3721）のソースで描き直した 39 枚と比べ、36 枚が画素一致。差があるのは `canvas-sleeping-closed.png`・
  `screen-sleeping.png`・`gallery.png`（sleeping のセルの右上だけ）。sleepy を含むほかの表情には Z が出ない（`gallery.png`）。
- codex の独立計測（`renders/final/codex-independent-check.json`。別の計測コードで HEAD の再描画と比較）: sleeping の Z 領域外の差 0、
  ほかの表情の canvas・screen はすべて差 0、Z 領域外の青 0。青の判定の閾値が違うため IoU は 0.989（本文の指標は上の 0.9877 に統一）。
- 補足: 作業の最初に描いた baseline と比べると、`canvas-curious-closed.png` の 410 画素が最大 1/255 ずれていた。HEAD のソースのまま
  ハーネスを再ビルドしても同じ 410 画素がずれる（appearance だけ、shapes だけを差し替えても同じ）ので、今回のソース変更が原因ではない。
  ずれの原因は特定していない。比較の基準には HEAD の再描画を使った。

## 画像（`renders/final/`）
- `canvas-sleeping-closed.png`（1280×720）、`baseline-canvas-sleeping-closed.png`（HEAD）、`canvas-sleepy-closed.png`（Z なし）、
  `screen-sleeping.png`（1704×786）、`gallery.png`（10 表情）
- `compare-full.png`（上: 参照の縮小、下: 描画）、`overlay-full.png`（50% 重ね）、`diff-full.png`（画素差の絶対値 ×2。顔の部分の差は
  image_gen による顔の揺らぎ）
- `zzz-crop-compare-x3.png`（Z の部分を 3 倍。上: 参照、下: 描画）、`zzz-crop-mask-diff-x3.png`（灰: 両方、赤: 参照だけ、緑: 描画だけ）
- `source.txt`（製品 3 ファイルの識別子）、`measure.txt`（`compare_zzz.py` の出力）、`codex-independent-check.json`（codex の独立計測）
- `ios-sleeping-closed.png`・`ios-sleepy-closed.png`（iOS Simulator の FaceRenderingTests の添付画像）、`ios-test-summary.json`（xcresult の要約）

## 試験
- `CatFaceGeometryTests.testOnlySleepingShowsSleepMarksAboveTheClosedEyes`（scripts/face-render の check にも同じ判定）:
  Z を見せるのは sleeping だけ。3 つが小 → 大で右上がりに並び、画面の右半分で、閉じた目の弧より上にあること。
- `FaceRenderingTests`: sleeping の画面では青い画素が 0.4% より多く（Z がまぶたの黒に隠れていない）、ほかの表情では 0。
- iOS（codex が実行。iPhone 18 Pro Simulator `40C29D25-C8EC-42C7-8145-65AB37A2BB7D`、iOS 27.0）: `-only-testing` で
  `CatFaceGeometryTests` と `FaceRenderingTests` を実行し、xcodebuild は exit 0、TEST SUCCEEDED（13 件中 13 件通過、失敗 0、スキップ 0。
  `renders/final/ios-test-summary.json`）。試験が添付した画像のうち `ios-sleeping-closed.png`（右上に Z）と `ios-sleepy-closed.png`（Z なし）を
  保存し、codex と claude がそれぞれ目視で確認した（2556×1179。iOS のキャプチャなので色は Mac の描画と少し違って見える）。
- 新しいファイルはないので、`ruby scripts/generate_project.rb` と `generate_face_size_tuner_project.rb` を実行しても
  xcodeproj の差分は出ない。`ruby scripts/test_generate_project.rb` は PASS。

## 実機画面での位置（Z を移す前。計算による見積もり）
- iPhone 18 Pro の横向き 874×402 で、safe area を左右 62・下 21・上 0 と仮定して見積もった。顔の枠は全画面の 80%（699×322）で、
  キャンバスは 572×322（x 151..723、y 40..362）。Z の範囲はおよそ x 576..677pt、y 67..147pt。
- 右上の「…」メニュー（44pt、trailing 12、top 4）はおよそ x 756..800、y 4..48 で、Z とは横に約 79pt 離れている。
  この safe area の値は実測していない（iOS の画面キャプチャによる確認は codex の担当）。

## 追加: 右へ移す・減光の削除（2026-10-28 午後）
ユーザーの要望: 「ZZZ をもう少し右へ」「待機中などの薄黒いかぶせを削除」。右へ 3.5% は codex が提案した調整値。
claude_sleep_zzz_1028 が Z の配置を、codex が減光の削除を担当した。

### 変更
- 位置: `sleepMarkBoxes` の x を 3 つとも +0.035。大きさと縦の位置、字形、色は前のまま。大の Z の右端は cv 0.9553。
  この段階の製品の差分は `CatFaceShapes.swift` の x の値 3 つとコメントだけ（`CatFaceView.swift`・`CatFaceAppearance.swift`・試験・harness は
  前の静止版のまま。listening の廃止による変更はこの後）。
- 減光の削除（codex）: タップで再開を待つ一時停止のときに顔を `opacity 0.5` で薄くしていた処理（`ConversationViewState.faceOpacity` と
  `ConversationView` の `.opacity` / `.animation`）を削除。状態チップの表示は変えていない。日付付きの記録にある「一時停止で不透明度 0.5」
  （`docs/validation/2026-10-27-ui-reorganization.md:8`、`docs/superpowers/specs/2026-10-27-ui-reorganization-design.md:73`、
  `docs/superpowers/specs/2026-10-24-face-expression-design.md:101`）は、削除前の設計の記録として扱い、書き換えない。
- 採用しなかった案: Z だけをゆっくり上下させる案（周期 3 秒、上下にキャンバス高さの 1%）を一度実装した。しかし眠っている間ずっと
  顔の Canvas 全体を毎フレーム描き直す作りで、電池や発熱に響くおそれがあるため、ユーザーの判断で取りやめて静止に戻した。

### 結果（`renders/shifted/measure.txt`。`shift_check.py` で移す前の静止版の preview と比較）
- Z 全体の外接は x が +45/+45px（0.035×1280 = 44.8）、y は ±0。右端は cv 0.9555。移す前の Z を 45px ずらしたマスクとの IoU は 0.9922（縁の AA の差）。
- 顔: sleeping のキャンバスで、移す前と移した後の Z 領域の外の差は 0px。ほかの表情は 39 枚中 36 枚が画素一致で、差は sleeping の画像 2 枚と
  gallery の sleeping のセルだけ。
- 参照画像との比較（`compare_zzz.py` の指標）は、x をユーザーの要望で動かしたので今回は使わない（形・大きさ・縦位置・色は前の一致のまま）。
- 画像: `canvas-sleeping-closed.png`、`screen-sleeping.png`、`gallery.png`、`compare-prev-new.png`（上: 移す前、下: 移した後）、
  `zzz-crop-prev-new-x2.png`（Z の部分を 2 倍。上: 移す前、下: 移した後）、`source.txt`。

### 試験
- この段階では試験コードは変更なし（前の静止版の `CatFaceGeometryTests` と `FaceRenderingTests` の判定がそのまま当てはまる）。
- iOS（codex が実行。iPhone 18 Pro Simulator `40C29D25-C8EC-42C7-8145-65AB37A2BB7D`、iOS 27.0）: 2 つの試験クラスに加え、codex の減光削除に関わる
  表示状態の試験、タップ・音声・文字入力での一時停止の 3 件、自動再開の 1 件、`FaceConversationPresentationTests` の
  `testConversationShowsOnlyTheFaceAndNeededChips` と `testInactivityFixturesRender` を実行した。xcodebuild は exit 0、35 件中 35 件通過、
  失敗 0、スキップ 0（`renders/shifted/ios-test-summary.json`）。生成し直した xcodeproj の差分はなく、生成の試験も PASS（codex が確認）。
- iOS の画面（`FaceConversationPresentationTests` の添付、852×393）: `ios-user-paused.png`（タップで一時停止）、`ios-system-paused.png`
  （システムによる一時停止）、`ios-sleeping.png`（待機中の寝顔）。一時停止の 2 枚は下 75%（顔の範囲）が画素一致（差 0px、最大差 0）で、
  顔は薄くなっていない（codex の比較と claude の再計測が一致）。寝顔の Z は x 593〜691pt、y 66〜144pt、「…」メニューの記号は x 770〜786pt で、
  横に約 79pt 離れて重ならない（この 852×393 の試験の画面での実測。実機の 874×402 では測っていない）。

### 実機画面での位置（計算による見積もり。実測ではない）
- 前の見積もりと同じ仮定（iPhone 18 Pro 横向き 874×402、safe area 左右 62・下 21）では、Z は x 約 596〜697pt、y 約 67〜147pt。
  「…」メニュー（x 756〜800、y 4〜48）とは横に約 59pt 離れる。
