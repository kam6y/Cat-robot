# sleeping 表情の視覚比較（下書き `sleeping-draft.png` と SwiftUI 描画）

担当: claude_sleep（ベクター実装）。codex がタイマー・coordinator・設定・UI 統合と Xcode のテスト実行を担当し、画像の一致レビューも並行して行った。

## 対象
- 下書き: `sleeping-draft.png`（1672×941、16:9 の全面がキャンバス、sha1 先頭 `601dd30e2fe5`）。生成条件は `sleeping-draft.prompt.txt`
  （round-8 の `canvas-sleepy-closed.png` を入力に、目だけを完全に閉じた金色の弧へ編集。鼻・口・ひげは保持を指示）。
- 描画: `CatFaceView` の sleeping プリセット。`CatFaceAppearance.sleeping` = sleepy の値 + まぶた `lid` 1（黒いまぶたが虹彩を全部覆う）
  + `closed` 1（閉じた目の弧）。弧の形は `CatFaceGeometry.closedLid(frame:)`、色は `Palette.closedLid`。
  鼻・口・ひげは sleepy と同じ値（codex の実装方針: 既存デザインの保持）。
- 計測と画像: `scripts/render_face.sh sleeping <round>` が `renders/round-N/` に次を出す。
  - `canvas-sleeping-closed.png`（1280×720）、`canvas-sleepy-closed.png`（下書きの元）、`screen-sleeping.png`（1704×786）、`screen3x-sleeping.png`（2556×1179）
  - `draft-1280x720.png`（下書きの縮小）、`compare-sleeping.png`（上: 下書き、下: 描画）、`overlay-sleeping.png`（50% 重ね）、`diff-sleeping.png`（画素差の絶対値 ×2）
  - `gallery.png`（10 表情）、`measure.txt`（`scripts/render_face.sh measure --sleeping` の出力）、`source.txt`（製品 3 ファイルの識別子）

## 座標と計り方
- cv: 16:9 キャンバスの 0...1 正規化座標。局所座標: 目の枠（中心 (0.2374, 0.4327)、半径 (0.1247, 0.2231)。sleeping の枠は neutral と同じ）に対する
  u（鼻側が正）と v（下が正）。1 局所 v = 0.2231 × キャンバス高さ = 160.6px（1280×720）= 87.7pt（実機 852×393）。
- 弧: 虹彩の色の分類（`Classify.swift` の Y/O/M/D）の連結成分 2 つ。列ごとに上縁・下縁を読み、固定の u（0.1 刻み）で下書きと描画を並べる。
  色は縁から 2px 以上内側（周囲 5×5 が同じ分類）の画素の平均と中央値。
- 鼻・口・ひげ: 外接矩形と、キャンバス幅を 1/640 に刻んだ列ごとの中心 y。下書きと描画で同じ列を比べる。
- 下書きは 1672×941、描画は 1280×720 で計り、差は 1280×720 の px に換算して示す。実機 852×393 ではキャンバス高さが 393pt なので
  1px（1280×720）= 0.546pt。

## 下書きの実測（左目の弧。右目は u の符号を除いて 0.005 以内で同じ）
- 外接: cv x 0.1162..0.3631、y 0.4888..0.5919 → 局所 u −0.972..1.008、v 0.252..0.714。横幅は目の外形（u ±1）と同じで、目の枠の下半分に入る。
- 色: 内側の平均 #FCCA43、中央値 #FDCA44（右目 #FCC943 / #FDCA43）。全画素の平均 #F9C944（縁のぼけを含む）。
- 最下点: 局所 (0.014, 0.714)、最上点（先端）: 0.252。先端の列の厚さ: 外側 3px、鼻側 2px（941 高）。先端は尖らず、わずかに丸い。

