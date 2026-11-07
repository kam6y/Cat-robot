# Clarification history validation

実装の候補はTask 4のcommit `50528558e261f40d11bfae298b9c4d4c0b0fbb93`（source入力 `1487a2562f7a3a18ff463166252d0db182a9bcf4b6c02da892850f1b47ab81e0`。文書を除くapp・test・project・scripts・nativeの入力）。Task 4の実モデル受入は、初回72試行（`A9666B46…`）が不合格、宛先判定と要約の指示文2か所を直した後の全件再実行（`21090B5F…`）で72/72合格。詳細は「結果」。

## 確認済みの実装

| 対象 | commit | 検証 |
| --- | --- | --- |
| 分類要求・確認待ち専用Haiku経路 | `190b5f35c0877a66b8cf52a89d63ba97c819c153` | 3クラス29件成功 |
| 実発言・pendingの寿命・履歴 | `2f8bca757c8c46a3871f7208773fb3222411469b` | 8クラス108件成功 |
| 参考往復つき要約・正常な0件 | `25d37d587e8f105f1c8c74afd23b04ef375480a9` | 6クラス102件成功 |
| 確認待ち専用の分類指示・要約指示の修正、実モデル試験 | `50528558e261f40d11bfae298b9c4d4c0b0fbb93` | 10クラス149件のうち148件成功・有料1件skip、実モデル72/72（`21090B5F…`） |

これらはSimulatorとfakeによる検証（最後の行の実モデル72/72は「結果」を参照）。各commitの全source入力がGREENの入力と一致することも照合した。証跡は `/private/tmp/cat-issue29-clarification-20261107/` のTask別manifest、xcresult、検証JSONにある。実モデルの意味判断、実請求額、実機の利用者受入を代替しない。

## 固定する初回の実モデル受入

fixture版は `issue29-v1`、各fixtureを3回。分類39＋返答18＋要約15＝72試行（Haiku 54、Opus 18）。これは最上位の要求数であり、tool結果の追加往復、認証、実際のHTTPリクエスト数や請求額の上限ではない。SDKはClaudeForFoundationModels 0.2.3、revision `0262e1a766c461a4268dcec656eca95dd74cebf8` に固定する。モデルは既存のHaiku 5.5 / Opus 5.5、effort low、fallbackなし。

### 分類13件

元発言は「今日の天気はどう？」、聞き返しは本番の `ClarificationContext.question`。

| 今回の発言 | 期待するenum（各3回すべて） |
| --- | --- |
| はい / うん / いいえ / ううん | addressed |
| 言ったよ / そうそう、天気の | addressed |
| いいえ、あなたには言ってない / 違うよ、ママに言ったの | addressed |
| 猫ちゃん、5たす4はいくつ？ | addressed |
| 明日の予定は？ | ambiguous |
| ママ、鍵はどこ？ / これは独り言。疲れたな。 | notAddressed |
| 部長に電話しておいて。 | notAddressed または ambiguous |

本番 `ClaudeAddressModelClient` を直接使い、enumを自動照合する。

### 返答6件

本番 `ClaudeConversationService.prepareMemory` → `recordExternalTurn` で固定の聞き返しを記録し、今回の発話を `streamReply` へ渡す。本番が組んだ `ConversationInstructions` をtest-only factory decoratorが記録し、本番 `ClaudeSessionFactory` へ変更せず渡す。本番RememberToolの定義と実装を変えず、引数・結果を記録するwrapperを通す。試行ごとに新しいsessionとin-memoryの記憶・usageを作り、アプリの利用者の記憶やusageへ保存しない。音声・首・表情・カメラのtoolは渡さない。

| 元発言 | 今回の発言 | 期待する意味・tool |
| --- | --- | --- |
| 7たす5はいくつ？ | はい | 12に答える |
| 同上 | 言ったよ | 12に答える |
| 同上 | いいえ、あなたには言ってない | 通常の1〜2文で短く受け止め、元の算数に答えない |
| 同上 | 猫ちゃん、5たす4は？ | 新しい質問の9に答える |
| 私の好きな飲み物はほうじ茶です。覚えておいて。 | いいえ、それはママのこと。あなたには言ってない | remember呼出し0。本人の好みを保存しない |
| 同上 | うん、私の好みだから覚えて | rememberで本人のほうじ茶の好みを保存する |

自動チェックは非空と、指定2件のremember呼出し・保存の有無。意味・短さ・保存の主体と内容は、Navigatorが18試行すべての返答・tool引数と結果・保存したfactsを読んで照合する。数字や語が含まれるだけで合格にはしない。

