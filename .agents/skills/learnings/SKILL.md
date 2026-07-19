---
name: learnings
description: Preserve VoiceInk++ institutional memory, search rejected approaches, and normalize Ethan's mouse-button terminology. Use automatically before any bug fix, regression investigation, fragile behavior change, primary/thumb/toggle-button or Next/forward/Next Track work, paste delivery, live compatibility testing or tracing, and after any feature, fix, deployment, or investigation that produces durable verified evidence. Read TERMINOLOGY.md, search LEARNINGS.md and FAILED_APPROACHES.md, apply accepted contracts, record new evidence, and improve this skill when reusable workflow, terminology, safety, or validation changes.
---

# VoiceInk++ learnings

Compound verified project knowledge for Codex and Claude Code. Treat `LEARNINGS.md` as the dated evidence index, `FAILED_APPROACHES.md` as the mandatory negative-evidence ledger, and this skill as the reusable procedure that maintains both.

## Continuous improvement

Improve this skill as part of using it. Whenever use, debugging, feature work, deployment, investigation, or user feedback produces a durable verified finding, update `LEARNINGS.md` during the same task without waiting for a separate request. When real evidence rejects a plausible mechanism or exposes a repeated regression trap, also update `FAILED_APPROACHES.md` with the observed result and the narrow condition required before reconsideration. When a finding changes how future agents should gather, interpret, validate, or preserve evidence, update this skill's instructions, scripts, tests, or references too. Retest affected behavior and validate the skill before finishing. Preserve reusable evidence; never record guesses, duplicate guidance, secrets, credentials, or transient runtime state.

## Start with prior evidence

1. Resolve the repository root and read its `AGENTS.md`.
2. Read the newest relevant entries in `LEARNINGS.md` and the matching rejected/superseded sections in `FAILED_APPROACHES.md`. For either mouse button, recording destinations, focus restoration, recorder UI, paste, or auto-send, read `TERMINOLOGY.md` and `RECORDING_DESTINATIONS.md` completely. For background insertion, auto-send, or verification, also read `BACKGROUND_DELIVERY_TEST_MATRIX.md`.
3. Search with one to three symptom or subsystem terms:

   ```sh
   bash .agents/skills/learnings/scripts/check.sh "<keyword>"
   ```

4. Inspect named accepted commits and current tests when a learning points to them. If `FAILED_APPROACHES.md` names the proposed mechanism, stop unless new evidence changes the exact recorded failure condition; write that distinction down before experimenting. Preserve verified contracts instead of recreating remembered behavior.
5. For a remembered historical rollback, never choose by version proximity or a version label alone. Correlate Ethan's timestamped acceptance/failure message with the immediately preceding verified install/restart, then require the artifact's build, CDHash or executable checksum, and delivery architecture to agree. Early build 203 was reused for materially different binaries, so its label is not an identity.
6. State any relevant prior constraint before making a risky change.

For upstream work, read `UPDATING.md` and treat upstream as a feature source, never a branch to merge wholesale. Audit in a disposable clone/worktree, obtain Ethan's approval for one user-visible feature, and manually port only that feature while preserving VoiceInk++'s destination, delivery, vocabulary, identity, and release guards.

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
| Primary normal stop, then Next button while the newest result is still transcribing and before post-processing | Second chance: replace that newest pending session's input and complete Mode atomically (`focusedDuringTranscription`) |

First check the runtime delivery-engine flag `VIPPExactInputDeliveryEnabled`. When it
is false, VoiceInk++ deliberately uses base VoiceInk compatibility delivery: Primary
follows the current Mode and keyboard-focused input, no exact input is captured at start
or stop, and Next Track passes through. Keep the recorder's second destination slot
visible as a warning in this state; returning a stale target would lie about ownership,
while hiding the slot would conceal that the Next/exact route is unavailable. The flag
is an escape hatch around delivery, not a fourth route, and must never delete or merge
the exact three-route contract.

Preserve the recorder's action feedback mapping on every mirrored panel: a primary normal stop pulses the left/current-focus app icon; Next while recording and a successful second-chance Next latch pulse the right/locked-destination icon. Failed retargets and pass-through media presses do not pulse. Keep the Reduce Motion variant non-scaling.

Treat transient action feedback and persistent destination ownership as separate UI state. After any stop route freezes a real exact input, keep only the stable right/locked-destination icon outlined through transcription and delivery (including compact background chips) until success, visible failure, or cancellation. Do not outline a recording-time preview, missing target, or app-only no-caret fallback until exact-composer promotion succeeds. Never persistently outline the live left/current-focus icon; it may change after the route decision and cannot represent session ownership.

