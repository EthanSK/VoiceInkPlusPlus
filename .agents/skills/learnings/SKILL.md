---
name: learnings
description: Preserve VoiceInk++ institutional memory. Use automatically before any bug fix, regression investigation, fragile behavior change, Next button/Next Track or paste-delivery work, and after any feature, fix, deployment, or investigation that produces a durable verified lesson. Search LEARNINGS.md, apply accepted contracts, record new evidence, and improve this skill when reusable workflow, terminology, safety, or validation changes.
---

# VoiceInk++ learnings

Compound verified project knowledge for Codex and Claude Code. Treat `LEARNINGS.md` as the dated evidence index and this skill as the reusable procedure that maintains it.

## Start with prior evidence

1. Resolve the repository root and read its `AGENTS.md`.
2. Read the newest relevant entries in `LEARNINGS.md`. For recording destinations, focus restoration, recorder UI, paste, or auto-send, also read `RECORDING_DESTINATIONS.md` completely.
3. Search with one to three symptom or subsystem terms:

   ```sh
   bash .agents/skills/learnings/scripts/check.sh "<keyword>"
   ```

4. Inspect named accepted commits and current tests when a learning points to them. Preserve verified contracts instead of recreating remembered behavior.
5. State any relevant prior constraint before making a risky change.

## Use the canonical Next button vocabulary

- **Next button** is the preferred user-facing name for Ethan's programmable mouse control.
- **macOS Next Track**, **Next Track media key/action/event**, and `NX_KEYTYPE_NEXT` are implementation names for the event emitted by that button.
- **Secondary mouse button**, **latch button**, and **retarget button** are conversational aliases. Interpret them from context; do not invent separate behaviors.
- **Second chance** names only the post-stop, still-transcribing retarget route. Never call it a toggle.

Keep these three routes distinct:

| Action | Destination |
| --- | --- |
| Normal stop while recording | Exact editable input focused at stop (`focusedAtStop`) |
| Next button while recording | Input captured at recording start (`recordingStart`) |
| Normal stop, then Next button while the newest result is still loading | Replace that pending session's input and auto-send atomically (`focusedDuringTranscription`) |

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

## Continuous improvement

Whenever use, debugging, feature work, deployment, or investigation produces a durable verified finding, update `LEARNINGS.md` during the same task. When that finding changes how future agents should gather, interpret, validate, or preserve evidence, also update this skill's instructions, scripts, tests, or references. Retest affected behavior and validate the skill before finishing. Preserve reusable evidence; never record guesses, secrets, or transient state.
