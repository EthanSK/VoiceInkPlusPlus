# VoiceInk++ background delivery test matrix

This is the permanent compatibility matrix for Ethan's main destinations. Read it and
[FAILED_APPROACHES.md](FAILED_APPROACHES.md) before changing exact-input capture, background
insertion, auto-send, focus restoration, or verification.

**Current installed state verified 2026-08-04:** signed v2.0.282 is installed from the combined
source through `d34737e`, including passive recording-start composer capture in `2cfa3a1`, recording
input-device metadata in `34d8e32`/`2246ee7`, and the exact `self.recorder` structural-test
correction in `09e5249`. The Mini's canonical Xcode action rebuilt the candidate but stalled in
TestManager before naming tests; a fresh direct `xcrun xctest` fallback then named and passed all
121 tests in 3 suites. The installed executable SHA-256 is
`e5904ca57df3df7f5396a30e201929ccbddfcb9f8aa388f84ce8f98850253990`, its CDHash is
`d03b0048722151e4e887883590e7a196229ffa62`, deep/strict signing and outer Automation/audio-input
entitlements verify, exact delivery is enabled, v2.0.280 is preserved as rollback, and
`/Applications/VoiceInk.app` remains untouched. The required physical acceptance is still pending:
Primary from a focused ChatGPT annotation/secondary field must leave the caret and paste there, and
a recording-time Next press must still use its passively saved exact destination without stealing
system focus.

**Current installed state verified 2026-08-04:** signed v2.0.280 at implementation commit `00fa934`
plus structural-test correction `3952485` is installed but has not yet been physically accepted.
The Mini's canonical Xcode action rebuilt the candidate but stalled in TestManager before naming
tests; the fresh direct `xcrun xctest` fallback then named and passed all 116 tests in 2 suites.
The candidate allows an older valid Primary result to paste while a newer recording is active,
suppresses the older Return, and leaves only the eventual Primary cohort tail eligible to send.
Exact Next, command/response, raw/skip, assistant, and other non-cohort side effects still wait for
capture to end. The installed executable SHA-256 is
`6af320ae7855682b98b07f4bf3355d1fb5be8b28c2e33e71f9bb9c86f1d478d7`, its CDHash is
`aabb54d8f4d2c8ea989622932fb10d8b856c6072`, deep/strict signing and outer Automation/audio-input
entitlements verify, exact delivery is enabled, and v2.0.279 is preserved as rollback. Physical
A-stop/B-start and ChatGPT background-Next acceptance remain required.

The preceding signed v2.0.279 build produced a correlated ChatGPT 26.727.51351 build 6119
`recordingStart` Next run captured the exact composer, kept Chrome frontmost, and finalized 483
characters, but failed before insertion because ordinary background preparation could not re-resolve
the saved element/window. v2.0.280 adds only a tuple-pinned preparation exception for that audited
ChatGPT build: it may open one targeted-input activation session before resolving, then must reprove
the same task/window/editor anchors, ChatGPT-internal focus, and unrelated macOS foreground. This
candidate path remains unaccepted until a physical trace and visible submission agree.

The v2.0.279 rapid-recording reproduction also separates queue policy from provider output. Its old
exclusive delivery barrier deferred Primary A until recording B ended. That particular A could not
paste afterward either: GPT Live committed zero characters, completed-WAV fallback returned no usable
text, no realtime draft existed, and the retained 16.9-second WAV was quiet (mean -49 dB, maximum
-31.4 dB). The candidate policy fixes the avoidable deferral for valid results; it cannot manufacture
text from an empty provider result.

**Current runtime state verified 2026-07-24:** signed VoiceInk++ v2.0.259 is installed from commit
`049efc7` with CDHash `b791737a00d593fdb8a76ac67fce5ed74149824f` and exact delivery
enabled. Its fresh Mini bundle named and passed all 46 unit tests through direct `xcrun xctest`
after the canonical Xcode action built and stalled in TestManager; deep/strict signing and outer
Automation verify, and `/Applications/VoiceInk.app` was untouched. v2.0.259 changes only the
ChatGPT-hosted Codex audited tuple list for ChatGPT 26.721.31836 build 5828 / Chromium
150.0.7871.128, plus exact wrong-build and wrong-Chromium rejection tests. It preserves v2.0.258's
bounded read-only system-focus retry, v2.0.257's generic 100 ms Primary paste-to-Return settle, and
every non-Codex route.

Ethan physically accepted v2.0.259's background Codex `recordingStart` route: while Chrome remained
frontmost, the trace verified exact insertion, resolved the FooterActions Send control twice at the
irreversible boundary, issued exactly one `skyLightTargetedSendClick`, and the dictated message
visibly arrived in Codex. The composer wrapper became unreadable after the action, so telemetry
correctly remained indeterminate and did not retry or show a false failure; visible submission is
part of this acceptance. The distinct Codex `focusedDuringTranscription` second-chance route,
the current Primary physical regression, and the context-menu check remain pending.

