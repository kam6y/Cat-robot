# Cat Robot MVP Design

Date: 2026-08-12  
Status: Approved for implementation by neutral product and engineering review

## Summary

Cat Robot is a native SwiftUI app for iPhone 16 Pro that provides a foreground, turn-taking voice conversation with an animated AI cat. While the landscape conversation screen is active, the app continuously transcribes nearby speech on device, quickly decides whether each completed utterance is addressed to the cat, sends accepted utterances to Apple's on-device Foundation Models framework, and speaks the response with the system speech synthesizer.

The primary product value is conversational flow: low response latency, few ritual interactions, and the ability to repair misunderstandings naturally in the next turn. The MVP does not claim perfect addressee detection or add a second model pass to validate ordinary replies. Once a conversation is engaged, speech is accepted optimistically. Outside an engaged conversation, clearly unrelated room speech is ignored, while genuinely ambiguous speech prompts the cat to ask a short conversational clarification.

## Goals

- Run natively in Swift on an iPhone 16 Pro with iOS 26 or later.
- Provide foreground continuous listening without requiring a wake phrase on every turn.
- Optimize for fast perceived response and conversational repair over defensive double-checking.
- Use Apple `SpeechAnalyzer` / `SpeechTranscriber` for live, on-device transcription.
- Use Apple Foundation Models for addressee classification and conversational replies.
- Present a glanceable, landscape, dark experience reminiscent of StandBy without copying system UI.
- Make the centered cat visibly react while listening, thinking, and speaking.
- Speak responses aloud and always show the same response as readable text.
- Keep microphone state, AI use, addressee uncertainty, and recoverable errors transparent.
- Support typed input when voice input is unavailable or undesirable.
- Keep all conversation and classification processing on device for this MVP.

## Non-goals

- Background or locked-screen listening.
- Speaker identification or voice enrollment.
- Full-duplex audio, barge-in, or interruption while the cat speaks.
- Perfect intent or addressee detection in crowded rooms.
- A second AI pass that critiques, rewrites, or safety-checks every ordinary reply.
- Cloud models, remote tools, accounts, analytics, persistence, or cross-device sync.
- Robot hardware control, camera input, image generation, or long-term memory.
- Exact phoneme lip sync. Mouth movement communicates speech activity only.
- Supporting devices or OS versions that cannot run Foundation Models.

## Supported environment

- iOS 26.0 or later.
- iPhone only, with both landscape orientations enabled and portrait disabled for the MVP.
- Primary validation device: iPhone 16 Pro (`iPhone17,1`) named `Not so bad`, running iOS 26.6.
- Swift 6 with strict concurrency and SwiftUI lifecycle.
- Apple Intelligence enabled, model assets ready, and a supported app locale.
- Japanese is the primary locale; UI strings and the default cat response language are Japanese.

## First-run and conversation flow

1. The app opens to a landscape welcome screen that plainly identifies the character as AI and explains that the microphone is used only while the conversation screen is open.
2. The person taps **会話を始める**. Only then does the app request microphone permission and preflight speech assets, Foundation Models availability and locale support, and an installed Japanese speech-synthesis voice.
3. If ready, the app enters the conversation screen and begins capture. A persistent control says **端末上で聞き取り中** and offers **一時停止**.
4. Live provisional text can appear briefly as **聞き取り中…**, but it is not sent to any model.
5. An utterance-segmentation layer closes a turn after final transcription plus a tested silence interval. `SpeechTranscriber.Result.isFinal` alone is not treated as an end-of-turn signal.
6. The addressee gate evaluates the completed utterance. Clear wake-name matches and utterances inside the active-conversation window are accepted immediately without a classifier call. Only speech outside that fast path uses a short-lived classifier session.
7. Accepted speech enters the stateful reply session. The cat shows **考え中…** and the response streams into the caption as soon as the first snapshot arrives. Replies are prompted to be one or two spoken sentences by default, then the synthesizer speaks the completed text.
8. Capture pauses while the cat speaks, preventing self-transcription. When speech ends, capture resumes automatically unless the person paused it, the scene became inactive, or an audio interruption occurred.
9. Clearly unrelated speech never reaches the reply session. For ambiguous speech, the app keeps the utterance only in memory and asks **今の、ぼくに言った？** using a fixed local phrase. A simple affirmative forwards the original utterance; a negative discards it. The pending utterance is overwritten or expires after 15 seconds.
10. Leaving the screen, backgrounding the app, or encountering an audio interruption stops microphone capture. The app returns visibly paused and requires **再開** rather than silently listening again.

