# 顔サイズ調整

iPhone上でCat Robotの通常会話画面の顔サイズを選ぶための別アプリです。本体と同じSwiftUIベクター3ファイルを参照し、調整前の本体と同じ85%の枠を初期値にしています。

1. 下のスライダーか「−」「＋」で50〜100%を0.5%刻みで調整します。
2. 表情を切り替えたり「全画面」で操作を隠したりして確認します。右上の調整ボタンで操作を戻せます。
3. 「値をコピー」を押し、この会話に貼り付けてください。表示された割合をそのまま伝えても構いません。
4. Codexが選んだ値を本体に反映します。このツールには本体へ書き込む機能はありません。

「85%に戻す」で初期サイズに戻せます。倍率は別アプリ内に保存され、再起動後も残ります。全画面の枠が変わる値なので、顔の縦横比や各パーツの形は変えません。文字入力時・設定時の顔サイズの調整は対象外です。

## 開発

```sh
ruby scripts/generate_face_size_tuner_project.rb
xcodebuild test -project tools/face-size-tuner/FaceSizeTuner.xcodeproj \
  -scheme FaceSizeTuner -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGNING_ALLOWED=NO
```

- bundle ID: `com.kamby.CatFaceSizeTuner`
- iOS 27.0、横向きLandscapeRight。音声・カメラ・Bluetooth・モデルの依存は持ちません。
- `CatFaceView.swift` / `CatFaceAppearance.swift` / `CatFaceShapes.swift` は本体を直接参照します。
- 表情と口のenumは既存の描画ハーネス `scripts/face-render/Stubs.swift` を参照します。
- 試験は `CatRobotTests/App/AccessibilityActivationSupport.swift` も共有します。この補助ファイルは本体アプリの型に依存させないでください。
- コピー値は `ConversationView.faceScale = 0.735` のように小数3桁で出力され、描画倍率と一致します。

2026-10-27にユーザーが80%を選択し、本体の通常会話画面へ反映しました。ツールの初期値とリセット値は比較用の85%です。
