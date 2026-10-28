# SDD ledger — plan: docs/superpowers/plans/2026-10-27-face-size-tuner.md

Pre-flight: one tool-only task, no shared source edits. Existing host-managed worktree; 223 app inputs match the passing 839-test suite.
Ruling: proceed with the authorized separate iPhone tool after user platform and scope clarification; no additional implementation approval gate. Current app size stays unchanged until the user provides the chosen value.

Task 1 RED: red.log, 4 tests / 44 expected assertion failures (no persistence/copy/normalization; preview ignored scale). No compile failures. Implemented model and overlay controls after confirmed RED.

Task 1: implementation complete, green.log 4/4 passed and controls.log full tool suite 5/5 passed. Real UISlider, copy/reset/full-screen buttons exercised at large and accessibility5. Original app 223 hashes unchanged. CUA could not resolve Simulator app; official XCTest host supplied UI interaction and images. Independent review and deployment follow.

Task 1: complete. Final full tool suite 5/5 passed, 0 skipped/failures; signed be3d780 installed and launched on iPhone16Pro. Original app installation record and 223 source inputs unchanged.
Final: minor (deferred): AX5 expression picker wraps vertically and covers the face while adjusting; controls remain operable and largest-text full-screen capture shows the face.
Final: Ruling: tool scopes size to the normal conversation face, not typing/settings/error/content-first layouts — matches the chosen normal-screen size workflow — cost if wrong: a separate adjustment for those layouts would be required.
Final: Ruling: static expressions with closed mouth share the real vector renderer; no conversation, blinking or hardware is included — user is choosing overall size — cost if wrong: dynamic appearance differences are not established by this tool.
Final: Ruling: do not infer standard full-screen pixels from an incomplete hierarchy capture — code overlay geometry and state/action assertions remain valid; AX5 full-screen image shows face — cost if wrong: a device-specific full-screen rendering issue could need follow-up.
Final: Ruling: physical installation and launch are confirmed by devicectl, not by an observed device screen — tool is delivered without claiming manual device QA — cost if wrong: physical-only visual issues remain unobserved.
Handoff: tool ready on iPhone at initial85%; wait for the user's selected value before modifying/deploying main app. No merge/push.
