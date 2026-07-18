# VoiceInk++ agent instructions

These repository-specific rules are mandatory for every future agent working on recording destinations, mouse-button handling, focus restoration, recorder UI, paste delivery, or auto-send.

## Repository learnings contract

- Use the public `.agents/skills/learnings` skill automatically before fixes, regressions, fragile workflow changes, destination/delivery work, or investigations that resemble an earlier failure.
- After any feature, fix, deployment, or investigation, add every durable verified project lesson to `LEARNINGS.md` during the same task. Do not record guesses, secrets, duplicate knowledge, or transient runtime state.
- When a lesson changes the reusable workflow, terminology, safety rules, or validation procedure, update the learnings skill itself, retest its affected scripts/behavior, and validate the skill before finishing.
- Codex discovers the canonical skill in `.agents/skills`; Claude Code uses the same folder through `.claude/skills/learnings`. Never maintain divergent copies.

## Behavioral-intent comments

- Preserve the reason for VoiceInk++'s deliberately unusual behavior in the code beside the branch or safety check that enforces it. In particular, comments must distinguish all three destination routes, explain why input plus Mode/auto-send are atomic per-session state, and document why exact-input identity, non-activating delivery, surface-specific submission, one-shot fallbacks, and fail-closed checks exist.
- Update those comments whenever behavior changes. Do not remove a constraint as "redundant," merge routes, or replace a bounded app-specific path with a generic shortcut unless the adjacent comment and accepted contract prove that simplification safe.
- Comment intent and invariants, not obvious syntax. `TERMINOLOGY.md`, `RECORDING_DESTINATIONS.md`, and `BACKGROUND_DELIVERY_TEST_MATRIX.md` are the long-form source of truth; code comments must make the relevant intent visible without requiring a future agent to guess which rule applies.

## Canonical mouse terminology

Read `TERMINOLOGY.md` before interpreting button names. The **primary button** is also Ethan's normal button, thumb button, toggle button, recording button, “same button,” and historical G5 button. Its first press starts recording; pressing that same button again performs a normal stop into only the exact input focused at stop (`focusedAtStop`). A primary normal stop must never reuse or fall back to `recordingStart`; capture or verification failure must remain visible and safe.

The separate **Next button** is also the forward button, secondary button, Next Track control, latch button, and retarget button. In this repository, unqualified **toggle** means the primary button's start/stop lifecycle. It never means toggling a destination.

Ethan's live G502 X LIGHTSPEED `Desktop: Default` profile was sanity-checked on 2026-07-14: the upper side thumb control runs the `speech to text` Shift-Control-Option macro and is the primary button; a different control is explicitly labeled `Next Track` and is the Next button. G HUB's separately labeled `Mouse Button 4` and `Mouse Button 5` are not aliases for that Next control. Never infer “forward button” means raw Mouse Button 5.

## Non-negotiable Next button contract

The runtime feature flag `VIPPExactInputDeliveryEnabled` selects the delivery engine. While false,
VoiceInk++ deliberately behaves like base VoiceInk: Primary output follows only the keyboard-focused
input at delivery, the current app's Mode supplies optional Return, and Next Track passes through.
The second destination slot remains visible as a warning because no exact input is owned; it must
not disappear or imply a saved app that compatibility delivery will ignore. This escape hatch is
not a fourth route and must not delete or reinterpret the exact engine below. While true, all three
routes below apply.

Use **Next button** as the preferred user-facing term. **Next Track**, **Next Track media key/action/event**, **secondary mouse button**, **latch button**, and **retarget button** are aliases for the same physical control or its macOS event. They do not create additional routes. Use **second chance** only for route 3 below, and never describe it as a toggle.

VoiceInk++ has three distinct one-click destination routes. Do not merge them, reinterpret them as a toggle, or infer one from another:

1. **Primary button again while recording:** normal stop and save only the exact editable input focused at stop (`focusedAtStop`). Never fall back to the recording-start input.
2. **Next Track while recording:** stop recording and save the input captured at recording start (`recordingStart`), with the documented safe application fallback for Electron/Chromium.
3. **Next Track after a normal stop, while the newest result is still transcribing and before post-processing begins:** this is Ethan's **second chance**. Replace that pending session's destination with the exact editable input focused now (`focusedDuringTranscription`). It does not stop anything, toggle anything, or release the target. Never skip an ineligible newer pending result to retarget an older session.

The canonical second-chance scenario is:

