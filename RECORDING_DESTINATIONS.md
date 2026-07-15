# Recording destination controls (VoiceInk++)

VoiceInk++ lets the stop action decide which text input receives a recording. This is useful when
you start dictating in one app, move elsewhere while speaking, and only decide at the end where the
transcript belongs.

## Terminology

The **primary button** is Ethan's normal/thumb/toggle recording button: the first press starts recording and pressing that same button again performs a normal stop. **Next button** is the preferred name for the separate forward/secondary/latch/retarget button. It emits the standard macOS **Next Track** media event, which is why implementation code and system configuration use “Next Track.” These aliases do not name extra modes. “Second chance” refers only to a Next-button retarget after a primary-button normal stop while transcription is still loading.

Read [VoiceInk++ terminology](TERMINOLOGY.md) for the complete alias map, timing table, and history of the deliberately reverted Next-toggle experiment.

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
an editable input nor a safe web-app container can be captured.

The icon for the action just taken confirms the route with a brief neon pulse on every monitor. A
primary-button normal stop pulses the first/current-focus icon. Next while recording pulses the
second/locked icon, as does a successful Next second-chance retarget while transcription is loading.
A failed retarget or an ordinary pass-through Next Track media press does not pulse. With macOS
Reduce Motion enabled, the same confirmation uses a light fade without the scale beats.

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
4. If Codex is in the background, VoiceInk++ resolves and verifies that exact original composer internally, types there without making Codex frontmost, and uses the bounded verified submit chain. If no safe route exists, it keeps control in your current app and copies the transcript to the clipboard.

### Keep normal media controls outside recording

1. With VoiceInk++ idle and no transcription still loading, press the **Next button**.
2. VoiceInk++ does not consume the key, so the current media app advances normally.

### Change your mind while transcription is loading

1. Stop a recording normally and let transcription begin with its stop-time destination saved.
2. While it is still transcribing and before destination-dependent formatting/enhancement begins, focus a different text input.
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

The change is accepted until raw transcription finishes and VoiceInk++ freezes the target's complete
Mode before formatting/enhancement. After that cutoff, or when no pending transcription exists, Next
Track passes through to the media system. If
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

Codex desktop owns its composer directly, so VoiceInk++ can resolve that exact input and use its bounded verified Send fallbacks. Codex CLI and Claude Code do not own separate macOS windows: their terminal or editor host owns the editable input. VoiceInk++ therefore saves the exact Terminal, iTerm, Ghostty, Warp, VS Code, Cursor, or other host input together with that host app's configured `autoSendKey`.

The current and locked recorder icons show the host application for CLI agents by design. Configure a Mode for the host app and enable Return only where automatic submission is safe. Apple Terminal and iTerm capture a stable window-ID plus TTY/session-ID pair while the exact terminal input is focused, then bind the transcript and Return to that same pair in one native operation without selection or activation; mutable or duplicated titles are never routing identities. Apple Terminal does not expose a proven exact-session paste-only operation, so paste without Return fails safely there; iTerm can write to the exact session with `newline false`. Ghostty, Warp, VS Code, Cursor, and generic editors do not currently have a safe background Enter route; their exact background paste may still work, but VoiceInk++ must report that it could not auto-send instead of focusing the host or posting Return to its process. The normal-stop, recording-start, and second-chance routes remain identical; no agent-specific toggle, shell hook, or plugin is involved.

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
   content anchors fail closed if a stale wrapper could match a different document or tab. Telegram
   may reuse one editor wrapper after a chat switch, so its original wrapper is retained only while
   independently readable chat-context anchors still match and the app reports that exact structurally
   identical editor/window as its own internal focus. Hidden, empty, or mismatched context fails closed.
2. Opens one bounded internal activation-state session only when needed, restores the exact internal
   window/editor, and proves from immediate pre/post Accessibility focus that it did not take control.
   A non-activating panel that already owns the exact keyboard input skips synthetic activation.
3. Uses native `AXSelectedText` insertion where live evidence supports it (currently Telegram), then
   falls back to bounded targeted Unicode only when the exact readable value proves the AX setter was
   a no-op. It never uses background Command–V.
4. Verifies that the exact editor changed, the intended transcript appeared, and the target app did
   not become frontmost. Ethan may keep moving among other apps; his foreground PID need not freeze.
5. If auto-send is enabled, uses a surface-specific chain. A chat composer must clear/reset;
   non-empty mutation is not submission. Apple Terminal/iTerm send text plus Return together through
   the captured window-ID + TTY/session-ID pair and verify native contents before/after for both the
   transcript and a prompt/buffer line transition. Generic
   editors, Chrome, Notion, Ghostty, Warp, VS Code,
   and Cursor have no generic background Enter route and are never retried. Only an unchanged OpenAI
   composer that still owns exact system keyboard focus can receive one ordinary-HID Return retry.
   Semantic Send requires a proven chat bundle, the nearest shared composer container, and an explicit
   Send label. An unlabelled OpenAI square is never pressed because the same slot can become Stop while
   an agent runs; exact wrapper/geometry does not prove its meaning. Submitted-message echo remains
   optional telemetry.
6. Restores the target app's previous internal window/editor state. A failure at any checkpoint copies
   the transcript to the clipboard and shows a visible error rather than guessing.

Process-targeted Return is deliberately prohibited. Earlier disposable Codex probes showed both why
plain PID posting is unreliable and why event acceptance is not proof that Electron submitted.
VoiceInk++ now uses only a proven semantic Send action, an ordinary HID key while the exact saved
input still owns system keyboard focus, or a host-native exact-session API such as Terminal/iTerm
scripting. It never uses process-targeted Command–V/Return, and `AXConfirm` is not generic editor
Return.

If the target app is frontmost but Ethan is working in a different input in that same app,
application PID is not treated as destination identity. VoiceInk++ keeps the exact saved-input route
and may use only direct Accessibility insertion plus a proven semantic action. It never changes the
app's internally focused editor just to make a key event work; if direct delivery is unavailable it
fails visibly to the clipboard instead of stealing intra-app focus.

When only a recording-start application fallback exists and the app is backgrounded, VoiceInk++
uses that app's internally focused editable element only when it can verify one; it does not activate
the app. VoiceInk++ retains the ordinary foreground route only when the exact saved input is also the
current keyboard input. If the background app exposes no verifiable editable element, delivery fails
visibly to the clipboard.

If the app closed, the input disappeared, or focus cannot be verified, VoiceInk++ copies the
transcription to the clipboard instead of risking a paste into the wrong place.

The permanent required compatibility set and safe live scenarios are in
[BACKGROUND_DELIVERY_TEST_MATRIX.md](BACKGROUND_DELIVERY_TEST_MATRIX.md): Codex desktop, ChatGPT's
Option-Space window, Claude Code terminal/editor hosts, Telegram, Google Chrome, and a selected
Notion card/property/block editor. Notion validation must use a disposable card/page, never Ethan's
current to-do board.

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
