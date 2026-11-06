# Smart Turn: simplify・独立レビュー・相互受け止め

## 対象と手順

対象は割り込み前の `6ddf6ba4b8e217c70d2c9cfff4f50773a1ee232c` から、既存mainの `f206a1e72afdbce96aee451b6887bf17c70feb9b` までのSmart Turn実装と接続境界。issue #25のエフォート設定は別ブランチに保持し、Smart Turnの修正をmainへ反映した後にスカッシュ統合する。

Claudeは実際に `/simplify` を実行し、Reuse・Simplification・Efficiency・Altitudeの4担当を並行実行した。Codexは `superpowers:requesting-code-review` に従う独立サブエージェントへ同じ対象を渡した。初回報告を独立に保存してから交換し、双方と親実装者が `superpowers:receiving-code-review` で根拠と採否を検証した。Codex側の処理再開時は保存済み報告を引き継ぎ、初回レビューを繰り返していない。

独立コードレビューはCritical 0・Important 2・Minor 1。simplifyはImportant 5・Minor 11・Nit 2と統合境界1件で、主に共通化・効率改善の案だった。未測定の性能案を自動的に統合阻害とせず、再現した正しさの問題を優先した。

最終B差分を双方が再確認し、Critical・Importantは0件。追加Minorは、否定待ちの短縮（worker完了の正のシームがないため維持）、通常入力テストの送信backpressure（遅いCIでのqueueあふれリスクとして保留）、音声感度の検証範囲（下記へ明記）。テストの整頓のために本番APIを増やしていない。

## 修正

| ID | 再現と反映 |
|---|---|
| SR-1 | 最後の無音フレームのVAD中にキャンセル・キューあふれが起きると、復帰後に退役済みcaptureが新しい推論を始めた。VAD処理後・推論要求時・detached scorer入口で停止を確認する。実行中の同期処理はjoinしない。次captureだけが共有scorerを呼ぶことも回帰テストで確認。 |
| SR-2 | 凍結した音声frontierを越える新しい端数に発話が残っていても、古い結果を新しいrevisionで通知できた。frontierの簿記を削除し、端数を非コミットのVADプローブで評価する。通知前後で同じraw revision・drain・停止・300 ms期限を検証する。 |
| SR-3 | モデル初期化中のキャンセル後にもwarmup・VAD生成を開始していた。同期準備段階の間にキャンセル確認を追加。呼び出し側は待たずに戻り、旧ownerの終了まではbusyを維持し、終了後の再準備も検証。 |

SR-2の最初の修正案「変換済み端数が空になるまで待つ」は採らなかった。Claudeが実際のtapサイズ（48 kHz、1024 frames）では端数が周期的に残り続けることを測定し、親実装者も早期終了が発火しない回帰テストを確認した。人工的な1サンプル刻みで整列させる成功例だけでは、通常入力での可用性を証明できなかったため。