### 要約5件

evictedは「私の好きな飲み物はほうじ茶です。覚えておいて。」と固定の聞き返し。in-memory snapshotと保持文字数で本番 `ClaudeConversationService.compact` を駆動する。そこで作るrequestをtest-only decoratorが変更せず本番 `ClaudeSessionFactory.summarize` へ渡し、本番の検証・候補確定・保存後の要約を記録する。要約後の返答だけは固定の非ネットワークclientで閉じ、追加の有料返答を発生させない。分類39＋返答18＋要約15という内訳は変わらない。

| ID | previousSummary / reference | 期待 |
| --- | --- | --- |
| confirmed-across-boundary | 前回なし / 肯定＋参考だけの合言葉 | 本人のほうじ茶の好みを残し、合言葉を追加しない |
| denied-across-boundary | 前回なし / 否定＋参考だけの合言葉 | 本人の好みや未解決の質問として残さず、合言葉を追加しない |
| unconfirmed-empty | 前回なし / 肯定なし、参考なし | raw結果はnoContent、解決後も空 |
| previous-and-reference-only | 確定済みのジャズの好み / 参考だけの合言葉 | ジャズを保ち、未確認のほうじ茶や合言葉を追加しない |
| previous-and-denied | 確定済みのジャズの好み / 追加発言への否定 | 否定された追加内容を混入せずジャズを保つ |

参考だけの新事実は合言葉 `REFERENCE_ONLY_29`。rawの型・本文と、前回要約を適用した後の本文を両方記録する。最後のfixtureはrawをnoContentへ誘導せず、noContentなら前回要約を保持することも確認する。この分岐そのものはTask 3のfakeで確定検証済み。

型・1,200字以内・sentinelの混入・指定fixtureの明示noContentを自動照合する。本人の事実・否定・既存の好みの保持・参考だけの事実混入は、Navigatorが15試行すべてを意味で照合する。本人の好みの否定を「ほうじ茶」という語の有無だけで判定しない。

### 合否と失敗時の扱い

全72試行が期待どおりであることが受入条件。分類は全39件のenum、返答18件と要約15件は上記の自動チェックとNavigatorの全件レビューが必要。runnerの自動チェック完走は `pending-navigator-semantic-review` として記録し、最終受入成功とはしない。

timeout・認証・parse・通信の失敗や、欠けた記録・skipは成功として数えない。自動retryや試行の選別再実行はしない。実出力を保存し、指示修正が必要なら別HANDOFFで製品の編集対象を決め、その指示に依存する受入セットを全件再実行する。

## 実行の隔離と証跡

専用runnerは `scripts/run_clarification_history_model_tests.sh <Xcode-device-ID> <CoreDevice-ID>`。build-for-testing後のxctestrunを複製し、OnlyTestIdentifiersは `ClarificationHistoryModelTests/testAcceptanceMatrix` の1メソッドだけにする。明示のopt-in・UUID・凍結HEAD/入力SHA/SDK revisionは複製した設定へ渡し、元の設定や通常起動は変更しない。並列実行と自動retryを無効にする。

paidメソッドはDebug実機・opt-in・UUIDが揃わなければauthの取得やmodelの構築より前にskipする。ローカルの `testFixtureInventoryAndPromptSizes` はネットワークを持たないcapture-only decoratorで同じ本番の外部記録・セッション構築・compactを駆動し、実際に作られる指示/requestのサイズとSHAを出す。生成部分は固定fakeで、モデルを構築しない。元発言の記録・1回のセッション作成・evicted/reference/previousSummaryの一致も事前に確かめる。Simulatorではpaidメソッドの本文もコンパイルし、通常実行時のskipを確認する。

実機は `Documents/ClarificationHistory/<runID>/results.json` へ、試行の開始/終了とrememberの開始/終了を逐次atomic保存する。trial ID・モデル・effort・指示/prompt/hash・結果・errorの型と写像・所要時間・tool引数と結果を記録する。秘密情報や認証ヘッダを出力しない。runnerはrequest/sourceのbefore/after、xcresult、summary、実機のJSON、実行完了の照合結果をrunID別に回収する。

分類のprompt SHAは本番requestInputのJSONをキー順でcanonical化した論理入力のSHA。内部のJSONEncoderのキー順やHTTPのwire bodyは観測していない。返答と要約は本番の指示文と最上位promptの文字列のSHA。SDKのtool/schema包装やtool結果に伴う追加入力は、最上位promptのSHA/文字数へ含めない。

