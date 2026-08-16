# Foundation Models 分類・返答並列実行調査 — 2026-08-17

## 判定

Cat Robotの分類モデルと返答モデルを、異なる`LanguageModelSession`で同時実行したときの可否と実機上の競合を調べた。

判定は**MVPでは逐次実行を維持する**。

別sessionへの要求は同時に未完了の状態を持てて、全12試行が成功した。一方、並列時は分類が25%、返答の最初の出力が84%、返答完了が53%遅くなった。先行開始によるユーザー待ち時間の短縮は、同じ入力同士の中央値で約41msにとどまる。この結果は、共有される推論資源またはフレームワーク内部のスケジューリングによる競合と整合する。ただし、計測したのはAPI callの時刻であり、hardware内部で同時に推論していたことは示さない。

約41msのために、宛先でない発話にも返答を生成する追加計算と、それに伴いうる電力・熱負荷、候補sessionの履歴分岐と昇格、破棄時のキャンセル完了待ちを追加する価値は、現在のMVPにはない。

## 調査した問い

呼びかけのない発話について、次の投機実行が有効かを確認した。

1. 分類と候補返答を別sessionで同時に開始する。
2. 分類が先に`.addressed`で完了した場合は、それ以降に届く候補返答snapshotを公開し、返答完了時にfinal responseを確定する。
3. 候補返答のsnapshotまたはfinal responseが分類より先に届いた場合はbufferし、分類完了後に`.addressed`のときだけ公開する。
4. `.ambiguous`または`.notAddressed`なら候補返答を破棄する。

同じ`LanguageModelSession`への重複要求は`LanguageModelSession.GenerationError.concurrentRequests`の対象になるため、本調査では本番案と同じく**異なるsession**だけを比較した。

## 検証環境

| 項目 | 値 |
| --- | --- |
| 実機 | iPhone 16 Pro（iPhone17,1） |
| 実機OS | iOS 26.6（23G71） |
| 接続 | USB-C有線、paired、Developer Mode有効 |
| Xcode | 26.6（17F113） |
| iOS SDK | 26.5 |
| 検証対象commit | `b34f4c0` |
| 分類モデル | `SystemLanguageModel(useCase: .contentTagging)` |
| 返答モデル | `SystemLanguageModel(useCase: .general)` |
| 実行日 | 2026-08-17（Asia/Tokyo） |

変更前のCat Robotテストを同じ実機で実行し、237 tests、0 failuresを確認してから計測した。

## 実験方法

アプリのservice wrapperを通すと一部のFoundation Modelsエラーがまとめられるため、診断用XCTestからraw `LanguageModelSession`を直接呼び出した。計測用コードは一時的なもので、製品コードおよび通常のテストには残していない。

### 比較条件

`A`を逐次、`B`を並列とした。

- `A: sequential`
  - `.contentTagging`の分類完了後に`.general`の返答streamを開始する。
- `B: parallel`
  - `.contentTagging`と`.general`の異なるsessionを`async let`で同時に開始する。

各試行で分類sessionと返答sessionを新しく作成した。返答sessionは毎回、同じinstructionsだけを含む初期`Transcript`から復元し、会話履歴の長さによる差を排除した。instructionsは検証対象commitの`CatRobot/Conversation/Services/FoundationModelAddressClassifier.swift`と`CatRobot/Conversation/Services/FoundationModelReplyService.swift`からそのまま使った。

これは投機返答で必要になる候補sessionに近い一方、現行MVPの通常返答は、起動中に使い続けるprewarm済みの長寿命sessionである。公平な条件比較のため逐次・並列ともfresh sessionに揃えたので、絶対時間と競合率を現在のproduction lifecycleへそのまま当てはめない。

分類は本番と同じ`AddressDecision`のstructured generationを使い、greedy・temperature 0とした。返答は出力の揺れを減らすためgreedy・temperature 0・最大48 tokenに固定した。

### 固定prompt

1. `今日いちばん気分がよかったことを短く話して`
2. `雨の日に家で楽しめることを一つ教えて`
3. `明日の朝を気持ちよく始める一言をお願い`

3種類を2巡し、同じpromptについて逐次と並列を1回ずつ実行した。順序による温度・cacheの偏りを減らすため、6ペアの順序は次のようにした。

```text
AB / BA / BA / AB / AB / BA
```

分類と返答を各1回ウォームアップし、その値は集計から除外した。試行間は1秒空け、実機のthermal stateが`serious`または`critical`になった場合は中止する条件とした。

### schedulingと時刻計測

単調時計として`ProcessInfo.processInfo.systemUptime`を使い、各trialのorigin直後にcomponent内でも開始時刻を取得した。時刻は1ms単位へ丸めた。並列条件の中核は次の形で、XCTestCaseやアプリのservice wrapperはchild taskへ渡していない。

