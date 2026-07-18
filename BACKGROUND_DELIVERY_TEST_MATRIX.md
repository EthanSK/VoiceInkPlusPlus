# VoiceInk++ background delivery test matrix

This is the permanent compatibility matrix for Ethan's main destinations. Read it before changing
exact-input capture, background insertion, auto-send, focus restoration, or verification.

**Current runtime state (2026-07-19):** signed v2.0.224 is installed with
`VIPPExactInputDeliveryEnabled=true`. It repairs the live ChatGPT-hosted Codex capture rejection by
allowing the description and placeholder to differ only when each independently proves the same
product; ChatGPT/Codex cross-product pairs and arbitrary editors still fail closed. The Mac Mini ran
all 56 named unit tests, but the disposable live Codex capture/background-delivery trace remains the
acceptance gate and must not be inferred from installation or tests. v2.0.223 is preserved as the
immediate operational rollback; v2.0.207/v2.0.208 remain rejected evidence and v2.0.206 remains the
accepted exact-location rollback floor until v2.0.224 passes that physical trace.

## Safety invariant

When a saved target is not frontmost, VoiceInk++ must not activate it. Ethan may move between other
apps while transcription and delivery run. A passing trace proves the exact saved input changed and
the target app did not become frontmost; it does not require Ethan's foreground PID to stay frozen.
Never use background Command-V. Never infer success from an AX/CGEvent return code alone.

If Ethan is using input B in the same frontmost app while input A is latched, VoiceInk++ must not
rewrite the app's internal focus to A. That route may use only direct Accessibility insertion and a
proven semantic action. Immediate pre/post system focus must remain on B.

## Required destinations

| Destination | Saved input | Preferred non-activating insertion | Auto-send chain | Verification | v2.0.207 live status |
| --- | --- | --- | --- | --- | --- |
| Codex desktop | Exact Codex task composer | Targeted Unicode after verified internal window/editor focus | Nearby semantic Send only when the nearest shared composer container exposes an explicit Send label; ordinary HID Return only while the exact composer owns system keyboard focus, with one retry after a readable unchanged composer | Exact composer clears/resets; rendered-message echo is optional telemetry | **Not tested on v2.0.207 (2026-07-15):** no disposable task could be driven without touching Ethan's active Codex workspace |
| ChatGPT Option-Space floating window | Exact `AXTextArea` in the compact non-activating window | Targeted Unicode without synthetic activation only while it still owns keyboard focus | Explicitly labelled nearby Send or ordinary HID Return while exact system focus remains; one retry only after readable unchanged text | Floating composer clears/resets without the app becoming frontmost | **Not tested on v2.0.207 (2026-07-15):** safe UI automation was unavailable |
| Claude Code/Codex CLI in Apple Terminal or iTerm | Exact terminal input plus captured window-ID + TTY/session-ID pair | Host-native text addressed to that exact pair; never PID-targeted Unicode | Text + Return in one exact-session native operation; Apple Terminal paste-only unsupported, iTerm supports `newline false`; no title routing, activation, or retry | Native contents show a new exact transcript occurrence plus prompt-tail line transition; host never activated | **Not tested on v2.0.207 (2026-07-15):** existing terminal sessions were active and safe UI automation was unavailable |
| Claude Code/Codex CLI in Ghostty, Warp, VS Code, or Cursor | Exact host input when uniquely resolvable | Targeted Unicode after exact host/window verification | None in the background; fail visibly without focusing the host | Exact readable insertion only; no claim of background submission | **Not tested on v2.0.207 (2026-07-15);** background Enter remains unsupported |
| Telegram | Exact Telegram message `AXTextArea` plus readable chat-context anchors | `AXSelectedText`; targeted Unicode only after a proven AX no-op | Explicit nearby or exact retained labelled Send; ordinary HID Return only if the exact composer already owns system keyboard focus; no retry | Composer clears/resets; empty/hidden/mismatched context fails closed because a reused editor wrapper cannot identify a chat | **Not tested on v2.0.207 (2026-07-15):** Telegram was not running |
| Google Chrome | Exact editable element plus saved window/tab fingerprint | Targeted Unicode | None in the background; no generic Send discovery or Return | Exact readable input change while saved context still matches | **Not tested on v2.0.207 (2026-07-15):** no disposable personal-Chrome target was available; background Enter remains unsupported |
| Notion (`notion.id`) | Exact selected card title/property/block editor plus its board/page context | Targeted Unicode; `AXSelectedText` only for same-app/different-editor, otherwise fail closed—never reconstruct/set the whole rich-editor `AXValue` | None in the background; no generic Send discovery or Return | Exact card/editor changes while a sibling card/editor and current board remain untouched | **Not tested on v2.0.207 (2026-07-15):** the active workspace contained personal work and no UI mutation was performed; background Enter remains unsupported |

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