history文字数は、返答のinstructions/要約のpromptにすでに含まれる部分を別に表示する値で、費用の推定で二重に加えない。実token usageは本番の戻り値に露出していないため、`usage=null` / `usageAvailability=notExposedByProductionAPI` とする。文字数換算を実測トークン数や実請求額として報告しない。

## 同意と費用の前提

2026-11-07 07:47:32 UTC、Navigatorからagmsgで、提示した概算と条件に対する利用者の「いいよ」を受領した。受領した概算は初回72試行で約$0.75、token数が想定の2倍でも$2未満。単価の確認と概算の提示はNavigatorが担当した。これは文字数からの概算であり、今回の実token数・実請求額は未計測。

fixture確定後のサイズで概算が大きく増える場合（例: $2超の見込み）は実行前にNavigatorへ知らせ、Navigatorが再確認する。再実行前もNavigatorへ連絡し、利用者への報告を経る。fixture/runnerの事前検証とNavigator照合が終わってから初回の実行へ進む。同意を再度求める新しいフローは加えない。

## 結果

ローカルpreflight（smoke-1）はfixture inventory 1件成功、有料メソッド1件は想定どおりskip、失敗/unexpected 0、モデル呼出し0。実行前後の入力SHAは `a0542a593519174b7d1285323a2c574ee352d682fc38a8711870ebd34c02e2db` で一致した。本番経路から得たサイズは次のとおり（historyを追加で加算しない）。表示統計のsummary話者ラベルを本番どおりAIへ揃え、最終preflightで再確認する。

| 種別 | 1試行のinstructions | 1試行のprompt | 3反復を含むinstructions＋prompt合計 |
| --- | --- | --- | --- |
| 分類39試行 | 615字 | 79〜91字 | 27,285字 |
| 返答18試行 | 履歴込み1,081〜1,095字 | 2〜23字 | 19,743字 |
| 要約15試行 | 412字 | 90〜201字 | 8,625字 |

合計55,653文字。token数ではなく、SDKのtool/schema包装やtool結果の追加入力も含めない。事前にNavigatorが用いた指示文の文字数より小さく、同意済みの費用前提と照合するためサイズJSONを渡した。runnerはbash構文とembedded Python構文、生成projectは再生成の決定性と契約試験を確認済み。

最終preflight（smoke-2）も1件成功・有料1件skip、失敗/unexpected 0、モデル呼出し0。入力SHA `b85fd775c892582845e4dd8f3d3c2f3bd9a4504408c91f3e8abf5401a9195f80` は前後一致。全24件の実instructions/prompt・期待値・入力SHAはsmoke-1と同一で、変更したのはsummaryのhistory表示とその文字数だけ。最終inventoryは `/private/tmp/cat-issue29-clarification-20261107/task4-fixture-inventory-final.json`（SHA-256 `dc6d9903ce76478c280070e6df7a38d74a33ee73980e9340714c861f0f648e2c`）、検証は `task4-preflight-verification.json`（`73014c6e…`）。

Navigatorは08:12:17 UTCに実サイズを独立集計し、同意済みの範囲内で再確認は不要と回答した。最終SHAの照合後に初回72試行へ進む。

実機attempt `3F323D6E-1AC3-44DA-BF5F-340BC5CF3161` は、物理iPhone向けのbuild-for-testingに成功した後、XCTestの開始前に止まった。xcodebuildが「Must specify -test-iterations with more than 1 iteration.」と、runnerの `-test-iterations 1` 指定を拒否したため（test exit 64）。passed/failed/skipped/totalはすべて0、モデル呼出しも0で、課金は発生していない。実行前後でsource/docsは不変。証跡は `model-runs/3F323D6E-1AC3-44DA-BF5F-340BC5CF3161/failure-verification.json`（SHA-256 `bfa252893a1008d0158821ca47a059baa705896ae924325b5158ec6ffa263fc4`）。runnerからこの指定だけを外した。反復なしの既定の1回のまま、複製した設定の `MaximumTestRepetitions=1`・`RetryTestsOnFailure=false`・並列なし・1メソッド限定は変えない。Swiftのfixture・期待値・モデル入力は変わらないので、同じ72試行を新しいrunIDで初回として実行する。追加の同意は求めず、利用者へは停止と修正を報告した。

