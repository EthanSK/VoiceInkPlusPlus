# Recording destination controls (VoiceInk++)

VoiceInk++ keeps normal dictation as simple as base VoiceInk while the Next button adds optional
exact-input latching. A Primary stop follows whichever keyboard input is current when delivery
happens. Next can instead preserve the recording-start input or select a second-chance input while
transcription is still loading.

## Primary isolation and exact Next delivery

Primary permanently uses base VoiceInk compatibility: the finished text and current Mode follow
whichever input owns system keyboard focus at delivery. It owns no saved Accessibility input and can
never enter Telegram, OpenAI, Terminal, or another app-specific exact-delivery path.

The two Next-button routes separately use exact saved-input delivery whenever their capture/state
requirements pass. There is no current delivery-engine toggle between those policies. The historical
`VIPPExactInputDeliveryEnabled` preference is ignored by current source and must not be treated as a
fourth route. The second destination slot becomes the captured app icon only when a Next route proves
an exact target; before that, or after a Primary stop, it remains an honest unoutlined warning.

## Terminology

The **primary button** is Ethan's normal/thumb/toggle recording button: the first press starts recording and pressing that same button again performs a normal stop. **Next button** is the preferred name for the separate forward/secondary/latch/retarget button. It emits the standard macOS **Next Track** media event, which is why implementation code and system configuration use “Next Track.” These aliases do not name extra modes. “Second chance” refers only to a Next-button retarget after a primary-button normal stop while transcription is still loading.

Read [VoiceInk++ terminology](TERMINOLOGY.md) for the complete alias map, timing table, and history of the deliberately reverted Next-toggle experiment.
Before changing capture, paste, focus, Return, semantic Send, or verification, also read
[the failed-approaches ledger](FAILED_APPROACHES.md); successful API return codes and passing mocked
tests repeatedly failed on the real destination apps.

## Controls

| Stop action | Paste destination |
| --- | --- |
| Primary/thumb/toggle button again | Normal stop: base VoiceInk pastes into whichever system keyboard input is focused at delivery and uses that current Mode; it never invokes a saved input |
| **Next button** while recording | The exact text input focused when you started recording, or that application when macOS hides the editor element |
| **Next button** while the newest transcription is still loading | Second chance after a normal stop: replace that pending session's destination and auto-send behavior with the text input/app focused now |
| **Next button** while the recorder bar is visible but no route is still eligible | VoiceInk++ consumes the press without changing the saved destination; it never advances media |
| **Next button** after the recorder bar is hidden | Its Next Track event passes through normally to Spotify, Music, and other media apps |

The Mode emoji/symbol sits immediately left of the waveform. Two app icons sit to its right: the
first is the app focused now; the second is the exact destination owned by a Next route. While
recording, the second icon previews where a Next stop would paste. A Primary stop intentionally owns
no exact input, so its second slot becomes an unoutlined warning until delivery or until a successful
second-chance Next press replaces it with a locked app icon. A Next stop or successful second chance
keeps that exact icon visible for the session until delivery succeeds or visibly fails. The same
destination icon remains on a compact transcription chip if a newer recording starts. Hover over
either icon to distinguish current focus from the exact pending app/input. If Electron/Chromium
exposes only an app-level container while the shortcut is down, VoiceInk++ may save the owning
application for the recording-time **Next** route only. A warning appears when an exact Next target
cannot be captured. Disabling exact delivery never collapses the two-icon layout.

The icon for the action just taken confirms the route with a brief neon pulse on every monitor. A
primary-button normal stop pulses the first/current-focus icon. Next while recording pulses the
second/locked icon, as does a successful Next second-chance retarget while transcription is loading.
A failed retarget or an ordinary pass-through Next Track media press does not pulse. With macOS
Reduce Motion enabled, the same confirmation uses a light fade without the scale beats.

That flash confirms the action; a persistent cyan outline confirms **exact Next ownership**. As soon
as a Next route freezes a real exact input, the stable second/locked icon remains outlined while that
session is transcribing or delivering, including on a compact background chip. The outline follows a
successful second-chance replacement and clears only when delivery resolves, visibly fails, or is
cancelled. Primary's warning slot, the recording-time preview, a missing target, and an app-only
no-caret fallback remain unoutlined. The first/current-focus icon never stays outlined because it can
change before Primary's eventual delivery or after a Next destination decision.

## Write the transcript into the input while speaking

