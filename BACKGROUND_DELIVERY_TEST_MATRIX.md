# VoiceInk++ background delivery test matrix

This is the permanent compatibility matrix for Ethan's main destinations. Read it and
[FAILED_APPROACHES.md](FAILED_APPROACHES.md) before changing exact-input capture, background
insertion, auto-send, focus restoration, or verification.

**Current runtime state verified 2026-07-19:** signed VoiceInk++ v2.0.236 is installed and running as
PID 3326 with CDHash `5074d3bbb946ee5815ee10bd043e696db73255e7`. Its accepted trace proves only
the uninterrupted Primary current-input compatibility route from `fb3ead7`: live-caret guarded
Command-V followed immediately by one ordinary HID Return. It does not prove either Next route or
exact background Send. The installed bundle also contains uncommitted v2.0.235/SkyLight source, so
the complete binary is not reproducible from `fb3ead7` or the branch HEAD and must not become a
source baseline.

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

## Safety invariant

When a saved target is not frontmost, VoiceInk++ must not activate it. Ethan may move between other
apps while transcription and delivery run. A passing trace proves the exact saved input changed and
the target app did not become frontmost; it does not require Ethan's foreground PID to stay frozen.
Never use background Command-V. Never infer success from an AX/CGEvent return code alone.

If Ethan is using input B in the same frontmost app while input A is latched, VoiceInk++ must not
rewrite the app's internal focus to A. That route may use only direct Accessibility insertion and a
proven semantic action. Immediate pre/post system focus must remain on B.

## Required destinations

| Destination | Saved input | Preferred non-activating insertion | Auto-send chain | Verification | Audited live evidence through v2.0.236 |
| --- | --- | --- | --- | --- | --- |
| Codex desktop | Exact Codex task composer | Targeted Unicode after verified internal window/editor focus | Explicit nearby semantic Send only; ordinary HID Return only while the exact composer owns system keyboard focus, with at most one retry after a readable unchanged composer | Exact composer clears/resets; rendered-message echo is optional telemetry | Exact capture/insertion succeeded in bounded v206/v231–234 runs; v223/v224 capture failed; v236 Primary foreground compatibility is accepted; exact background and both Next routes remain unverified |
| ChatGPT Option-Space floating window | Exact `AXTextArea` in the compact non-activating window | Targeted Unicode without synthetic activation only while it still owns keyboard focus | Explicitly labelled nearby Send or ordinary HID Return while exact system focus remains; one retry only after readable unchanged text | Floating composer clears/resets without the app becoming frontmost | Exact insertion repeatedly worked; Return produced newline, no-op, or unreadable state, and v233 `AXPress` left the composer unchanged; background Send failed/unaccepted |
| Claude Code/Codex CLI in Apple Terminal or iTerm | Exact terminal input plus captured window-ID + TTY/session-ID pair | Host-native text addressed to that exact pair; never PID-targeted Unicode | Text + Return in one exact-session native operation; Apple Terminal paste-only unsupported, iTerm supports `newline false`; no title routing, activation, or retry | Native contents prove the inserted segment at the expected prompt boundary plus prompt-tail transition; host never activated | Architecture/tests existed, but no accepted final exact live trace established the complete route; unverified |
| Claude Code/Codex CLI in Ghostty, Warp, VS Code, or Cursor | Exact host input when uniquely resolvable | Targeted Unicode after exact host/window verification | None in the background; fail visibly without focusing the host | Exact readable insertion only; no claim of background submission | No accepted host-by-host final trace; unverified |
| Telegram | Exact Telegram message `AXTextArea` plus readable chat-context anchors | `AXSelectedText`; targeted Unicode only after a proven AX no-op | Explicit nearby or exact retained labelled Send; ordinary HID Return only if the exact composer already owns system keyboard focus; no retry | Composer clears/resets; empty/hidden/mismatched context fails closed because a reused editor wrapper cannot identify a chat | v209 failed before mutation; later work never produced strong final background paste-and-Send proof; failed/unverified |
| Google Chrome | Exact editable element plus saved window/tab/document fingerprint | Targeted Unicode | None in the background; no generic Send discovery or Return | Exact readable input change while saved context still matches | No safe disposable target in Ethan's personal Chrome session was completed; not tested |
| Notion (`notion.id`) | Exact selected card title/property/block editor plus its board/page context | Targeted Unicode; `AXSelectedText` only for same-app/different-editor, otherwise fail closed—never reconstruct/set the whole rich-editor `AXValue` | None in the background; no generic Send discovery or Return | Exact card/editor changes while a sibling card/editor and current board remain untouched | Required selected-card/editor scenario was never safely live-tested; not tested |

Ethan's normal setup deliberately disables auto-send in Chrome. Chrome remains in this matrix because
exact background paste must be validated independently; do not enable a scratch Return Mode until a
safe Chrome-specific background submit route actually exists.

## Required live scenario

Use a disposable task/chat/tab/terminal/card session; never inject test text into Ethan's active work.
For Notion, create or open a disposable test card/page and never operate on Ethan's current to-do board.
For each destination that is available:

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