| u | 上縁 v | 下縁 v | 厚さ（局所 v） | 厚さ px（1280×720） |
|---|---|---|---|---|
| −0.90 | 0.290 | 0.342 | 0.052 | 8.4 |
| −0.80 | 0.347 | 0.433 | 0.086 | 13.8 |
| −0.70 | 0.399 | 0.504 | 0.105 | 16.9 |
| −0.60 | 0.447 | 0.561 | 0.114 | 18.3 |
| −0.50 | 0.485 | 0.609 | 0.124 | 19.9 |
| −0.40 | 0.514 | 0.647 | 0.133 | 21.4 |
| −0.30 | 0.542 | 0.676 | 0.133 | 21.4 |
| −0.20 | 0.556 | 0.695 | 0.138 | 22.2 |
| −0.10 | 0.571 | 0.709 | 0.138 | 22.2 |
| 0.00 | 0.576 | 0.714 | 0.138 | 22.2 |
| +0.50 | 0.495 | 0.623 | 0.129 | 20.7 |
| +0.80 | 0.371 | 0.456 | 0.086 | 13.8 |
| +0.90 | 0.314 | 0.375 | 0.062 | 10.0 |
| +1.00 | 0.252 | 0.275 | 0.024 | 3.9 |

## ベジェの当てはめ（`CatFaceGeometry.closedLid`）
- 閉じた形 = 上縁（耳側の先端 → 中央 → 鼻側の先端）+ 下縁（戻り）。各縁は中央で水平に接する左右対称の 2 本の 3 次ベジェ。
  両端は同じ点に集めるので先端は尖る。
- 値（局所座標）: 対称の中心 u 0.017、先端 (±0.988, 0.265)。上縁: 先端側の制御点 (先端 + 0.084, 先端 v)、中央側の制御点 u ±0.577、中央 v 0.573。
  下縁: 先端側の制御点 (先端 + 0.144, 先端 v + 0.180)、中央側 u ±0.502、中央 v 0.714。
- 当てはめは下書きの列ごとの上縁・下縁に対する最小二乗（格子探索 + 局所探索）。残差 rms は上縁 0.27px、下縁 0.28px（1280×720）。
- 試して採らなかった案: 先端を u ±0.992 に延ばし、上縁の先端側の制御点を v −0.02（先端のわずかな反り）にすると、先端の列は下書きへ近づくが
  |u| ≤ 0.9 の縁の差が 1.0/0.6/1.1px → 2.1/1.4/2.2px、色分類 IoU（Y）が 0.968 → 0.947 に悪化した。

## Round 1（2026-10-26 20:07〜20:10 JST、`renders/round-1/`）
- source.txt: `CatFaceShapes.swift` `3d4bb5f45f83226057140bf7991d47044fcd0298`、`CatFaceAppearance.swift` `16ff0f9ff4bb8e627e402f8f3aec12e45eb61e7b`、
  `CatFaceView.swift` `72e6c9ac2096e9433460feef90b8b76e1e97ff5b`、差分 ID `1df1d98bc5ce`（base `f6eeedad`）。
- 弧の色は虹彩の明るい黄 `iris.bright` #FDCA40 を流用していた。codex のレビュー: 「ベクターのほうがやや黄色が強い」→ round-2 で専用色へ。
- 幾何は round-2 と同じ（round-1 → round-2 の変更は色だけ。measure.txt の差分表は同じ値）。
- 注意: round-1 の `measure.txt` は差分表を加えた計測で再生成したもの（画像は同じ描画）。再生成時に `canvas` 166 バイト・`screen` 7 バイト（最大差 1 段階）の
  縁の画素が変わった。`ImageRenderer` の出力は実行ごとに縁の数画素が ±1 段階ずれることがあるので、識別子の比較ではなく幾何と色の表で比べる。

## Round 2（2026-10-26 20:14 JST、`renders/round-2/`）— 最終
- source.txt: `CatFaceShapes.swift` `611aa3e9937b735ad36ea9c4a94153a403a64fad`、`CatFaceAppearance.swift` `16ff0f9ff4bb8e627e402f8f3aec12e45eb61e7b`、
  `CatFaceView.swift` `06310f0c4d2c4fbc0bc43c571cc27a3b226cc5d9`、差分 ID `9817daaeb3d6`（base `f6eeedad`）。
