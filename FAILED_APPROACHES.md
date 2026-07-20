# VoiceInk++ failed approaches and regression ledger

> **Mandatory negative evidence.** Read this file completely before changing mouse-button
> routing, target capture, exact/background delivery, auto-send, focus restoration, the recorder
> HUD, release installation, or live-test infrastructure. It records approaches that looked
> plausible, compiled, passed unit tests, or even worked once, but failed the real VoiceInk++
> contract. Do not retry an entry merely under a new name.

This is the consolidated negative-evidence companion to [LEARNINGS.md](LEARNINGS.md).
`LEARNINGS.md` is the dated positive evidence index; this file answers the equally important
question: **what did we already try, why did it fail, and what would have to be different before it
could be reconsidered?**

The initial audit covered the complete 13–19 July 2026 VoiceInk++ task transcript: 207 user
messages, 1,398 assistant messages, 115 compaction/handoff checkpoints, repository history, build
and install records, live delivery traces, and Ethan's observed results. It intentionally excludes
dictated text, clipboard contents, terminal buffers, credentials, and other private content.

## How to use this ledger

Every claim has one of these states:

- **REJECTED** — real runtime evidence disproved the mechanism or release. Do not reintroduce it
  without new evidence that directly changes the proven failure condition.
- **SUPERSEDED** — it was a useful intermediate step or worked under a narrower contract, but a
  later accepted design replaced it. Preserve the lesson, not the old implementation.
- **INCONCLUSIVE** — source, mocks, static Accessibility inspection, or event-post acceptance did
  not prove the user's real result. Do not present it as working and do not ship it merely because
  the same shallow check passes again.
- **PROCESS FAILURE** — the implementation may or may not have been sound, but the build, test,
  installation, tracing, or handoff process made the result untrustworthy.
- **ACCEPTED BOUNDARY** — a narrow condition that is currently proven. Do not generalize it to a
  different route, app, app build, input, tab, window, or focus state.

Evidence strength, from strongest to weakest:

1. A real user-visible result correlated with a trace from the uniquely identified installed app.
2. A real surface verifier, such as the exact composer clearing while the foreground stays put.
3. A live trace proving route selection, mutation, focus boundaries, and one attempted action.
4. Named tests that actually executed from the freshly built test bundle.
5. Source inspection, offline bundle inspection, mocked Accessibility trees, or successful API
   return codes.

Levels 3–5 can prove that VoiceInk++ attempted something. They cannot, by themselves, prove that
the destination app accepted paste or submitted text.

## Red-box warnings

These are the highest-cost mistakes from the audited session.

1. **Never identify a binary by `v2.0.<build>` alone.** Early build 203 was reused for materially
   different binaries. Correlate the user's timestamped verdict with the immediately preceding
   install, PID, CDHash or executable checksum, and delivery architecture.
2. **Never equate “event posted,” `AXError.success`, or an accepted Accessibility setter with app
   behavior.** Electron repeatedly accepted events/actions while ignoring paste or Return.
3. **Never use process-targeted Command-V for exact background paste.** macOS can enqueue it while
   Electron/VS Code ignores it.
4. **Never use ordinary unauthenticated process-targeted Return as background submission.** It has
   the same false-success failure.
5. **Never treat `AXConfirm` as generic editor Return.** A text area accepting the action does not
   mean its host submitted.
6. **Never activate or raise a saved background app as a fallback.** Earlier versions stole Ethan's
   foreground workspace and still failed to submit.
7. **Never infer Send from an arbitrary unlabelled OpenAI square button.** The same position/state
   can be Stop while an agent is running.
8. **Never bypass a Computer Use refusal with repeated custom activation-state probes against
   ChatGPT/Codex.** That destabilized keyboard focus and apparently restarted ChatGPT.
9. **Never make broad delivery changes while fixing ordinary Primary dictation.** The accepted
   uninterrupted Primary route is deliberately insulated from all Next/background experiments.
10. **Never hide a failed or disabled destination by removing the recorder's second icon.** Keep
    the slot and show the warning honestly.
11. **Never restart VoiceInk++ while a recording may be active.** One restart destroyed a long
    in-progress dictation. Inspect state, preserve recoverable audio/history, notify, wait five
    seconds, and quit cooperatively.
12. **Never call a release shipped because source changed or an app compiled.** It must have a new
    build number, named tests, a signed installed artifact, a new verified PID/CDHash, and a real
    route trace. `/Applications/VoiceInk.app` must remain untouched.

## Current accepted boundary at the end of the audit

The installed app at the accepted checkpoint is VoiceInk++ v2.0.236. Commit `fb3ead7` is the
verified implementation for ordinary uninterrupted Primary delivery:

- Primary starts and stops in the same continuously keyboard-focused app.
- A monotonic external-app activation generation and the start PID remain unchanged.
- `focusedAtStop` uses the live caret, guarded ordinary Command-V, and one immediate HID Return.
- It does not require exact AX capture, text read-back, focus restoration, semantic Send,
  background preparation, retry, or a visible verification result.
- Switching away, including switching away and back, rejects this compatibility path.
- `recordingStart` and `focusedDuringTranscription` structurally cannot enter it.

The live v2.0.236 trace contained:

```text
destination=focusedAtStop ... primaryContinuity=true
paste: primary current-input compatibility selected ... exactCaptureRequired=false
paste: primary current-input command completed result=commandPosted
paste: primary current-input immediate HID auto-send issued=true verification=notRequired
```

Ethan observed the paste and submission working. This proves that narrow Primary case. It does **not**
prove exact background paste/Send, Next-while-recording, second-chance background submission,
Telegram, Claude Code, Chrome, Notion, or another OpenAI app/build.

The three route contracts remain:

| Physical action | Destination | Status |
| --- | --- | --- |
| Primary again while recording | `focusedAtStop`; uninterrupted same-app may use live-caret compatibility | Contract accepted; uninterrupted v236 path live-proven |
| Next while recording | `recordingStart` | Contract accepted; universal background delivery unresolved |
| Primary normal stop, then Next while newest result is transcribing | `focusedDuringTranscription` plus that target's complete Mode | Contract and atomic Mode fix accepted at `1eabb1b`; universal background delivery unresolved |

