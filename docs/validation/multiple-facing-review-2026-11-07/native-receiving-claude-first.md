# Native receiving — Claude /simplify 初回4観点

対象: `07363aaae506ebe153b7580c7efbae7610e5ef46`、app入力 `4e99d6b42c5cf3684b7e1d02c9e74ee51f6504aa95490d88f9033973a4f8494f`。

`superpowers:receiving-code-review`を読み、reuse / simplification / efficiency / altitude の4初回報告とcombinedを今回初めて読んだ。独立初回レポートは変更していない。今回は指摘受領のための限定照合であり、全ブランチの再レビュー、source編集、build/test/device実行、新規agent起動は行っていない。

## 判定

C1の文言修正を採用。C2はroot提案の「2026-11-07時点のsnapshotと明示し、mutable mainの行番号を外す」対応を採用する。generatorの新設・永続化は今回の完了条件にしない。Critical / Importantのproduction不具合は確認していない。

| Combined / 元指摘 | 受領判定・重要度 | 根拠と対応 |
|---|---|---|
| C1 / R1, S1 | 採用、Minor。native初回Minorと同一 | `docs/application-flow.html:45`の「別の発話→顔が1人・こちら向き」は古い条件。`AddresseePolicy.swift:50`は同じcamera結果を使うため、複数人でも有効な顔が1人以上なら受理する。誤説明は実在するがrouting自体は正しいのでImportantにはしない。HTMLとprivate builder双方の文言を直す案は妥当。関連する検証記録を追記し、変更後artifactのhashを記録する。過去に何を確認したかの記録は事後的に書き換えて合格扱いにしない。 |
| C2 / A3, S5, S6, E1一部 | 一部採用、Minorの保守・位置付け問題。snapshot案で解決可能 | JSONだけからページを再生成できず、行番号付きmainリンクは将来ずれる点は確認できる。しかし納品済み単体HTMLの復元という今回の要求に、repo内再生成frameworkまでは含まれない。既存footerも静的・非自動更新・参照はmainと説明している。README/indexからも日付付きsnapshotと分かるようにし、行番号を除去する案は十分。詳細と残存制約は下記。 |
| C3 / E1, E2 | 延期、任意のMinor最適化 | 大きなSVG・繰返しCSS/markerは実在する。外部依存なしの6図という要件は満たしており、容量起因の失敗は示されていない。35%/15%削減量や描画同一性はレビュー提案値で、私が計測・render比較した結果ではない。丸め・marker削除・CSS共有は再描画検証が必要となる。今回の一文修正のために導入しない。 |
| C4 / R2, A4, S4 | 構造変更は延期、Minor以下 | 同じ要件の複数記載はあるが、READMEの製品説明、FR-CONV-2、dated spec、検証記録、図は役割が異なる。検証記録は結果時点の説明であり、将来の全変更で同期すべきliving contractではない。#28 specは既存selector・維持契約を明記し、旧#22にはsupersede noteがある。C1だけを直すための全面DRY化は不要。C2で図の時間的位置付けを明示すれば、常に全資料を同時更新するという誤解も減る。 |
| C5 / A2, S2, R4, E5 | テスト削減案は不採用。case labelは任意のNitとして延期 | 実camera→実VMで複数の具体的危険例を確認することはplanのReview Focusに沿う。独立したConversationHarnessは継続窓によるfalse positiveを防ぐ。直接`h.isFacing`のassertionがなくても、実camera closure、分類器0回、全文replyという観測で経路を検証できる。重複による実害は示されておらず、報告自身もmilliseconds程度とする。失敗時のfixture名は改善余地だが必須ではない。 |
| C6 / E4, S3, A2 | defaults cleanupの事実は採用、Minor。今回の修正は延期可能。ケース削減は不採用 | `FacingAddressingTests.swift:292–294`はUUID suiteを作り、`RobotPreferences.swift:44`のdidSetで永続値を書く。cleanupがないため孤立domainが増えるという指摘は正しい。`FaceTrackingPreferencesTests.swift:9`のdeferが既存の手本。ただし本番設定には影響せず、UUID隔離のためテスト間汚染もなく、今回追加分は2 domain/run。実際のplist数やサイズは私が測っていない。3ケース/単一caller helper自体は欠陥ではない。固定app/test入力を維持する今回のdoc-only修正でcleanupを延期する判断は妥当。後で直すならケースを残してsuite名を保持しdeferで除去するだけでよい。 |
| C7 / R3, S7 | 延期、Nit | 小さなliteralの重複や命名は実在するが、具体的な境界値がテストで読める利点もある。fixture helperの引数拡張・定数化は意図したbehaviorの証明を強めず、誤りも確認していない。 |
| C8 / S8, A2 | 削除案は不採用 | 全員横向きの最新観測による撤回と、一般的な不適格観測の拒否は異なる観測目的。複数顔の0.399/0.400秒境界も明示されたreview focus。旧count guardを戻すと複数顔のfresh positiveが失敗するので、「新しいbranchがない」ことを削除理由にしない。 |
| C9 / A1, E6 | 変更不採用、将来懸念として記録 | selector再利用は受諾済み構成そのもの。存在判定専用predicateを今導入する必要はない。将来trackingだけの条件が加わるなら、その変更時にattention契約と今回の回帰テストを考慮する。<1µsという値は私が計測した値ではないが、今回性能問題を示す証拠はない。 |
| C10 / E3, S10 | 延期、Nit | JSのresize/fit計算・querySelector重複は実在する。初期表示の読みやすさを優先するfloorと明示的fitの違いは直ちに欠陥ではない。jankの実測はなく、ブラウザreceiptは操作成功を記録。単一printボタン化やCSS整理、rAF化は今回の顔条件とは別の改善。 |
| C11 / S9 | 任意、Nit。削除を必須にしない | 前文は一般的な窓の再作成、後文は今回の複数人にも適用する点を明示している。完全な同義重複ではなく利用者に役立つ強調になりうる。ASCII spaceを取る程度はdoc-only修正と同時でもよいが、behavior説明を減らす必要はない。 |
| C12 / S11 | 状態更新として採用、コードfindingではない | 残作業がある時点で未完了と書くことは正確。未実施の結果を先に完了扱いにしない。統合の各gateが実際に完了した時点で計画・検証記録を更新する。rootから通常署名preview install/launch済みPID11428との連絡を受けたが、私は実機を確認していない。人の2人確認は引き続きpending。 |