最終形は、端数の私有コピーだけを512サンプルまでゼロ詰めして既存VADで仮評価する。返されたrecurrent stateとcontextをコミットせず、本来のPCM・発話フレーム数・無音フレーム数を進めない。[固定版Sileroの公式wrapper](https://raw.githubusercontent.com/snakers4/silero-vad/066409f3d9db45a30d21dfcbf9147826ffdd7052/src/silero_vad/utils_vad.py)も末尾のpartial frameをゼロ詰めしている。発話再開のしきい値は既存の0.5を維持し、調整値を追加していない。

## simplifyの採否

| ID | 採否・理由 |
|---|---|
| C1・C9 | フェンス統合・再確認の削除は見送り。別スレッドのraw admission/cancelがあり、対応する呼び出しだけでは同一の原子的状態と証明できない。Claudeも最終再確認を外せるという含意を撤回した。 |
| C2・C10 | 設定型・状態表現の広い整理は保留。通常構成の0.5/7は既に固定で、正しさの修正に5型横断のAPI変更は必要ない。 |
| C3 | 採用。300 ms、128000、512の本番参照を既存契約定数へ集約。独立したテスト期待値は保持。 |
| C4 | 変換層の共通化は保留。ASR側のSpeech.AnalyzerInput・時刻管理との結合を増やすため、等価性を別に検証する必要がある。 |
| C5・C6・C8・C14 | ORTセッション共有、ring buffer、準備並列化、バッファ再利用は保留。端末上の効果が未測定で、capture状態の分離やキャンセル・エラー順序を変え得る。 |
| C7 | 部分採用。未読の観測時刻・推論所要時間・変換処理を削除。期限テスト用の時計と確率・受理結果の観測は保持。 |
| C11・C16 | 防御的入力検証・時計注入の削除は不採用。独立した境界契約を守り、本番の時計は既にsystemUptimeで一致する。 |
| C12 | 部分採用。必須準備をOptionalと呼ぶテスト名・文言を訂正。通常compositionは既にSmart Turnを明示的に渡すため、recognizerの別注入API変更は保留。 |
| C13 | 資産スクリプト・生成器・manifest同梱の整理は保留。固定ハッシュとprovenanceの境界を今回の不具合修正に混ぜない。 |
| C15 | 部分採用。触るテストは正の到達点・ブロッカーの確実な解放を使い、必要な有界の否定確認を保持。待ち時間だけを短くする変更はしない。 |
| C17 | 部分採用。常にtrueだった引数、不要になったfrontier・強制unwrapを削除。資源解放時のidempotentなcancelは保持。 |
| C18 | 部分採用。READMEを現行動作と本記録への参照に整理。履歴文書・ログ形式は保持。 |
| B-1 | 既存mainの返答予算4096 tokensを保持。Smart Turnのポリシーとは分け、issue #25統合後のsettings/session/service接続で検証する。 |

## 検証

| 検証 | 結果 |
|---|---|
| SR-1 RED→GREEN | 回帰1件の4 assertion失敗→capture 18件成功 |
| SR-3 RED→GREEN | 回帰1件の5 assertion失敗→service 4件成功 |
| SR-2当初の再現 | 不規則な端数1/127/256/511で8 assertion失敗。strict-only案は後続の通常入力テストで不採用 |
| SR-2最終形 RED→GREEN | 通常48k/1024のmono/stereoと端数評価の2件で7 assertion失敗→全コア62件成功 |
| 実Sileroの追加 RED→GREEN | 状態保持・無音端数の8 assertion失敗→model 5件成功 |
| 最終Mac分離環境 | 実production State/Signal/Capture/Service/Modelsと既存・追加XCTest 62件、失敗0 |
| 実Sileroの無音端数 | 1/127/256/511サンプルで各0.006883949、既存onset 0.5未満。反復probeと次フレームのcontrol比較は誤差0.000001内 |
| Python全体 | 34件成功。Pythonの変更なし |
| 生成プロジェクト | xcodeproj 1.27.0、deterministic contract成功、生成差分なし |
| iOS関連 | 新規のiPhone 18 Pro / iOS 27.0 Simulator、関連151件成功、失敗0。ライブcompositionを抑制する既存のテストモードで実行 |
| iOS全体 | 同じ新規Simulatorで968件成功、失敗0。専用の音声・ロボット実機試験2件は明示除外。全体の実行結果を保存 |
| 通常実機 | Smart Turn単独修正では未実行。端末はpairedだがunavailableで、再接続後もMacのUSB一覧に見えない。通常アプリはissue #25統合後に別途検証 |

Macの分離環境は実productionを無変更でコンパイルし、実Core MLモデルと固定版ONNX Runtime/Sileroを使う。テスト側だけ、同一資産へのパスと既存のtest clockの抽出を適応した。認識・VM・画面全体の実行確認の代わりにはしない。

回帰テストは、通常の1024-frame入力、発話を含む端数、probe中のraw admission/cancel、元の期限、0.49/0.5境界、例外・非有限・範囲外の出力、エラー1回通知を含む。実Sileroではprobeの反復と次の正規フレームをcontrolと比較し、context/recurrent stateの非コミットを検証した。

## 限界と証跡

VADの32 msフレームとAVAudioConverterの内部保持による時間分解能は残る。変換済み端数の評価を、全source sampleのゼロ遅延検出と同一視しない。測定した保持量が小さいことから「あらゆるVAD結果へ影響しない」とは主張しない。合成入力・無音モデル試験から、人の日本語発話・雑音下の精度や実音響遅延は推定していない。

無音端数の4サイズは、ゼロ詰め後には同じ全ゼロ入力となる。非ゼロの合成波形で確認したのは状態・contextの非コミットであり、部分的な人の発話を捉える感度は未測定。発話再開の偽陰性には音声を切る可能性があり、これをfail-safeと呼ばない。

ASRの元の1.2秒無音終了と最大発話時間、16発話/7無音フレーム、p>0.5、300 ms、最新pause 1件・有界queue、文字/数字ゲート、stop-finalの1回drain、返答中に録音しない構成を維持する。3秒・100 msの後付け処理は復活させていない。

主要な[結果と入力ハッシュ](data/2026-11-06-smart-turn-cross-review/results.json)、[通常入力サイズの整列測定](data/2026-11-06-smart-turn-cross-review/alignment-probe.log)を保存した。全初回報告・相互受け止め・修正前後ログ・固定差分は `/tmp/cat-smart-turn-cross-review-20261106/`。`codex-reception-addendum.md` がstrict-only案の受理を取り消した記録。最終B差分のSHA-256は `d51f44954b94be39ca8a2d29da7ea03d05a0ead24284fc0f6b689300d321c7e4`。実装の採否は上記へ残し、任意の改善案すべてを実装済みとはしていない。

旧構成と比較測定の参照は `experiment/smart-turn-audio-only` の `0249e34`。入力経路が異なる旧測定を、この構成の精度・速度の保証に使わない。
