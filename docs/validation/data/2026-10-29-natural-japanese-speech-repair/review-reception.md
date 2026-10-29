# Review reception and executor decisions

## Pair consultation via agmsg

Existing Claude claude_sleep_zzz_1028 read spec, actual code and tests, then supplied claude-consult.md and agmsg findings. Root owns all edits. A broad filesystem search in the first attempt was interrupted and replaced with the known model asset path; no private history was supplied to Claude.

Accepted: numeric-only runs retain notation (+ verbalized); digits inside complete Latin terms can be read with that term; original ASCII/fullwidth whitelist precedes width-only folding; maximal non-Japanese clusters protect Greek/accents/marks; marks attach only to base; ーｰﾞﾟ excluded; known-stem Unicode test cases; Wi-Fi actual baseline pronunciation preserved by internal connectors; obsolete full-Japanese separator/grouped-number code retired; output-limit assertion uses real + expansion.

Supertonic glyph limitation: root clarifies that negative ids are rejected by existing engine validation, not fed to the model. Keep this boundary, document arbitrary-kanji limitation; no model replacement. Future latency-feature rebase requires fresh candidate-budget/device validation because normalized16characters changes meaning. No latency code merged into this main repair.

## Fresh whole-fix review

Critical0, Important1, Minor1. Root read complete report and checked actual scanner.

Important: U2010/U2011/U2019 internal connectors can split unknown complete words and partially rewrite a known stem. Adopted; root stops the already-started pre-fix full suite rather than recording it as acceptance. Add literal failing regression before widening only maximal scanner connectors; conversion whitelist remains unchanged, wrappers and Japanese em-dash boundaries retained. RED/GREEN and rebuilt receipt/full suite pending at this entry.

Minor (deferred): no separate near-limit dictionary-word expansion case, only plus-symbol expansion cases. Shared Swift output guard is after all native normalization and current tests exercise actual expansion to2000/2001 and prevent synthesis on rejection; dictionary word behavior5G/25cm also independently covered. No current guard bug found. Ruling: keep symbol-expansion coverage and document the narrower test scope instead of adding a second guard-equivalent case. Cost: dictionary-only expansion near the threshold is not directly paired with the no-synthesis assertion. Plan wording updated to reflect this decision, not silently claimed as exercised.

## Exclusions to resolve before completion

- Perceived naturalness: user chose C in one fixed comparison; current native result equals that selected input. Further device/acoustic quality cannot be inferred from string/PCM-validity tests.
- Arbitrary model glyphs: retain existing validation failure, document unsupported glyphs; do not claim all preserved Japanese can synthesize.
- Vendor emoji removal/NFKD/symbol changes: unchanged, frontend preservation ends at its API boundary; not a claim of lossless vendor preprocessing.
- Unmerged latency16character gate: excluded from main, must be revalidated if later integrated.
- Additional URL/email/markup conventions: preserve existing protection grammar; no broad parser expansion or guarantee beyond existing cases.

Main repair verification and final material-findings disposition will be appended after actual results. No repeat fresh review is needed for the single connector fix; its new failed/passed test and final whole suite are the gate.

## Final acceptance and dispositions

Important connector finding: RED typographic_internal_connectors_do_not_split_unknown_terms observed known-prefix rewrite. Scanner-only connector widening then exposed existing+curlyquote regression; separating starts from continuations fixed it without changing eligibility. Finalnative22PASS, native3architecture rebuild/receiptPASS, fullSwift848total846PASS/2physicalskips/0FAIL. Pre-fix full run intentionally interrupted, its incomplete xcresult is excluded. No second fresh review dispatched.

Claude final agmsg review found no new blocking logic issue. Its possible dotted-term regression was probed old/new: Mr.Children→エムアール.チルドレン/ミスターチルドレン; Dr.STONE→ドクター.STONE/Dr.STONE; No.1→ノー.イチ/ナンバーイチ; Lv.5→エルブイ.ゴ/Lv.5; YouTube’s unchanged. Root retains whole-term unknown preservation instead of optional partial fallback, consistent with the no-partial-rewrite contract. Cost: some unknown dotted compounds remain uncorrected; pronunciation is not guaranteed. This optional fallback is a deferred minor, not an unresolved blocker.

Currentnative output matches the listener-selected C input. Signed physical pronunciation stage on f2367d5 passed1test/0skip/0fail,8fixedpairs16WAV and production speaker9successful records. Actual accepted speaker input is ｢プラスボタン｣でユーチューブを開くよ。 (Japanese surface intact). Foregroundstate0. Normal app restored without SUPERenv, process2273confirmed. Final262sourcefiles match fullsuite and physical.

All fresh-review exclusions resolved as scope/verification rulings: perceived naturalness is one listener-selected fixed example only, not universal/acoustic acceptance; unsupported glyphs retain current engine failure and are documented; unchanged vendor preprocessing is outside frontend preservation; unmerged latency budget must be retested before any later integration; protected URL/email/backtick grammar retained without expansion. Cost: arbitrary rare glyphs/newmarkup/allvoices/allphrases remain unverified or unsupported.

Ruling: reuse previously passed project/generator contract because3relevantsource/projectfiles hash-identical, no file membership change. Python17PASS. No repeat fullsuite for subsequent documentation-only changes. Private history and private comparison audio remain only in authorized local temporary storage and are excluded from Git.