- SHA-1 先頭 12 桁: canvas-sleeping-closed `b2dd3e667662`、screen-sleeping `f91b96a1eb5f`、screen3x-sleeping `bd7c5a2d2d48`、compare `5e900c9b9fee`、
  overlay `ed50e51d60cf`、diff `22dab1af7e77`、draft-1280x720 `24f2580c905b`、gallery `a9bffb4b7712`、canvas-sleepy-closed `821fdb7551f6`（round-8 と同じ描画）。

### 判定
弧の位置・曲線・太さ・色は下書きと一致（|u| ≤ 0.9 で縁の差 ≤ 1.0px、太さの差 ≤ 1.2px、1280×720。実機 852×393 では 0.55pt / 0.66pt）。
残る相違は先端の形（下書きは丸い端、ベクターは尖った点）と、鼻・口・ひげの生成由来の 1〜2px の差（下記）。

### 弧の縁（描画 − 下書き、局所 v。左目。右目は measure.txt）
| u | 上縁 下書き | 上縁 描画 | 差 | 下縁 下書き | 下縁 描画 | 差 | 厚さ 下書き | 厚さ 描画 | 差 |
|---|---|---|---|---|---|---|---|---|---|
| −0.90 | 0.290 | 0.295 | +0.006 | 0.342 | 0.345 | +0.003 | 0.052 | 0.050 | −0.003 |
| −0.80 | 0.347 | 0.351 | +0.005 | 0.433 | 0.432 | −0.000 | 0.086 | 0.081 | −0.005 |
| −0.70 | 0.399 | 0.401 | +0.002 | 0.504 | 0.507 | +0.003 | 0.105 | 0.106 | +0.001 |
| −0.60 | 0.447 | 0.451 | +0.004 | 0.561 | 0.563 | +0.002 | 0.114 | 0.112 | −0.002 |
| −0.50 | 0.485 | 0.488 | +0.003 | 0.609 | 0.613 | +0.004 | 0.124 | 0.125 | +0.001 |
| −0.40 | 0.514 | 0.520 | +0.006 | 0.647 | 0.650 | +0.003 | 0.133 | 0.131 | −0.003 |
| −0.30 | 0.542 | 0.538 | −0.004 | 0.676 | 0.675 | −0.000 | 0.133 | 0.137 | +0.004 |
| −0.20 | 0.556 | 0.557 | +0.000 | 0.695 | 0.694 | −0.001 | 0.138 | 0.137 | −0.001 |
| −0.10 | 0.571 | 0.569 | −0.001 | 0.709 | 0.706 | −0.003 | 0.138 | 0.137 | −0.001 |
| 0.00 | 0.576 | 0.576 | +0.000 | 0.714 | 0.713 | −0.001 | 0.138 | 0.137 | −0.001 |
| +0.10 | 0.571 | 0.569 | −0.001 | 0.709 | 0.713 | +0.004 | 0.138 | 0.143 | +0.005 |
| +0.20 | 0.561 | 0.563 | +0.002 | 0.704 | 0.700 | −0.004 | 0.143 | 0.137 | −0.006 |
| +0.30 | 0.547 | 0.544 | −0.003 | 0.685 | 0.681 | −0.004 | 0.138 | 0.137 | −0.001 |
| +0.40 | 0.523 | 0.526 | +0.003 | 0.661 | 0.657 | −0.005 | 0.138 | 0.131 | −0.007 |
| +0.50 | 0.495 | 0.495 | +0.000 | 0.623 | 0.625 | +0.002 | 0.129 | 0.131 | +0.002 |
| +0.60 | 0.461 | 0.464 | +0.002 | 0.580 | 0.582 | +0.001 | 0.119 | 0.118 | −0.001 |
| +0.70 | 0.418 | 0.420 | +0.002 | 0.528 | 0.526 | −0.002 | 0.110 | 0.106 | −0.004 |
| +0.80 | 0.371 | 0.370 | −0.001 | 0.456 | 0.457 | +0.001 | 0.086 | 0.087 | +0.001 |
| +0.90 | 0.314 | 0.314 | +0.001 | 0.375 | 0.376 | +0.001 | 0.062 | 0.062 | +0.000 |
| +1.00（先端） | 0.252 | 0.264 | +0.013 | 0.275 | 0.271 | −0.005 | 0.024 | 0.006 | −0.018 |

