# Recording destination controls (VoiceInk++)

VoiceInk++ lets the stop action decide which text input receives a recording. This is useful when
you start dictating in one app, move elsewhere while speaking, and only decide at the end where the
transcript belongs.

## Delivery engine switch

VoiceInk++ temporarily defaults **Exact Saved-Input Delivery** to off while its background Codex
compatibility is being repaired and physically re-tested. The switch is in **Settings → Pasting**:

- **Off — base VoiceInk compatibility:** the Primary button records normally, the finished text
  pastes into whichever input owns keyboard focus at delivery, and the current Mode owns
  post-processing, output, and optional Return. The Next Track media key passes through. The
  latency-sensitive start/stop path performs no saved-input Accessibility capture and no saved app
  is activated or internally focused. The second destination slot stays visible as a warning so
  the recorder never pretends that compatibility mode owns an exact app/input.
- **On — VoiceInk++ exact delivery:** all three destination routes and their Next-button behavior
  below are enabled. The second slot becomes the captured app icon when one exact target is proven;
  a genuine capture failure remains a visible warning.

The underlying UserDefaults feature flag is `VIPPExactInputDeliveryEnabled`. It is evaluated at each
delivery/Next-button decision, so the Settings toggle does not require a rebuild. This is a delivery
engine switch, not a fourth destination route: never merge or reinterpret the three routes below.

## Terminology

The **primary button** is Ethan's normal/thumb/toggle recording button: the first press starts recording and pressing that same button again performs a normal stop. **Next button** is the preferred name for the separate forward/secondary/latch/retarget button. It emits the standard macOS **Next Track** media event, which is why implementation code and system configuration use “Next Track.” These aliases do not name extra modes. “Second chance” refers only to a Next-button retarget after a primary-button normal stop while transcription is still loading.

Read [VoiceInk++ terminology](TERMINOLOGY.md) for the complete alias map, timing table, and history of the deliberately reverted Next-toggle experiment.
Before changing capture, paste, focus, Return, semantic Send, or verification, also read
[the failed-approaches ledger](FAILED_APPROACHES.md); successful API return codes and passing mocked
tests repeatedly failed on the real destination apps.

## Controls

| Stop action | Paste destination |
| --- | --- |
| Primary/thumb/toggle button again | Normal stop: only the exact text input focused when you stop recording; never the recording-start input |
| **Next button** while recording | The exact text input focused when you started recording, or that application when macOS hides the editor element |
| **Next button** while the newest transcription is still loading | Second chance after a normal stop: replace that pending session's destination and auto-send behavior with the text input/app focused now |
| **Next button** with no recording or retargetable transcription | Its Next Track event passes through normally to Spotify, Music, and other media apps |

The Mode emoji/symbol sits immediately left of the waveform. Two app icons sit to its right: the
first is the app focused now; the second is the saved destination owned by that recording. While
recording, the second icon previews where a Next Track stop will paste. After stopping, it remains
visible for that session until delivery succeeds or visibly fails. If Next Track retargets a loading
transcription, that second icon silently changes to the new pending destination; successful retargets
do not add a redundant text popup. The same destination icon remains on a compact transcription chip
if a newer recording starts. Hover over either icon to distinguish current focus from the exact
pending app/input. If Electron/Chromium exposes only an app-level container while the shortcut is
down, VoiceInk++ saves the owning application. A warning icon and notification appear when neither
an editable input nor a safe web-app container can be captured. The same second-slot warning remains
visible while compatibility delivery is selected because that engine intentionally owns no exact
destination; disabling the feature never collapses the two-icon layout.

The icon for the action just taken confirms the route with a brief neon pulse on every monitor. A
primary-button normal stop pulses the first/current-focus icon. Next while recording pulses the
second/locked icon, as does a successful Next second-chance retarget while transcription is loading.
A failed retarget or an ordinary pass-through Next Track media press does not pulse. With macOS
Reduce Motion enabled, the same confirmation uses a light fade without the scale beats.

That flash confirms the action; a persistent cyan outline confirms ownership. As soon as any stop
route freezes a real exact input, the stable second/locked icon remains outlined while that session
is transcribing or delivering, including on a compact background chip. The outline follows a
successful second-chance replacement and clears only when delivery resolves, visibly fails, or is
cancelled. The recording-time preview, missing target, and app-only no-caret fallback remain
unoutlined until exact-composer promotion succeeds. The first/current-focus icon never stays
outlined because it can change after the destination decision.

