# Look: one requested camera image per tool call

## Intent and scope

Implement the approved FR-VIS-2/3/4/5 and NFR-PRIV-1 requirements in `2026-10-11-cat-robot-claude-neck-requirements.md`. On 2026-10-26 the user explicitly selected 「lookの実装へ進む」 after approving the completed face feature. The feature uses the existing front camera and ClaudeForFoundationModels 0.2.3; no package upgrade or new service is needed.

A person can say or type 「これ何？」「見て」. Claude calls `look(purpose)` when seeing is useful, receives a short tool result plus one image, and continues the same reply. The face becomes curious and a status chip says 「見ています」 before the image is handed to the SDK. The normal speech and expression lifecycle continues afterward.

Keep the adopted nine-expression geometry unchanged. Sleep/wake, pupil tracking, onboarding reorganization, rear-camera selection, a photo library, camera previews, video streaming, and on-device vision tools remain separate work. No production image uploads or real-device/robot motion tests run automatically during this implementation.

## Existing behavior and chosen approach

The capture worker already uses one front-camera AVCaptureSession, at most 640×480 and 5 fps (currently 3 fps), with correct sensor orientation and a queue-confined Vision detector. Only face rectangles leave the worker. FaceTrackingCoordinator currently starts/stops this source according to tracking preference, conversation visibility, fresh BLE STATUS, and thermal state. That ownership cannot serve `look` while the neck is disconnected.

Chosen implementation decision: a small `ConversationCamera` owner wraps the existing source. Face tracking continues using its `FaceCaptureSource` interface through this owner; look requests a temporary snapshot from the same owner. The owner starts the physical source for either consumer and stops it when neither needs it. It forwards only face observations to the tracking consumer, translating the physical capture generation to the tracking generation. No second AVCaptureSession and no change to tracking's geometry or motion policy.

Alternatives considered: opening a second capture session for each look adds camera contention and interruption handling; requiring BLE/tracking for look makes phone-only use fail. Both are excluded by the intended phone-only behavior. These are implementation decisions made by the agent against the approved requirements, not new user preferences.

## Camera contract

- Preserve the current low-resolution, low-frame-rate front-camera configuration and rotation normalization. The source retains at most one current pixel buffer on its capture queue; no frame files, image logs, base64 logs, or constant image conversion.
- Add request/cancel snapshot callbacks to FaceCaptureSource. Defaults return unavailable so existing injected/test sources remain source-compatible. Images cross the source boundary only for an explicit snapshot request.
- The worker materializes an upright, non-mirrored CGImage only on request. Long edge is at most 1,024 px, never upscale. CGImage has no source EXIF/GPS; the existing SDK re-encodes and applies its own wire limits.
- A frame is usable only for the current physical generation, with finite monotonic times and age strictly below 0.4 seconds. Each returned snapshot has a unique ID; the owner retains only its valid ID after capture stops normally. Global invalidation clears that lease, and camera validity/freshness is checked again at each look return boundary. Otherwise wait for the next valid frame. ConversationCamera has one in-flight snapshot request, a 3-second timeout, and rejects concurrent requests as busy.
- A look can start the camera without a robot or tracking. An active tracking capture is reused; finishing look must not stop tracking. Tracking stopping/disconnecting must not cancel a pending look.
- The display and capture use a fixed landscape with the front camera on the screen’s left (port on the right). Dynamic orientation switching is unsupported; sensor mounting is still normalized.
- Conversation hidden, inactive/background, settings/calibration, paused/failed/preparing, serious/critical heat, and camera interruption invalidate a pending image. Stop/failure releases the retained frame. Late callbacks never satisfy a newer request.
- Snapshot requests never display an OS permission prompt. Existing tracking permission flow stays in place; a camera permission action in Settings enables phone-only look even when tracking is off. Denial/restriction produces a textual unavailable result and leaves conversation functional. Refresh authorization when the scene/settings become active.

## Turn ownership and visible indication

`LookCoordinator` is a MainActor ReplyTurnObserving participant using existing MotionTurnID/Context and RobotClock. It accepts calls only for the current generating turn while the conversation is visible, and captures the caller's TaskLocal before any actor hop. One look is in flight at a time; another gets a busy result. Sequential calls are allowed, each obtaining one current image.

