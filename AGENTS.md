# VoiceInk++ agent instructions

These repository-specific rules are mandatory for every future agent working on recording destinations, Next Track handling, focus restoration, recorder UI, paste delivery, or auto-send.

## Repository learnings contract

- Use the public `.agents/skills/learnings` skill automatically before fixes, regressions, fragile workflow changes, destination/delivery work, or investigations that resemble an earlier failure.
- After any feature, fix, deployment, or investigation, add every durable verified project lesson to `LEARNINGS.md` during the same task. Do not record guesses, secrets, duplicate knowledge, or transient runtime state.
- When a lesson changes the reusable workflow, terminology, safety rules, or validation procedure, update the learnings skill itself, retest its affected scripts/behavior, and validate the skill before finishing.
- Codex discovers the canonical skill in `.agents/skills`; Claude Code uses the same folder through `.claude/skills/learnings`. Never maintain divergent copies.

## Non-negotiable Next Track contract

Use **Next button** as the preferred user-facing term. **Next Track**, **Next Track media key/action/event**, **secondary mouse button**, **latch button**, and **retarget button** are aliases for the same physical control or its macOS event. They do not create additional routes. Use **second chance** only for route 3 below, and never describe it as a toggle.

VoiceInk++ has three distinct one-click destination routes. Do not merge them, reinterpret them as a toggle, or infer one from another:

1. **Normal stop while recording:** stop recording and save the exact editable input focused at stop (`focusedAtStop`).
2. **Next Track while recording:** stop recording and save the input captured at recording start (`recordingStart`), with the documented safe application fallback for Electron/Chromium.
3. **Next Track after a normal stop, while the newest result is still transcribing/enhancing:** this is Ethan's **second chance**. Replace that pending session's destination with the exact editable input focused now (`focusedDuringTranscription`). It does not stop anything, toggle anything, or release the target.

The canonical second-chance scenario is:

> normal stop → transcription begins → focus a new editable input → press Next Track once → optionally move to another app → finished text pastes into the newly selected input and uses that input app's configured auto-send → VoiceInk++ restores the later workspace when applicable.

The saved input and its target app's `autoSendKey` are one atomic, per-session decision. Never re-read auto-send solely from the globally current Mode at delivery time: Ethan may already be using another app by then. `RecordingPasteTarget` must continue to carry both values, and `TranscriptionPipeline` must resolve the latest target immediately before delivery. One-shot raw/skip mode remains the intentional exception and must force no auto-send.

## UI contract

- Recorder panels appear on every connected monitor.
- Do not show routine “Recording” text above the waveform; visible text is reserved for real warnings/errors.
- Mode icon/emoji is left of the waveform.
- The right side has two separate icons: current focused app first, then the per-session locked destination.
- The locked icon remains visible through transcription and changes immediately after a successful second-chance retarget. Do not replace that visual confirmation with a success toast.

## Delivery safety

- Never use process-targeted Command-V or Return for this flow. macOS can accept those events while Electron/VS Code ignores them.
- Never treat `AXConfirm` as generic editor Return.
- Restore and verify the saved app/input, paste in the foreground, perform/verify auto-send, then restore the displaced app.
- ChatGPT/Codex submission retains its bounded semantic Send-button/System Events/humanized-HID fallbacks and visible failure notification.
- If capture, activation, focus verification, paste creation, or auto-send fails, surface the error; do not silently claim success.
- Ethan may be actively using the Mac. Prefer read-only logs and treat his live focus changes as real input, not contradictory test results.

## Required reading and validation

Before changing this behavior, read `RECORDING_DESTINATIONS.md` and the newest relevant entries in `LEARNINGS.md`. The accepted implementation is commit `1eabb1b` (`Fix second-chance transcription retarget auto-send`). The earlier accepted retarget foundation is `cba45ba`; the later toggle experiment `671b4c7` was deliberately reverted by `bed22b7`.

At minimum, preserve the regression test named `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt` and verify a real trace contains all of:

- `paste retarget: ... destination=focusedDuringTranscription targetCaptured=true`
- `pipeline: about to DELIVER ... targetAutoSend=enter destination=focusedDuringTranscription`
- `paste: foreground auto-send finished success=true`

Build only on the Mac Mini. A source fix is not complete until the signed build is installed at `/Applications/VoiceInkPlusPlus.app`, the user receives the real five-second restart notification, the new PID/CDHash/signature are verified, and `/Applications/VoiceInk.app` remains untouched.
