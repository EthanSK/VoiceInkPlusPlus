# VoiceInk++ terminology

This is the canonical glossary for Ethan's mouse controls and recording destinations. Read it before interpreting phrases such as “same button,” “toggle,” “secondary behavior,” “latch,” “original input,” or “current input.” Timing is part of the meaning.

## The two physical controls

| Preferred term | Ethan may also say | Exact meaning |
| --- | --- | --- |
| **Primary button** | normal button, thumb button, toggle button, recording button, same button, normal click/toggle, G5 | The programmable mouse button mapped to VoiceInk++'s normal recording shortcut. While idle, one press starts after a 0.45-second debounce; a second accepted press in that window cancels the pending start before UI/audio/media side effects. While recording, one press performs a normal stop after the shorter of the macOS double-click interval and 0.45 seconds; two presses finish to a recoverable clipboard-only draft if no third press arrives, three presses pause capture, and a fourth press in the same continuous gesture finishes with normal Primary paste but no configured auto-Return. While paused, one fresh press resumes after that short decision window; two fresh presses finish immediately to the same clipboard-only/no-paste result. In code, the shortcut uses `.toggle` mode. |
| **Next button** | forward button, secondary button, secondary mouse button, Next Track, Next Track media key/action/event, latch button, retarget button | The separate programmable mouse button mapped to the macOS Next Track media event (`NX_KEYTYPE_NEXT`). Its action depends on whether VoiceInk++ is recording or a normal-stop result is still loading. It is not the primary button and “secondary” does not mean macOS right-click. |

In this repository, **toggle** without another qualifier means the primary button's start/stop lifecycle. It never means toggling a paste destination on or off. The short-lived Next-destination toggle experiment was deliberately reverted.

When dictation renders the product name as “Voice Ink,” “Voice Inc,” “Voice sync,” “voicing,” or a similar phrase, treat it as **VoiceInk++** only when the repository and surrounding context make that clear.

## Ethan's verified Logitech G HUB mapping

A read-only check of the live **Desktop: Default** software profile on Ethan's G502 X LIGHTSPEED on 2026-07-14 confirmed the physical distinction:

- The upper side thumb control is assigned the custom `speech to text` macro. It taps Left Shift + Left Control + Left Option in 50 ms steps, exactly matching VoiceInk++'s saved modifier-only primary shortcut (`Shift + Control + Option`) and `.toggle` recording mode. This is the **primary button**.
- A different control in G HUB's top view is explicitly labeled **Next Track**. This is the **Next button**.
- G HUB separately labels two side controls **Mouse Button 4** and **Mouse Button 5**. Neither label names the Next button in this setup. In particular, never mechanically translate Ethan's spoken alias “forward button” into raw Mouse Button 5; the relevant invariant is the separate control that emits the macOS Next Track media event.

When diagnosing the hardware mapping, verify G HUB's active profile and resolved assignment diagram as well as VoiceInk++'s stored shortcut. Do not infer the physical control from a historical G-number, a raw card ID, or the English word “forward” alone.

## Equivalent hardware Primary releases

The current shared mouse layer maps the Corsair F19 release and both Razer DPI-button releases
(F21/F22) to the same Shift-Control-Option Primary chord. Once Karabiner emits that chord,
VoiceInk++ cannot identify which physical source produced it. Each control alone is therefore one
ordinary Primary activation.

If both Razer DPI buttons are released together, Karabiner can emit two complete equivalent chords.
VoiceInk++ coalesces only the second chord when its event-tap timestamp lands less than 90 ms after
the last accepted Primary chord. A rejected duplicate does not extend the window. A later human
double-click still reaches the clipboard-only coordinator, click three still reaches Pause, and
click four still reaches the one-shot paste-without-auto-send finish. Do
not replace this narrow boundary with the old 500 ms Primary cooldown: that
would erase both accepted multi-click gestures.

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
| Idle | Primary button once | Immediately reserve continuation intent and the passive Next-only recording-start candidate, then start recorder UI/audio/media lifecycle after the 0.45-second start window expires | Not yet final |
| Idle | Primary button twice within 0.45 seconds | Cancel the pending start and its reservation; do not show the recorder, open the microphone, pause media, or notify the YouTube helper | No recording |
| Transcription pending, no active recording | Primary button twice within 0.45 seconds | Cancel the prospective new start and select red **Won’t paste** for the newest result identified by click one, if it is still transcribing; retain final text/audio and suppress provider-error banners | Clipboard/history only; no paste or auto-send |
| Transcription pending, no active recording | Primary button four times as one continuous click gesture | Keep clicks three and four bound to the newest eligible result identified by click one; replace the intermediate **Won’t paste** choice with normal delivery while suppressing that session's configured auto-send once | Existing per-session destination; paste with no auto-send |
| Recording | Primary button once | After the bounded double-click decision window, **normal stop** through base VoiceInk | Whichever system keyboard input is focused at delivery (`primaryCurrentInput`) |
| Recording | Primary button twice within the VoiceInk++ second-press window | Immediately show a red **Won’t paste** HUD state on every monitor, wait through the remaining third-press interval, then persist the original WAV plus current realtime HUD text in History and finalize normally to the clipboard; do not paste, Return, or cancel/discard, and resume only media/YouTube playback VoiceInk++ paused for this recording | No paste destination; clipboard only |
| Recording | Primary button three times as one continuous click gesture | Cancel the pending clipboard finish, pause this same recording, and stop microphone/WAV/stream input; leave media playback unchanged | Not yet final; existing tentative Next preview remains |
| Recording | Primary button four times as one continuous click gesture | After click three pauses, finish the same session through normal Primary base-current-input delivery, restore playback owned by that recording, and suppress only this result's configured Return/Enter | Whichever system keyboard input is focused at delivery (`primaryCurrentInput`); paste with no auto-send |
| Paused | Primary button once | Resume capture into this same recording after the short double-click decision window; leave media playback unchanged | Not yet final; existing tentative Next preview remains |
| Paused | Primary button twice inside the short decision window | Finish the same session as recoverable clipboard-only “Won’t paste”; do not paste or auto-send | No exact destination; final text goes only to clipboard/history |
| Recording or paused | Next button | Stop and send it back to the input captured when recording began | `recordingStart` |
| Loading after a primary-button normal stop | Next button once | **Second chance:** replace that pending session's destination with the exact editable input focused at this press | `focusedDuringTranscription` |
| Recorder bar visible, but no session remains eligible for a destination change | Next button | Consume the press as a VoiceInk++ no-op; never advance media while the bar is visible | Existing destination remains unchanged |
| Recorder bar hidden, with no active recording or eligible normal-stop result | Next button | Pass the Next Track event through to media normally | No VoiceInk++ destination action |