When **Write Realtime Transcript into Input** is enabled and the recording uses Soniox V5 realtime,
VoiceInk++ mirrors the cumulative hypothesis into the actual system-focused input as you speak. The
HUD still shows the same partial transcript, but the input becomes the crash-resilient working copy:

1. VoiceInk++ replaces only the exact UTF-16 selected-text range that this recording inserted. It
   never reconstructs or sets an entire generic `AXValue`.
2. Move focus to another supported input and the complete transcript-so-far is seeded there; later
   hypotheses replace only that new owned range.
3. A provably safe same-app migration may restore the old selected text. Cross-app residue is left in
   place rather than activating the old app or risking deletion from the wrong field.
4. Primary reconciles the final processed text into whichever input owns keyboard focus at delivery,
   then uses that current Mode's one generic auto-send. It still owns no saved destination.
5. Next while recording reconciles into `recordingStart`. A second-chance Next immediately seeds and
   later reconciles `focusedDuringTranscription`. Both keep their exact input plus complete Mode atomic.

The preference key is `VIPPRealtimeInputStreamingEnabled` and defaults on. The feature currently
requires Soniox V5 realtime, a paste-output Mode, and a normal editable Accessibility input. Telegram
and rich inputs without safe selected-text mutation skip the live draft and retain their established
final-delivery behavior. Turning the feature off restores final-paste-only behavior without changing
any Primary or Next route.

“Recording start” means the moment the recording command begins, before asynchronous microphone
setup can allow another app or field to replace the intended input. It does not mean the later
transcription phase that starts after recording stops.

## Examples

### Let the current input decide, like base VoiceInk

1. Focus an input in Codex and start recording with the normal recording shortcut.
2. Move to a VS Code editor while speaking.
3. Stop with the normal recording shortcut.
4. You may keep VS Code focused or move again while transcription runs.
5. VoiceInk++ pastes into whichever keyboard input is focused when delivery posts Command-V, then
   uses that input app's current Mode for generic auto-send. No Codex, VS Code, Telegram, or other
   app-specific exact resolver runs.

With realtime input streaming supported, step 2 also seeds the complete live draft into VS Code and
keeps replacing that owned range while you speak. Final delivery reconciles it instead of pasting a
duplicate; if you move again before final delivery, the current input still decides Primary.

### Send the transcript back where recording began

1. Focus an input in Codex and start recording with the normal recording shortcut.
2. Move to a VS Code editor while speaking.
3. Stop with the **Next button**.
4. If Codex is in the background and its exact current surface exposes a proven non-activating
   insertion and Send path, VoiceInk++ restores and verifies that exact original composer internally,
   types and submits there, and leaves the current app frontmost. Otherwise it fails closed and
   preserves the transcript instead of activating Codex or guessing at Return.

### Keep normal media controls outside recording

1. Wait until VoiceInk++ is idle and the recorder/transcription bar has closed, then press the **Next button**.
2. VoiceInk++ does not consume the key, so the current media app advances normally.

### Change your mind while transcription is loading

1. Stop a recording normally and let transcription begin. No exact destination is owned yet.
2. While it is still transcribing or enhancing, focus a different text input.
3. Press the **Next button**.
4. The locked destination icon switches to that app. VoiceInk++ replaces both the exact input and
   its configured auto-send key for the newest not-yet-delivered transcription.
5. You may immediately move to another app. When the result finishes, VoiceInk++ delivers into the
   second-chance input and performs that input app's configured Return without displacing your newer
   workspace when an exact background target is available.

This is deliberately separate from pressing Next Track while recording. During recording, Next
Track stops and chooses the recording-start input. After a normal stop has already started
transcription, Next Track is a one-click second chance to choose a new input. It replaces the pending
target once; it does not toggle or release it.

Primary has no stop-time capture or exact-input verification to fail. If ordinary system-focused
paste cannot be posted, VoiceInk++ preserves the transcript on the clipboard and reports that generic
paste failure. It must never fall back to the recording-start input; that input is invoked only by
Next while recording.

This exact second-chance route was live-confirmed repeatedly on 2026-07-13 after commit `1eabb1b`:
the trace recorded `focusedDuringTranscription`, `targetAutoSend=enter`, and verified successful
OpenAI composer submission after Ethan moved between apps. Treat that commit and the root
`AGENTS.md` contract as the regression baseline.