修正後のattempt `1C7B94A3-62DE-48C3-B70D-4D827F94DD6A` も、XCTestの開始前に止まった。物理iPhoneのbuild-for-testingは成功したが、端末がロックされていた。Xcodeは実行前の端末確認で「Unlock … to Continue」（device is locked）となって解除を待ち、その後「Lost pending connection to the test runner before launch」で終了した（test exit 65）。xcresultの集計はpassed 0 / failed 1 / skipped 0 / total 1。この失敗1件はXCTestの起動インフラの失敗で、`testAcceptanceMatrix` は始まっていない（Test Caseの開始行も実機のresults.jsonもない）。モデルの試行・呼出しは0で、課金は発生していない。実行前後でsource/docsは不変。証跡は `model-runs/1C7B94A3-62DE-48C3-B70D-4D827F94DD6A/failure-verification.json`（SHA-256 `2b7598a0515ca735c081182fc751a3d53363dbea1c9e98ddbe63a24739028922`）。runner・fixture・期待値は修正しない。利用者にロック解除を依頼し、解除を確認してから、同じ72試行を新しいrunIDで初回として実行する。

端末のロック解除後に開始したattempt `A9666B46-4D81-44ED-B429-34381F258EED` が、初回の実モデル72試行（Haiku 54、Opus 18）である。72件すべてが記録され、モデル呼出しのerror・timeout・parse失敗とskipは0。実行前後でsource/docsは不変（入力SHA-256 `0719bc556e427e9374506792e6e629446e2ec4c91ec4c941dfc9874664175028`）。raw `model-runs/A9666B46-4D81-44ED-B429-34381F258EED/data/results.json` のSHA-256は `2b78f467af82fabecf036e2069bf938b7c0aa70e3aa1524d40e9993b9bee0cba`、集計の検証は `acceptance-failure-verification.json`（`e0c808938603d69084fbdaa1abc643418b5225d8cccb946d1113295f8598cd71`）。XCTestはpassed 0 / failed 1 / skipped 0 / total 1で、失敗は全試行の期待一致を求めるassertionによる。自動照合は69件一致、3件不一致。

- `classification/denied-mom/2`: 「違うよ、ママに言ったの」が notAddressed（期待 addressed）。1回目と3回目は addressed。
- `summary/unconfirmed-empty/2` と `/3`: 肯定の返事が無いのに、元の発言「私の好きな飲み物はほうじ茶です。覚えておいて。」をraw text「- 利用者の好きな飲み物はほうじ茶です。」として要約した（期待はnoContentで、解決後も空）。1回目はnoContent。

返答18件と要約15件は、ClaudeとCodexがそれぞれ独立に全件を読み、各自の初回判定を保存してから突き合わせた（Claude `semantic-review.json` SHA-256 `960e8c4957755b4e6771199b6cf3f7d0a08bd702ca76e3a9da6a4c80989d826c`、Codex `codex-semantic-review.json` `7ba9f571c831fe4dfc8e8e94685d577f4443bbd8a492c88f5122f0e269756160`）。33件すべてで判定が一致し、合格31、不合格2（上記の要約2件）。返答は18件とも期待どおりだった。肯定の「はい」「言ったよ」には元の算数に12と答え、否定には1〜2文で受け止めるだけで12を答えず、猫を呼ぶ新しい質問には9と答えた。好みの否定ではrememberを呼ばず、好みの肯定ではrememberで本人の好みを1件保存した。`denied-across-boundary` の3件は、否定された経緯を注記として残したが、本人の好みや未解決の質問としては扱っておらず、参考だけの合言葉も含まないため合格とした。同じ否定を参考に持つ `previous-and-denied` では3件とも項目自体を作らなかった。

初回の実モデル受入は不合格。fixture・期待値・3/3の基準・モデル・SDKは変えず、失敗した試行だけの再実行もしない。分類の専用指示（`ClaudeAddressClassifier.swift`）と要約の指示（`ConversationSessionFactory.swift`）の文言だけを別HANDOFFで直し、同じ72試行を新しいrunIDで全件再実行する。語の一覧や確認状態は追加しない。

Navigatorだった Codex が Driver を引き継ぎ（ACK 10:34:03 UTC）、2つの指示文の本体だけを直した。