## C2 bounded案の十分性と残存リスク

採用可能な最小条件は次のとおり。

1. READMEのリンクとdocs indexのタイトルまたは説明に「2026-11-07時点の静的スナップショット」を明示する。現在仕様の完全な自動追従図であるかのような表現を避ける。HTML自身の既存の日付・issue #28・非自動更新説明は維持し、必要なら表紙の「現在」をsnapshot時点に合わせる。
2. mainへのリンクの`#L<number>`と表示上の`:number`を外し、ファイルへの参照とする。footerの「参照リンクはmainの最新コード」は維持する。これによりリンク先はsnapshotを厳密に証明するものではなく、現在の実装を探すための案内だと分かる。より厳密な歴史的参照が必要になればcommit固定を別途選べるが、今回必須ではない。
3. embedded DSLは図の編集補助・保存された定義として残せる。「repoだけから同じHTMLが再生成できる」「これがページ全体の唯一の生成元」とは説明しない。private builderを今回永続化しない選択は、検証記録に制約として残す。
4. C1修正とsnapshot/リンク変更後のHTML SHAと検証対象を対応付ける。SVG/CSS/interaction script不変なら、文字・リンクと構造の限定確認で十分であり、アプリの再build/testを要求しない。旧browser確認を変更後HTMLへ無条件に転記しない。

この対応で「living docなのに自動追従せず、mainの行番号が古くなる」という現在の読み手の誤解は解消できる。private generatorが失われた場合の再生成コスト、SVGの大きな差分、HTMLとembedded JSONの二重表現は残る。これは将来そのsnapshotを改版するときの保守コストであり、現状の閲覧不能・runtime不具合ではない。次の改版でgeneratorをrepo管理するか、新snapshotとして作るかを選べばよく、今回新frameworkを作る根拠にはしない。

A3の「ブラウザ確認後に編集したためgeneratorが再現しない」という主張は分けて扱う。7つのanchor調整とhash逆変換は既存証拠にあり、これはbrowser検証範囲の管理の話である。そこから現在のprivate builderの再現可否までは断定できない。今回私はprivate builderを実行・照合しておらず、その再現性を認定しない。

## 結論

C1修正、C2の明示的snapshot化・行番号除去というdoc-only対応で進めてよい。コード・テストの再設計やSVG最適化は不要。C6のcleanupは事実として受け入れたうえで、低影響の既存テスト環境衛生として延期可能。残る実機2人確認と統合gateをこの受領評価で代替しない。
