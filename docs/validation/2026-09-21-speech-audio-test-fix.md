# SpeechAudioConverterTestsの既存9件の失敗を修正

Gemma版をmain `41fd888` へ反映した後、`fix/speech-audio-converter-tests` で調査した。変更はテストと本記録のみで、音声変換の製品コードは変更していない。

## 原因と修正

iPhone 16 Pro / iOS 27.2（24B5084k）/ Xcode 27.0（27A266a）で、対象12件中9件のクラッシュを修正前に再現した。すべてSpeechフレームワークが以下の条件違反で停止していた。

```text
Failed precondition: Audio sample data must be 16-bit signed integers
```

スタックの先頭は `AnalyzerInput.data(from:)` → `AnalyzerInput.init(buffer:bufferStartTime:)` → `SpeechAudioConverter.convert(_:at:)`。XCTestの失敗概要は呼び出し元の `XCTFailableInvocation` を示していたが、原因はテストで指定したFloat32の認識用出力形式だった。

製品の `AppleSpeechRecognizer` は `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:considering:)` で対応形式を取得しており、テストの固定形式とは異なる。[AppleのSpeechAnalyzerドキュメント](https://developer.apple.com/documentation/speech/speechanalyzer)も、バッファ入力は対応する形式へ変換してから `AnalyzerInput` に渡す手順を示している。

- 認識側のテスト形式をInt16へ修正。マイク相当の入力はFloat32のまま維持し、実際のFloat32・48 kHz→Int16・16 kHz変換を引き続き検証する。
- Int16テストバッファにも非ゼロの波形を設定する。
- 形式一致時の検証は、フレーム数・形式・全音声サンプル・元の時刻の保持を確認する。変換backendが生成されないことも確認する。
- `AnalyzerInput.buffer` のオブジェクト同一性への依存を除く。Int16化後に残った1件はこの比較の失敗であり、現在のAPIが返す新しいバッファの音声内容は同一だった。
- リサンプリング出力はInt16で非ゼロの音声を含むことも確認する。既存の時刻連続性、flush、入力を二重供給しないこと、エラー変換の検証は維持する。

## 検証結果

| 実行 | 結果 |
| --- | --- |
| 修正前・音声変換テストのみ | 12件中3成功、9クラッシュ |
| Int16形式への修正後 | 12件中11成功、バッファ同一性の比較1失敗 |
| 最終修正後・通常テスト全体 | 249件中247成功、0失敗、2スキップ |
| 最終修正後・音声変換テスト | 12件すべて成功（上記の全体実行に含む） |
| プロジェクト生成の契約チェック | 成功、生成物の差分なし |
| 独立レビュー | Critical / Importantの残件なし |

2件のスキップは通常schemeでは無効になるGemma実機専用テスト。今回は製品コードを変更しておらず、Gemma推論テストの再実行は行っていない。iOS 26での再実行も未実施。

[全体テスト結果](speech-audio-fix-2026-09-21/full-test-summary.json)。一時的なxcresultとログは `/private/tmp/cat-speech-fix/` に保存した。