The uncommitted v234–v236 SkyLight/authenticated-Return source in the candidate worktree is not an
accepted background implementation. It must not be smuggled into policy merely because the same
installed v236 binary contains it; the accepted v236 trace returned through the separate Primary
compatibility branch before that experiment ran.

### Post-audit v2.0.243 checkpoint: Primary accepted, latch rejected

On 2026-07-20, session reconstruction identified v2.0.238 commit `bfef0e4` as the last user-accepted
Codex background-delivery baseline. Commit `5475ef2` rebuilt that source in isolation as v2.0.243,
adding only the audited `/Applications/ChatGPT.app` 26.715.52143 build-5591 tuple and tuple tests.
Later Telegram, Terminal, and Claude delivery changes are absent.

The signed build is a checkpoint because Ethan confirmed its normal Primary `focusedAtStop` route
works. It is **not** an accepted latch build. A physical Codex `focusedDuringTranscription` attempt
captured the exact composer, inserted into it while VS Code remained frontmost, resolved the bounded
FooterActions Send control, and issued one targeted Send action. The post-action composer became
unreadable and the visible message did not submit. This is another proof that action issuance plus
unreadable verification cannot be promoted to success. Both Codex Next routes remain unresolved.

The same checkpoint captured Telegram's foreground `AXTextArea`, but a second-chance run and a
Next-while-recording run both failed before insertion with `Background exact-input preparation could
not resolve the saved window`. Telegram is therefore the next isolated compatibility target. Do not
change the accepted Primary path, fold later cross-app code into this checkpoint, or add a blind Send
retry. Reconsider latch support only after a route-specific trace and explicit visible result agree.

## Version-by-version evidence map (13–19 July 2026)

This chronology exists because “the working version” was repeatedly misidentified by build-number
proximity. It is an evidence index, not a sequence of increasingly correct releases. Several builds
were dirty, build 203 was reused, and later versions often regressed an earlier narrow success.

| Phase / version | Mechanism or intent | Observed evidence and verdict |
| --- | --- | --- |
| Pre-session contract | `cba45ba`, then `1eabb1b`, established transcription-time retarget plus atomic input/Mode ownership | Accepted behavioral contract; preserve `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt` |
| Rejected toggle | `671b4c7` made Next toggle destination ownership | Rejected and exactly reverted by `bed22b7`; never resurrect it |
| Early background events | `b694eac` process-targeted Command-V; `744c2ce` process-targeted Return | Both were accepted by macOS and ignored by Electron/VS Code; proven failures |
| v2.0.203–205 | Exact-location foundation, mirrored HUD, version UI, and multiple build-203 artifacts | Useful narrow ancestry, but artifacts were not consistently reproducible and build 203 is not an identity |
| v2.0.206 | Native source `96e494e`; exact-location rollback floor later restored by `b2aeaa2` | Background Codex insertion/Return worked in a bounded observation, with false verification; not universal Send proof |
| v2.0.207 | `86b50c2` plus a broad dirty delivery/focus/Terminal rewrite | Named tests passed, but latency, incomplete app proof, and overlapping installation made the release unacceptable; rejected wholesale |
| v2.0.208 | Added Claude handling and surface-specific verification | ChatGPT exact paste could work, foreground Return could insert a newline, background Send was unavailable, and focus/latency regressed; rejected |
| Rollback | `b2aeaa2` restored native source exactly to `96e494e`; main docs `413137d` recorded the rejection | Signed v206 restored and verified; accepted rollback boundary |
| v2.0.209 | Removed required rendered echo, classified clear/newline/unreadable, removed unsafe retry | Some ChatGPT/Terminal runs appeared to work; Codex could submit with a false warning; Telegram failed re-resolution; mixed only |
| v2.0.210 | One bounded background session, strict Telegram context, restricted semantic Send | Telegram attempts remained foreground and did not prove background delivery; latency remained; architecture lessons only |
| v2.0.211 | Short Telegram anchors and capture refinements | G HUB's modifier chord exposed `AXGroup`/`AXWebArea`; exact target was lost and no verified sender was found; regression |
| v2.0.212 | Larger capture/scope/focus/Telegram hardening | Signed/tested source existed, but no accepted installation/live result before work moved on; unverified |
| v2.0.213 | Suppressed only the shortcut-completing modifier event and forwarded releases | Intended to repair v211; 46 tests passed, but physical G HUB proof was still pending; strong static evidence only |
| v2.0.214 | Silence/proxy handling and current-input repair | First paste regression improved, but ChatGPT paste/Return reliability remained incomplete; mixed |
| v2.0.215 | HID-state Command-down then V-down | Electron replaced/reparented the wrapper between events and the safety preflight cancelled; proven transport regression |
| v2.0.216 | Restored the prior foreground Cmd-V event source with exact focus preflights | Foreground paste recovered; auto-send remained separate and unresolved; narrow mechanism boundary only |
| v2.0.217 | Optimized selected-task/no-caret scan | Focused ChatGPT Primary paste worked, then the version was rolled back during broader work; do not extrapolate to background Send |
| v2.0.218 | Expanded no-caret/background work | All 53 named tests passed while live Codex background submission still did not fire; physical Send failure |
| v2.0.219 | Exact flag off; base VoiceInk current-focus compatibility; Next passes through | Ethan confirmed current-input Codex worked; accepted compatibility escape hatch only |
| v2.0.220 | `13fb3a9` integration lineage | With exact off, no target was captured and the HUD showed warning; OpenAI tuples were stale and exact Send stayed unproven |
| v2.0.221 | `744b7d1`; hid the locked slot in compatibility and audited newer tuples | Hidden slot was explicitly rejected; exact-on capture failed bounded fingerprinting; tuple evidence only |
| v2.0.222 | `e9ed1f6`; separated ChatGPT host artifact from embedded Codex product | Product/host distinction is valid, but selected-task scope remained unresolved and exact delivery was not live-proven |
| v2.0.223 | `f06399b`, docs `610752d`, UI lineage `3c44ebc` | Real trace logged `incomplete bounded context fingerprint`, `recordingStart targetCaptured=false`, then clipboard fallback; warning was genuine |
| v2.0.224 | `3639f60`, docs `c10ad6c`; relaxed description/placeholder pairing | All 56 named tests passed; live trace repeated v223's fingerprint failure; hypothesis disproven and exact mode disabled again |
| v2.0.225 | v206-based branch beginning `9da9fc5`, then focus-session work | Became the experiment base; no complete accepted exact background Send result; do not call the version successful as a whole |
| v2.0.226 | Focus lifecycle around `c439317` | Correct Codex target captured, but legitimate inactive `focused element = absent` was treated as failure; regression |
| v2.0.227 | Accepted explicit absent prior focus and kept cleanup safety | Paste worked, but semantic scans cost 1–3 seconds and accepted events did not submit; paste improvement, Send failure |
| v2.0.228 | `2c33cf0`; fast exact-focus-guarded foreground HID Return | First test lacked a target; later evidence supports foreground transport only when the saved composer owns real keyboard focus |
| v2.0.229 | `c2a05bc` lineage | Replaced/lost wrapper after Return became indeterminate instead of a visible failure; useful verification rule, not Send proof |
| v2.0.230 | `76afaea`; recognized clear/placeholder/reset and unrelated status | Foreground trace looked non-failing without a preserved user verdict; background semantic Send still failed; mixed |
| v2.0.231 | `9fef647`; traversed Chromium navigation-order children | Exact background insertion worked and foreground stayed unchanged; semantic Send remained unavailable; split result |
| v2.0.232 | `be4f6ec`; bounded Send diagnostics | Trace showed `auditedUnlabelled=0`; diagnostic evidence only |
| v2.0.233 | `6d93b36`; exact tuple plus audited unlabelled idle button | Background paste succeeded and `AXPress` returned success, but the composer stayed unchanged; proven action/result gap |
| v2.0.234 | Uncommitted SkyLight-authenticated Return | One run failed before paste; another pasted then produced newline/non-empty `modifiedWithoutSubmit`; proven semantic failure |
| v2.0.235 | Continued dirty SkyLight work plus a Primary compatibility fast path | Installed without a clean accepted background result; build does not identify a reproducible source snapshot |
| v2.0.236 | `fb3ead7` implementation, `f9b13c4` docs, plus dirty v235/SkyLight source | Primary current-input compatibility traced and Ethan observed it working; both Next routes and the complete binary remain unproven/unreproducible |