The change is accepted until delivery resolves its target immediately before paste. After that
cutoff, or when no pending transcription exists, a visible recorder bar still owns and consumes
Next Track as a no-op. The key passes through to the media system only after the bar is hidden. If
no editable text input is focused during an eligible retarget, VoiceInk++ consumes the intentional
press, keeps the existing destination, and asks you to focus an input and try again.

## Mouse setup

This feature listens for the standard macOS **Next Track** media event. A mouse button can emit that
event through its existing vendor software, such as Logitech G HUB. No VoiceInk-specific Logitech
macro and no Karabiner configuration are required.

Keep the ordinary mouse button assigned to the existing VoiceInk++ recording shortcut. Assign the
alternative **Next button** to **Next Track**. VoiceInk++ intercepts that button for the entire time
any recorder/transcription bar is visible; eligible recording and transcription states perform
their normal destination action, while an ineligible visible-bar press is consumed as a safe no-op.

Ethan's verified G502 X LIGHTSPEED setup uses an upper side thumb control with a `speech to text`
Shift-Control-Option macro for the primary button and a different control explicitly labeled **Next Track**
for the Next button. G HUB's separate **Mouse Button 4** and **Mouse Button 5** controls are unrelated to
that Next Track route. The spoken alias “forward button” must therefore not be treated as a request to
listen for raw Mouse Button 5.

## Codex and Claude Code destinations

Codex desktop owns its composer directly, so VoiceInk++ can restore that exact input and use a
bounded Send action only when the current Codex surface proves one. It must fail closed when it
cannot distinguish Send from Stop or verify submission. Codex CLI and Claude Code do not own
separate macOS windows: their terminal or editor host owns the editable input. VoiceInk++ therefore
saves the exact Terminal, iTerm, Ghostty, VS Code, Cursor, or other host input and uses that host
app's configured `autoSendKey` only through a proven host-specific route.

The current and locked recorder icons show the host application for CLI agents by design. Configure a Mode for the host app and enable Return only where automatic submission is safe. The normal-stop, recording-start, and second-chance routes remain identical; no agent-specific toggle, shell hook, or plugin is involved.

## How Next Track is consumed

VoiceInk++ installs a macOS `CGEvent` tap at the head of the session event stream and watches the
system-defined `NX_KEYTYPE_NEXT` event. While the recorder bar is visible, its event-tap callback
returns no event for both key-down and key-up, so Spotify and other media apps never receive that
press. An eligible state performs the recording-start or second-chance action; an ineligible state
consumes the press as a no-op. Only after the bar is hidden does the callback return an otherwise
unowned event unchanged so macOS can route it to the normal media destination. The behavior is
global and is not Spotify-specific.

## Accessibility and safe failure behavior

Exact-input routing uses the macOS Accessibility API, which VoiceInk++ already needs for pasting.
The focused Accessibility element is stored on the individual recording session, so overlapping
background transcriptions cannot exchange destinations. The selected app's auto-send key is stored
on that same per-session target; it is not re-read from whichever app happens to be current when the
transcription service returns.

Editable Accessibility roles such as text areas, text fields, search fields, and combo boxes are
saved as exact destinations. Some apps briefly expose only a container such as `AXWebArea` or
`AXGroup` while a modifier shortcut is being handled. For the recording-start/Next Track route,
VoiceInk++ then saves the owning application as a fallback. It uses the same app fallback if Electron
replaces the saved editor's Accessibility wrapper before delivery. A transcription-time
second-chance retarget still requires an exact editable input, so an incidental non-editable control
cannot silently replace its destination. Primary performs no stop-time exact capture at all.

For an exact saved input whose app is currently backgrounded, VoiceInk++:

1. Uniquely resolves the saved Accessibility window and editor. Structural identity plus nearby
   content anchors fail closed if a stale wrapper could match a different document or tab.
2. Reproduces Electron's inactive-to-active internal notification sequence without making the app
   macOS-frontmost, restores the exact internal window/editor, and verifies both.
3. Types Unicode directly into that process in bounded chunks. It never uses background Command–V.
4. Verifies that the exact editor changed, the intended transcript appeared, and the app that Ethan
   was using remained frontmost.
5. If auto-send is enabled, uses only a proven semantic Send control or a host-native exact-session
   API. An ordinary HID Return is allowed only while the exact saved input already owns real system
   keyboard focus. Chat verifies the exact composer clearing/resetting; rendered-message echo is
   optional telemetry and never required proof.