“Recording start” means the moment the recording command begins, before asynchronous microphone
setup can allow another app or field to replace the intended input. It does not mean the later
transcription phase that starts after recording stops.

## Examples

### Keep the transcript where you finish

1. Focus an input in Codex and start recording with the normal recording shortcut.
2. Move to a VS Code editor while speaking.
3. Stop with the normal recording shortcut.
4. VoiceInk++ pastes into the VS Code editor because it was focused at stop.

### Send the transcript back where recording began

1. Focus an input in Codex and start recording with the normal recording shortcut.
2. Move to a VS Code editor while speaking.
3. Stop with the **Next button**.
4. If Codex is in the background and its exact current surface exposes a proven non-activating
   insertion and Send path, VoiceInk++ restores and verifies that exact original composer internally,
   types and submits there, and leaves the current app frontmost. Otherwise it fails closed and
   preserves the transcript instead of activating Codex or guessing at Return.

### Keep normal media controls outside recording

1. With VoiceInk++ idle and no transcription still loading, press the **Next button**.
2. VoiceInk++ does not consume the key, so the current media app advances normally.

### Change your mind while transcription is loading

1. Stop a recording normally and let transcription begin with its stop-time destination saved.
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

If a primary normal stop cannot capture or later verify its exact stop-time input, VoiceInk++ must
fail visibly and preserve the transcript safely. It must not silently fall back to the older
recording-start input; that input is invoked only by Next while recording.

This exact second-chance route was live-confirmed repeatedly on 2026-07-13 after commit `1eabb1b`:
the trace recorded `focusedDuringTranscription`, `targetAutoSend=enter`, and verified successful
OpenAI composer submission after Ethan moved between apps. Treat that commit and the root
`AGENTS.md` contract as the regression baseline.

The change is accepted until delivery resolves its target immediately before paste. After that
cutoff, or when no pending transcription exists, Next Track passes through to the media system. If
no editable text input is focused, VoiceInk++ consumes the intentional retarget press, keeps the
existing destination, and asks you to focus an input and try again.

## Mouse setup

This feature listens for the standard macOS **Next Track** media event. A mouse button can emit that
event through its existing vendor software, such as Logitech G HUB. No VoiceInk-specific Logitech
macro and no Karabiner configuration are required.

Keep the ordinary mouse button assigned to the existing VoiceInk++ recording shortcut. Assign the
alternative **Next button** to **Next Track**. VoiceInk++ intercepts that button while recording or while a
pending transcription can still be retargeted.

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
system-defined `NX_KEYTYPE_NEXT` event. For a special VoiceInk++ action, its event-tap callback
returns no event for both key-down and key-up, so Spotify and other media apps never receive that
press. When no special action is available, the callback returns the original event unchanged and
macOS routes it to the normal media destination. The behavior is global and is not Spotify-specific.

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
replaces the saved editor's Accessibility wrapper before delivery. Normal stop-time and
transcription-time retargets still require an exact editable input, so an incidental non-editable
control cannot silently replace their destination.

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

- `focusedAtStop` — normal recording shortcut.
- `recordingStart` — Next Track stop.
- `focusedDuringTranscription` — Next Track retarget while a result is still loading.

## Implementation map

- `VoiceInk/Shortcuts/ShortcutMonitor.swift` detects and conditionally consumes the system media key.
- `VoiceInk/Shortcuts/RecordingShortcutManager.swift` selects the stop destination.
- `VoiceInk/Transcription/Engine/VoiceInkEngine.swift` captures the start or stop input.
- `VoiceInk/Transcription/Engine/RecordingSession.swift` owns the target for that recording.
- `VoiceInk/Modes/FocusLockService.swift` captures, re-resolves, internally focuses, and verifies exact inputs.
- `VoiceInk/Paste/CursorPaster.swift` implements bounded targeted Unicode/key events and foreground fallbacks.
- `VoiceInk/Transcription/Engine/TranscriptionDelivery.swift` selects and verifies background-exact or foreground delivery.