Ethan also physically accepted v2.0.259's Telegram `recordingStart` route in Saved Messages. While
OBS remained frontmost, the trace revalidated the exact Telegram composer through the pinned
privacy-bounded visual chat identity, verified background insertion, issued exactly one
`telegramTargetedHIDReturn`, and verified the composer cleared (`verification=verifiedCleared`).
This current-build acceptance does not extrapolate to Telegram `focusedDuringTranscription` or
wrong-chat rejection; both still require separate v2.0.259 runs.

Signed v2.0.243 from reproducible commit `5475ef2` with CDHash
`5be83c4f545772472a836306d64eded1253f1c63` remains the rollback checkpoint. It reconstructs the
accepted v2.0.238 Codex source at `bfef0e4`, adding only the audited ChatGPT 26.715.52143 build-5591
tuple, tuple tests, and the unique build number; later Telegram, Terminal, and Claude delivery work is
absent. **v2.0.243 is a historical checkpoint because its then-current Primary `focusedAtStop`
compatibility route worked. Its continuity/fallback architecture is not the current Primary contract,
because an app switch could fall through into app-specific exact delivery. Neither Next/latch route
was accepted there.** A correlated Codex `focusedDuringTranscription`
run captured and changed the exact background composer, resolved FooterActions Send, issued one action,
and preserved VS Code foreground, but the visible message did not submit; unreadable post-state was
indeterminate, not success. Telegram `focusedDuringTranscription` and `recordingStart` attempts both
failed before insertion because the saved Telegram window could not be re-resolved in the background.
Future Telegram work must remain isolated from the accepted Primary path, and v2.0.243 must stay
available as its rollback checkpoint.

The earlier signed v2.0.236 checkpoint proved only the uninterrupted Primary current-input compatibility
route from `fb3ead7`: live-caret guarded Command-V followed immediately by one ordinary HID Return. Its
installed bundle also contained uncommitted v2.0.235/SkyLight source, so that complete binary is not a
reproducible source baseline.

The byte-preserved signed v2.0.206 remains the accepted exact-location rollback floor (CDHash
`a88d4bbe7ab463ba5a1f62509757b349d98d7f97`, source anchor `96e494e`, restored by `b2aeaa2`). Ethan
confirmed bounded background Codex insertion/Return with a false verification warning and a separate
Option-Space paste-without-submit failure. That is narrow evidence for saved-location insertion, not
universal app or Return compatibility.

The earlier v2.0.203 artifact (CDHash `715d9686a428e9c7d9a9064236f21e942901bc2b`, commit
`1eabb1b`) is the first build Ethan repeatedly celebrated for all three destination routes, including
second chance. It activated/restored the target app for ordinary foreground paste and Return before
restoring the later workspace, so it is not the matching rollback for a request specifically about
non-frontmost/background Codex delivery. v2.0.216 had one later partial Enter-with-false-warning
observation, but session chronology does not make it the requested historical floor.

v2.0.224 is rejected live evidence, despite all 56 named Mac Mini tests passing: it captured the real
ChatGPT-hosted Codex `AXTextArea`, then rejected it because the bounded context fingerprint was still
incomplete, leaving the locked slot as a warning and failing exact delivery. The description-versus-
placeholder relaxation therefore did not repair the physical surface. Its signed bundle is preserved
as a rollback artifact, and native source was not destructively rewound. v2.0.207/v2.0.208 remain
rejected evidence.

## Primary current-input regression gate

Primary/toggle is deliberately outside the app-specific matrix below. It must always use base
VoiceInk current-input delivery, even while Exact Saved-Input Delivery is enabled and even in an app
with a hard-coded latch path such as Telegram. For every app-specific latch change, run a foreground
Primary stop before and after the change and require all of:

```text
destination=primaryCurrentInput targetCaptured=false deliveryPolicy=baseCurrentInput
pipeline: about to DELIVER ... destination=primaryCurrentInput
paste: primary current-input compatibility selected ... appSpecificDelivery=false
paste: primary current-input command completed result=commandPosted
paste: primary current-input HID auto-send issued=true verification=notRequired settleMs=100
```

The same delivery must contain no exact-input preparation/resolution, Telegram identity, OpenAI Send,
Terminal native-session, semantic action, read-back, verification, retry, or exact-delivery fallback
line. The intended system-focused input must receive and, when the current Mode enables it, submit the
text. This regression gate is required even when the current task only changes one of the Next routes.

## Exact Next-route safety invariant

The rules in this section and the app table apply only after the physical Next button selected
`recordingStart` or `focusedDuringTranscription`. When a saved target is not frontmost, VoiceInk++
must not activate it. Ethan may move between other apps while transcription and delivery run. A
passing trace proves the exact saved input changed and the target app did not become frontmost; it
does not require Ethan's foreground PID to stay frozen. Never use background Command-V. Never infer
success from an AX/CGEvent return code alone.

If Ethan is using input B in the same frontmost app while input A is latched, VoiceInk++ must not
rewrite the app's internal focus to A. That route may use only direct Accessibility insertion and a
proven semantic action. Immediate pre/post system focus must remain on B.