6. Restores the target app's previous internal window/editor state. A pre-mutation/action failure
   copies the transcript to the clipboard and shows a visible error rather than guessing. After one
   irreversible Send attempt, an unreadable/replaced wrapper is indeterminate telemetry: do not
   retry, claim success, or show a false failure.

Telegram's parentless composer is a narrow identity exception, not an app-only fallback. Prefer
readable matching AX chat anchors. For the exact audited Telegram 12.9 build 282526 layout only, when
the selected chat is not exposed through AX, VoiceInk++ may retain a SHA-256 digest of the fixed
avatar plus primary-title row and re-sample that same window immediately before insertion and Send.
The independently changing lower status/activity row is excluded because hashing the complete header
caused false rejection of the unchanged chat. The route still requires the exact editor/window
structure, Telegram's own internal focus, and proof the app
remained backgrounded. Screen Recording permission is required; no screenshot, OCR, title, message,
or crop bytes are retained or logged. Missing permission, an app/layout update, blank/protected
capture, or any digest mismatch fails closed. After v2.0.245 verifies insertion and revalidates that
same identity at the action boundary, Telegram alone may receive one HID-system modifier boundary,
Return down/up, and live modifier-state restoration addressed to its PID. The composer must clear;
there is no retry or generic fallback.

There is no generic process-targeted Return exception. Ordinary two-event PID posting was accepted
by macOS while Electron and Telegram ignored it. The later v2.0.233 audited-unlabelled `AXPress`
returned success while the composer stayed unchanged, and the v2.0.234 SkyLight-authenticated Return
produced `modifiedWithoutSubmit` instead of a cleared composer. The pinned Telegram sequence above
is accepted only because both background Next routes physically proved exact identity, insertion,
composer clear/reset, and no focus theft. Authentication or event acceptance alone still does not
establish application Send semantics. `AXConfirm` is likewise not a generic editor Return. See
[FAILED_APPROACHES.md](FAILED_APPROACHES.md) before proposing another targeted-event variant.

When the exact saved input already owns system keyboard focus, VoiceInk++ uses the foreground route:
it re-verifies that same app/window/input at the irreversible boundary, sends ordinary Command–V,
and performs only the surface's bounded semantic or ordinary-HID auto-send. It never activates or
internally refocuses a delivery target. If Ethan moves before Command–V, the key is cancelled and the
same frozen target may continue through the non-activating exact-input route; otherwise delivery
fails visibly. Separately, recording-start capture may make one bounded in-place attempt to focus a
uniquely proven main composer while that app/window/task is already active. It rechecks the original
control immediately before the one focus setter and never performs a compensating focus rewrite,
because a rollback cannot distinguish VoiceInk++'s caret from a newer user click on that composer.

If the app closed, the input disappeared, or focus cannot be verified, VoiceInk++ copies the
transcription to the clipboard instead of risking a paste into the wrong place.

## Diagnostic logs

The logs record the physical route, selected destination, app process, Accessibility role, element
identity, activation timing, and final focus verification. Recent routing events can be inspected with:

```sh
log show --last 10m --info --style compact \
  --predicate 'process == "VoiceInkPlusPlus"' | \
  grep -E 'Recording shortcut|Next Track|Captured focused input|paste: BEGIN|background exact|auto-send finished'
```

The important destination values are:

- `primaryCurrentInput` — normal Primary stop; system keyboard focus and current Mode at delivery.
- `recordingStart` — Next Track stop.
- `focusedDuringTranscription` — Next Track retarget while a result is still loading.

## Implementation map

- `VoiceInk/Shortcuts/ShortcutMonitor.swift` detects and conditionally consumes the system media key.
- `VoiceInk/Shortcuts/RecordingShortcutManager.swift` selects the stop destination.
- `VoiceInk/Transcription/Engine/VoiceInkEngine.swift` captures the tentative recording-start input
  for Next and deliberately creates no saved input for Primary stop.
- `VoiceInk/Transcription/Engine/RecordingSession.swift` owns the target for that recording.
- `VoiceInk/Modes/FocusLockService.swift` captures, re-resolves, internally focuses, and verifies exact inputs.
- `VoiceInk/Paste/CursorPaster.swift` implements bounded targeted Unicode/key events and foreground fallbacks.
- `VoiceInk/Transcription/Engine/TranscriptionDelivery.swift` isolates base current-input Primary
  delivery from app-specific foreground/background exact delivery used only by Next routes.