The table deliberately separates source, tests, installation, traces, and user-observed behavior.
No row may be promoted merely because a later build reused part of it.

## Terminology and route misunderstandings

### Treating Next as a destination toggle

- **State:** REJECTED.
- **Attempt:** Commit `671b4c7` made Next Track toggle a paste destination on and off.
- **Observed result:** It contradicted Ethan's timing-based workflow and made later agents interpret
  the same physical button as multiple undocumented toggles.
- **Resolution:** `bed22b7` reverted it. `TERMINOLOGY.md` now defines Next as one action whose route is
  selected by lifecycle timing.
- **Do not retry:** Do not add an on/off destination state. “Latch,” “retarget,” and “second chance”
  do not mean toggle.

### Merging recording-start and second-chance routes

- **State:** REJECTED as a mental model; accepted fix at `1eabb1b`.
- **Attempt:** Several iterations treated “Next” as one generic saved-input behavior and allowed the
  locked target or Return Mode to be recomputed later.
- **Observed result:** The icon could show the chosen app while delivery used a different app's
  current Mode, or the target disappeared as transcription began.
- **Cause:** Input identity and target Mode/auto-send were sourced at different times.
- **Resolution:** `RecordingPasteTarget` owns the input and complete Mode atomically. The pipeline
  freezes the newest eligible target before destination-dependent post-processing.
- **Do not retry:** Never read formatting, enhancement, output, or auto-send solely from the global
  current Mode after a destination has been chosen.

### Falling back from Primary normal stop to the recording-start input

- **State:** REJECTED.
- **Attempt:** Use the older known recording-start target when stop-time capture/verification failed.
- **Observed result:** A normal Primary stop could paste into an old input that Ethan did not invoke.
- **Do not retry:** `focusedAtStop` never falls back to `recordingStart`. In the uninterrupted
  v236 case it follows the live caret; after any app activation it uses only the exact stop-time
  input or fails visibly and preserves the transcript.

### Inferring hardware controls from “forward,” G5, Mouse Button 4, or Mouse Button 5

- **State:** REJECTED.
- **Attempt:** Treat conversational aliases or G HUB card IDs as proof of a physical control.
- **Observed result:** Agents confused the Primary macro with the distinct Next Track assignment.
- **Accepted evidence:** The G502 X LIGHTSPEED `Desktop: Default` profile maps the upper thumb
  control's `speech to text` Shift-Control-Option macro to Primary and a separate explicitly labelled
  `Next Track` control to Next.
- **Do not retry:** Verify the active G HUB profile, software/onboard mode, resolved assignment
  diagram, and VoiceInk++ shortcut. Raw G-numbers are not identities.

## Target capture and identity failures

### Saving only an application instead of an exact input

- **State:** REJECTED as a universal solution; bounded fallback only for the documented
  recording-start Electron case.
- **Attempt:** Remember a bundle/PID and later ask the app for whichever input is internally focused.
- **Observed result:** It cannot distinguish two inputs in the same app, another tab, another task,
  or a reused editor wrapper. The right app icon can therefore look correct while the destination is
  not owned.
- **Do not retry:** A saved app is not a saved composer. Promote any allowed app-only fallback to one
  exact, replay-safe wrapper before mutation or fail closed.

### Requiring an editable AX element for ordinary same-app Primary delivery

- **State:** SUPERSEDED by `fb3ead7`.
- **Attempt:** Make stop-time exact AX capture/read-back a prerequisite even when Ethan never left the
  app and the live keyboard caret was correct.
- **Observed result:** Electron transiently exposed `AXGroup` or no editable wrapper; ordinary
  dictation copied to the clipboard, delayed Return, or showed false errors.
