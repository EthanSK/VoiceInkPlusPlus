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
4. VoiceInk++ reactivates Codex, restores that exact original input, verifies it, and pastes there.

### Keep normal media controls outside recording

1. With VoiceInk++ idle and no transcription still loading, press the **Next button**.
2. VoiceInk++ does not consume the key, so the current media app advances normally.

### Change your mind while transcription is loading

1. Stop a recording normally and let transcription begin with its stop-time destination saved.
2. While it is still transcribing or enhancing, focus a different text input.
3. Press the **Next button**.
4. The locked destination icon switches to that app. VoiceInk++ replaces both the exact input and
   its configured auto-send key for the newest not-yet-delivered transcription.
5. You may immediately move to another app. When the result finishes, VoiceInk++ returns to the
   second-chance input, pastes there, performs that input app's configured Return, then restores your
   newer workspace.

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

Codex desktop owns its composer directly, so VoiceInk++ can restore that exact input and use its bounded verified Send fallbacks. Codex CLI and Claude Code do not own separate macOS windows: their terminal or editor host owns the editable input. VoiceInk++ therefore saves the exact Terminal, iTerm, Ghostty, VS Code, Cursor, or other host input and uses that host app's configured `autoSendKey`.

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

Before pasting, VoiceInk++:

1. Activates the saved application and waits until macOS reports it as genuinely frontmost.
2. Restores the saved Accessibility element and verifies its exact identity. For a safe
   recording-start app fallback, it uses that now-frontmost application's current input.
3. Sends an ordinary Command–V to the verified frontmost destination.
4. If auto-send is enabled, keeps that destination frontmost through the paste-settle delay,
   verifies it again, and issues the configured Return there.
5. Only after the complete paste/Return sequence, restores and verifies the application that was
   active before delivery. A plain paste restores it after a 100 ms settlement delay. If Ethan has
   already moved focus himself, VoiceInk++ preserves that live choice instead of overriding it.

VoiceInk++ deliberately does not post Command–V to a background process: macOS can report that the
event was posted even when apps such as VS Code ignore it. If app activation, input restoration, or
paste-command creation fails, VoiceInk++ copies the transcription to the clipboard and shows an
error instead of pasting into an unintended field or reporting a false success.

For ordinary destinations, auto-send uses a foreground HID Return with a real key-down/key-up
interval; plain Enter retains its bounded redundant retry. The OpenAI ChatGPT/Codex Electron composer
gets a stricter route because live tests proved that it can ignore both process-targeted Return and
an instantaneous foreground event while macOS reports success. VoiceInk++ first presses the nearby
accessibility **Send** control when that exact composer exposes one. If the control is absent (for
example, while a response is already running), it asks System Events to issue script key code 36,
then tries one human-timed HID Return only if the editor text remains unchanged. If both routes leave
the pasted transcript untouched, VoiceInk++ keeps the text in the editor and shows a visible
“transcription pasted, but Return could not be sent” error.

VoiceInk++ deliberately does not use process-targeted Return or `AXConfirm`: Electron can ignore
either even when macOS accepts the request. Every fallback immediately rechecks that the saved app is
still frontmost, so Ethan using the Mac during delivery cannot make Return drift into another app.

If the app closed, the input disappeared, or focus cannot be verified, VoiceInk++ copies the
transcription to the clipboard instead of risking a paste into the wrong place.

## Diagnostic logs

The logs record the physical route, selected destination, app process, Accessibility role, element
identity, activation timing, and final focus verification. Recent routing events can be inspected with:

```sh
log show --last 10m --info --style compact \
  --predicate 'process == "VoiceInkPlusPlus"' | \
  grep -E 'Recording shortcut|Next Track|Captured focused input|Focused input restore|paste: BEGIN'
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
- `VoiceInk/Modes/FocusLockService.swift` captures, activates, restores, and verifies exact inputs.
- `VoiceInk/Transcription/Engine/TranscriptionDelivery.swift` restores the target before paste.