Before requesting a frame, set `isLooking = true`, overriding the displayed expression with curious and showing a 「見ています」 status chip. Allow 0.1 seconds for this indication to be displayed before requesting/returning the snapshot (an implementation choice, tested using ManualRobotClock). Do not mutate the underlying caption, expression reservation, phase, microphone, playback, or head motion. Keep the indication through the final Tool handoff, even if earlier streamed speech starts during the delay, capture, or handoff. After handoff, a later speech start or generation completion clears it; if speech already started, generation completion clears it. A failed/cancelled look clears it immediately. Any old completion must not clear a newer indication.

A stop, new conversation, settings, scene transition, fallback, generation failure, or shutdown synchronously resets the coordinator and cancels its snapshot wait. A late SDK call, expired request, or old turn cannot capture or return an image. At the Tool return boundary, recheck cancellation, turn ownership, and the snapshot validity lease after each await. `finishCapture` synchronously validates and releases request ownership immediately before constructing the output; an old rejected snapshot cannot clear a newer indication. Returning an unavailable tool result is not a conversation-generation failure.

The tool output uses FoundationModels Prompt/Attachment(CGImage), not JSON/base64, a disk URL, or a second model request. `purpose` is the model's short reason for looking; it is not logged or used to broaden camera access. Instructions permit look only for a user request or when visual context is actually needed, and forbid claiming to see after an unavailable result.

## Image lifetime and conversation history

ClaudeConversationService already persists only prompt/response strings, summary, and long-term text facts. Preserve that contract. Its cached LanguageModelSession would otherwise carry a tool image into later turns; add a session-client query for image attachments and discard the cached session after a successful image-bearing reply. The next turn rebuilds from the existing text memory. Non-image sessions stay reusable. Failure/cancellation already discard the session.

The image can be used throughout the SDK's tool loop for the current reply. It is never retained in the next reply's app session or persisted in app memory. No network-level deletion claim is made for an image already sent to Claude.

## Composition and UI

Create one ConversationCamera and one LookCoordinator in live composition. Add look to the existing tool provider and to ReplyTurnMulticaster with motion and expressions. Add a default no-op look controller to dependencies for existing callers. App scene/visibility, thermal changes, settings, and teardown reach the shared camera. ViewModel's existing synchronous invalidation points reset look beside expressions.

ConversationViewState adds `isLooking` and derives `displayedCaption`; `caption` remains complete original text. Face selection gives the temporary look indication priority over a held expression. The visible indication is a status chip (`statusChip.looking`); captions are no longer rendered under the 2026-10-27 UI reorganization design. The existing VoiceOver policy still exposes 「見ています」 and the complete reply. Controls, content-priority scrolling and mouth state remain intact.

Settings has camera authorization status and an explicit permission/Open iPhone Settings action. No new persistent look toggle. Update onboarding, Settings information, usage description, and README to say a requested still image is sent to Claude, while continuous camera footage/audio are not sent or saved. Keep camera permission independent of turning on head tracking.

## Acceptance and tests

1. Synthetic-buffer tests cover rotation, no mirroring, dimensions ≤1,024, freshness, generation rejection, and retained-frame clearing. Shared-owner tests cover phone-only request, reuse with tracking, stop of either consumer, timeout, concurrent calls, denied permission, heat, scene invalidation, and late callbacks.
2. ManualRobotClock plus controllable camera tests prove curious/「見ています」 precede the image, held expression and caption survive, old/cancelled/fallback turns do not return images, and speech/generation/reset clear the right indication.
3. A real FoundationModels tool-dispatch test produces one image attachment in the current tool output without a network call. Session lifecycle tests prove only image-bearing replies discard the cached session and the next session receives text memory without image attachments.
4. Integration tests cover voice and typed paths, no robot/tracking, settings/background/startup/shutdown, shared live composition and failure preserving chat. Render representative normal/maximum-type indication and camera permission UI fixtures; no new face-shape snapshot loop is needed.
5. Run related regressions after each task, then project generation contract, the full Simulator suite, and one fresh whole-branch code review. Physical camera framing, image contents, permission UI, real Claude response, speech timing, and BLE coexistence remain explicitly unverified unless performed with the user present.

## Work and integration

Use the existing native isolated worktree at `/Users/goodapple/.codex/worktrees/b200/Cat_robot`, new branch `feature/look` based on `83dd9f897c5e03746e42434c1d249e74188e6d24`. The completed `feature/face-expression` ref remains unchanged. Native implementation is retained from the established workflow. No merge or push is implied.

## Fixed-mount scope correction — 2026-10-26

During attended device acceptance, the user explicitly required a fixed left-side front camera and removal of opposite-orientation support. [Fixed left camera design](2026-10-26-fixed-left-camera-design.md) governs this constraint. Sensor-rotation normalization remains necessary for upright, unmirrored images.