- **Resolution:** The uninterrupted Primary compatibility path uses app continuity rather than input
  identity. Exact capture remains mandatory for the routes that claim to preserve a saved input.
- **Do not retry:** Do not pull the exact/background engine back into the uninterrupted Primary path.

### Treating away-and-back as uninterrupted foreground use

- **State:** REJECTED.
- **Attempt:** Compare only the start and delivery PIDs.
- **Failure:** Ethan could leave the app, change work, then return; matching final PID did not prove
  the live caret remained the intended one for the whole recording.
- **Resolution:** Use a monotonic external-app activation generation as well as PID and recheck it at
  each irreversible boundary.
- **Do not retry:** PID equality alone is insufficient continuity evidence.

### Over-strict OpenAI context fingerprints in v2.0.223/v2.0.224

- **State:** REJECTED.
- **Attempt:** Require a complete bounded task/window/scope fingerprint before accepting the real
  ChatGPT-hosted Codex composer. v224 relaxed description/placeholder matching but retained the rest
  of the gate.
- **Observed result:** Live traces captured the correct `AXTextArea` and app icon context, then logged
  `Exact-input capture rejected incomplete bounded context fingerprint`; `recordingStart` was cleared
  and delivery copied to the clipboard. All 56 named v224 tests still passed.
- **Lesson:** Tests and offline ASAR strings did not model the live missing fingerprint field.
- **Do not retry:** Do not claim a fingerprint fix until a real start trace proves
  `targetCaptured=true`, exact insertion, one verified Send, and unchanged foreground.

### Accepting a stable or UUID-shaped wrapper as task/tab identity

- **State:** REJECTED.
- **Attempt:** Treat renderer editor/window identifiers or wrapper equality as enough to survive tab,
  task, or chat changes.
- **Failure:** Chromium/Electron and Telegram can reuse wrappers across logical contexts.
- **Do not retry:** Revalidate readable semantic context at capture and irreversible mutation/action
  boundaries. Empty context is not identity; Telegram always requires matching readable chat anchors.

### Conflating an absent prior focused element with an AX read failure in v2.0.226

- **State:** REJECTED; corrected in the v2.0.227 candidate.
- **Attempt:** Make every missing focused-element snapshot fail background focus preparation.
- **Observed result:** v226 showed the correct locked app icon but refused delivery with “couldn't
  focus the recording-start input.” Electron's explicit no-previous-element state was legitimate.
- **Do not retry:** Model `value`, `absent`, and `AX read failure` separately. Absence can own a valid
  cleanup path; read failure still fails closed.

### Continuously polling or recapturing focus

- **State:** REJECTED.
- **Attempt:** Continuously chase the currently focused element rather than capture at the physical
  route decision and freeze it per session.
- **Failure:** It converts Ethan's later clicks into destination changes and makes diagnostics race
  with normal computer use.
- **Do not retry:** Capture at recording start, Primary stop, or eligible transcription-time Next.
  Treat subsequent focus changes as user input, not noise to overwrite.

## Paste transport failures

### `CGEvent.postToPid` Command-V (`b694eac`)

- **State:** REJECTED.
- **Attempt:** Paste to the saved background process without activating it by targeting Command-V at
  the PID.
- **Observed result:** macOS reported the event posted, but VS Code/Electron did not paste. Logs
  falsely looked successful while the transcript never appeared.
- **Do not retry:** Background exact text uses bounded Unicode/direct Accessibility only inside a
  verified exact-input session. Foreground compatibility may use normal system Cmd-V because the
  actual keyboard caret owns focus.

### AppleScript/System Events as background paste

- **State:** REJECTED.
- **Attempt:** Run `System Events` Command-V while another app remained active.
- **Failure:** System Events targets the system keyboard focus/frontmost surface, not an arbitrary
  saved background input.
- **Do not retry:** AppleScript is not an addressing primitive. It is legitimate only for a surface
  that already owns real system keyboard focus and only when the route's safety gate proves that.

### Setting an entire generic `AXValue`

- **State:** REJECTED for generic/rich editors.
- **Attempt:** Reconstruct the full current value plus transcript and set it directly.
- **Risk/failure:** It can flatten rich text, damage Notion block semantics, overwrite concurrent
  edits, or target a reused wrapper.
- **Do not retry:** Use `AXSelectedText` only when settable and verified, or bounded targeted Unicode
  within an exact session. Fail closed for rich/contenteditable surfaces without a proven insertion
  primitive.

### Long targeted Unicode after only one initial identity check

- **State:** REJECTED.
- **Attempt:** Prove the context once, then type an arbitrarily long transcript while Ethan remains
  free to change tabs/tasks/chats.
- **Failure:** The logical context can change mid-stream while PID/window/editor wrappers remain.
- **Do not retry:** Run the expensive semantic resolver before, at bounded checkpoints, and after;
  run cheap exact PID/window/editor/focus checks per chunk. Never log the content.

### Mutating before opening the one bounded internal activation session

- **State:** REJECTED, especially for Telegram.
- **Attempt:** Strictly re-resolve a background app's hidden AX tree before preparing its bounded
  internal activation state.
- **Observed result:** Telegram v2.0.209 exposed zero background window children, so resolution failed
  before the still-live exact editor could be assessed.
- **Boundary:** Preparation cannot weaken chat identity. Telegram still requires readable matching
  chat context immediately before every mutation/action.
- **Do not retry:** Do not solve hidden trees by trusting internal focus or geometry alone.

## Return and Send failures

### PID-targeted Return (`744c2ce` and later variants)

- **State:** REJECTED as a general mechanism.
- **Attempt:** Address Return to the saved process after paste or after restoring another foreground
  app.
- **Observed result:** Electron/VS Code accepted the post at the macOS layer but ignored it. Logs said
  “posted” while the composer remained unchanged.
- **Do not retry:** Use a proven semantic action, a host-native exact session API, or ordinary HID
  only when the intended input actually owns system keyboard focus. No success claim without the
  surface verifier.

### Global HID Return after forcing the target foreground

- **State:** REJECTED as a background fallback; accepted only for the guarded current-foreground
  compatibility route.
- **Attempt:** Activate the saved app, restore the AX input, paste, wait, send a normal Return, then
  restore Ethan's later app.