- |u| ≤ 0.9 の最大差: 上縁 0.006、下縁 0.005〜0.006、厚さ 0.007（局所 v）= 1.0 / 0.9 / 1.2px（1280×720）。左右の目で同じ。
- 外接の差（描画 − 下書き、1280×720 px）: 左 x +1.2/−0.8、y +2.0/−0.2。右 x +0.8/−2.0、y +2.0/−0.2。
- 最下点: 下書き v 0.714（cv y 0.5919）、描画 0.713（0.5917）。

### 先端
- 下書き: 先端の列で厚さ 1〜3px（941 高）の丸い端。外側 u −0.972、鼻側 1.008 まで伸び、先端の上縁は v 0.252 と、弧の中心線の延長より約 0.012（2px @720）高い。
- 描画: 両縁が同じ点に集まる尖った先端。外側 −0.964、鼻側 1.003 まで。先端の列の厚さ 1px。
- 差は先端の 1〜2 列に限られ、1280×720 で x 1〜2px、上端 y 2px（実機 852×393 で約 1.1pt）。先端を延ばす・反らせる案は上の「試して採らなかった案」のとおり
  弧全体の一致を損ねたので、尖った先端のまま残す。

### 色
- 描画の弧の内側 #FDCA43（`Palette.closedLid` = rgb(0xFD, 0xCA, 0x43)）。下書きの内側の中央値 #FDCA44（左）/ #FDCA43（右）、平均 #FCCA43。
- round-1 の `iris.bright` #FDCA40 との違いは青 3 段階。既存 9 表情の虹彩の色は変えていない。
- 鼻 #F98B6E（下書き）/ 製品 #FB8B6D、口・ひげ #F8E9CD / #F9E9CB。生成由来の 1〜2 段階の差。

### 鼻・口・ひげ（sleepy と共用）
- 共用の理由: codex の実装方針（既存デザインの保持。作業指示として claude_sleep に伝えられた）。下書きは sleepy のキャンバスを image_gen で編集したもので、
  鼻・口・ひげは「保持」を指示した生成物なので、差は生成由来のゆらぎとして扱い、round-8 で確認済みの sleepy の形を優先する。
  `CatFaceGeometryTests.testSleepingSharesSleepyNoseMouthAndWhiskers` で口とひげの全パスが sleepy と一致することを固定した。
- 差（描画 − 下書き、1280×720 px。外接 4 辺 / 同じ列での中心 y の平均と最大）:

| 要素 | 外接 x（左/右） | 外接 y（上/下） | 中心 y の差 平均 | 最大 |
|---|---|---|---|---|
| 鼻 | −0.5 / −0.3 | +1.7 / +0.5 | +0.96 | 1.49 |
| 口 | −0.2 / −0.5 | +1.2 / −1.2 | −1.23 | 2.42 |
| 左ひげ 1 | +0.4 / −0.5 | +0.2 / +0.3 | +0.73 | 1.66 |
| 左ひげ 2 | +0.4 / −0.4 | +0.5 / −0.2 | +0.27 | 1.00 |
| 左ひげ 3 | −0.0 / −0.9 | +0.6 / +0.3 | −0.10 | 1.12 |
| 右ひげ 1 | −0.3 / −0.4 | +0.2 / +0.3 | +0.69 | 1.66 |
| 右ひげ 2 | +0.4 / −1.1 | +0.5 / −0.2 | +0.23 | 1.00 |
| 右ひげ 3 | +0.9 / −0.8 | +0.6 / −1.3 | −0.10 | 0.86 |