```swift
let origin = ProcessInfo.processInfo.systemUptime

async let classifier = measureClassifier(
    session: freshClassifierSession,
    prompt: prompt,
    origin: origin
)
async let reply = measureReply(
    session: freshReplySessionFromCheckpoint,
    prompt: prompt,
    origin: origin
)

let (classifierResult, replyResult) = await (classifier, reply)
```

逐次条件では同じ2つの計測関数を`await measureClassifier(...)`、`await measureReply(...)`の順に呼んだ。各関数は呼び出し直後にcomponent start、成功またはerror捕捉直後にcomponent endを記録した。返答はstream内の最初の非空snapshotも記録した。

request lifetimeの重なりは、次で算出した。これは未完了のAPI callが同時に存在した時間であり、model内部の処理がhardware上で同時進行した時間ではない。

```text
request lifetime overlap =
    max(0, min(classifier end, reply end) - max(classifier start, reply start))
```

### 計測値

- 分類の開始・完了
- 返答の開始・最初の非空snapshot・完了
- 並列taskの開始時刻差
- 分類と返答のAPI call lifetimeが重なった時間
- 分類で公開をgateした最初の返答時刻
- 分類で公開をgateした返答完了時刻
- raw Foundation Modelsエラー種別
- 返答文字数
- 試行前後のthermal state

ユーザーが見られる最初の返答時刻は次で定義した。

```text
gated first = max(classifier end, reply first snapshot)
```

## 結果

ウォームアップを除く12試行、24 model requestsはすべて成功した。

- `concurrentRequests`: 0件
- `rateLimited`: 0件
- その他のgeneration error: 0件
- thermal state: 全試行`fair`
- 並列taskの開始時刻差: 計測上0ms
- 並列時のrequest lifetime overlap: 434〜498ms
- 同じpromptペアの返答文字数: すべて一致

診断XCTest自体も1 test、0 failuresで完了し、実行時間は30.658秒だった。

### 処理単体の中央値

| 指標 | 逐次 | 並列 | 並列時の変化 |
| --- | ---: | ---: | ---: |
| 分類の所要時間 | 350.5ms | 438.5ms | +25.1% |
| 返答開始から最初の非空snapshot | 384.5ms | 709.0ms | +84.4% |
| 返答開始から返答完了 | 623.5ms | 954.5ms | +53.1% |

別sessionの要求は同時に未完了の状態を持てたが、両処理の単体時間は明確に悪化した。並列中も分類は全6回で最初の返答snapshotより先に終わり、その先行幅は117〜315msだった。したがって今回の条件では、「返答はできているが分類待ち」という分岐は一度も発生していない。

### ユーザー待ち時間

| 指標 | 逐次の中央値 | 並列の中央値 | 同一入力ペアでの短縮中央値 |
| --- | ---: | ---: | ---: |
| gated first | 734.0ms | 709.0ms | 40.5ms |
| gated completion | 973.0ms | 954.5ms | 39.0ms |

中央値同士の差とペア差の中央値は、promptごとの出力長が異なるため一致しない。採否判断には同じpromptを直接比較するペア差を使った。

全6ペアで並列のほうが短かったが、短縮幅は次の範囲だった。

- gated first: 21〜48ms、ペア差中央値40.5ms（逐次中央値の約5%）
- gated completion: 10〜68ms、ペア差中央値39.0ms（逐次中央値の約4%）

### trial別の生値

時刻は各trialのoriginを0msとした。分類startは全trialで0msだったため表では省略する。`reply first`はgate前の最初の非空snapshotだが、全trialで分類がそれより先に完了したので、結果的に`gated first`と同じ値になった。`overlap`は上記のrequest lifetime overlapである。

| Trial | Pair | Mode | Prompt | 分類end | 返答start | 返答first | 返答end | start skew | overlap | 分類結果 | 文字数 | thermal | error |
| ---: | ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :--- | ---: | :---: | :---: |
| 1 | 1 | A | 1 | 353ms | 353ms | 740ms | 981ms | 353ms | 0ms | addressed | 31 | fair→fair | none |
| 2 | 1 | B | 1 | 439ms | 0ms | 711ms | 954ms | 0ms | 439ms | addressed | 31 | fair→fair | none |
| 3 | 2 | B | 2 | 437ms | 0ms | 751ms | 1,277ms | 0ms | 437ms | addressed | 95 | fair→fair | none |
| 4 | 2 | A | 2 | 350ms | 350ms | 793ms | 1,334ms | 350ms | 0ms | addressed | 95 | fair→fair | none |
| 5 | 3 | B | 3 | 498ms | 0ms | 615ms | 659ms | 0ms | 498ms | addressed | 11 | fair→fair | none |
| 6 | 3 | A | 3 | 351ms | 351ms | 663ms | 693ms | 351ms | 0ms | addressed | 11 | fair→fair | none |
| 7 | 4 | A | 1 | 346ms | 346ms | 728ms | 965ms | 346ms | 0ms | addressed | 31 | fair→fair | none |
| 8 | 4 | B | 1 | 447ms | 0ms | 707ms | 955ms | 0ms | 447ms | addressed | 31 | fair→fair | none |
| 9 | 5 | A | 2 | 347ms | 347ms | 788ms | 1,331ms | 347ms | 0ms | addressed | 95 | fair→fair | none |
| 10 | 5 | B | 2 | 434ms | 0ms | 749ms | 1,263ms | 0ms | 434ms | addressed | 95 | fair→fair | none |
| 11 | 6 | B | 3 | 438ms | 0ms | 619ms | 650ms | 0ms | 438ms | addressed | 11 | fair→fair | none |
| 12 | 6 | A | 3 | 351ms | 351ms | 665ms | 694ms | 351ms | 0ms | addressed | 11 | fair→fair | none |