- **Observed result:** Codex was dragged front and left there when restoration failed; Return could
  still be ignored. The settle delay added visible disruption without reliability.
- **Do not retry:** Never activate a background target. A normal HID key is valid only when the exact
  route already proves real keyboard focus without taking it from Ethan.

### `AXConfirm` on text areas

- **State:** REJECTED.
- **Attempt:** Invoke the Accessibility confirm action as a generic Return substitute.
- **Observed result:** `AXError.success` was returned while Codex did nothing.
- **Do not retry:** `AXConfirm` is not editor submission. Use only an app control whose semantics
  explicitly define Confirm for that control and still verify the surface result.

### System Events Return plus “humanized” CGEvent retries

- **State:** REJECTED as a generic OpenAI fallback chain.
- **Attempt:** Try System Events, then a delayed physical-looking key-down/up, then another Return if
  the text looked unchanged.
- **Observed result:** Different apps handled different steps; Electron sometimes inserted a newline,
  sometimes ignored both, and retries created duplicate-submission risk. Terminal accepting the key
  did not prove ChatGPT/Codex would.
- **Do not retry:** One irreversible action per proven route. A readable unchanged OpenAI composer
  may justify only the explicitly documented single retry while it still owns exact keyboard focus.
  Unreadable state never justifies a retry.

### Generic nearby semantic-Send traversal

- **State:** REJECTED as a universal solution; bounded labelled actions remain legitimate.
- **Attempt:** Traverse a large AX tree for a nearby button and invoke `AXPress`.
- **Observed result:** Traversal added one-to-three seconds of latency. Electron could return AX
  success without submitting. Candidates were unavailable when the tree exposed navigation-order
  children differently, and permissive matching risked Stop or remote buttons.
- **Do not retry:** Restrict discovery to a proven chat bundle and nearest shared composer container;
  require explicit Send/Submit semantics, same PID/window, bounded geometry, enabled state, press
  action, and a final boundary check. Verify composer clear/reset.

### Treating an unlabelled OpenAI square as Send

- **State:** REJECTED unless an exact audited app/version/build/Chromium tuple and idle state have
  been independently proven at the irreversible boundary.
- **Attempt:** Use uniqueness and geometry to infer that the only square beside the composer was Send.
- **Observed result:** Running tasks expose Stop in the same slot. ChatGPT and Codex also share a
  bundle identifier while differing in versions and UI structure.
- **Do not retry:** Label-read failure is not an empty label. Stop must always be rejected. Static
  ASAR evidence is a hypothesis, not live submission proof.

### Requiring rendered-message echo after submission

- **State:** REJECTED.
- **Attempt:** Require the submitted text to appear elsewhere in the AX tree after the composer
  changed or disappeared.
- **Observed result:** Return actually submitted, but virtualization/replacement made the rendered
  echo unreadable; VoiceInk++ played an error sound and showed a false warning.
- **Resolution:** Exact composer clear/reset is the authoritative chat verifier. Rendered-message
  echo is optional telemetry.
- **Do not retry:** Never make a remote rendered copy a required success condition.

### Treating unreadable post-state as failure

- **State:** REJECTED.
- **Attempt:** After one issued Return/press, interpret a missing/replaced AX wrapper as failed Send.
- **Observed result:** ChatGPT/Codex often replaced the composer on successful submission, producing
  a false red error and sound.
- **Do not retry:** `unreadable` is indeterminate telemetry after one irreversible action. Do not
  retry and do not show a false failure. A readable unchanged composer remains a real no-op; a
  newline/non-empty mutation is `modifiedWithoutSubmit`.

### Treating “changed” as “submitted”

- **State:** REJECTED.
- **Attempt:** Verify only that current text differed from previous text.
- **Observed result:** A Return could insert a newline, or optional-string comparison could treat nil
  as changed, and the verifier claimed success.
- **Do not retry:** Chat submission requires clear/reset. Preserve explicit states for verified
  clear, unchanged, modified without submit, and unreadable.

### Counting transcript occurrences for repeated phrases

- **State:** REJECTED as insertion or submission verification.
- **Attempt:** Count matching copies of the transcript in a composer, terminal buffer, or surrounding
  AX tree and infer success when the count increases.
- **Failure:** Dictation can intentionally repeat a phrase; the same text may already exist in the
  composer, scrollback, rendered message history, or a virtualized off-screen node. Wrapper
  replacement can also change the searchable tree without proving that this invocation inserted or
  submitted anything.
- **Do not retry:** Compare the exact target's bounded before/after state and use its surface-specific
  postcondition. Chat requires the exact composer to clear/reset; Terminal/iTerm require the bound
  native session's inserted text plus prompt-tail transition. Repeated text elsewhere is telemetry.

### SkyLight-authenticated PID Return in v2.0.234–v2.0.235

- **State:** REJECTED for background ChatGPT submission; later dirty implementation remains
  INCONCLUSIVE as a broader transport experiment.
- **Attempt:** Recreate a narrow part of Computer Use's background-focus architecture: prepare an
  internal activation session, attach a SkyLight authentication message to Return down/up, post to
  the exact audited ChatGPT tuple, then verify clear/reset.
- **Observed result:** A real v234 background attempt inserted into the intended composer, then the
  authenticated Return produced a newline/non-empty mutation and explicit
  `modifiedWithoutSubmit` instead of clear/reset. Other attempts failed before paste or had
  unavailable authentication/transport. Later dirty v235/v236 code was never independently
  accepted for the background route. The one accepted v236 test used the separate Primary
  compatibility branch.
- **Do not retry:** Do not describe this as a supported exception, commit the dirty experiment, or
  generalize it to Codex, another build, Command-V, text insertion, or other keys. Reconsider only
  with a disposable target and a trace proving exact insertion, one authenticated action, composer
  clear/reset, unchanged system foreground, no latency regression, and no fallback/retry.

## Focus and workspace failures

### Activating/raising the destination and restoring later

- **State:** REJECTED for background delivery.
- **Attempt:** Use `NSRunningApplication.activate`, `NSWorkspace.openApplication`, `AXRaise`, and AX
  focus setters to bring the saved target frontmost, then try to restore Ethan's app afterward.
