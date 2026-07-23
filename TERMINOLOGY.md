# VoiceInk++ terminology

This is the canonical glossary for Ethan's mouse controls and recording destinations. Read it before interpreting phrases such as “same button,” “toggle,” “secondary behavior,” “latch,” “original input,” or “current input.” Timing is part of the meaning.

## The two physical controls

| Preferred term | Ethan may also say | Exact meaning |
| --- | --- | --- |
| **Primary button** | normal button, thumb button, toggle button, recording button, same button, normal click/toggle, G5 | The programmable mouse button mapped to VoiceInk++'s normal recording shortcut. The first press starts recording. Pressing that same button again performs a normal stop. In code, the shortcut can use `.toggle` mode. |
| **Next button** | forward button, secondary button, secondary mouse button, Next Track, Next Track media key/action/event, latch button, retarget button | The separate programmable mouse button mapped to the macOS Next Track media event (`NX_KEYTYPE_NEXT`). Its action depends on whether VoiceInk++ is recording or a normal-stop result is still loading. It is not the primary button and “secondary” does not mean macOS right-click. |

In this repository, **toggle** without another qualifier means the primary button's start/stop lifecycle. It never means toggling a paste destination on or off. The short-lived Next-destination toggle experiment was deliberately reverted.

When dictation renders the product name as “Voice Ink,” “Voice Inc,” “Voice sync,” “voicing,” or a similar phrase, treat it as **VoiceInk++** only when the repository and surrounding context make that clear.

## Ethan's verified Logitech G HUB mapping

A read-only check of the live **Desktop: Default** software profile on Ethan's G502 X LIGHTSPEED on 2026-07-14 confirmed the physical distinction:

- The upper side thumb control is assigned the custom `speech to text` macro. It taps Left Shift + Left Control + Left Option in 50 ms steps, exactly matching VoiceInk++'s saved modifier-only primary shortcut (`Shift + Control + Option`) and `.toggle` recording mode. This is the **primary button**.
- A different control in G HUB's top view is explicitly labeled **Next Track**. This is the **Next button**.
- G HUB separately labels two side controls **Mouse Button 4** and **Mouse Button 5**. Neither label names the Next button in this setup. In particular, never mechanically translate Ethan's spoken alias “forward button” into raw Mouse Button 5; the relevant invariant is the separate control that emits the macOS Next Track media event.

When diagnosing the hardware mapping, verify G HUB's active profile and resolved assignment diagram as well as VoiceInk++'s stored shortcut. Do not infer the physical control from a historical G-number, a raw card ID, or the English word “forward” alone.

## Timing defines the route

Primary always uses base VoiceInk current-input delivery. The table below describes the
additional routes available while **Exact Saved-Input Delivery** is enabled. When the runtime
feature flag `VIPPExactInputDeliveryEnabled` is off, no tentative recording-start capture runs and
Next Track performs no destination action; finished Primary text and Mode behavior still follow the
current app/input at delivery. While the recorder bar is visible the press is consumed; after the bar
hides it passes through as media. The second recorder slot remains visible as a warning because no
exact destination is owned. This is an engine switch, not another timing route or a new meaning for
either physical button.

| State before the press | Control pressed | Result | Destination value |
| --- | --- | --- | --- |
| Idle | Primary button | Start a new recording; while exact delivery is enabled, tentatively capture a recording-start candidate only in case Next is pressed | Not yet final |
| Recording | Primary button again | **Normal stop** through base VoiceInk | Whichever system keyboard input is focused at delivery (`primaryCurrentInput`) |
| Recording | Next button | Stop and send it back to the input captured when recording began | `recordingStart` |
| Loading after a primary-button normal stop | Next button once | **Second chance:** replace that pending session's destination with the exact editable input focused at this press | `focusedDuringTranscription` |
| Recorder bar visible, but no session remains eligible for a destination change | Next button | Consume the press as a VoiceInk++ no-op; never advance media while the bar is visible | Existing destination remains unchanged |
| Recorder bar hidden, with no active recording or eligible normal-stop result | Next button | Pass the Next Track event through to media normally | No VoiceInk++ destination action |

If a new recording is active while an older result is transcribing, the active recording determines the button action: primary stops that recording normally; Next stops it into `recordingStart`. Do not silently reinterpret that press as a retarget of an older session.

