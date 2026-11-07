# C1 / C2 限定修正確認

確認対象: HEAD `07363aaae506ebe153b7580c7efbae7610e5ef46`に対するREADME.md、docs/README.md、docs/application-flow.htmlの文書限定変更。

**判定: C1 / C2とも、合意した対応で解消。**

- **C1:** `docs/application-flow.html:45`の「別の発話」が「有効でこちら向きの顔が1人以上なら返答」に修正された。旧「顔が1人・こちら向き」は残っていない。確認待ちの肯定・否定優先と、顔向きなしの場合の再判定説明は維持されている。
- **C2:** READMEリンクとdocs indexは2026-11-07時点の静的スナップショットと明示し、indexでは現役仕様の一覧から分離されている。HTMLの版表示・導入文・footerも同じ時点を示す。footerは非自動更新に加え、参照先mainが図の時点から変わりうると説明する。31件のリンクの行番号・表示行番号が除去され、embedded refsも同じ31ファイルのpath stringになった。合意したbounded案を満たす。

## 限定確認の根拠

`driver-doc-diff-verification.json`、`handoff3/tracked-docs.diff`、`handoff3/structure-compare.json`を参照し、実際のworktree文書を候補HEADの内容と読み取り比較した。

- 実HTML SHA256を独立計算: `dcf5c78969b05a780302817356806c46d5b05fc4861e81492decf33012874ead`。提示された最終hashと一致。
- 6図＋6印刷iconのSVG計12件、styleブロック8件、操作JavaScriptは候補HEADと文字列単位で一致。
- embedded definitionsのrefs以外は不変。refsのファイルパスは元の31件と一致。
- 31件のsource linkの表示はファイルパスと一致し、mainの`#L`参照は0件。
- tracked差分は指定の3文書のみ。app入力 `4e99d6b…`不変はrootのreceiptによる報告として受領し、今回はapp入力全体の再計算をしていない。

初回レポートとmutual受領レポートは変更していない。source編集、別agent、全ブランチ再レビュー、build/test/device操作は行っていない。

## 残る範囲

private builderを永続化しないことによる将来の再生成コストは、mutual受領で合意したsnapshotの制約として残る。今回そのbuilderの再現性を認定するものではない。

Chromeでの変更後表示確認はDriverの別receipt、人による2人QAは別の実機受入gateである。私はそれらを実行・確認しておらず、この文書修正確認をもって合格とは扱わない。C1/C2の解消に伴うproduction/test変更やアプリの再buildは不要。