> normal stop → transcription begins → focus a new editable input → press Next Track once → optionally move to another app → finished text pastes into the newly selected input and uses that input app's configured auto-send → VoiceInk++ restores the later workspace when applicable.

The saved input and its target app's complete Mode are one atomic, per-session decision. Never re-read formatting, enhancement, output, or auto-send solely from the globally current Mode: Ethan may already be using another app by then. `RecordingPasteTarget` must continue to carry both values, and `TranscriptionPipeline` must freeze the latest target after transcription/trigger-word selection but before any destination-dependent formatting or enhancement begins. One-shot raw/skip mode remains the intentional exception and must force no auto-send.

## UI contract

- Recorder panels appear on every connected monitor.
- Do not show routine “Recording” text above the waveform; visible text is reserved for real warnings/errors.
- Mode icon/emoji is left of the waveform.
- The right side has two separate icons: current focused app first, then the per-session locked destination.
- Keep both icon slots visible for every active session. When exact delivery is disabled or capture genuinely fails, the second slot shows the warning icon; never hide the slot merely to conceal a missing destination.
- The locked icon remains visible through transcription and changes immediately after a successful second-chance retarget. Do not replace that visual confirmation with a success toast.
- Destination actions use the per-session neon confirmation pulse on every mirrored panel: a primary-button normal stop pulses the left/current-focus icon; Next while recording and a successful second-chance Next latch pulse the right/locked-destination icon. Failed retargets and pass-through media presses do not pulse. Preserve the non-scaling Reduce Motion variant.
- The pulse is transient action feedback. Once any stop route has frozen a real exact input, the stable right/locked-destination icon stays outlined until that session succeeds, visibly fails, or is cancelled. A recording-time preview, missing target, and app-only no-caret fallback remain unoutlined until exact-composer promotion succeeds. The live left/current-focus icon is never persistently outlined; it can change after the decision and would misrepresent ownership.

## Delivery safety

- Never use process-targeted Command-V or Return. macOS can accept either event while Electron/VS Code ignores it. Exact background text may use bounded Unicode events only inside one verified internal activation-state session; auto-send must instead use a semantic AX action, a normal HID key only when the exact saved input already owns system keyboard focus, or a host-native exact session API such as Terminal/iTerm scripting.
- At recording start only, when the capture-time app/window/task is already active but no editable input owns the caret, VoiceInk++ may make one bounded in-place focus attempt on exactly one proven main composer. Never activate an app for this convenience. Revalidate the original control immediately before the single `AXFocused = true` setter, capture the replay-safe exact destination independently of whether that optional focus attempt succeeds, and never perform a compensating focus rewrite because it cannot distinguish VoiceInk++'s caret from a newer user click on that composer.
- Never treat `AXConfirm` as generic editor Return.
- Prefer non-activating delivery whenever a saved target is backgrounded. Also use it when the target app is frontmost but Ethan is working in a different input in that same app; that case may use only direct Accessibility insertion and a proven semantic action, never an app-internal focus rewrite. A recording-start application fallback is allowed only when the app exposes one verifiable internally focused editable element; a foreground fallback must be promoted to one frozen exact wrapper before paste, verification, or Return. Never activate a background target as a fallback.
- Same-app/different-input direct insertion may use `AXSelectedText` only where settable and verified. Never reconstruct and set an entire generic `AXValue`; on rich/contenteditable surfaces such as Notion that can flatten formatting or damage block semantics. Fail closed instead.
- Semantic Send is restricted to proven chat bundles and the nearest shared composer container, and normally requires an explicit Send label. Never infer Send from an arbitrary unlabelled OpenAI square: the same slot can become an enabled Stop control while an agent runs, so retained wrapper/geometry is not semantic proof. The only exception is an exact audited ChatGPT app/version/build/Chromium tuple whose unique idle button is revalidated as still unlabelled, enabled, same-window, and pressable at the irreversible boundary.
- Telegram exact-wrapper delivery requires readable matching chat context immediately before every mutation/action. A reused editor/window with empty, hidden, or mismatched context fails closed; internal focus and geometry alone never identify the selected chat.
- Auto-send verification is surface-specific. Chat requires the exact composer to clear/reset; a newline or other non-empty mutation is `modifiedWithoutSubmit`. Terminal/iTerm capture stable window-ID plus TTY/session-ID pairs and must bind transcript text and Return to that same pair in one host-native operation; never insert terminal text by PID/AX and send only the newline natively. The asynchronous native-identity lookup must also preserve the decision-moment selected-tab control plus a readable AX/native content fingerprint when siblings exist, because terminal hosts can reuse editor wrappers. Apple Terminal has no proven exact-session paste-only API, so background paste without Return fails closed; iTerm may use `write ... newline false`. Native contents before/after must prove the inserted text plus prompt-tail line transition; mutable titles are not identities, scrollback/TUI rewrites are indeterminate, and Return is never retried. Generic editors may verify an exact readable change but never use that change to justify a retry. Only a readable unchanged OpenAI composer that still owns exact system keyboard focus may receive one normal-HID Return retry. Unreadable post-state is indeterminate telemetry, not a proven success or a visible false-failure error.
- Terminal/iTerm automation source must enter `osascript` over stdin, and captured terminal contents must return directly through bounded length-framed stdout. Never put a transcript, TTY buffer, or terminal scrollback into process arguments, the environment, or an interpolated `do shell script` command.
- If capture, activation, focus verification, paste creation, or auto-send fails, surface the error; do not silently claim success.
- Ethan may be actively using the Mac. Prefer read-only logs and treat his live focus changes as real input, not contradictory test results.
- If Computer Use or another UI tool refuses ChatGPT/Codex, do not bypass that boundary with repeated custom AX activation-state probes against Ethan's live process. Those probes destabilized keyboard focus and restarted ChatGPT during the rejected v2.0.208 investigation. Use existing traces, offline bundle inspection, or a disposable target, and distinguish `/Applications/ChatGPT.app` from `/Applications/Codex.app` by bundle URL/executable because both can use `com.openai.codex`.