- 宛先判定（`ClaudeAddressClassifier.swift` の確認待ち専用指示）: notAddressed とする条件を「今回の発話で猫以外の相手に直接呼びかけている」に絞った。さらに、文中に家族や友人が出ても、元の発言は別の人に言ったと猫へ説明・訂正する返事は今回の返事自体が猫宛て（addressed）であり、元の発言の宛先を今回の発話の宛先にしない、という段落を加えた。分類例は変えていない。
- 要約（`ConversationSessionFactory.swift` の `ConversationSummaryRequest.instructions`）: 聞き返された発言をAI宛てと認める返事が追加の会話にも参考にも無ければ確認されていないとみなし、好みや「覚えて」の依頼でも項目にしない、AIの聞き返し自体は肯定ではない、ほかに残す内容が無ければitemsを空配列にし「未確認」「否定された」という説明だけの項目は作らなくてよい、の3点を加えた。

通常の宛先判定の指示、返答の指示、schema・API・fixture・期待値・モデル・SDK・runnerは変えていない。語の一覧や確認状態も追加していない。SHA-256は `ClaudeAddressClassifier.swift` `eb77dad9cf9e4cb3e12c23f38974c1936d14adf1cd3ab39386a40f2b420c070b`、`ConversationSessionFactory.swift` `79e5a44256d7148fb0ea5260370f5cbb31ae6d7df6e0bb1628a942be44794b7a`、tracked patch `519ec6936d9b6f881159a0a0399cb9a0955d53148837c431630c2dfe9963e3b0`、source入力 `1487a2562f7a3a18ff463166252d0db182a9bcf4b6c02da892850f1b47ab81e0`。Navigator（Claude）が差分を読み、2つの文字列本体以外に変更が無いことを照合した。

関連10クラス149件のSimulator試験は148件成功、有料メソッド1件だけ想定どおりskip、失敗・unexpected 0、モデル呼出し0（`task4-prompt-verification.json`、`2224ce87ebb038ad5d56bdfdda1806d22345b8a84acfb7dea5a4ee0d9424da39`）。プロジェクトの再生成は2回とも既存とbyte一致した。新しいinventory（`task4-prompt-inventory.json`、`d62645ec1ad1f8cfc1254cce075ca8aad6ed09a2607e93ad06a3099951689fdf`）では、72試行のinstructions＋promptが64,206字（分類32,823、返答19,743、要約11,640）。分類の指示は615字から757字、要約の指示は412字から613字になり、初回からの増分はHaikuへの入力8,553字だけで、返答の全入力は初回と同一。1文字を1tokenと見ても増分は約$0.001で同意済みの範囲に収まるため、Navigatorが再同意は不要と判断し、利用者へ再実行を事前に報告した。

再実行attempt `21090B5F-C31A-4A6E-AAE6-9A289D41E144` で、同じ固定72試行を全件実行した（失敗した試行だけの再実行はしていない）。72件すべてが記録され、自動照合は72/72一致（分類39、返答18、要約15）、error・timeout・parse失敗とskipは0。XCTestはpassed 1 / failed 0 / skipped 0。実行前後でsource/docsは不変。raw `model-runs/21090B5F-C31A-4A6E-AAE6-9A289D41E144/data/results.json` のSHA-256は `e17ff43c005e00b2f3d62e59ad836a2289e878fa6f43c35fe82ffb5277cb86dd`、実行の検証は `execution-verification.json`（`fb53fab8fd07cd2809328bdfc359e290b07efd9c544989cae324b1b0254df103`）。初回に外れた箇所は、「違うよ、ママに言ったの」が3回ともaddressed、返事の無い元の発言の要約が3回ともnoContentになった。直接の呼びかけではない「部長に電話しておいて。」は3回ともnotAddressed（期待範囲内）。

返答18件と要約15件は、初回と同じ基準で両者が独立に全件を読み、各自の初回判定を保存してから突き合わせた（Claude `semantic-review.json` SHA-256 `6132c84be7907a2821e1ec823a2a49aa99a8bcb42441160cf64223a9bf4a6cf3`、Codex `codex-semantic-review.json` `52ade081e77f70d9ec1d18709fc8fab09e2a1b49aa4019323e3ef76589d0b324`）。33件すべて合格で判定が一致した。返答は初回と同じく、肯定に12、否定に短い受け止め、新しい質問に9と答え、好みの否定ではrememberを呼ばず、好みの肯定ではrememberで本人の好みを1件保存した。`denied-across-boundary` は3回とも、否定の経緯を注記した初回の形ではなくnoContent（項目なし）になった。最終の受入記録は `model-runs/21090B5F-C31A-4A6E-AAE6-9A289D41E144/final-acceptance.json`（`a1840ae6b67a6ba46d9326d4dd95cfad8d7d25cd99d27034e5ff9ae72f61c20f`）。