If a new recording is active while an older result is transcribing, the active recording determines the button action: primary stops that recording normally; Next stops it into `recordingStart`. Do not silently reinterpret that press as a retarget of an older session.

Pause is capture state inside the existing recording session, not a paste destination and not a
fourth route. Words, music, and room audio while paused are excluded from both the saved WAV and a
realtime provider stream. The realtime HUD remains visible with its last partial frozen, and the
recorder waveform slot shows a pause symbol on every monitor. Pause/resume never sends playback
commands or YouTube-helper recording notifications: Ethan controls media himself during that
interval. VoiceInk++ may still unmute system output while capture is paused and restore its optional
output mute when capture resumes. Only recording start and final stop/cancel own the normal media
pause/resume lifecycle.

The first-to-second Primary interval remains capped at 0.45 seconds because that timer also delays
every ordinary single stop. Once click two has canceled the pending stop, its clipboard-only finish
waits for click three through the full macOS multi-click interval (0.8 seconds in the verified
2026-08-02 setup). The red **Won’t paste** state appears as soon as click two is accepted and stays
visible through a committed clipboard-only transcription. Click three inside the interval clears it
before showing Pause and opens one full-system-interval continuation for click four. A fourth press
finishes that same session with normal Primary paste and a session-local no-auto-send policy; a fifth
press in the consumed burst is ignored. After either interval expires, the prior action commits and a later click
begins a fresh gesture. The recorder HUD is the only expected-route feedback; successful clipboard-only
completion never opens a separate notification banner or plays the error sound. While paused, the next
Primary press starts a fresh short decision window: it resumes when that window expires, or a second
press finishes immediately through the same clipboard-only route.

The same 0.45-second bound also delays only a prospective idle Start. The first physical press still
reserves FIFO continuation intent immediately so an older Primary result cannot press Return beneath
the pending capture, and it freezes the passive Next-only input while Electron's pre-chord snapshot
is still valid. A second accepted idle press cancels that reservation before recorder UI, microphone,
media, or helper lifecycle begins. Once a single idle press commits, the existing recording-time
single/double/triple/quadruple classifier is unchanged.

After a completed double-click receives no third press, VoiceInk++ finalizes the WAV and saves a
`recoverableDraft` History record before the
asynchronous provider finalization is enqueued. The record contains the original audio plus the last
realtime HUD transcript/translation; History can replay, copy, reveal, or retranscribe it even if the
provider or app exits before the final clipboard text arrives. Automatic retention jobs do not delete
this recovery record. Permanent deletion remains a separate confirmed History action.

The recorder bar is the strict ownership boundary for the physical Next button. While any mirrored black recorder/transcription bar is visible, VoiceInk++ consumes the complete Next Track press even if the newest session already latched, crossed the delivery cutoff, or exact delivery is temporarily disabled. Only a press made after the recorder bar is hidden may reach Music, Spotify, or another media app. This prevents an attempted latch from unexpectedly becoming Next Song because of an internal timing race.

## Non-negotiable distinctions

### Primary normal stop is always base VoiceInk

One Primary press while recording does not latch any exact input. After the short
double-click decision window proves it was a single press, it posts ordinary system-focused paste
and the current Mode's generic auto-send key to whichever keyboard input macOS owns at delivery. It
must not capture, reuse, restore, verify, or fall back to the tentative recording-start input, and it
must never enter Telegram/OpenAI/Terminal or other app-specific delivery. A second Primary press
inside that window cancels the pending stop and schedules the clipboard-only finish; a third press
inside the continuation window cancels that finish and pauses capture; a fourth press in that same
continuous gesture finalizes normal base-current-input paste with auto-send suppressed once. While paused, one fresh press resumes
after the short decision window and two presses finish through the same clipboard-only route.

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
