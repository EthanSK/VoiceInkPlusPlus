# Recording destination controls (VoiceInk++)

VoiceInk++ lets the stop action decide which text input receives a recording. This is useful when
you start dictating in one app, move elsewhere while speaking, and only decide at the end where the
transcript belongs.

## Controls

| Stop action | Paste destination |
| --- | --- |
| Normal configured recording shortcut | The exact text input focused when you stop recording |
| macOS **Next Track** media key | The exact text input focused when you started recording |
| **Next Track** while the newest transcription is still loading | Replace that pending transcription's destination with the text input focused now |
| **Next Track** with no recording or retargetable transcription | Passed through normally to Spotify, Music, and other media apps |

When microphone recording successfully begins, VoiceInk++ briefly shows the app and input it saved,
for example: **Recording start input: Codex — text area**. This is the destination that the Next Track
stop action will use. If no editable field actually has focus, it instead warns: **Recording start
input unavailable — focus a text input before recording**.

While recording, the right side of the recorder capsule persistently shows that saved app's icon,
so the destination of a Next Track stop is always visible. Hover over the icon to see the exact app
and input name. A warning icon means no valid recording-start input was captured.

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
3. Stop with the **Next Track** media key.
4. VoiceInk++ reactivates Codex, restores that exact original input, verifies it, and pastes there.

### Keep normal media controls outside recording

1. With VoiceInk++ idle and no transcription still loading, press **Next Track**.
2. VoiceInk++ does not consume the key, so the current media app advances normally.

### Change your mind while transcription is loading

1. Stop a recording normally and let transcription begin with its stop-time destination saved.
2. While it is still transcribing or enhancing, focus a different text input.
3. Press **Next Track**.
4. VoiceInk++ shows **Pending transcription target: [app] — [input]** and replaces the destination
   for the newest not-yet-delivered transcription.

The change is accepted until delivery resolves its target immediately before paste. After that
cutoff, or when no pending transcription exists, Next Track passes through to the media system. If
no editable text input is focused, VoiceInk++ consumes the intentional retarget press, keeps the
existing destination, and asks you to focus an input and try again.

## Mouse setup

This feature listens for the standard macOS **Next Track** media event. A mouse button can emit that
event through its existing vendor software, such as Logitech G HUB. No VoiceInk-specific Logitech
macro and no Karabiner configuration are required.

Keep the ordinary mouse button assigned to the existing VoiceInk++ recording shortcut. Assign the
alternative button to **Next Track**. VoiceInk++ intercepts that button while recording or while a
pending transcription can still be retargeted.

## How Next Track is consumed

VoiceInk++ installs a macOS `CGEvent` tap at the head of the session event stream and watches the
system-defined `NX_KEYTYPE_NEXT` event. For a special VoiceInk++ action, its event-tap callback
returns no event for both key-down and key-up, so Spotify and other media apps never receive that
press. When no special action is available, the callback returns the original event unchanged and
macOS routes it to the normal media destination. The behavior is global and is not Spotify-specific.

## Accessibility and safe failure behavior

Exact-input routing uses the macOS Accessibility API, which VoiceInk++ already needs for pasting.
The focused Accessibility element is stored on the individual recording session, so overlapping
background transcriptions cannot exchange destinations.

Only editable Accessibility roles such as text areas, text fields, search fields, and combo boxes are
accepted as destinations. Some apps briefly expose a container such as `AXGroup` while a modifier
shortcut is being handled, so VoiceInk++ retries an invalid initial capture once when microphone
recording becomes active. It never saves a generic container and later guesses which descendant the
user intended.

Before pasting across apps, VoiceInk++:

1. Activates the saved app and waits until macOS reports it as frontmost.
2. Restores the saved Accessibility element as the focused input.
3. Verifies both the owning process and exact element identity.
4. Sends the paste keystroke only after verification succeeds.
5. Returns to the previously active app after the paste unless you already moved focus yourself.

If the selected mode has auto-send enabled, Return is posted directly to the saved destination
process rather than whichever app happens to be frontmost after the paste delay. This lets a
Claude Code or other terminal prompt submit while you continue working in another app. AppleScript
cannot reliably type into a background Electron app, so VoiceInk++ uses a process-targeted macOS
keyboard event for this step.

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