## Required exact Next destinations

| Destination | Saved input | Preferred non-activating insertion | Auto-send chain | Verification | Current audited live evidence |
| --- | --- | --- | --- | --- | --- |
| Codex desktop | Exact Codex task composer | Targeted Unicode after verified internal window/editor focus | Explicit nearby semantic Send only; ordinary HID Return only while the exact composer owns system keyboard focus, with at most one retry after a readable unchanged composer | Exact composer clears/resets; rendered-message echo is optional telemetry; one issued action followed by an unreadable replacement remains indeterminate and requires matching user-visible confirmation | v259 physically passed `recordingStart` on ChatGPT build 5828: exact background insertion plus one audited FooterActions Send action while Chrome remained frontmost, followed by the dictated message arriving here. AX post-state was unreadable/indeterminate, so the matching visible result is part of acceptance. `focusedDuringTranscription` remains pending |
| ChatGPT Option-Space floating window | Exact `AXTextArea` in the compact non-activating window | Targeted Unicode without synthetic activation only while it still owns keyboard focus | Explicitly labelled nearby Send or ordinary HID Return while exact system focus remains; one retry only after readable unchanged text | Floating composer clears/resets without the app becoming frontmost | Exact insertion repeatedly worked; Return produced newline, no-op, or unreadable state, and v233 `AXPress` left the composer unchanged; background Send failed/unaccepted |
| Claude Code/Codex CLI in Apple Terminal or iTerm | Exact terminal input plus captured window-ID + TTY/session-ID pair | Host-native text addressed to that exact pair; never PID-targeted Unicode | Text + Return in one exact-session native operation; Apple Terminal paste-only unsupported, iTerm supports `newline false`; no title routing, activation, or retry | Native contents prove the inserted segment at the expected prompt boundary plus prompt-tail transition; host never activated | Architecture/tests existed, but no accepted final exact live trace established the complete route; unverified |
| Claude Code/Codex CLI in Ghostty, Warp, VS Code, or Cursor | Exact host input when uniquely resolvable | Targeted Unicode after exact host/window verification | None in the background; fail visibly without focusing the host | Exact readable insertion only; no claim of background submission | No accepted host-by-host final trace; unverified |
| Telegram | Exact Telegram message `AXTextArea` plus readable AX chat anchors, or an audited app/version/build/layout with a stable SHA-256 digest of the selected-chat avatar/title row | One-shot `AXSelectedText`; bounded targeted Unicode only after full visual/AX identity revalidation when selected-text insertion is unavailable | On pinned Telegram 12.9/282526 only: fresh exact-chat revalidation, then one `telegramTargetedHIDReturn` sequence (HID source, modifier boundary, Return down/up, live modifier restoration); no retry or generic fallback | Composer clears/resets; exact structure/internal focus plus matching anchors or a freshly matching visual digest; missing Screen Recording permission, blank/protected capture, tuple/layout drift, or any identity mismatch fails closed | v259 physically passed `recordingStart` in Saved Messages: exact visual chat identity, insertion, one targeted Return, verified composer clear, and OBS remained frontmost. v245 remains the earlier evidence for both Next routes. v259 `focusedDuringTranscription`, Primary isolation, and wrong-chat rejection remain to be rerun |
| Google Chrome | Exact editable element plus saved window/tab/document fingerprint | Targeted Unicode | None in the background; no generic Send discovery or Return | Exact readable input change while saved context still matches | No safe disposable target in Ethan's personal Chrome session was completed; not tested |
| Notion (`notion.id`) | Exact selected card title/property/block editor plus its board/page context | Targeted Unicode; `AXSelectedText` only for same-app/different-editor, otherwise fail closed—never reconstruct/set the whole rich-editor `AXValue` | None in the background; no generic Send discovery or Return | Exact card/editor changes while a sibling card/editor and current board remain untouched | Required selected-card/editor scenario was never safely live-tested; not tested |

Ethan's normal setup deliberately disables auto-send in Chrome. Chrome remains in this matrix because
exact background paste must be validated independently; do not enable a scratch Return Mode until a
safe Chrome-specific background submit route actually exists.

## Required live scenario

Use a disposable task/chat/tab/terminal/card session; never inject test text into Ethan's active work.
For Notion, create or open a disposable test card/page and never operate on Ethan's current to-do board.
For each exact Next destination that is available:

1. Focus the disposable exact input and start recording.
2. Exercise the relevant route, including at least one **second chance** run:
   primary normal stop → transcription begins → focus the destination → press Next → move to
   a different app before delivery.
3. Keep using another app while delivery finishes. VoiceInk++ must not bring the destination forward.
4. Confirm only the saved input changed, auto-send happened exactly once when enabled, and no sibling
   input/window/tab received text.
5. Preserve a trace containing the destination, insertion resolution/route, auto-send route,
   `verification=verified`, surface, target PID, start foreground PID, and final foreground PID.

If a destination is unavailable or a safe disposable session cannot be created, record it as
**not tested** rather than claiming support from event-post success or a different app's behavior.