- **Observed result:** Visible focus theft, app jumping/spazzing, inability to click the current app,
  failed restoration, and still-unhandled Return. A foreground-to-background race could reactivate
  the target after Ethan had already moved on.
- **Do not retry:** The user's current workspace is a hard boundary, not state to repair after the
  fact. Background routes must remain non-activating or fail closed.

### Rewriting app-internal focus for same-app/different-input delivery

- **State:** REJECTED.
- **Attempt:** Make latched input A internally focused while Ethan used input B in the same app, then
  restore B.
- **Failure:** The restoration cannot distinguish VoiceInk++'s focus from a newer user click and can
  overwrite legitimate interaction.
- **Do not retry:** Use direct verified insertion plus a proven semantic action only; never perform
  an app-internal focus rewrite in this case.

### Requiring Ethan's unrelated foreground PID to remain frozen

- **State:** REJECTED.
- **Attempt:** Abort background delivery whenever the app Ethan was using changed from A to B.
- **Observed result:** It defeated the product's “keep moving” workflow even though the saved target
  remained safely backgrounded.
- **Do not retry:** Prove that the target did not become frontmost and that the exact target identity
  remains valid. Ethan may switch among unrelated foreground apps during delivery.

### Repeated private activation-state probes after Computer Use refusal

- **State:** REJECTED and unsafe.
- **Attempt:** Recreate blocked Computer Use inspection with custom AX/private activation events
  against Ethan's live ChatGPT process.
- **Observed result:** Keyboard focus destabilized and ChatGPT apparently restarted.
- **Do not retry:** Treat tool refusal as a safety boundary. Use existing traces, offline bundle
  inspection, or a truly disposable target. Never probe Ethan's active Codex/ChatGPT task this way.

### Assuming Computer Use has a second independent macOS mouse/focus channel

- **State:** REJECTED mental model.
- **Attempt:** Infer from the visible agent cursor that the helper can type/click without macOS focus
  constraints and therefore VoiceInk++ can copy one reusable API.
- **Finding:** `VirtualCursor` is presentation/targeting state. `SyntheticAppFocusEnforcer` and
  `SystemFocusStealPreventer` are OpenAI implementation types, not documented Apple APIs. The helper
  combines AX, synthesized input, refetchable trees, PID/window addressing, private mechanisms, and a
  trusted local service.
- **Do not retry:** Public AXSwift/AXorcist wrappers do not supply the full architecture. Public CUA
  projects are audit sources, not drop-in proof for delayed exact VoiceInk++ delivery.

## App-specific negative evidence

### ChatGPT.app and Codex.app identity

- **State:** ACCEPTED BOUNDARY.
- Both can report bundle identifier `com.openai.codex`.
- Session failures were repeatedly attributed to “Codex” when the target executable was actually
  `/Applications/ChatGPT.app`.
- **Rule:** Persist/verify bundle URL or executable plus short version, build, and Chromium tuple.
  Never allowlist or interpret a trace from bundle ID alone.

### ChatGPT Option-Space floating composer

- **State:** PARTIALLY PROVEN, not universal.
- It can own real system keyboard focus while another app is still reported frontmost. Treating
  `NSWorkspace.frontmostApplication` alone as truth rejects legitimate foreground-key delivery.
- Background exact insertion and ordinary main-window submission results do not prove this
  non-activating surface.
- **Rule:** Prove its exact AXTextArea and real system keyboard focus; do not synthesize app
  activation merely because the workspace frontmost app differs.

### Telegram

- **State:** UNRESOLVED across later releases; several generic fixes rejected.
- Telegram can hide its background AX children and reuse an editor wrapper across chats.
- v2.0.209 failed strict pre-preparation re-resolution. Relaxing to internal focus/geometry alone
  could paste into the wrong chat.
- `AXSelectedText` may be settable, but that proves mutation capability, not chat identity or Send.
- **Rule:** Require readable matching chat anchors immediately before every mutation/action. Hidden,
  empty, or mismatched context fails closed. Use the dedicated Telegram live-test procedure.

### Terminal, iTerm, and Claude Code

- **State:** Surface-specific; do not infer from GUI chat apps.
- Terminal accepting ordinary Enter proved only that Terminal accepted it; it did not validate
  ChatGPT/Codex.
- PID/AX text followed by a separately addressed native newline can cross sessions/tabs.
- Apple Terminal has no proven exact-session paste-only API. iTerm can write with `newline false`.
- **Rule:** Capture stable window ID plus TTY/session ID and bind transcript plus Return to the same
  pair in one host-native operation. Verify prompt-tail transition. Mutable title and wrapper identity
  are insufficient; TUI/scrollback rewrites can be indeterminate and never justify retry.

### Claude Desktop versus Claude Code

- **State:** Do not conflate them.
- v2.0.209 logs suggested Claude Desktop exact background paste/Return worked in two attempts after
  the composer was genuinely focused; that is not proof for Claude Code in Terminal/iTerm/Ghostty,
  nor for another Claude Desktop build.
- **Rule:** Record the host surface and exact session identity. A Claude bundle allowlist or unit test
  without a live disposable trace remains unverified.

### Google Chrome

- **State:** Background exact paste not universally proven; auto-send normally disabled in Ethan's
  setup.
- Browser PID/window/editor identity does not prove a tab or site context. A reused renderer wrapper
  can point at another tab.
- **Rule:** Preserve a readable window/tab/document fingerprint. Do not enable Return merely to make
  a test easier.

### Notion

- **State:** NOT LIVE-TESTED in the required selected-card/editor scenario during the audited work.
- Generic `AXValue` mutation risks damaging rich block semantics and Ethan's real board.
- **Rule:** Use a disposable page/card only. Prove the exact card/property/block and sibling safety;
  otherwise report not tested and fail closed.

## Recorder HUD and feedback regressions

### Showing the HUD on only the activation monitor

- **State:** REJECTED; multi-monitor mirroring accepted.
- **Failure:** Ethan heard recording start but had to search another display for the bar.
- **Rule:** Mini and notch panels mirror the same recording sessions on every connected `NSScreen`.
  Per-screen notch geometry must remain local to each panel.

