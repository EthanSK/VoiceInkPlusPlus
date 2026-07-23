<div align="center">
  <img src="VoiceInk/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="156" height="156" alt="VoiceInk++ app icon">

  # VoiceInk++

  ### Become Jarvis. Keep it moving. Not a second of waiting around.

  **Either you or the agent is running.**

  [Website](https://ethansk.github.io/VoiceInkPlusPlus/) · [Build guide](BUILDING.md) · [Button glossary](TERMINOLOGY.md) · [Destination guide](RECORDING_DESTINATIONS.md) · [Issues](https://github.com/EthanSK/VoiceInkPlusPlus/issues)

  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-50e3bf.svg)](LICENSE)
  ![Platform: macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-7aa7ff.svg)
  ![Swift](https://img.shields.io/badge/Swift-native-ffbc6b.svg)
  [![GitHub stars](https://img.shields.io/github/stars/EthanSK/VoiceInkPlusPlus?style=social)](https://github.com/EthanSK/VoiceInkPlusPlus/stargazers)
</div>

VoiceInk++ is Ethan Sarif-Kattan's opinionated macOS voice-to-text workflow. With Soniox V5 realtime, your words appear directly in the actual input while you are still speaking—and remain visible in the recorder HUD too. Let current focus decide where a normal stop finishes, or use a second mouse button to lock an exact input and carry on elsewhere while final processing and auto-send finish behind you.

It is built for people who use AI agents, terminals, chats, and editors all day—and do not want to spend even an awkward second staring at a transcription spinner.

## Your words are already there

Turn on **Write Realtime Transcript into Input** and VoiceInk++ continuously replaces one range it owns with Soniox's latest cumulative hypothesis. It does not append every partial or rewrite the rest of the field.

- Keep speaking in one input and the draft grows in place.
- Move the caret to another supported input and the complete transcript-so-far appears there; new speech continues from that full draft.
- The recorder HUD still keeps the live transcript, so the UI and the real input both reflect what was heard.
- If safely removing an older same-app draft cannot be proven, VoiceInk++ leaves it alone. A cross-app copy may remain rather than steal focus or risk deleting the wrong text.
- Final delivery reconciles the owned range instead of pasting a duplicate, then follows the same Primary or Next-button send rule described below.

This makes dictation feel immediate and makes an interrupted recording less costly: much of what you said is already ordinary text in an app, not trapped only inside a transient recorder session. Unsupported rich editors and Telegram keep the established final-paste-only path.

## The reason VoiceInk++ exists

Most dictation tools bind a recording to wherever you happen to be when the result arrives. VoiceInk++ gives two mouse buttons three deliberate routes. The **primary button** is Ethan's normal/thumb/toggle recording button; the separate **Next button** is mapped to the standard macOS **Next Track** media action. [The canonical glossary](TERMINOLOGY.md) records every conversational alias.

| What you do | Where the transcript goes |
| --- | --- |
| Press the primary button again to stop normally | Whichever input owns keyboard focus at final delivery, using that input app's current Mode |
| Press the **Next button** while recording | The input captured when recording started |
| Stop normally, then press the **Next button** while transcription is loading | A second chance: replace the pending destination with the exact input focused now |

The third route is the workflow-defining one:

> Normal stop → transcription begins → focus a new input → press the Next button once → move on → VoiceInk++ delivers there with that app's auto-send setting without pulling your later workspace to the foreground.

An exact Next target belongs to the individual recording. Starting another recording or focusing another app does not release it. Primary intentionally owns no saved target: current keyboard focus remains in charge all the way to delivery.

## Ethan's recommended setup

This is the setup Ethan actually uses—not an exhaustive menu of possibilities.

### 1. Put two controls under your thumb

Use a mouse with at least two programmable buttons. Ethan uses a **Logitech G502 X LIGHTSPEED** because it is light, comfortable, smooth over its USB receiver, and highly configurable.

In **Logitech G HUB**:

- Map one side button to your normal VoiceInk++ toggle shortcut.
- Map a second side button—your **Next button**—to the standard macOS **Next Track** media action.

VoiceInk++ owns that Next Track event whenever the black recorder/transcription bar is visible. Eligible presses stop or retarget; an ineligible press is a safe no-op. When the bar is hidden, the media key works normally.

### 2. Copy the fast VoiceInk++ stack

Ethan's current configuration is:

- **Transcription:** Soniox V5 with **Real-time** enabled
- **Realtime input:** **Write Realtime Transcript into Input** enabled
- **AI provider/model:** OpenAI · gpt-5.5
- **Fast direct-paste Modes:** AI enhancement off
- **Language:** Automatic
- **Paste method:** Default
- **Audio input:** the best available microphone (Ethan currently uses Digital Mic)
- **Auto-send:** Return in the Codex app, Claude desktop, ChatGPT, and the terminal/editor hosts used by Codex CLI or Claude Code; deliberately off in Chrome

Add your own Soniox API key, select **Soniox V5**, enable **Real-time** in every Mode where you want live input writing, and keep the global realtime-input setting on. Other providers still use VoiceInk++'s ordinary final-paste path. Copy the per-app auto-send pattern rather than blindly enabling Return everywhere.

### 3. Learn the two-button rhythm

- **Finish here:** stop normally and keep using the input that should own final delivery.
- **Send it back:** press the Next button while recording to use the input where recording began.
- **Second chance:** after a normal stop, focus another input and press the Next button while the result is still loading. Then keep working elsewhere.

That is the whole idea: stay in the flow. Something is always happening.

## Codex and Claude Code support

VoiceInk++ targets the editable macOS input owned by the desktop app or CLI host. The general route model is shared, but background insertion and submission are surface-specific and are only claimed as physically verified where an installed build has completed the real route:

| Agent surface | What VoiceInk++ locks | Current evidence |
| --- | --- | --- |
| **Codex desktop** | The exact Codex composer | Recording-start Next physically verified in the background; second-chance rerun remains pending |
| **Codex CLI** | The exact terminal or editor input hosting the CLI | Host-specific exact-session code and tests exist; complete background live proof remains pending |
| **Claude Code** | The exact Terminal, iTerm, Ghostty, VS Code, Cursor, or other host input | Uses the same host-specific route; complete host-by-host live proof remains pending |
| **Claude desktop** | The exact Claude composer when resolvable | Not yet physically verified; failures must remain visible and safe |

For a CLI agent, the recorder intentionally shows the **host app icon**—for example, Terminal or VS Code—because that app owns the real input. Create a VoiceInk++ Mode for the host app and enable Return only where automatic submission is safe. No Codex or Claude plugin, shell hook, or process-name detection is required. Unverified background routes fail closed rather than pulling an app to the foreground or guessing at an input.

## What the recorder shows

The compact recorder panel appears on every connected monitor and keeps its information spatially consistent:

```text
[ v<version> ]
[  .<build>  ] [ Stop ] [ Mode ] [ waveform ] [ current focused app ] [ locked destination ]
```

- The two-row `v<version>` / `.<build>` identifier changes with every installed native release.
- Routine “Recording” text stays out of the way; visible text is reserved for real warnings and errors.
- The current app and locked destination are separate, so you can see both what you are doing and where the transcript will land.
- The destination remains visible through transcription and updates immediately after a successful second-chance retarget.
- Delivery errors are surfaced instead of being silently reported as success.

## More flow-first features

- Record a new thought while earlier recordings are still transcribing.
- Watch the cumulative Soniox draft appear directly in a supported input while speaking.
- Switch inputs mid-speech and carry the complete draft forward without duplicating every partial.
- Keep each recording's Mode, input, auto-send key, and delivery state isolated.
- Type and auto-send into a verified exact background input without interrupting the workspace you moved to.
- Keep ordinary Primary dictation on the system-focused input; use exact app-specific machinery only for the two Next routes.
- Cancel a recording instantly with Escape or the recorder's cancel control.
- Use one-shot raw/skip mode when you want untouched transcription with no auto-send.
- Pause and resume supported media without blindly toggling playback state.
- Keep the recording waveform visible across every connected display.

## Build it

VoiceInk++ currently ships as source rather than a notarized public binary. You need **macOS 14.4 or later**, Xcode, Git, Microphone permission, and Accessibility permission.

```sh
git clone https://github.com/EthanSK/VoiceInkPlusPlus.git
cd VoiceInkPlusPlus
make local
open ~/Downloads/VoiceInkPlusPlus.app
```

`make local` creates an ad-hoc signed standalone app without requiring a paid Apple Developer account. Read [BUILDING.md](BUILDING.md) for prerequisites, build targets, and troubleshooting.

## Documentation

- [Build VoiceInk++](BUILDING.md)
- [Translate Ethan's mouse-button terminology](TERMINOLOGY.md)
- [Understand the Next button and recording destinations](RECORDING_DESTINATIONS.md)
- [Read the accepted implementation learnings](LEARNINGS.md)
- [Review failed approaches before retrying delivery work](FAILED_APPROACHES.md)
- [Use the self-improving Codex/Claude Code learnings skill](.agents/skills/learnings/SKILL.md)
- [Review update guidance](UPDATING.md)
- [Report a VoiceInk++ issue](https://github.com/EthanSK/VoiceInkPlusPlus/issues)

## Project status

VoiceInk++ is a personal, opinionated fork being shared in public. The destination workflows are intentionally specific and regression-protected; changes to them should preserve all three routes rather than collapsing them into one toggle.

There is no VoiceInk++ Homebrew cask or public binary release at present. The upstream `voiceink` cask and downloads install the upstream product, not this fork.

## Origin and license

VoiceInk++ is built on [VoiceInk](https://github.com/Beingpax/VoiceInk) by [Pax/Beingpax](https://github.com/Beingpax). The native macOS foundation, model integrations, and much of the broader application come from that project; VoiceInk++ adds Ethan's opinionated agent workflow, destination routing, overlapping-session behavior, recorder UI, and delivery hardening.

This repository is licensed under the [GNU General Public License v3.0](LICENSE). VoiceInk and related names belong to their respective owners; VoiceInk++ is Ethan's independent fork.
