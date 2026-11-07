# Issue #28 — root receiving-code-review

対象は基点 b59f0b9dc93d97ee79204e824961bafdd390cb19、独立初回候補 07363aaae506ebe153b7580c7efbae7610e5ef46。初回6報告は first-review-sha256.json のhashで保存し、独立報告後に初めて交換した。rootは receiving-code-review に従い、指摘を実装・受諾済み要件・試験証拠と照合した。この文書は受領判断であり、未実施の修正や実機試験を完了扱いにしない。

## 採用

- **C1 / native Minor:** 聞き返し後の「別の発話」行に旧「顔が1人」が1箇所残っている。実際の AddresseePolicy は同じ camera result を使うため、正しく「有効でこちら向きの顔が1人以上」へ直す。図と task-private builder の両方を対象にし、実DOMの確認を追加する。アプリのrouting不具合ではないが、今回納品する分岐図の整合に必要。
- **C2:** repoのみからHTMLを再生成できないこと、main行番号リンクがずれること、現役仕様一覧に日付図が混在することは実在する。レビュー自身が許容する代替案のうち、2026-11-07時点の静的snapshotと明示する案を採用する。README/index/HTMLをそろえ、mainリンクのhref・表示行番号・embedded JSON refsの行番号を外す。mainは現在コードを探す案内、図は日付時点の説明であると区別する。SVGを含む単体HTMLは保存され、オフライン表示できる。新たなgenerator frameworkは受諾済みscopeに不要。private生成元未永続化・改版時の保守コストは制約として記録し、repoから再生成できるとは約束しない。
- **C12:** 計画・記録のpendingは、各結果が実際に得られた時点で更新する。previewの署名版install/launchは実施済みだが、実際の2人条件は利用者の回答待ち。main/push/issue閉鎖の結果を先に書かない。

## 延期・不採用の理由

- **C3 SVG圧縮:** サイズと重複はあるが、568KBのオフライン図に閲覧失敗・性能問題の実測はない。提案の削減率・描画同一性は未検証。今回coordinates/CSS/markersを変える必要はない。
- **C4 文書集約:** FR、製品説明、dated spec、dated検証記録は目的が異なる。古い検証履歴を書き換えたり全面的な文書再構成を行わない。C2で図の時間的位置付けを明示する。
- **C5/C8 テスト削減:** 実camera→実VMで複数の具体的な危険例を確認する計画に沿う。毎回独立したVMは30秒継続窓による誤った成功を防ぐ。負荷の実害はなく、複数顔のfreshness・最新否定観測による撤回も別の契約。削減しない。case labelは任意の診断改善として延期。
- **C6 UserDefaults:** UUID suiteのcleanup欠如は事実。既存由来のMinorで、今回2 domain/run増える。UUID隔離で本番設定・テスト間汚染はない。実際のplist容量は測っていない。今回の文書修正に混ぜず、後続でケースを残してdefer除去を行える。固定入力維持を優先して延期する。
- **C7 fixture整理:** 数値literal・命名は挙動の誤りを示さない。境界値を読める現状を維持する。
- **C9 selector分離:** 既存selectorの再利用が受諾済み構成。別の存在判定を追加すると重複する。将来tracking専用条件を導入する際に今回のattention回帰テストを守る。
- **C10 JS/CSS整理:** jankや操作不良は確認していない。読みやすさを優先する初期拡大率と全体fitは目的が異なる。rAF化・ボタン統合等は延期する。
- **C11 30秒説明:** 追加文は複数人にも従来窓が適用することの説明。削除必須とはしない。今回の対象外。

## 証拠と次の限定確認

native初回は Critical 0 / Important 0 / Minor 1。Claude初回は重複整理後 Important 2 / Minor 5 / Nit 5 で、Importantは上記C1/C2の文書問題。重要度の相違を隠さず両初回と相互受領を保存する。双方ともproduction変更を要求していない。話者と顔の対応付けは利用者が求めておらず、#27/#29・音声・履歴はscope外。

Claudeは相互受領で、初回C1の「validationが全文言整合を主張」という表現を訂正した。旧validationの対象は描画済み条件と列挙したREADME等で、mini-rowの確認済みとは書いていない。したがって旧証拠を偽ったと扱わず、今回追加するmini-row確認と変更後artifact証拠を別に記録する。旧初回報告・旧browser/hash逆変換証拠はそのまま保存する。

app/test/project/native/scripts入力は4e99d6b42c5cf3684b7e1d02c9e74ee51f6504aa95490d88f9033973a4f8494f、full実測1004 PASS / 0 fail / 0 skip。native receiptは2ee2883ca23745dc8729e88a780264d32a270c3b1d3faa4de42e657fe555d0ca。文書限定修正では再び1004件を走らせず、入力不変・変更箇所のDOM/リンク・最終HTML hash・SVG/CSS/JS不変を確認する。

HANDOFF3はrootからactual Claudeへ文書限定Driverを提示済み。ACK後、rootはNavigatorとしてlive diffを読み、Chrome確認前にGOを送る。実際のhandoff/結果は別記録へ残す。最終統合は人の2人確認と相互受領・修正確認がそろってから行う。

相互受領が双方保存された後、Claudeが18:28:53 UTCにHANDOFF3 ACK。C2の4条件とMinor延期に相違なし。Claudeが図/リンク/private builderを編集、rootは全tracked source編集を停止してNavigatorとなった。

Claudeの編集後、rootはlive diffと独立verify-docfix.pyを照合し、HTML dcf5c789…、図6＋印刷icon6のSVG全12、CSS8、操作JS不変、31 refsのパス維持、app入力4e99不変を確認して18:33:16 UTCにGOした。Claudeが旧版/probeの意図した失敗と新版全browser検査成功を記録し、18:34:47 UTCにRELEASE。rootはreceiptとdesktop/mobile実画像を読み、同じnative reviewerのnative-review-resolution.mdでもC1/C2解消が確認された。初回・相互受領報告は不変。人の2人QAとmain統合は引き続き未実施である。