**Task 4の実モデル受入は、指示文を直した後の全件再実行で合格とする。** 初回の不合格の記録、raw結果、両レビューはそのまま残す。今回の結果は各fixture 3回の固定セットに対するもので、ほかの言い方の返事や長い会話全般での正しさ、実token数・実請求額は確認していない。

## 文書と分岐図（Task 5 Step 1・2）

Task 4のcommit `50528558e261f40d11bfae298b9c4d4c0b0fbb93` の後、Codexから文書のDriverを受け取り（OFFER 10:55:34 UTC）、アプリの入力（source入力 `1487a256…`）は変えずに文書だけを更新した。

- `README.md`: 聞き返しの文言、15秒の確認待ちの間の振り分け（こちら向きはそのまま返答、向いていない返事は元の発話と聞き返しを添えてHaikuで判定し、端末内モデルがあっても通信と利用料が発生する）、文意による肯定・否定、元の発話を再送しないこと、周りの発言を捨てて確認待ちを残すことを加えた。記憶の節には、返事を実際の文で1往復として保存すること、否定にも返答すること、要約へ残す側の往復を参考として渡すこと、加えるものが無い要約を失敗としないことを加えた。Claudeへ送る内容と実機確認の手順（確認待ち中に顔をそらした肯定・否定）も更新した。
- `docs/README.md`: #29の設計を索引へ加え、#23の行に「肯定語で元発話を再送する部分は#29で廃止」と注記した。分岐図の時点を「issue #29対応時点」にし、検証記録の表へこの記録と計画を加えた。
- `docs/superpowers/specs/2026-11-06-neutral-history-design.md`: 冒頭に、肯定語による再送（2往復になる経路）と否定語による取消を#29で廃止した旨の追記を入れた。本文は当時の記録として残す。
- `docs/application-flow.html`: 「聞き返した後」の欄を6行（こちら向き／向いていない／猫宛てと判定／それ以外と判定／判定に失敗／返答の内容）に置き換えた。「モデルによる宛先判定」の注記（埋め込み定義と表示の2か所）に、確認待ち中に向いていない返事は端末内モデルがあってもHaikuで判定することを加えた。宛先の図の参照へ `AddressClassificationRequest.swift` と#29の設計を加え（参照は全33件）、版の表記を「issue #29 対応版」、metaの入力digestを `1487a2562f7a3a18ff463166252d0db182a9bcf4b6c02da892850f1b47ab81e0` にした。

分岐図は、#28で使った生成器（Mermaid 12.3.0の描画済みSVGを含む）を作業用ディレクトリへ複製し、まずHEADのHTMLをbyte単位で再現できることを確かめてから入力を直した。6図のMermaid定義は変えていないので、描画済みSVGは再描画せずそのまま使った。旧HTML（`dcf5c789…`）との比較では、SVG 12個（図6・印刷アイコン6）、style 8個、操作用JavaScriptがすべて同一で、埋め込み定義の変更は宛先の図の `notes` と `refs` だけ。変更したHTMLの本文は、meta・版の表記・聞き返しの欄・注記・参照2件・footerに限られる。

オフライン（ネットワーク遮断）のChromeで、6図の切替、宛先の例の強調、詳細の図への移動、キーボード操作、拡大と全体表示、印刷時の6図表示、幅390pxで横にはみ出さないこと、直接リンクを確認し、JavaScriptエラー0・外部要求0だった。6図の大きさとノード数は#28の受入記録と一致した。同じ確認を旧HTMLにかけると、新しい「向いていない」の行が見つからず失敗する。聞き返しの欄は幅1440pxと390pxの画像を目視で確認した。証跡は `/private/tmp/cat-issue29-clarification-20261107/task5-diagram-verification.json`（SHA-256 `9dff733c1621bb060568c6c71ed854407dc9778781b0b3b4f6f6b244060f67ad`）と `flow/verify/`。生成器は作業用の複製で、リポジトリの依存にはしない。アプリのbuild・XCTest・実機はこの手順では実行していない。

レビュー前の文書候補のSHA-256（`docs/application-flow.html` と `docs/README.md` は後のC1修正・記録で更新）: `README.md` `8ce1bdd22f1b05f40a637d9dace8646fa7f7fd244d55f0326d33213f13b6f257`、`docs/README.md` `2e3f00399907839e5a4513810379713c1f61a792d9eafa8eab90374928b8ac5c`、#23の設計 `21016cdfdb86a6298ab91375705135e87f30bcec82551f047041462e96f89004`、`docs/application-flow.html` `e3cc131e529cd4f278c2c543270183d1baccd1e1bd828d04d72653ddbc97d87a`。