### Routine “Recording” text above the waveform

- **State:** REJECTED.
- **Failure:** It added clutter and was mistaken for warning/status content.
- **Rule:** Routine state belongs in waveform/icon affordances. Visible text above the bar is reserved
  for real warnings/errors.

### Hiding the locked destination when transcription begins

- **State:** REJECTED.
- **Cause:** Mini/notch views gated the icon on `.recording` even though the session still owned the
  target during `.transcribing` and `.delivering`.
- **Rule:** Keep the session's locked icon visible until success, failure, or cancellation; update it
  immediately after a successful second-chance retarget.

### Replacing a successful retarget icon change with a toast

- **State:** REJECTED.
- **Failure:** Text feedback was noisy and did not show which app the session now owned.
- **Rule:** A successful retarget switches/pulses the locked icon. Use selectable warning text only
  for a genuine failure.

### Collapsing current focus and locked destination into one icon

- **State:** REJECTED.
- **Failure:** One icon cannot answer both “where am I working now?” and “where will this session
  deliver?”
- **Rule:** Mode is left of the waveform. On the right, current focus is first and locked destination
  is second.

### Removing the warning/second icon to make a regression look cleaner

- **State:** REJECTED, observed around v2.0.222 compatibility work.
- **Failure:** The UI stopped disclosing that exact delivery had no owned destination. Ethan asked for
  the warning to be fixed, not hidden.
- **Rule:** Keep both slots. Exact disabled or genuine capture failure shows the warning icon.

### Treating the action pulse as persistent ownership

- **State:** REJECTED.
- **Rule:** The neon pulse is transient: Primary stop pulses current-focus; Next/latch pulses locked.
  Persistent outline belongs only to a real frozen exact destination, never the live current icon or
  an app-only preview.

### Removing or obscuring the running version

- **State:** REJECTED process/UI behavior.
- **Rule:** The recorder displays `v<marketing>` on row one and `.<build>` on row two immediately left
  of Stop. Every installed native binary receives a unique build number.

## Verification failures and false confidence

### Unit tests passed, real app failed

- **State:** REPEATED PROCESS FAILURE.
- v2.0.208 passed 29/29 tests while ChatGPT paste succeeded and Send failed.
- v2.0.224 passed 56 named tests while the live composer still failed capture with an incomplete
  fingerprint.
- Mocked AX actions proved guard logic, not Electron handling.
- **Rule:** The required final evidence is a real disposable surface trace plus Ethan's observed
  result. Keep test claims scoped to what the test actually proves.

### Compilation mistaken for test execution

- **State:** REPEATED PROCESS FAILURE.
- Xcode's TestManager frequently built app/tests and then stalled without naming a test. XCTest can
  also print a zero-test preamble before the Swift Testing cases execute.
- **Rule:** Canonical Xcode action first. If it stalls, preserve evidence and run the already-built
  bundle directly with correct app/framework paths. Require every expected test name and a real pass
  count.

### Reusing a stale direct-xctest bundle

- **State:** REJECTED.
- **Failure:** A passing old bundle can be reported against newer source.
- **Rule:** Prove the bundle was freshly built from the exact candidate. Record source commit/tree,
  derived-data path, and named output.

### Logs treated as destination proof

- **State:** REJECTED.
- **Failure:** `commandPosted`, `AXError.success`, or `targetCaptured=true` was repeatedly reported as
  working when the destination did nothing.
- **Rule:** Logs establish route/attempt. Surface-specific verification and user observation establish
  handling. Preserve `unreadable` as indeterminate.

### User interaction treated as contradictory noise

- **State:** REJECTED diagnostic behavior.
- **Failure:** Ethan was actively using the Mac; agents interpreted legitimate focus changes as
  inconsistent results or “repaired” them by stealing focus back.
- **Rule:** Check current logs after each physical reproduction. Treat user input as real. Prefer
  read-only evidence and announce any unavoidable focus-changing test.

## Build, signing, installation, and rollback failures

### Treating v2.0.207/v2.0.208 as an accepted cumulative rewrite

- **State:** REJECTED and rolled back.
- **Attempt:** Replace capture, focus, insertion, Terminal identity, semantic Send, verification, and
  fallback behavior together, then infer release readiness from 27/29 named tests and successful
  signing/install steps.
- **Observed result:** Recorder start/stop latency regressed, background ChatGPT Send remained
  unavailable, foreground Return could mutate rather than submit, repeated private focus probes
  destabilized/restarted ChatGPT, and the app matrix was never physically proved.
- **Resolution:** `b2aeaa2` restored native source exactly to the v2.0.206 `96e494e` baseline. Later
  work may reuse an individual safety constraint only after it is independently re-proven.
- **Do not retry:** Never resurrect the whole rewrite, cherry-pick it as a block, or cite its test
  count as accepted behavior.

### Editing source without replacing the running app

- **State:** REPEATED PROCESS FAILURE.
- **Failure:** UI changes appeared while delivery changes did not, or agents reasoned from source that
  was not the installed binary. Ethan repeatedly had to ask whether he was on the new version.
- **Rule:** Distinguish source, committed, built, signed, transferred, installed, launched, and
  live-confirmed. Never collapse these states.

### Reusing build 203

- **State:** REJECTED.
- **Failure:** `bf757cf` through `1eabb1b` and additional installed variants shared build 203 despite
  materially different delivery behavior. Later rollback searches by “the working 203” were
  ambiguous.
- **Rule:** Increment `CURRENT_PROJECT_VERSION` for every different installed binary and verify the
  visible badge plus checksum/CDHash.

### Re-signing the outer app without Automation entitlement

- **State:** REJECTED.
- **Failure:** A generic outer signature could pass nested verification yet silently strip
  `com.apple.security.automation.apple-events`, breaking Terminal/iTerm automation.
- **Rule:** Reapply `VoiceInk/VoiceInk.local.entitlements`, then require deep/strict verification and
  inspect the outer entitlement.

### Raw recursive app-bundle transfer