## Addressee decision policy

The gate deliberately favors continuity once engagement is established. It uses the following ordered policy:

1. Reject empty, noise-only, or extremely short filler utterances.
2. Accept an explicit address such as “ねこ”, “猫ちゃん”, “Cat Robot”, or “キャットロボット”. Strip only the leading address phrase before forwarding the remaining content. If the utterance is only the wake name, skip both models, show and locally speak **なあに？**, arm engagement when that acknowledgement finishes, and resume listening. For Japanese ASR that omits a separator after the wake name, use a small fixed conversational-starter allowlist for the fast path; uncertain prefix collisions still go to classification.
3. Accept any plausible conversational utterance during the active-conversation window. Its soft expiry is 30 seconds after the cat finishes speaking and each fast-path reply can refresh that soft expiry. A separately recorded hard expiry, five minutes after engagement was armed, cannot be extended by fast-path speech. This path does not call a classifier.
4. If a clarification is pending, interpret a short affirmative as acceptance of the pending utterance and a short negative as rejection.
5. Otherwise, run a separate `LanguageModelSession` that produces a constrained `AddressDecision` using guided generation.
6. Map `.addressed` directly to reply generation, `.ambiguous` to the fixed spoken clarification, and `.notAddressed` to silent ignore.
7. Never put rejected speech, classifier prompts, or classifier output into the reply session transcript.

Engagement is armed only after the cat finishes acknowledging or replying to an explicit wake-name, after a classifier result of `.addressed` is answered, or after affirmative confirmation of an ambiguous utterance is answered. It is cleared by pause, scene inactivity/backgrounding, or audio interruption. When the five-minute hard expiry is reached, the next non-wake utterance returns to classification; an explicit or positively classified address begins a new engagement period. Speech heard during the active window can therefore be assumed to be addressed to the cat. This intentional tradeoff favors responsiveness over eliminating every false activation.

The structured result is intentionally small:

```swift
@Generable
struct AddressDecision {
    @Guide(description: "Whether the utterance is addressed to the AI cat")
    var target: AddressTarget
}

@Generable
enum AddressTarget {
    case addressed
    case ambiguous
    case notAddressed
}
```

Classification and reply generation are serialized. The classifier is short-lived and stateless; the reply session is long-lived within the current in-memory conversation. There is no reply-validator session and no model-generated numerical confidence score.

## Responsiveness and conversational repair

- Prewarm the reply `LanguageModelSession` when conversation preparation completes, before the first utterance.
- Use deterministic wake-name and engaged-conversation fast paths so most turns incur only one model request.
- Show provisional local transcription immediately and replace it as `SpeechTranscriber` refines the text.
- Stream cumulative reply snapshots directly into the visible caption rather than waiting for the complete response.
- Keep default replies brief and natural. The user can explicitly ask for detail.
- Start speech synthesis as soon as the short reply completes. Sentence-by-sentence overlapping generation and speech is deferred because unstable partial text can produce audible corrections and more complex cancellation behavior.
- Do not perform a second AI pass for factuality, tone, or safety. Use the Foundation Models framework's built-in guardrails and show a simple disclosure that the AI can be wrong.
- Treat “違う”, “そうじゃない”, and ordinary corrections as normal follow-up turns in the same reply session. The cat acknowledges the correction and continues; it does not erase or secretly rewrite prior output.
- When addressee intent is ambiguous, prefer one short human-like clarification over a modal error or an invisible conservative rejection.
- Measure end-of-utterance to first visible reply and end-of-utterance to audible reply on the physical iPhone. Initial MVP targets are under 2 seconds to first visible reply and under 4 seconds to speech under normal ready-model conditions; these are product targets, not hard guarantees.
- Record latency separately for deterministic engaged/wake-name turns and classifier-gated turns so classifier cost is visible rather than hidden in one aggregate.

