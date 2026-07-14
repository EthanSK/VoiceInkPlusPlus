---
name: learnings
description: Preserve VoiceInk++ institutional memory and normalize Ethan's mouse-button terminology. Use automatically before any bug fix, regression investigation, fragile behavior change, primary/thumb/toggle-button or Next/forward/Next Track work, paste delivery, and after any feature, fix, deployment, or investigation that produces a durable verified lesson. Read TERMINOLOGY.md, search LEARNINGS.md, apply accepted contracts, record new evidence, and improve this skill when reusable workflow, terminology, safety, or validation changes.
---

# VoiceInk++ learnings

Compound verified project knowledge for Codex and Claude Code. Treat `LEARNINGS.md` as the dated evidence index and this skill as the reusable procedure that maintains it.

## Continuous improvement

Improve this skill as part of using it. Whenever use, debugging, feature work, deployment, investigation, or user feedback produces a durable verified finding, update `LEARNINGS.md` during the same task without waiting for a separate request. When that finding changes how future agents should gather, interpret, validate, or preserve evidence, also update this skill's instructions, scripts, tests, or references. Retest affected behavior and validate the skill before finishing. Preserve reusable evidence; never record guesses, duplicate guidance, secrets, credentials, or transient runtime state.

## Start with prior evidence

1. Resolve the repository root and read its `AGENTS.md`.
2. Read the newest relevant entries in `LEARNINGS.md`. For either mouse button, recording destinations, focus restoration, recorder UI, paste, or auto-send, read `TERMINOLOGY.md` and `RECORDING_DESTINATIONS.md` completely.
3. Search with one to three symptom or subsystem terms:

   ```sh
   bash .agents/skills/learnings/scripts/check.sh "<keyword>"
   ```

4. Inspect named accepted commits and current tests when a learning points to them. Preserve verified contracts instead of recreating remembered behavior.
5. State any relevant prior constraint before making a risky change.

## Normalize the two mouse controls before reasoning

- **Primary button** is the preferred name for Ethan's normal recording control. **Normal button**, **thumb button**, **toggle button**, **recording button**, **same button**, and historical **G5** are aliases. First press starts; the same primary button again performs a normal stop into only `focusedAtStop`.
- **Next button** is the preferred name for the separate forward/secondary control. **Forward button**, macOS **Next Track**, **Next Track media key/action/event**, **secondary mouse button**, **latch button**, and **retarget button** are aliases.
- Unqualified **toggle** means the primary button's start/stop lifecycle and corresponding shortcut mode. Never reinterpret it as a Next-button destination toggle. Commit `671b4c7` tried that and was deliberately reverted by `bed22b7`.
- **Second chance** names only the post-primary-stop, still-transcribing retarget route. **Latch** means preserve/replace one session's destination; it never means toggle the destination off.
- If Ethan says “input on start of transcription” while contrasting the two buttons, use the corrected meaning **recording-start input**. Recording precedes transcription.
- Ethan's verified G502 X LIGHTSPEED `Desktop: Default` mapping uses the upper side thumb control's `speech to text` Shift-Control-Option macro for the primary button and a different control explicitly labeled `Next Track` for the Next button. G HUB's `Mouse Button 4` and `Mouse Button 5` are separate controls; never infer that the spoken alias “forward button” means raw Mouse Button 5.
- When wording remains ambiguous, restate the physical control, timing, and destination value before changing behavior. Never invent a route from an alias.

For a G HUB sanity check, confirm the live active profile, onboard/software mode, resolved assignment diagram, and VoiceInk++'s stored shortcut. Raw profile card IDs or historical G-numbers alone are insufficient to identify the physical control.

Keep these three routes distinct:

| Action | Destination |
| --- | --- |
| Primary button again while recording | Normal stop into only the exact editable input focused at stop (`focusedAtStop`); never fall back to `recordingStart` |
| Next button while recording | Input captured at recording start (`recordingStart`) |
| Primary normal stop, then Next button while the newest result is still loading | Second chance: replace that pending session's input and auto-send atomically (`focusedDuringTranscription`) |

## Record only durable verified findings

Record a learning when evidence establishes something likely to affect future work, including a corrected semantic, reproducible failure and root cause, environment constraint, safety boundary, accepted terminology, or reliable validation signal.

Do not record speculation, generic progress, duplicate knowledge, credentials, secrets, raw private configuration, or transient runtime state such as a one-off PID. Commit identities are appropriate when they anchor an accepted implementation.

Keep each field concise but specific enough to prevent rediscovery. Name the symptom, proven cause, actual change, implementation commit, and regression guard. Use logs or user confirmation as evidence only after the behavior is genuinely observed.

## Finish the learning loop

1. Verify the affected behavior with the strongest safe evidence. Follow the Mac Mini build, signed-install, five-second restart warning, and live-trace contract in `AGENTS.md` for native destination changes.
2. Land the implementation commit before recording its SHA.
3. Add the newest entry with:

   ```sh
   bash .agents/skills/learnings/scripts/record.sh \
     --symptom "<observed behavior>" \
     --cause "<verified root cause>" \
     --fix "<changed behavior and files>" \
     --commit "<implementation SHA>" \
     --guard "<test, trace, validator, or invariant>" \
     --trigger "<user request or reproduction>"
   ```

4. Review the inserted entry, then commit the learning separately so it names the reachable implementation commit.
5. If the finding changes reusable workflow, terminology, safety, or validation, update this skill during the same task. Retest changed scripts and run `quick_validate.py` before finishing.
6. If no durable verified lesson emerged, do not add noise.