- 色分類の IoU（下書きを 1280×720 に縮めて描画と比較）: Y（弧）0.968、C（口・ひげ）0.877、P（鼻）0.957。
  C と P は下書きと round-8 の sleepy の間でも 0.873 / 0.956（navigator の計測）で同じ水準なので、差は下書き側の生成由来。

### 既存 9 表情が変わっていないこと
- `scripts/render_face.sh preview <作業 dir>` の出力のうち、9 表情の 36 ファイル（canvas 21、screen 9、screen3x 2、compare 2、overlay 2）が
  round-8（`docs/design/face-expression-2026-10-26/renders/round-8/`）とバイト単位で一致（round-2 のソースで確認）。
- 根拠: 9 表情は `Eye.closed` 0 のままで弧を描かず（`testOnlySleepingClosesTheEyes`）、`highlightDrop` の変更は `lid` が 1 のときだけ効く（9 表情の lid は最大 0.55）。
- `gallery.png` は 10 表情（4 行目に sleeping）。

## 補間
- sleepy → sleeping は `lid` 0.55 → 1 と `closed` 0 → 1 を同時に 0.25 秒で補間する（`animatedKeyPaths` に `closed` を追加、成分数 55 → 57）。
  まぶたが下りて虹彩を隠しながら、弧がまぶたの上に薄く現れて濃くなる。逆向きも同じ経路。
- `highlightDrop` は `lid` < 1 の間だけ白丸を下げる（lid 1 では見せる白丸がないので動かさない。lid 1 で下げると四つ星の制御点がキャンバス外に出た）。
  補間の途中で下げられた白丸は外形の切り抜きで見えない。
- codex が iOS の端点と、以下の Mac 診断描画による補間 5 コマを目視確認した。iOS 上の動画撮影は行っていない。

### 補間の確認（Mac、製品の `CatFaceCanvas` で描画。`renders/interpolation/`、2026-10-26 20:28 JST）
- 方法: 製品ソースは変更せず、`/private/tmp/cat-sleeping-20261026/interp-harness/` に `CatFaceView.swift` のコピー（末尾に private な `CatFaceCanvas` へ
  渡す診断 helper だけを追加）と `main.swift` を置き、製品の `CatFaceShapes.swift` / `CatFaceAppearance.swift` と一緒に swiftc でビルドした。
  sleepy と sleeping の `AnimationVector` を t = 0, 0.25, 0.5, 0.75, 1 で線形に混ぜ（SwiftUI の補間と同じ）、appearance に戻して 1280×720 で描いた。
  出力は `interp-sleepy-to-sleeping-t*.png`（5 コマ）、`interp-sleepy-to-sleeping-strip.png`（縦に並べた 1 枚）、`interpolation.txt`（数値）。
- 成分数: sleepy / sleeping とも 57。10 表情すべてで vector → appearance の往復で元の値に戻る。
- 補間の値（左目。右目は同じ値）: lid 0.55 → 0.6625 → 0.775 → 0.8875 → 1、closed 0 → 0.25 → 0.5 → 0.75 → 1。
  瞳の位置（0.12）、口（幅 0.8・笑み 0.75）、ひげ（lift −7、spread 0）は t によらず同じ。
- 画素: 目の枠（中心 ±1.05 半径）の外では、t = 0.25・0.5 のコマは t = 0 と 1 画素も違わない。t = 0.75・1 は 113 画素が 1 段階だけ違う
  （`ImageRenderer` の縁の ±1 のゆらぎ。round-1 の再生成で見たものと同じ）。鼻・口・ひげは動かない。
- 目: まぶたの縁（中央の列で最初に黒でない行）は t = 0 で局所 v 0.295（sleepy）、t = 0.25 で 0.569（弧の上縁と同じ高さ）、それより先は弧の上縁
  0.569 が最初の明るい行になる。弧の中心の色は t = 0.5 で #7F6521、0.75 で #BE9732、1 で #FDCA43（期待値 t × #FDCA43 = #7E6521 / #BD9732 / #FDCA43）。