## Utterance segmentation

`SpeechTranscriber` uses its progressive transcription preset for responsive visual feedback. Finalized segments accumulate in the current turn. A turn closes when all of the following hold:

- At least one non-whitespace finalized segment exists.
- There has been no new speech or volatile transcript update for the configured silence interval (initially 1.2 seconds).
- The app is in the listening state and is not synthesizing audio.

A maximum turn duration of 20 seconds prevents a noisy environment from keeping a turn open indefinitely. The silence and duration values live in a testable configuration type. `SpeechDetector` may reduce noise processing but is not a correctness dependency for the MVP.

## Architecture

### Presentation

- `CatRobotApp`: lifecycle and landscape scene root.
- `OnboardingView`: AI and microphone disclosure plus the start action.
- `ConversationView`: full-bleed cat, caption, listening control, text-entry fallback, and transient recovery/error cards.
- `CatFaceView`: code-drawn SwiftUI shapes for eyes, ears, whiskers, and mouth poses.
- `ConversationViewModel`: main-actor observable state machine and the only presentation coordinator.

### Domain

- `ConversationPhase`: `idle`, `preparing`, `listening`, `classifying`, `clarifying`, `thinking`, `speaking`, `paused`, and `failed`.
- `UtteranceSegmenter`: pure stateful logic that converts finalized/provisional transcription events and time into completed utterances.
- `AddresseePolicy`: deterministic wake-name, engaged-conversation, and clarification rules before optional model classification.
- `EngagementWindow`: testable soft/hard expiry state, armed only by explicit, classified, or confirmed addressing and cleared when listening continuity breaks.
- `ConversationTurn`: in-memory user/assistant text used only for display; the Foundation Models session owns its own model transcript.

### Service boundaries

- `SpeechRecognizing`: start, stop, and stream transcript events.
- `AddressClassifying`: classify completed utterances using a fresh guided-generation session.
- `ReplyGenerating`: stream a reply from one stateful `LanguageModelSession`.
- `SpeechSpeaking`: speak text and publish word/speech lifecycle events.
- `ModelAvailabilityChecking`: translate Apple availability states into actionable app states.

Concrete Apple-framework services conform to these protocols. Tests inject deterministic fakes and do not invoke models, microphones, or audio output.

## State and concurrency

`ConversationViewModel` is isolated to the main actor. It owns one top-level orchestration task and cancels child work when the scene deactivates or the person pauses. Service implementations isolate audio and model work behind actors or other `Sendable` boundaries.

Allowed happy-path transitions are:

```text
preparing -> listening -> classifying -> thinking -> speaking -> listening
```

Deterministic acceptance normally skips `classifying`. An ambiguous classification enters `clarifying`, speaks the fixed question, and returns to `listening` with exactly one ephemeral pending utterance. The next short affirmative processes that original utterance; a negative response or 15-second timeout discards it. Unrelated speech returns silently to `listening`. Any active phase can move to `paused` or `failed`, which also clears engagement and pending clarification. Resume always re-preflights the required resources before listening.

Only one Foundation Models request runs at a time. The UI disables conflicting actions during classification or response generation. A fresh reply session is created when the context window is exceeded, with a short Japanese explanation that conversational memory was reset.

## Audio behavior

