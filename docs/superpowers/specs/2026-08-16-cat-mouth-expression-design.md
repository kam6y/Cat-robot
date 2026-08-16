# Cat Mouth Expression Refinement

## Context

The first physical iPhone 16 Pro smoke test confirmed that the landscape conversation screen, on-device listening, Foundation Models reply, caption, speech, and automatic listening resume work. It also exposed two visible UX problems:

- the cream muzzle is drawn as two separately stroked halves, producing a long black center seam that makes the face look split;
- short spoken replies can show little mouth motion because speech start and the first word both select the same small pose, while the current openings are subtle on the device.

This refinement keeps the existing character, speech delegate integration, and MVP scope. It changes only muzzle geometry and the deterministic pose sequence.

## Decision

Use one continuous cream muzzle silhouette with a single exterior outline. Remove the internal seam and retain only a short, rounded line from the bottom of the nose to the mouth hinge. No line may extend below the mouth hinge toward the chin.

Keep speech animation driven by `AVSpeechSynthesizer` lifecycle events. Do not add a timer, audio amplitude analysis, phoneme synchronization, or another audio tap. The first `willSpeak` event must visibly open the mouth so even a one-word reply reads as speech.

## Geometry

- Replace the two separately stroked muzzle layers with one symmetric closed path covering the same friendly cream area.
- Stroke only the unified path's exterior. The result must remain seamless with Increase Contrast enabled.
- Preserve the existing nose and short nose-to-mouth stem.
- Use normalized mouth openings of approximately:
  - small: `0.025`
  - medium: `0.055`
  - wide: `0.090`
- Keep wide below `0.095` and inside the cream muzzle outline.
- Preserve the existing tongue and fang details for medium and wide poses.

## Motion

- Speech start selects `.small`.
- The first and subsequent `willSpeak` events cycle through `.wide`, `.medium`, `.small`.
- Voice and typed reply paths use the same sequence.
- Adjacent start/first-word events must therefore be visibly different.
- Finish, cancellation, pause, scene inactivity, and failure continue to close the mouth.
- Reduce Motion retains the functional pose changes using the existing restrained crossfade.

## Testing and Validation

Automated tests will prove:

- unified muzzle geometry is a single closed outline without a separate mirrored seam;
- mouth openings increase through small, medium, and wide and stay within the approved bounds;
- voice and typed speech paths select `.wide` for the first `willSpeak` event and `.closed` after finishing;
- existing lifecycle and cancellation behavior remains unchanged.

Physical iPhone validation will confirm:

- the cream muzzle no longer looks vertically split in listening or speaking states;
- a short reply such as `なあに？` visibly moves `small -> wide -> closed`;
- the mouth remains inside the muzzle, sounds and captions still match, and listening resumes normally.

## Non-goals

- exact phoneme lip sync;
- continuous timer-driven mouth motion;
- audio-level analysis;
- changes to the cat's eyes, ears, palette, layout, speech voice, reply prompt, or addressee policy.