## 全体検証・独立レビュー（Task 5 Step 3・4）

全体検証はCodexが実行した。プロジェクトの再生成2回と生成器の契約試験はすべてexit 0で、全入力がbyte同一（`task5/generation-verification.json` SHA-256 `42fdab696d29375bfe5f311173dfdd334d3fc74be93aa5ff0ec7da2d033a7f9e`）。通常の全suiteは1,039件成功、失敗・unexpected・skipは0（約345秒）。明示的に除外したのは有料・実機向けの3クラス4メソッド（ClarificationHistoryModelTests 2、SupertonicIntegrationDeviceTests 1、RobotMotionIntegrationDeviceTests 1）だけで、モデルのopt-inは無く、モデル呼出しは0。実行前後で全source・文書は不変（`task5-full-verification.json` SHA-256 `42a50653bbf2f5066ad70ba84eb9068525927dd4e96ce5a06b1cfad245c59236`）。通常Debug版の署名build（bundle `com.kamby.CatRobot`、XCTest・モデル試験の引数なし）もexit 0で、`codesign --verify --deep --strict` は通常のOS信頼サービスへアクセスできる権限でexit 0だった（sandbox内で得た `CSSMERR_TP_NOT_TRUSTED` の結果も保存。証明書は変えていない）。記録は `task5-normal-build-verification.json`（`efe665a4f43ee89503ccc9694c94e04351458a654d78733d40765386244f4538`）。この時点でinstall・起動・利用者の確認はしていない。

独立レビューは、同じ凍結候補（full diff SHA-256 `12406dc9a487f28b799fcc41b0c320d257ca4936fbf695f68ba105f51577e903`）に対して両側で行い、各自の初回を保存してから交換した。

- Claude: 実際の `/simplify` をreport-only（修正を適用しない）で実行し、再利用・簡素化・効率・Altitudeの4観点をそれぞれ新しい読取専用のopusコンテキストで調べた。初回4件と整理報告は `task5/claude-review/` の `claude-simplify-first-{reuse d1fe36d7…, simplification 6054e647…, altitude 3fcb51dc…, efficiency e6c54297…, combined c506b553cd992845e13448fc8cbd6d7f316b7eed12c23208825f9d736f4eb161}.md`。整理後はImportant 1（C1、文書の誤り）、Minor 10、Nit 6。
- Codex: 新しい独立レビュアー1名が全差分と関連経路を読取専用で確認した（`task5/review/codex-independent-first.md` SHA-256 `43f1be16f2b665212a5bb2aa9bdc4fd38ac84782fbd2173b4cefff568de0df13`）。Critical・Importantは0、Minor 1（C1と同じ箇所）。判定は「修正つきでmerge可」。

受領評価は双方が `superpowers:receiving-code-review` で行った（Claude `task5/claude-review/claude-receiving-codex-first.md` `d7f1900218e67cbe10851db6882047cda339598ed8cfa54d8774148e2c58d775`、Codex `task5/review/codex-receiving-first.md` `95f9367162f6c6e2159485f4a367cb63f3f80823d3eb89e6ab7f6de9b1152ea2`）。初回の重要度の違い（C1はCodex Minor、Claude Important）は上書きしない。採否は次のとおりで、この候補へ入れる変更はC1だけ。

- **採用 C1:** 分岐図の「判定に失敗」の行が「確認待ちを解除し、聞き取りへ戻る」としていた。実際は `finishVoiceFailure` が確認待ちを解除して聞き取りを止め（`wantsListening = false`）、失敗の理由と「もう一度」などの再開方法を表示する。行を「確認待ちを解除して聞き取りを止め、理由と『もう一度』などの再開方法を表示する」に直した。
- **延期:** C2（文脈なしの `classify(String)` adapterが本番protocolに残る。計画で残すと決めた互換adapterで、本番の呼出しはすべて型つきの要求。文脈の欠落は ClarificationRoutingTests が検出する）、C3（`validatedText` の `previousSummary` 既定値と二重検証。noContentで前回要約を保つことは試験で固定済み）、C5・C14（指示文が失敗ごとに節を足した形、personaのパイプライン用語。書き換えには有料の再実行が要るので、次に指示を変えるときに一般化し、別の言い方も確認する）、C7〜C9・C11・C13・C15（runnerのdigest計算の重複、device testの描画・件数の重複、待機helperの重複、fakeの重複配列、質問文の直書き、手書きのprobe）。
- **不採用:** C4（確認待ちの判定を方針・VM・routerに分けているのは、寿命と文脈をVM、振り分けを方針、モデル選択をrouterが持つ責務分担のため）、C6（圧縮のたびに残す側の往復を参考として渡す費用。承認済みspecは常に全件を添え切り詰めないと決めており、費用は未計測のまま記録する）、C10（inventory試験の出力と保持は実行前の入力と費用の監査証跡）、C12（router・実際の組立て・VMの各試験は別の境界を守る）、C16（有料実行の途中で失敗しても自己完結した証跡を残す）、C17（版を固定したfixture表と機械inventoryの相互照合を保つ。factory引数の差は既存のRulingで説明済み）。

