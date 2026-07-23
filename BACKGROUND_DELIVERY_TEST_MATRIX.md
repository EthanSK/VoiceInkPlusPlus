# VoiceInk++ background delivery test matrix

This is the permanent compatibility matrix for Ethan's main destinations. Read it and
[FAILED_APPROACHES.md](FAILED_APPROACHES.md) before changing exact-input capture, background
insertion, auto-send, focus restoration, or verification.

**Current candidate installed 2026-07-23:** signed VoiceInk++ v2.0.252 is installed from commit
`2332296` with CDHash `c7e1adde3ef1aeef6ee81ecb10d5ad759a3209b7` and executable SHA-256
`b74bb77e73930ddef3c7c7a9021b60eb990d38ec3ebf809392484f226e0db2e0`. Its fresh Mac Mini Release
bundle passed deep/strict signing, retained outer Automation, relaunched under a new verified PID, and
the official `/Applications/VoiceInk.app` remained byte-identical. The canonical Xcode test action
rebuilt but stalled in TestManager; direct `xcrun xctest` against that exact built bundle named and
passed all 48 tests. v2.0.252 adds Soniox V5 realtime owned-range input streaming and removes only the
currently focused, still-owned draft if trigger-word selection changes final output away from paste.
Physical validation of live partial replacement, input switching, Primary final reconciliation, both
Next routes, Cancel, overlap, non-paste cleanup, and final-paste-only fallback remains pending; do not
promote the new transport from tests alone.

The prior signed v2.0.247 (`60d9d6d`, CDHash
`781f46d54dc1cd1e41e951a2d834a27c9d66e081`) remains the accepted Codex `recordingStart`
background Next evidence: Ethan saw the dictated message arrive while VS Code stayed frontmost. Its
distinct Codex second-chance route, Telegram reruns, and context-menu check remained pending. Do not
replace the accepted v2.0.245 Telegram evidence or v2.0.243 Primary checkpoint with unit-test inference.

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
paste: primary current-input immediate HID auto-send issued=true verification=notRequired
```

The same delivery must contain no exact-input preparation/resolution, Telegram identity, OpenAI Send,
Terminal native-session, semantic action, read-back, verification, retry, or exact-delivery fallback
line. The intended system-focused input must receive and, when the current Mode enables it, submit the
text. This regression gate is required even when the current task only changes one of the Next routes.

## Realtime owned-range regression gate

Realtime input streaming is a transport optimization layered across the same three routes. It must
never weaken Primary isolation or exact Next identity. With
`VIPPRealtimeInputStreamingEnabled=true` and Soniox V5 realtime:

1. A disposable plain text input visibly replaces one cumulative hypothesis in place; it never
   appends every partial and never sets a complete generic `AXValue`.
2. Moving from input A to input B during speech seeds the complete transcript-so-far in B. Same-app
   cleanup may restore A only when direct exact Accessibility revalidation succeeds. Cross-app A may
   remain and the target app must never activate merely for cleanup.
3. Primary final delivery reconciles the owned range in whichever input owns system focus then and
   issues exactly one generic HID auto-send. Its trace includes
   `paste: realtime Primary current-input range finalized success=true` and contains no app-specific
   resolver/action line.
4. Next while recording reconciles only `recordingStart`; second-chance Next immediately seeds and
   later reconciles only `focusedDuringTranscription`. Both retain their target Mode/auto-send.
5. Explicit Cancel restores only a currently focused, still-owned range. An unreadable background
   range remains visible rather than being guessed away.
6. Two overlapping recordings keep distinct session/range lineage and cannot replace or deliver each
   other's text.
7. With realtime input streaming disabled—or on Telegram/rich inputs without safe selected-text
   mutation—no live range mutation occurs and the established final-delivery trace remains unchanged.

Any indeterminate setter/post-state must block further mutation for that app PID for the rest of that
recording. Final text is copied to the clipboard and no duplicate paste or Return is attempted.

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

| Destination | Saved input | Preferred non-activating insertion | Auto-send chain | Verification | Audited live evidence through installed v2.0.245 |
| --- | --- | --- | --- | --- | --- |
| Codex desktop | Exact Codex task composer | Targeted Unicode after verified internal window/editor focus | Explicit nearby semantic Send only; ordinary HID Return only while the exact composer owns system keyboard focus, with at most one retry after a readable unchanged composer | Exact composer clears/resets; rendered-message echo is optional telemetry; one issued action followed by an unreadable replacement remains indeterminate and requires matching user-visible confirmation | v243 commit `5475ef2` remains the Primary-working checkpoint. v247 physically passed `recordingStart`: exact background insertion plus the audited build-5650 FooterActions Send action while VS Code remained frontmost, followed by this message arriving in Codex. AX post-state was unreadable/indeterminate, and `focusedDuringTranscription` remains pending |
| ChatGPT Option-Space floating window | Exact `AXTextArea` in the compact non-activating window | Targeted Unicode without synthetic activation only while it still owns keyboard focus | Explicitly labelled nearby Send or ordinary HID Return while exact system focus remains; one retry only after readable unchanged text | Floating composer clears/resets without the app becoming frontmost | Exact insertion repeatedly worked; Return produced newline, no-op, or unreadable state, and v233 `AXPress` left the composer unchanged; background Send failed/unaccepted |
| Claude Code/Codex CLI in Apple Terminal or iTerm | Exact terminal input plus captured window-ID + TTY/session-ID pair | Host-native text addressed to that exact pair; never PID-targeted Unicode | Text + Return in one exact-session native operation; Apple Terminal paste-only unsupported, iTerm supports `newline false`; no title routing, activation, or retry | Native contents prove the inserted segment at the expected prompt boundary plus prompt-tail transition; host never activated | Architecture/tests existed, but no accepted final exact live trace established the complete route; unverified |
| Claude Code/Codex CLI in Ghostty, Warp, VS Code, or Cursor | Exact host input when uniquely resolvable | Targeted Unicode after exact host/window verification | None in the background; fail visibly without focusing the host | Exact readable insertion only; no claim of background submission | No accepted host-by-host final trace; unverified |
| Telegram | Exact Telegram message `AXTextArea` plus readable AX chat anchors, or an audited app/version/build/layout with a stable SHA-256 digest of the selected-chat avatar/title row | One-shot `AXSelectedText`; bounded targeted Unicode only after full visual/AX identity revalidation when selected-text insertion is unavailable | On pinned Telegram 12.9/282526 only: fresh exact-chat revalidation, then one `telegramTargetedHIDReturn` sequence (HID source, modifier boundary, Return down/up, live modifier restoration); no retry or generic fallback | Composer clears/resets; exact structure/internal focus plus matching anchors or a freshly matching visual digest; missing Screen Recording permission, blank/protected capture, tuple/layout drift, or any identity mismatch fails closed | v245 physically passed both `recordingStart` and `focusedDuringTranscription` in Saved Messages while Terminal stayed frontmost. v247 excludes the independently changing status/activity row from the otherwise exact visual digest; physical reruns remain pending. Primary must use the separate base-current-input regression gate; wrong-chat rejection remains not tested |
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