## Required reading and validation

Before changing this behavior, read `TERMINOLOGY.md`, `RECORDING_DESTINATIONS.md`, and the newest relevant entries in `LEARNINGS.md`. The current accepted shipped/runtime baseline is rollback commit `b2aeaa2`, which restores native source exactly to commit `96e494e` and the signed v2.0.206 app. Commit `1eabb1b` (`Fix second-chance transcription retarget auto-send`) remains the accepted behavioral contract for the second-chance route, with `cba45ba` as its earlier retarget foundation. The later toggle experiment `671b4c7` was deliberately reverted by `bed22b7`. The v2.0.207/v2.0.208 delivery rewrite is rejected evidence, not an accepted implementation.

Read `BACKGROUND_DELIVERY_TEST_MATRIX.md` before delivery work. Ethan's required compatibility set is Codex desktop, ChatGPT's Option-Space floating window, Claude Code in its terminal/editor host, Telegram, Google Chrome, and a selected card/editor in Notion (`notion.id`). Use disposable targets for live tests—especially a disposable Notion card/page, never Ethan's current to-do board—and report unavailable surfaces as not tested.

At minimum, preserve the regression test named `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt` and verify a real trace contains all of:

- `paste retarget: ... destination=focusedDuringTranscription targetCaptured=true`
- `pipeline: about to DELIVER ... targetAutoSend=enter destination=focusedDuringTranscription`
- either `paste: background auto-send finished success=true ... verification=verified` for a non-activating exact target or `paste: foreground auto-send finished success=true` for the safe current-input route

Build only on the Mac Mini. Use Xcode's normal test action as the canonical runner. If TestManager stalls without executing tests, preserve that evidence and run the already-built unit-test bundle directly with `xcrun xctest` plus the app/framework library paths; require named per-test output, not compilation or XCTest's zero-test preamble. Recover and retry the canonical runner when possible, and never enable Developer Mode without Ethan's direction.

A source fix is not complete until the signed build is installed at `/Applications/VoiceInkPlusPlus.app`, the user receives the real five-second restart notification, the new PID/CDHash/signature are verified, and `/Applications/VoiceInk.app` remains untouched. Any post-build outer-app re-sign must explicitly reapply `VoiceInk/VoiceInk.local.entitlements`; a generic outer signature can silently strip Automation while nested code still verifies. Before accepting a Terminal/iTerm-capable artifact, require deep/strict verification and confirm the outer signature contains `com.apple.security.automation.apple-events = true`.

Every native VoiceInk++ release must increment `CURRENT_PROJECT_VERSION` before building. The recorder bar displays `v<marketing-version>` on its first row and `.<build-number>` on its second row immediately left of Stop, so the running release can be identified at a glance. Never reuse a build number for a different installed binary, and never describe native source changes as shipped until that numbered, signed build is installed and running.