C1の修正は文書だけで、アプリの入力（source入力 `1487a256…`）は変わらないため、再build・全suiteの再実行はしていない。作業用の生成器の入力を直してHTMLを作り直し、閲覧確認に「判定に失敗」の行の断言を加えた。修正後のHTMLは同じオフライン確認がすべて通り（JavaScriptエラー0・外部要求0、参照33件、6図の寸法は前回と一致）、修正前の候補（`e3cc131e…`）は新しい断言で失敗する。修正前の候補との差はこの1行だけで、SVG・style・操作用JavaScript・埋め込み定義は同一。証跡は `task5-c1-diagram-verification.json`（SHA-256 `42a0a078d07bbdafccbeb890c6f435b3ca6442a2b5138c2f2ba17e3450c1d92b`）。前回の図の検証記録は上書きせず残す。修正後の `docs/application-flow.html` のSHA-256は `63c462ca2cd4b069ec995deeb3503c5bd03c53ad2ad902bc8f6541f40eb2c820`。

C1の修正後、Codex側の同じ独立レビュアーがその箇所だけを再確認し、解消済み・技術的に統合可と判断した（`task5/review/codex-c1-followup.md` SHA-256 `e033f3d3b37e0e9134cc8bdc8a60395b83795682c108022c7eb29ab64ab7e884`。初回報告は変えていない）。

## 通常版の実機受入と統合の承認（Task 5 Step 5・6）

Codexが、検証済みの入力（source入力 `1487a256…`、app実行ファイルSHA-256 `a924d92252c39651389c80bda34074a91c9a7ca0721362b5c28873032a97c1ba`）の通常Debug署名版をiPhone 16 Proへinstallし、通常起動した。XCTest・モデル試験のopt-in・appの引数と環境の上書きはない。最初の起動はCLIが空の `--environment-variables {}` 指定を拒否し、appの起動前にexit 64で止まった（証跡を保存）。この不要な指定を外して起動し直し、exit 0で起動した。記録は `task5-normal-device-verification.json`（SHA-256 `036ad15d33df54e3d300f117bb1c8b0a793a7109a7ddd02d45d7b5adf2be9e8f`）。install成功とプロセスIDは、人による受入の代わりにしない。

利用者には、こちらを向いた場合と向いていない場合のそれぞれで、聞き返しの後の肯定・否定・猫への新しい話題を試し、向いていない場合は周りの人への発話をはさんだ後の返事も試すよう依頼した。どれも会話継続の30秒の外で聞き返しを起こし、15秒以内に返事する。利用者は2026-11-07 11:38 UTCごろ、Claudeとの会話で「OKなのでmainにスカッシュマージしてどっちもpushしていいよ」と回答した。これを、通常版の実機受入OK、#29のmainへのsquash merge、未公開の#28 commit `1265a1070d8ad9691a8f7123fa18762a759b2e56` と#29のsquash commitの両方をorigin/mainへnon-forceでpushすることの承認として扱う。個々の発話と猫の返答の記録は受け取っていないので、ここには書かない。受入と承認の記録は `task5-human-acceptance-and-authorization.json`（SHA-256 `17b72558b51868801f72eb033b5680f8580e0b3b0d4397a6f5153be03ed39d2e`）。

この記録を書いた時点では、Task 5の文書のcommit、mainへのsquash、push、remote・issueの照合はまだ実行していない。これらはCodexが、squash後のtreeと検証済み入力の一致、最終の通常署名版のbuild・install・起動を確かめてから行う。結果はgitの履歴とremoteで確かめる。
