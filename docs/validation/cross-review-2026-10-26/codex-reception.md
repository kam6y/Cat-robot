# Codex reception of Claude /simplify

Reviewed against frozen dbd04589 and the current root-owned bug fixes. The source-level examination for R/A is recorded separately in codex-reception-reuse-altitude.md; root examined all S/E proposals, actual call sites and guards. These are maintenance findings, not additional Critical/Important correctness defects. Counts: 21 accepted/partially accepted C items; 9 deferred. Overlapping IDs are implemented once.

| ID (origin) | Disposition | Verified scope / reason |
|---|---|---|
| C1 (S1/R1) | Accept | Synchronous protected-byte-file helper shared by both actor stores. Preserve exact filename/temp-prefix deletion, caps, errors, protection/exclusion, atomic rename and JSON validation in stores. No await inside file transaction. |
| C2 (S3/R3/A1/A6) | Partial | Private VM reset and phase fan-out helpers only. Preserve all explicit resets and stop → expression → look order. Do not add TurnFeatures or replace failure publication with transition. |
| C3 (S5/R7/A5) | Partial | RobotStatus.with(yawDeci:pitchDeci:) preserving every other field and integer subtraction/clamping. No new pose/origin timing API or floating-point arithmetic changes. |
| C4 (S7/R2/A4/A8/A9) | Accept | Share exact flag predicates and exhaustive motion-priority classification; retain all scheduling, Task and BLE-write checks and optional == true semantics. Distinct two-flag checks stay distinct. |
| C5 (R4/R5/A8) | Partial | Name 1 s STATUS/0.4 s image limits and exact snapshot readiness. Keep motion resynchronization separate, richer RobotLink admission and all time-boundary arithmetic unchanged. |
| C6 (R4/A3) | Accept | Share capture-environment formula and thermal classification without changing callers' input values or public setEnvironment signatures. Preserve separate permission lifetime, cooling and tracking enable rules. |
| C7 (R5) | Defer | General RobotTime/Clock APIs and global epsilon substitutions add overlapping policy surfaces. Existing finiteness, subtraction/addition and strict comparisons are not interchangeable. C5 handles the meaningful duplicated limits. |
| C8 (S9/A2) | Partial | Local active control-mode expression only. No mutable callback wiring, ownership redistribution or notification reordering. |
| C9 (S2) | Defer | Unused settlement MOVE is real, but splitting the routine duplicates Task cancellation, write accounting and ownership bookkeeping. No clear net simplification over the current guarded branch; do not introduce another dispatch abstraction. |
| C10 (S4) | Accept | Remove constant taper field/animation dimensions and constant lerps, conditional on identical rendered pixels. Do not assume algebraic equivalence implies bitwise floating-point equivalence. |
| C11 (S6) | Accept | Remove verified unused production API/protocol requirements, enum cases, stale comments; move RememberToolProvider into test support. Preserve LookCoordinator's concrete internal isCurrent method and real UI cancellation behavior. Update tests to public production paths. |
| C12 (R6) | Defer | Generic stream-observer lifetime/cancellation equivalence is false for these owners. A two-line send preflight helper is possible but insufficient benefit to justify another indirection in this pass. |
| C13 (A4) | Accept | Part of C4: shared allowsIdlePowerOff predicate; keep all three boundary checks, active/rest/readiness and retry semantics. |
| C14 (A7) | Accept | Private camera global revoke helper at exactly five sites. Do not route request-ID cancellation/completion through it. |
| C15 (A10) | Accept | Private turn invalidation helper with valid=false, clear pending and waitingSince; retain caller-specific ID guards and cleanup. |
| C16 (S8) | Accept | Derive encrypted-status availability from preparation; derive playback started/finished flags from the existing deduplication sets. Preserve first-start and duplicate-event ordering. |
| C17 (S10) | Accept | Replace one-value presentation wrapper with connection-status initialization and existing announcement policy; same mapping and announcements. |
| C18 (S11) | Defer | Capture interruption versus failure remains a concrete diagnostic distinction. Collapsing events while preserving source diagnostics merely relocates the discriminator; little benefit for changing this boundary. |
| C19 (R8) | Accept | Narrow live LanguageModelSession text-snapshot bridge and protocol refinement only. Preserve buffering, error mapping, normal Task/task-local inheritance and cancellation on every termination. No service-level stream rewiring. |
| C20 (R10) | Partial | Canonical model defaults and yaw correction range/default, exact values/text preserved. No settings page abstraction or OpenURLAction wrapper. |
| C21 (R11) | Defer | Runner differences include schemes, environment keys, attended gates and validation, not just prefixes. Abstraction would add many parameters and its full device path is outside this review. |
| C22 (R12) | Accept | Reuse existing fixed-reply test fixture with exact texts; no fixture framework. |
| C23 (S12/S13/S14/R9) | Partial | Root owns firmware: remove unused Source, consume SAVE return instead of lastSaveOk state, make unused-return request method void, inline one-line STOP wrapper, simplify ignored saturation outputs and remove unused transport accessors. Reuse calibration output conversion if it remains simple. Defer new general gain/range/normalization helper API: distinct parser/core rejection behavior stays explicit. Preserve I3/M1 and existing waveform/safety rules. |
| C24 (S15) | Partial | Remove unused nose argument only. Array-returning splitCubic adds two temporary arrays per whisker and changes floating-point order; keep existing geometric arithmetic and ellipse-local precomputation. |
| C25 (E1) | Defer | Speculative precompaction changes API call timing/cost, traces, cancellation and state. This is new latency work, not behavior-preserving simplification; no measured latency evidence warrants it here. |
| C26 (E2) | Accept | Cache immutable literal WritableKeyPath & Sendable array, keeping exact order. Swift 6 strict-concurrency prototype passes for literal array; composed key paths fail to preserve writable/Sendable type. Prefer explicit literals over nonisolated(unsafe). Verify vector roundtrip and unchanged face render. |
| C27 (E3) | Accept | Run motion timer only while snapshot.state == connected; retain it during stale STATUS/resync. Observer remains live while disconnected. Add a meaningful regression for no disconnected clock wakeups and reconnect/recovery scheduling, RED before implementation. |
| C28 (E4) | Defer | CIContext initialization cost is unmeasured; optional/prepared context adds a failure state and changes cold-camera timing. Keep current always-ready context for this pass. |
| C29 (E5) | Defer | Moving pair-state refresh changes serial STATUS freshness and adapter API. Host-lock frequency is plausible but target cost is unmeasured; defer firmware timing optimization. |
| C30 (E6) | Defer | Additional GATT value caches/generations create redundant state for unmeasured savings. Preserve the simple current snapshot publication. |

## Correctness reception and decisions

Claude independently accepted I1/I2/I3/M1 (claude-reception.md). Root reproduced each before fixes. I3's initial deferred-calibration proposal was not adopted: deferred SAVE/readback/STOP semantics add state. Both parties instead agreed to reuse handOverFromWaveform, discard active/queued motion, apply calibration and reapply joint targets through Planner. Read/SAVE remain immediate. SET_LIMITS angle changes during playback retain their existing client-side rest requirement; the adopted waveform/velocity design is unchanged.

## Ownership / verification

Root retains firmware, docs, project generation and all build/test commands. Claude may implement the accepted iOS/test cleanup scopes after explicit handoff; preserve root's current I1/I2 edits. No concurrent xcodebuild or device actions. Face baseline is generated before face edits. C27 tests must fail on the pre-optimization timer before its product change. Pure refactors use existing behavioral coverage, then one final full iOS/native/target-build pass and before/after face comparison. No merge, push, device install or firmware upload is part of this task.
