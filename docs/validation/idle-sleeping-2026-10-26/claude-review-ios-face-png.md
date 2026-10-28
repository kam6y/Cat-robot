> Root annotation: This independent review used an iOS Simulator capture from the first full run, not a physical device. The product face source was unchanged in the final passing run. The original wording “実機レンダ” below should be read as “iOS Simulator render”. Final-run comparison and source hashes are in `../../design/sleeping-2026-10-26/ios/final/`.

# claude navigator review: iOS 寝顔 PNG の独立比較（2026-10-26 11:28Z）

対象
- iOS: /tmp/cat-idle-ios-face/6FC5C870-2371-4D43-AC79-106AFBFACEFC.png（manifest 名 face-sleeping-closed_0_…png、2556×1179、UIHostingController 852×393 @3x、UI なしの顔だけ）
- Mac 参考: docs/design/sleeping-2026-10-26/renders/round-2/screen3x-sleeping.png（2556×1179）
- 下書き: docs/design/sleeping-2026-10-26/sleeping-draft.png（1672×941、全面 16:9 キャンバス）
手段: 自作の計測（色分類 gold / coral / cream の連結成分の外接・平均色、iOS vs Mac の画素差・分類 IoU）。
スクリプトと出力: scratchpad compare-ios/main.swift, output.txt。製品ファイル未編集、画像生成なし。

## iOS vs Mac 参考（同寸）
- 画素差 >8 階調: 0 px、>64 階調: 0 px（全 20 帯で 0）。分類不一致 1 px（境界のアンチエイリアス）。
- 分類 IoU: gold 1.000、coral 1.000、cream 1.000。
- 結論: iOS 実機レンダは Mac 参考と同一。

## iOS vs 下書き（キャンバス正規化 cv。1280×720 換算は x ×1280 / y ×720）
| 部位 | iOS cv | 下書き cv | 差 |
|---|---|---|---|
| 左の弧 | x 0.1174..0.3621 y 0.4919..0.5920 c (0.2397, 0.5420) | x 0.1160..0.3630 y 0.4899..0.5919 c (0.2395, 0.5409) | 端 ≤0.0014 (≤1.8px)、上縁 +0.002 (1.4px)、下縁 0 |
| 右の弧 | x 0.6379..0.8826 y 0.4919..0.5920 c (0.7603, 0.5420) | x 0.6370..0.8840 y 0.4899..0.5919 c (0.7605, 0.5409) | 同上 |
| 鼻 | x 0.4604..0.5396 y 0.6166..0.7048 c (0.5000, 0.6607) | x 0.4605..0.5401 y 0.6142..0.7035 c (0.5003, 0.6589) | y +0.0024/+0.0013 (1.7/0.9px) |
| 口 | x 0.4203..0.5797 y 0.7031..0.7846 c (0.5000, 0.7439) | x 0.4205..0.5801 y 0.7035..0.7864 c (0.5003, 0.7450) | ≤0.002 (≤1.3px) |
| ひげ 6 本 | 例 左2: x 0.0606..0.2595 y 0.7396..0.8363 | x 0.0634..0.2596 y 0.7396..0.8332 | 最大 0.003 (≤3.6px@1280、≤2.2px@720) |
- 色: 弧 iOS #FCC942 vs 下書き #FBC944/#FBCA45（≤3 階調）。鼻 #FA8A6C vs #FA8B6E。ひげ・口 #F8E8CA vs #F8E9CB〜#F9EACE（≤4 階調）。
- 実機 852×393 では位置差はすべて 1pt 未満。残る相違は既知の 2 点のみ: 弧の先端（下書きは丸い端、ベクターは尖る）、鼻・口・ひげの生成由来の 1〜2px 差。大きな相違なし。