ペア差は同じPairの`A - B`である。gated firstの短縮は順に29、42、48、21、39、46ms、gated completionの短縮は27、57、34、10、68、44msだった。この表から処理単体の値を再計算するときは、Aの返答所要時間を`返答時刻 - 返答start`、Bを`返答時刻 - 0ms`とする。

参考として、集計から除外した最初のウォームアップは分類662ms、返答は開始から最初のsnapshotまで664ms、完了まで910msだった。

## 解釈

本調査から分かることは次のとおり。

1. 異なる`LanguageModelSession`なら、分類と返答の未完了API callを同時に持てる。
2. 両requestは`concurrentRequests`にならず完了したが、model内部で同時進行したか、queueされたかは観測できない。
3. 並列条件では単体時間が大きく悪化し、特に返答の最初のsnapshotが約1.8倍遅くなる。
4. 先行開始の利点は競合でほぼ相殺され、ユーザー待ち時間の純改善は約41msだけだった。
5. 分類は常に返答より先に終わったため、分類結果を待つgate自体は今回のbottleneckではない。

共有される推論資源やFoundation Models内部のスケジューリングが原因と考えられるが、この実験だけで特定のhardware unitまたは内部実装を断定はしない。

## 採用判断

現在のMVPでは、呼びかけのない発話を次の順序で処理する既存設計を維持する。

```text
分類 → addressedなら返答生成
```

full parallel speculative replyは採用しない。100〜200ms遅らせて候補返答を始めるhedged parallelは未測定であり、full parallelの結果からその性能を断定しない。現時点では、逐次実行が最も単純で、非宛先発話の投機計算とsession管理を増やさないため、hedgeも保守的に採用しない。

明示的な呼びかけ、会話継続中、確認への肯定など、分類を省略できる既存の高速経路はそのまま優先する。

## 再検討条件

次のいずれかが起きた場合だけ再測定する。

- 実アプリの`ClassifiedFirstCaption`がUX目標を継続的に外す。
- Foundation Models、iOS、SDKの更新でsession同時実行の特性が変わる。
- 分類instructions、structured output、返答session管理を大きく変更する。
- 長い会話履歴から候補sessionを作る実装へ移行する。

再測定時は、まず100ms hedgeと200ms hedgeを同じpromptで各3ペア比較する。候補がある場合だけ、実アプリの`ClassifiedFirstCaption`と`ClassifiedSpeechStart`を1〜3回測り、電力・thermal state・破棄完了までの時間も確認する。

## 適用範囲と制約

- ASR、TTS、SwiftUI更新は含めず、Foundation Modelsの競合だけを測った。
- 返答は本番のtemperature 0.5・最大160 tokenではなく、比較の揺れを抑えるgreedy・最大48 tokenとした。
- instructionsだけの初期`Transcript`を使い、長い会話履歴は含めていない。
- 各trialの返答sessionはfreshな`Transcript`復元sessionであり、現行MVPのprewarm済み長寿命sessionとはlifecycleが異なる。今回の競合率をproductionの絶対値として扱わない。
- 電力消費は直接測定していない。全trialのthermal stateは`fair`だった。
- 6ペアの小規模測定なので、平均やp95は主張せず、生値、中央値、範囲だけを使った。
- この結果はiPhone 16 Pro、iOS 26.6、検証対象commitに対する記録であり、将来のOS・model更新後も同じとは限らない。

## 関連資料

- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [LanguageModelSessionをTranscriptから初期化](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init%28model%3Atools%3Atranscript%3A%29)
- [LanguageModelSession.GenerationError.concurrentRequests](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error/concurrentrequests)
- `docs/validation/2026-08-16-iphone16pro-smoke-test.md`
- `docs/superpowers/specs/2026-08-12-cat-robot-mvp-design.md`