- **State:** REJECTED.
- **Risk:** Bundle metadata, symlinks, or signatures can be damaged.
- **Rule:** Transfer a signed `.app` as an archive stream and verify version, signature, CDHash, and
  entitlement after extraction.

### Building on the live MacBook

- **State:** REJECTED workflow.
- **Rule:** Build/test on the Mac Mini. Use the MacBook only for signed install verification and safe
  real-surface traces. Do not touch the Mini's dirty canonical checkout; use a disposable worktree.

### Assuming a Mini/OpenClaw gateway meant task progress

- **State:** PROCESS FAILURE.
- **Failure:** The gateway could be running while the delegated VoiceInk task had failed, was waiting,
  used the wrong model/thinking setting, or was not reporting to Telegram. Repeated scheduled checks
  consumed time without establishing implementation progress.
- **Rule:** Distinguish gateway health, agent reachability, active task state, candidate Git state,
  monitor runs, and an authoritative MacBook commit. The Mini is appropriate for build/test, not as a
  substitute for live Mac UI reproduction.

### Restarting during an active recording

- **State:** REJECTED and destructive.
- **Observed result:** A long in-progress dictation disappeared when VoiceInk++ was restarted.
- **Rule:** Before quit/install, inspect active recording/transcription state, preserve recoverable
  audio/history, send the five-second native warning, wait, and quit cooperatively. If state is
  uncertain, defer the restart.

### Broad cleanup on a nearly full Mini

- **State:** REJECTED.
- **Failure/risk:** Many historical DerivedData directories filled the Mini, but they may belong to
  other work. Broad deletion would violate preservation rules.
- **Rule:** Remove only disposable artifacts created by the current run, with concrete paths and
  evidence. Never clean the canonical dirty checkout.

### Installing from a stale Mini sync

- **State:** PROCESS FAILURE.
- **Failure:** A candidate could compile from an earlier rsync while newer local fixes remained only on
  the MacBook.
- **Rule:** Pin the exact Git commit/tree or transfer a small Git bundle, then verify the Mini worktree
  before building. A successful build of stale source is not validation.

## Trace and diagnostic failures

### Ad-hoc `log stream` children

- **State:** SUPERSEDED.
- **Failure:** Plain background/nohup streams were reaped when the bounded shell exited, silently
  leaving a physical test untraced or creating orphan processes.
- **Resolution:** Use `.agents/skills/learnings/scripts/live-delivery-trace.sh` with its launchd-owned
  runner.

### Logging content to make debugging easier

- **State:** REJECTED.
- **Rule:** Detailed does not mean invasive. Retain allowlisted routing metadata only. Never log the
  transcript, prompt, clipboard, selected text, audio, terminal buffer, chat text, or URL. Daily trace
  files self-prune after seven complete days and debug mode must be stopped when the investigation is
  genuinely closed.

### Changing mechanisms before reading the newest reproduction

- **State:** REPEATED PROCESS FAILURE.
- **Failure:** Several iterations fixed the previous theory while Ethan's newest trace showed a
  different route, app executable, or failure stage.
- **Rule:** At the start of an investigation and after every reported physical reproduction, inspect
  installed version/build/PID and newest trace before another edit. Correlate button route, target,
  Mode, focus boundary, paste, action, latency, verifier, and user result.

## What succeeded and therefore must not be lost

This file is mainly negative evidence, but the following accepted islands explain what superseded
the failed attempts:

- `cba45ba` established transcription-time target replacement.
- `1eabb1b` made target input plus full Mode/auto-send atomic and was repeatedly live-confirmed for
  the second-chance route.
- `bed22b7` removed the incorrect Next-toggle interpretation.
- Multi-monitor recorder mirroring, quiet routine UI, separate current/locked icons, persistent locked
  ownership, action pulses, selectable errors, and visible unique build badge are product contracts.
- `b2aeaa2` / native `96e494e` is the documented v2.0.206 rollback floor for exact-location paste,
  not proof of universal background Return.
- `fb3ead7` is the live-proven v2.0.236 uninterrupted Primary compatibility route.
- `5475ef2` is the reproducible v2.0.243 checkpoint: Ethan confirmed normal Primary current-input
  delivery works. Its Codex and Telegram latch routes are not accepted. Preserve its Primary path and
  one-shot indeterminate-verification behavior while app-specific latch work continues.
- Privacy-bounded rolling traces and installed-build identity markers are accepted diagnostic
  infrastructure.

## Still unresolved or not broadly proven

Future agents must state these gaps rather than extrapolate:

- Reliable non-activating exact background Send for Codex/ChatGPT. v2.0.243 accepts only the normal
  Primary route; its latest `focusedDuringTranscription` latch attempt inserted but did not submit.
- The user-reported lag/load sensitivity of v2.0.243; require a matching failed trace before deciding
  whether capture, overlap, host responsiveness, or another timing boundary is at fault.
- Exact tab/task preservation when Chromium does not expose a readable semantic scope.
- Telegram background capture, insertion, and Send while preserving the exact chat.
- Claude Code across Terminal, iTerm, Ghostty, Warp, VS Code, and Cursor as distinct hosts.
- Google Chrome exact tab/editor delivery beyond the specifically observed scenarios.
- Notion selected card/property/block delivery without rich-content damage.
- The v234–v236 authenticated SkyLight experiment.
- Universal verification of a submitted action when a host immediately replaces an unreadable
  composer. Indeterminate must remain honest and one-shot.

## Gate for reconsidering a rejected mechanism

A future agent may revisit a rejected mechanism only when all of these are written down first:

1. Which exact ledger entry is being revisited.
2. What new OS, app, app-build, API, or evidence changes the proven failure condition.
3. The narrow route and surface; never “all Electron apps” or “all inputs.”
4. The disposable target and how Ethan's active workspace will remain untouched.
5. The one irreversible action and why no fallback can double-submit.
6. The surface-specific verifier.
7. The focus/no-theft boundary.
8. The regression tests and exact live trace markers.
9. The new unique VoiceInk++ build number and rollback identity.
10. The criterion for abandoning the experiment without folding it into accepted docs.

If those answers are absent, use the current accepted path or fail closed. Do not rediscover this
week by iteration.