- Use an `AVAudioSession` configured for play-and-record and voice conversation.
- Use an `AVAudioEngine` input tap. On the iOS 26 SDK, convert its PCM buffers with a small `AVAudioConverter` bridge into `AnalyzerInput`; Apple's `AnalyzerInputConverter` and `CaptureInputSequenceProvider` helpers are iOS 27-only and are not compiled into this iOS 26 MVP.
- Install or prepare the current Japanese `SpeechTranscriber` asset before capture.
- Stop the input engine and analysis when paused, inactive, interrupted, or speaking.
- Use a retained `AVSpeechSynthesizer` with a Japanese voice. Delegate callbacks switch mouth poses during spoken word ranges and finish the speaking phase.
- No audio recordings are written to disk. Raw microphone audio and rejected transcripts are not retained.

## Visual design

The app uses a full-bleed semantic black/dark content layer. A large, original, code-drawn cat face is centered within the safe area and remains the unmistakable branded content. It borrows StandBy's landscape orientation, glanceability, sparse controls, and low-light comfort, but not its widget grid, clocks, type treatments, red night mode, or Lock Screen affordances.

The generated character reference at `docs/design/cat-character-reference-v1.png` establishes the proportions and palette. During implementation it may be placed behind `CatFaceView` at low opacity in a development-only preview so the SwiftUI geometry can be traced and compared. Production builds contain only the code-drawn version, not the raster reference. The implementation decomposes the face into independently animatable, normalized-coordinate layers: head silhouette, inner ears, forehead marks, eyes/irises/pupils, muzzle, nose, upper mouth, lower mouth, and whiskers. This preserves the friendly design while allowing clean scaling, Dark Mode semantics, Reduce Motion behavior, and deterministic mouth animation.

Cat states:

- `idle` / `paused`: neutral face, static mouth.
- `listening`: attentive eyes and a restrained ear motion.
- `classifying` / `thinking`: slow blink; no distracting perpetual pulse.
- `speaking`: alternating mouth poses driven by speech delegate callbacks.
- `failed`: neutral face, never an alarming animation.

The response caption sits below or beside the face depending on available height and Dynamic Type. It uses system text styles and a readable-width limit.

Liquid Glass is limited to the functional layer: one lower safe-area listening/control capsule and standard sheets or menus. It uses the Regular variant; the cat, caption, transcript, and error content do not use glass. Controls have at least 44×44 point hit regions. The status bar remains visible to preserve the system microphone indicator.

## Accessibility

- Every spoken response is also visible as text.
- Listening, paused, thinking, and speaking are identified with text and SF Symbols, never color or motion alone.
- The cat artwork and facial animation are hidden from VoiceOver; a concise semantic status describes the assistant.
- Dynamic Type is supported through accessibility sizes; the layout becomes stacked rather than truncating.
- Reduce Motion removes idle motion, bounce, waveform motion, and glass morphing; mouth changes use restrained crossfades.
- Standard controls preserve Reduce Transparency and Increase Contrast behavior.
- Typed input provides a complete alternative to speech.
- VoiceOver announces finalized state changes and recovery cards once, not every provisional transcript update.

## Privacy and transparency

- The first screen identifies the cat as AI, explains that generated answers may be incorrect, and states that MVP processing stays on device.
- Microphone permission is requested only after **会話を始める**.
- The conversation screen always shows a separate persistent microphone status, regardless of whether the cat is listening, thinking, or speaking.
- Capture stops outside the foreground conversation scene.
- No network tools, analytics, recordings, or persistent conversation storage are included.
- Ambiguous utterances stay only in memory, and only the latest one is retained for at most 15 seconds while conversational clarification is possible.

Suggested microphone purpose string:

> Cat Robotは、この会話画面を開いている間、AIの猫と話すためにマイクを使用します。音声は端末上で処理されます。

## Availability and error handling

Preflight checks produce specific recovery UI:

- Microphone denied: explain how to enable access in Settings and keep typed input available.
- Speech locale unsupported: explain that Japanese transcription is unavailable and keep typed input available.
- Speech asset missing: show **日本語の聞き取りを準備中…** with progress when available; never pretend to listen.
- `.deviceNotEligible`: state that this device cannot use Apple Intelligence.
- `.appleIntelligenceNotEnabled`: ask the person to enable Apple Intelligence in Settings.
- `.modelNotReady`: state that the on-device model is still preparing and offer retry.
- Unsupported model locale: keep the conversation screen paused and explain the language limitation.
- Guardrail/refusal: give a brief, neutral explanation and allow a different request.
- Context exceeded: create a new reply session and explain that short-term conversation memory was reset.
- Audio interruption: stop capture, show **一時停止中**, and require explicit resume.
- Unrecognized speech: show **うまく聞き取れませんでした** with **もう一度** and **文字で入力**.

