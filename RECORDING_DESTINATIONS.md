# Recording destination controls (VoiceInk++)

VoiceInk++ captures two possible paste destinations for every recording:

- the exact editable input focused when recording starts;
- the exact editable input focused when recording stops.

The macOS **Next Track** media key toggles which of those two saved inputs the session will use. It
does not stop recording. The normal configured recording shortcut remains the only stop control.

## Controls

| Action | Result |
| --- | --- |
| Normal configured recording shortcut | Start or stop recording |
| **Next Track** during recording | Toggle between the recording-start and recording-stop inputs |
| **Next Track** while that session is transcribing or enhancing | Toggle the same destination again |
| **Next Track** with no eligible recording or transcription | Pass through normally to Spotify, Music, and other media apps |

Every session begins in **recording-stop input** mode. Its recorder card persistently shows the
current state:

- **Paste: recording-stop input** with a subdued cursor icon;
- **Paste: recording-start input** with an amber return icon.

The indicator remains visible during recording and transcription, including on compact background
transcription cards. Repeated Next Track presses toggle the mode on and off until delivery resolves
the final destination immediately before paste.

When microphone recording successfully begins, VoiceInk++ also briefly shows the app and input it
saved, for example: **Recording start input: Codex — text area**. If no editable field actually has
focus, it instead warns: **Recording start input unavailable — focus a text input before recording**.

“Recording start” means the moment the recording command begins, before asynchronous microphone
setup can allow another app or field to replace the intended input. It does not mean the later
transcription phase that starts after recording stops.

## Examples

### Default: paste where recording stops

1. Focus an input in Codex and start recording with the normal recording shortcut.
2. Move to a VS Code editor while speaking.
3. Stop with the normal recording shortcut.
4. Leave the indicator on **Paste: recording-stop input**.
5. VoiceInk++ pastes into the VS Code editor.

### Choose the input where recording began

1. Focus an input in Codex and start recording normally.
2. Move to a VS Code editor while speaking.
3. Press **Next Track** once; the indicator changes to **Paste: recording-start input**.
4. Stop with the normal recording shortcut.
5. VoiceInk++ reactivates Codex, restores that exact original input, verifies it, and pastes there.

### Change your mind while recording

1. Press **Next Track** to enable recording-start mode.
2. Press it again before stopping.
3. The indicator returns to **Paste: recording-stop input**, so the eventual stop-time input wins.

### Change your mind while transcription is loading

1. Stop recording normally and let transcription begin.
2. Press **Next Track** while it is transcribing or enhancing.
3. The persistent indicator toggles between the already-saved start and stop inputs.
4. Repeat as often as needed until delivery begins.

This loading-time toggle does not capture a third input. It deliberately switches between the two
stable inputs already saved at recording start and stop, so the behavior is reversible and easy to
reason about.

### Keep normal media controls outside VoiceInk++ work

1. With no recording or retargetable transcription active, press **Next Track**.
2. VoiceInk++ returns the event unchanged, so the current media app advances normally.

## Mouse setup

This feature listens for the standard macOS **Next Track** media event. A mouse button can emit that
event through its existing vendor software, such as Logitech G HUB. No VoiceInk-specific Logitech
macro and no Karabiner configuration are required.

Keep the ordinary mouse button assigned to the existing VoiceInk++ recording shortcut. Assign the
destination-toggle button to **Next Track**.

## How Next Track is consumed

VoiceInk++ installs a macOS `CGEvent` tap at the head of the session event stream and watches the
system-defined `NX_KEYTYPE_NEXT` event. When a recording session still accepts destination changes,
its event-tap callback returns no event for both key-down and key-up, so Spotify and other media apps
never receive that press. When no special action is available, the callback returns the original
event unchanged and macOS routes it to the normal media destination. The behavior is global and is
not Spotify-specific.

## Accessibility and safe failure behavior

Exact-input routing uses the macOS Accessibility API, which VoiceInk++ already needs for pasting.
Both focused Accessibility elements are stored on the individual `RecordingSession`, so overlapping
background transcriptions cannot exchange destinations or toggle each other's state.

Only editable Accessibility roles such as text areas, text fields, search fields, and combo boxes are
accepted as destinations. Some apps briefly expose a container such as `AXGroup` while a modifier
shortcut is being handled, so VoiceInk++ retries an invalid initial capture once when microphone
recording becomes active. It never saves a generic container and later guesses which descendant the
user intended.

If Next Track requests a start or stop input that was not captured, VoiceInk++ consumes the
intentional toggle press, leaves the mode unchanged, and explains which input is unavailable.

Before pasting across apps, VoiceInk++:

1. Resolves and freezes the session's current start-vs-stop toggle.
2. Activates the selected app and waits until macOS reports it as frontmost.
3. Restores the saved Accessibility element as the focused input.
4. Verifies both the owning process and exact element identity.
5. Sends the paste keystroke only after verification succeeds.

If the app closed, the input disappeared, or focus cannot be verified, VoiceInk++ copies the
transcription to the clipboard instead of risking a paste into the wrong place.

## Diagnostic logs

The logs record media-key consumption, toggle state, selected destination, app process,
Accessibility role, element identity, activation timing, and final focus verification:

```sh
log show --last 10m --info --style compact \
  --predicate 'process == "VoiceInkPlusPlus"' | \
  grep -E 'Recording shortcut|Next Track|paste destination toggle|Captured editable input|Focused input restore|paste: BEGIN'
```

The final destination values are:

- `focusedAtStop` — toggle off;
- `recordingStart` — toggle on.

## Implementation map

- `VoiceInk/Shortcuts/ShortcutMonitor.swift` detects and conditionally consumes the system media key.
- `VoiceInk/Shortcuts/RecordingShortcutManager.swift` routes Next Track to the session toggle.
- `VoiceInk/Transcription/Engine/VoiceInkEngine.swift` captures start and stop inputs and selects the current session.
- `VoiceInk/Transcription/Engine/RecordingSession.swift` owns both inputs and the mutable-until-delivery toggle.
- `VoiceInk/Views/Recorder/` displays the persistent per-session destination state.
- `VoiceInk/Modes/FocusLockService.swift` captures, activates, restores, and verifies exact inputs.
- `VoiceInk/Transcription/Engine/TranscriptionDelivery.swift` restores the resolved target before paste.