- 見え方: 黒いまぶたが下りて虹彩と白丸を隠しながら、弧が同じ位置で濃くなる。t = 0.5 では弧の下に細い虹彩の帯が残り、t = 0.75 で虹彩は全部隠れる。
  閉じ切ったのに弧がないコマはない。

## iOS 側の確認（codex 担当。claude_sleep は xcodebuild を回さない取り決め）
- codex の報告（2026-10-26 20:29 JST）: Simulator の全体テスト 791 件、失敗 0、実機テスト 2 件は skip。iOS キャプチャと Mac の `screen3x-sleeping.png` を
  ICC → sRGB に変換して比較し、まぶた（弧）・鼻・口・ひげの色分類 IoU は各 1.0、外接は同一、主要色も同一（#FDCA43 / #FB8B6D / #F9E9CB）。
  iOS の sleeping 静止画・待機 UI・最大文字サイズ・設定の stepper は root の目視で正常。最終実行の証拠は下記に保存した。
- claude_sleep が書いた XCTest（`CatFaceGeometryTests` の新 3 件
  （`testSleepingClosesEyesUnderGoldLidArc`、`testSleepingSharesSleepyNoseMouthAndWhiskers`、`testOnlySleepingClosesTheEyes`）と
  `testPupilsAndHighlightsStayVisible` の閉眼分岐、`FaceExpressionTests.testSleepingIsNotExpressibleByTheTool`、
  `ExpressToolTests.testSleepingCannotBeReservedAndFallsBackToNeutral`、`FaceConversationPresentationTests.testInactivityFixturesRender`）は
  上の codex の全体テストに含まれて通過した。Mac では `scripts/render_face.sh check`（同じ判定）で確認している。

## 再現
```
scripts/render_face.sh check                 # 幾何条件（10 表情）
scripts/render_face.sh measure --sleeping    # 下書きと描画の計測と差分表
scripts/render_face.sh sleeping <round>      # renders/round-N/ へ画像・measure.txt・source.txt
scripts/render_face.sh preview <dir>         # 9 表情の無変更確認（round-8 と cmp）
```

## 最終 iOS 証跡（codex、2026-10-26）
- 最終の成功した xcresult から [寝顔](ios/final/face-sleeping-closed.png)、[待機画面](ios/final/inactivity-sleeping-paused.png)、[最大文字サイズ](ios/final/inactivity-sleeping-maximum-type.png)、[文字入力中からの待機](ios/final/inactivity-sleeping-typed-maximum-type.png)、設定画面 3 枚を保存した。画像は iPhone 18 Pro / iOS 27.0 **Simulator**。物理端末ではない。
- [provenance.json](ios/final/provenance.json) に xcresult、添付メタデータ、各ファイル SHA-256、最終テスト時の製品・テスト・診断ソース SHA-256 を記録した。
- [ios-mac-comparison.json](ios/final/ios-mac-comparison.json): 最終 iOS と Mac round-2 の 2556×1179 画像を sRGB に変換して比較。弧・鼻・口/ひげの分類 IoU はすべて 1.0、外接矩形と主要色も同じ。これは生成下書きとの画素完全一致を意味しない。
- claude navigator も独立に [iOS 画像を比較](../../validation/idle-sleeping-2026-10-26/claude-review-ios-face-png.md) した。root は最終 run の静止画、最大文字サイズ、設定、補間 strip を目視した。
- 計測表示の修正: `Measure.swift` の最大差の見出しを実装条件と同じ `|u| <= 0.95` に統一した。標本は 0.1 刻みなので対象点は従来どおり −0.9…+0.9。数値・画像は変更せず、round-1/2 の計測記録も見出しだけ直した。最終 iOS テスト後の診断ソースのみの変更として provenance に記録した。