Errors use plain Japanese and always include a next action. Debug details are not shown to the person.

## Testing strategy

### Unit tests

- Wake-name acceptance and prefix stripping.
- Engaged-conversation arming, fast-path behavior, 30-second soft expiry, five-minute hard expiry, and clearing on pause/background/interruption.
- Ambiguous clarification, affirmative recovery, negative rejection, and pending-utterance expiry.
- Silence-based segmentation, provisional updates, empty speech, and maximum duration.
- Happy-path and cancellation state transitions.
- Model, locale, permission, audio interruption, guardrail, and context-window error mapping.
- No classifier/reply concurrency, no per-reply validation pass, and no rejected text entering the reply service.
- Reduce Motion derived presentation state.

### Simulator checks

- Build and unit tests on an iOS 26.5 simulator.
- Both landscape directions, safe areas, keyboard, and accessibility Dynamic Type.
- VoiceOver labels and non-color state distinctions.
- Reduce Motion and Reduce Transparency presentation.
- Model/microphone unavailable screens using injected preview or launch configurations.

Foundation Models inference and the new speech model are not considered validated by simulator-only tests.

### iPhone 16 Pro smoke test

- Confirm the device is unlocked, Developer Mode is enabled, and Xcode finishes preparing its developer disk image.
- Build, sign, install, and launch on `Not so bad`.
- Grant microphone access from the contextual start action.
- Verify Japanese speech assets and Foundation Models availability.
- Speak one explicit-address request and confirm listen -> think -> speak -> automatic resume without a classifier delay.
- Continue naturally without repeating the cat's name and confirm the engaged fast path responds.
- After the engagement window expires, speak unrelated room speech and confirm no reply; produce an ambiguous phrase and complete the cat's spoken clarification flow.
- Confirm the cat's mouth moves while the audible response plays and the same response is captioned.
- Pause, background, foreground, and trigger an audio interruption; confirm capture does not silently resume.
- Confirm typed input still works with microphone access denied.

## Git workflow

- `main` contains only integrated work.
- Each bounded feature is implemented in its own `feature/*` branch and project-local ignored `.worktrees/` worktree.
- Every feature is tested and reviewed before integration.
- Integration uses `git merge --squash`; the resulting commit lands on `main`.
- Feature branches are pushed and retained after squash merge. Local worktrees may be removed after integration.
- Planned feature boundaries are project foundation, conversation domain, Apple voice/AI services, cat interface, and app integration.

## MVP acceptance criteria

The MVP is complete when it builds and launches on the connected iPhone 16 Pro and demonstrates, in Japanese:

1. Contextual microphone permission and actionable availability states.
2. Foreground continuous transcription with visible listening and pause controls.
3. Fast-path addressee handling during active conversation, plus classification that ignores unrelated speech and conversationally clarifies ambiguity.
4. A stateful Foundation Models response spoken aloud and displayed as text.
5. Cat mouth animation during speech and distinct listening/thinking/speaking states.
6. Automatic return to listening after speech, but no silent resume after backgrounding or interruption.
7. Typed-input fallback.
8. Passing focused unit tests and a successful real-device smoke test, without expanding into full-duplex or background audio.

## Primary Apple references

- [Foundation Models](https://developer.apple.com/documentation/foundationmodels/)
- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- [Generating Swift data structures with guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
- [Managing the context window](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)
- [Supporting languages and locales](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Generative AI HIG](https://developer.apple.com/design/human-interface-guidelines/generative-ai)
- [Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Layout HIG](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Privacy HIG](https://developer.apple.com/design/human-interface-guidelines/privacy)