The recorder bar is the strict ownership boundary for the physical Next button. While any mirrored black recorder/transcription bar is visible, VoiceInk++ consumes the complete Next Track press even if the newest session already latched, crossed the delivery cutoff, or exact delivery is temporarily disabled. Only a press made after the recorder bar is hidden may reach Music, Spotify, or another media app. This prevents an attempted latch from unexpectedly becoming Next Song because of an internal timing race.

## Non-negotiable distinctions

### Primary normal stop is always base VoiceInk

The second press of the primary/thumb/toggle button does not latch any exact input. It posts ordinary
system-focused paste and the current Mode's generic auto-send key to whichever keyboard input macOS
owns at delivery. It must not capture, reuse, restore, verify, or fall back to the tentative
recording-start input, and it must never enter Telegram/OpenAI/Terminal or other app-specific delivery.

The recording-start or “old known” input is invoked only by pressing the Next button while recording.

### Second chance is only the post-stop route

**Second chance** means exactly:

> primary normal stop → transcription begins → focus a new editable input → press Next once → optionally move elsewhere → deliver into that newly selected input

It does not name every Next-button action. It does not stop a recording, choose the recording-start input, toggle between inputs, or release a target.

### Latching is ownership, not a toggle

To **latch**, **lock on**, **attach**, **retarget**, or **hold on to** an input means that the individual recording session owns that exact destination until delivery resolves it. A later focus change does not release it. During second chance, one Next press replaces the pending destination; another focus change does not replace it again.

The recorder's locked app icon is a compact representation of that exact saved input. It does not mean VoiceInk++ saved only an application-level destination.

### “Current” and “saved” are different policies

- During a primary normal stop, “current input” means the keyboard input focused when delivery posts
  ordinary Command-V (`primaryCurrentInput`). The user may change it after stopping.
- During second chance, it means the input focused when Next is pressed after the normal stop (`focusedDuringTranscription`).
- For either Next route, whichever input happens to be focused at delivery is irrelevant; that
  per-session exact destination already owns the decision.

### Recording start is not transcription start

**Recording** is microphone capture before the primary or Next stop. **Transcribing/loading/enhancing** begins after recording stops. “Input at recording start” means the input captured when the microphone recording command began, not the input focused when transcription began.

## Historical confusion audit

These are superseded ideas that still appear in Git history, comments, or session logs:

1. In June 2026, the start-input workflow was explored as a long press of the existing recording shortcut. Code and reviews therefore use phrases such as “toggle mode,” “STOP hold,” and “focus lock.” That gesture is historical; it must not be mistaken for the current two-button contract.
2. On 2026-07-12, the first proposal again compared short and long presses. Ethan then simplified it to two physical controls. Historical source used a stop-time exact destination for Primary; on 2026-07-23 Ethan explicitly replaced that with base VoiceInk current-input-at-delivery behavior so app-specific latch work can never regress normal dictation. Next while recording still selects the recording-start input.
3. “Input on start of transcription” was explicitly corrected in the same session to mean **recording start**. Future agents must not use that early wording to move the capture point past the stop.
4. The post-stop **second chance** was added separately: while a normal-stop result is loading, Next captures the input focused at that later press. It is not an extension of the recording-start route.
5. Commit `671b4c7` temporarily made Next toggle between start and stop destinations. Ethan rejected that design because it required two clicks for the common case. Commit `bed22b7` exactly reverted it. Never resurrect `671b4c7` or describe the accepted design as a Next toggle.
6. Later phrases such as “same button as I started recording,” “normal click toggle,” and “normal button” all referred to the primary/thumb button. “Next,” “secondary button,” and “forward button” referred to the separate Next Track control.
7. The one-shot raw/skip-processing UI control is also described as a toggle in older code and learnings. It is unrelated to either physical mouse control or destination selection.

The accepted second-chance implementation is `1eabb1b` (`Fix second-chance transcription retarget auto-send`), based on `cba45ba`; the rejected toggle experiment remains `671b4c7`, reverted by `bed22b7`.

## Agent interpretation rule

When a phrase is ambiguous, identify the physical control and timing before touching code. Restate the route in concrete terms—such as “primary button again while recording → base current input at delivery (`primaryCurrentInput`)”—instead of asking whether Ethan means a generic “toggle.” Do not create a fourth route from an alias.