For delivery, never use process-targeted Command-V or Return and never activate a saved target that is currently backgrounded. Exact background text may use bounded Unicode only inside the exact-input session that resolves the saved window/editor (or meets Telegram's allowlisted retained-internal-focus fallback with readable matching chat context), prepares one activation-state session when needed, verifies exact insertion, and proves from immediate pre/post Accessibility focus that the target did not take control. For long text, run the expensive context resolver before, at bounded periodic checkpoints, and after typing; use only a fast exact PID/window/editor/focus boundary per chunk. Codex/ChatGPT, Chrome/Chromium, and Notion may reuse renderer wrappers: empty context requires a revalidated semantic task/document scope; a stable or UUID-shaped editor/window identifier alone never proves the selected task. Telegram always requires readable matching context. Auto-send must use a semantic AX action, an ordinary HID key only while the exact target already owns system keyboard focus, or a host-native exact-session API such as Terminal/iTerm scripting. Use the same non-activating route when the target app is frontmost but Ethan is working in a different input in that app; that case permits verified `AXSelectedText` and a proven semantic action only, never an internal-focus rewrite or generic whole-`AXValue` replacement. Rich/contenteditable surfaces such as Notion fail closed when selected-text insertion is unavailable. Ethan may switch between other apps while delivery runs; do not require his starting foreground PID to stay frozen. At recording start only, an already-active app/window/task with no caret may make one bounded in-place focus attempt on exactly one proven main composer; capture exact identity independently, revalidate immediately before the single `AXFocused = true`, and never perform a compensating focus rewrite.

Verify auto-send by surface. A chat composer must clear/reset; a newline or other non-empty mutation is `modifiedWithoutSubmit` and must not be retried. Terminal/iTerm must capture a stable window-ID plus TTY/session-ID pair and bind text plus Return to that same pair in one host-native operation—never PID/AX text followed by a native newline. Bind the asynchronous identity lookup to the decision moment with the selected-tab AX control and a readable AX/native content fingerprint whenever sibling tabs/panes exist; wrapper/window equality alone is insufficient. Apple Terminal paste-only fails closed because it has no proven exact-session no-Return API; iTerm may use native `newline false`. Verify native contents before/after for the inserted text and prompt-tail transition; mutable titles are not identities and scrollback/full-screen rewrites are indeterminate and never retried. Run host scripting off MainActor with a hard timeout and kill the helper at expiry. Send AppleScript source through stdin and return captured terminal buffers through bounded length-framed stdout; never expose transcripts or scrollback in argv, environment values, or an interpolated shell command. Generic editors can verify an exact readable change but cannot use it to justify a retry. Only a readable unchanged OpenAI composer that still owns exact system keyboard focus may receive one normal-HID Return retry. Restrict semantic Send to proven chat bundles and the nearest shared composer container, and normally require an explicit Send label. Never infer Send from an arbitrary unlabelled OpenAI square because the same slot can be Stop; the sole exception is an exact audited ChatGPT app/version/build/Chromium tuple whose unique idle button is revalidated as still unlabelled, enabled, same-window, and pressable at the irreversible boundary. Treat unreadable post-state as indeterminate telemetry rather than a proven success or a visible false-failure error. Rendered-message echo remains optional telemetry. Never treat AX/event acceptance alone as success.

Keep Ethan's required compatibility set explicit: Codex desktop, ChatGPT's Option-Space floating window, Claude Code in its Terminal/iTerm/Ghostty/editor host, Telegram, Google Chrome, and a selected card/editor in Notion (`notion.id`). Use disposable inputs and the scenarios in `BACKGROUND_DELIVERY_TEST_MATRIX.md`; for Notion, create/use a disposable card or page and never mutate Ethan's current to-do board. Mark unavailable surfaces **not tested** instead of extrapolating from another app. Telegram can reuse an editor wrapper across chats and may hide its AX tree while backgrounded; retain its captured editor only when independently readable chat-context anchors still match, the exact structure matches, and Telegram reports that editor/window as its own internal focus. Hidden or mismatched context fails closed.

For Telegram compatibility work, read [references/telegram-live-test.md](references/telegram-live-test.md) before touching its UI or interpreting a trace. Use `scripts/live-delivery-trace.sh start|status|show|stop` instead of rebuilding an ad-hoc unified-log pipeline; the script keeps only allowlisted destination/delivery metadata—including bounded semantic-Send candidate/readiness diagnostics and foreground `CursorPaster` Cmd-V cancellation/setup failures—and manages its child log stream so repeated tests do not leave orphans. Its detached runner must remain launchd-owned: a plain background or `nohup` child is reaped when Codex's bounded command shell exits and can silently leave the physical test untraced.

Treat a UI-automation denial as a safety boundary, not an invitation to recreate the blocked tool with ad-hoc Accessibility mutations against Ethan's live app. In particular, never repeatedly post ChatGPT/Codex private activation-state events merely to inspect its background AX tree: this can destabilize keyboard focus and restart the app. Prefer existing VoiceInk++ traces, offline bundle inspection, or a disposable app/task. Distinguish `/Applications/ChatGPT.app` from `/Applications/Codex.app` by saved bundle URL/executable because both may report `com.openai.codex`. A unit test, AX success code, or mocked Send button never proves ChatGPT submission; require the actual intended app surface to clear/reset without focus theft, and compare recorder start/stop latency with the accepted baseline before release.

Do not treat Codex Computer Use's visible agent cursor as proof that macOS offers a second independent mouse or keyboard-focus channel. The installed helper's `VirtualCursor` is presentation and targeting state. `SyntheticAppFocusEnforcer` and `SystemFocusStealPreventer` are OpenAI implementation types, not documented Apple APIs or reusable system classes: public Apple primitives beneath the pattern include AX focus/main setters, AX actions, and `CGEventPostToPid`, while CPS focus-state notifications are undocumented. The native helper combines those mechanisms with refetchable AX trees and PID/window-addressed synthesized input. Its bundled `@oai/sky` client is absent from the public npm registry, documents only OpenAI-internal publication, requires the trusted Codex `nodeRepl` runtime, and talks to a peer-code-signature-authorizing local service; never extract, redistribute, or runtime-depend on it. The public Responses API `computer` tool supplies model-authored actions but still requires the caller's own browser/desktop execution harness, so it is not an alternative route to the local driver. Public MIT implementations such as `trycua/cua` and its independently maintained Swift snapshot/rebrand `tropeai/trope-cua` are audit sources, not OpenAI code or drop-in proof: isolate any borrowed mechanism, retain licensing, enumerate private SkyLight/SLPS dependencies, and validate the exact delayed VoiceInk++ route. AXSwift and AXorcist are wrappers, not the full background-focus stack. That broad immediate-action architecture is useful evidence, not runtime proof for VoiceInk++. Preserve VoiceInk++'s narrower delayed exact-input contract and live-test its own target: Computer Use forbids `com.openai.codex`, so never bypass that policy with custom live probes.

## Record only durable verified findings

Record a learning when evidence establishes something likely to affect future work, including a corrected semantic, reproducible failure and root cause, environment constraint, safety boundary, accepted terminology, or reliable validation signal.

Do not record speculation, generic progress, duplicate knowledge, credentials, secrets, raw private configuration, or transient runtime state such as a one-off PID. Commit identities are appropriate when they anchor an accepted implementation.

Keep each field concise but specific enough to prevent rediscovery. Name the symptom, proven cause, actual change, implementation commit, and regression guard. Use logs or user confirmation as evidence only after the behavior is genuinely observed.

## Finish the learning loop

1. Verify the affected behavior with the strongest safe evidence. Background-delivery work must use the required app matrix and preserve `verification=verified`, the exact insertion route, and a safe target/frontmost boundary in the trace; message echo alone is never proof. Keep adjacent behavioral-intent comments current for every non-obvious route, identity check, fallback, and safety boundary; comments should explain the invariant and reason rather than narrate syntax. Use the normal Xcode test action as the canonical test path. If TestManager stalls without executing tests, preserve the stalled-run evidence, run the already-built unit-test bundle directly with `xcrun xctest` and the app/framework library paths as a bounded fallback, and confirm the output names every expected test; compilation or XCTest's zero-test preamble is not execution. Recover and retry the canonical path when possible, and never enable Developer Mode without Ethan's direction. For every native release, increment `CURRENT_PROJECT_VERSION`, then follow the Mac Mini build, signed-install, five-second restart warning, visible recorder-version label, and live-trace contract in `AGENTS.md`. Transfer a signed `.app` from the Mini as an archive stream (or another bundle-preserving archive), never raw recursive `scp`; reject the transfer until local bundle version, deep/strict signature, CDHash, and outer Automation entitlement all verify. If a post-build signer replaces the outer app signature, it must explicitly reapply `VoiceInk/VoiceInk.local.entitlements`; verify deep/strict signing and the outer `com.apple.security.automation.apple-events = true` entitlement before accepting Terminal/iTerm support. A source edit is not a shipped VoiceInk++ change until that uniquely numbered signed build is installed and running.
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
