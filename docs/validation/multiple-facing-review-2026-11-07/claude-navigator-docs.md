# claude_issue25 — Navigator review of Driver docs/diagram (read-only, ~18:10Z). Code diff still c0adc6f4… (frozen, unchanged).
OK — README.md:10: removes "1人だけ" and "複数人" from the fallback list; states 1人以上 even with several people, no face–speaker matching (may answer another person), facing acceptance starts/renews the continuation window, fallbacks now read "顔による省略を使いません" (correct: the 30 s rule may still accept). Links to the flow and #28 spec.
OK — requirements FR-CONV-2 updated to #22+#28, 1人以上 incl. multi-person frames, no face–speaker matching.
OK — #22 spec gets only a dated supersede note; #22 validation/review records untouched (dated, acceptable).
OK — application-flow.html: 2 scripts only (definitions JSON + 4.7 KB handwritten JS) with no fetch/XHR/eval/Function/storage/cookie/WebSocket/beacon/window.open/innerHTML; external URLs are only github blob/main links and the issue; no /Users, /tmp, UDID or simulator IDs; source-input meta = 4e99d6b4…. "address" diagram order matches AddresseePolicy.route exactly (filler → pending 15 s → facing 1人以上 → engagement 30 s → classify); notes state camera permission + fresh frame, no eye gaze, window arm/renew with multiple people; "face" notes state independence from neck/BLE and that tracking chooses among facing candidates.
MINOR (docs only, no code) — several `refs` line anchors land on blank lines, closing braces or mid-function lines when resolved against the post-#28 tree, so the "参照" links will show the wrong spot on blob/main:
  - CatRobot/Vision/ConversationCamera.swift 56 → now my added doc line; use 57 (func hasFreshFacingFace) — cited in address AND face.
  - CatRobot/Motion/MotionCoordinator.swift 731 → blank; 732 is serviceAutonomous().
  - CatRobot/Conversation/Tools/LookTool.swift 19 → blank; 16 is struct LookTool.
  - CatRobot/Conversation/Inactivity/ConversationIdleSettings.swift 29 → "}"; 5 (class) or 6–7 (sleepyRange/sleepingRange).
  - CatRobot/Conversation/Inactivity/ConversationInactivity.swift 74 → inside evaluate(); 73 is the func.
  - native/japanese-pronunciation/src/lib.rs 96 → "}"; 81 is the numbers::number_span dispatch (74 convert_plain).
  - CatRobot/Conversation/Services/Supertonic/SupertonicSentenceSpeaker.swift 60 → continuation.finish() inside a Task; likely intended 51 speak / 66 speakSentences / 7 maximumPreparedPronunciationCharacters.
  Durable fix: let the generator resolve each ref by a symbol pattern (e.g. "func hasFreshFacingFace") at generation time instead of fixed numbers, and assert the resolved line is non-blank; blob/main anchors will otherwise drift on every later commit. Minimal fix: correct the seven numbers above.
OPEN — #28 validation record not seen yet; when added, docs/README.md's validation index should get a #28 row next to the 2026-11-06 facing-addressing entry so readers of the dated #22 validation find the superseding record.
