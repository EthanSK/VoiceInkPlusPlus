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

VoiceInk++ is Ethan Sarif-Kattan's opinionated macOS voice-to-text workflow. Speak instead of reaching for the keyboard, decide exactly which input receives every transcript, and carry on in another app while transcription, paste, and auto-send finish behind you.

It is built for people who use AI agents, terminals, chats, and editors all day—and do not want to spend even an awkward second staring at a transcription spinner.

## The reason VoiceInk++ exists

Most dictation tools bind a recording to wherever you happen to be when the result arrives. VoiceInk++ gives two mouse buttons three deliberate routes. The **primary button** is Ethan's normal/thumb/toggle recording button; the separate **Next button** is mapped to the standard macOS **Next Track** media action. [The canonical glossary](TERMINOLOGY.md) records every conversational alias.

| What you do | Where the transcript goes |
| --- | --- |
| Press the primary button again to stop normally | The exact editable input focused when you stop; never the recording-start input |
| Press the **Next button** while recording | The input captured when recording started |
| Stop normally, then press the **Next button** while transcription is loading | A second chance: replace the pending destination with the exact input focused now |

The third route is the workflow-defining one:

> Normal stop → transcription begins → focus a new input → press the Next button once → move on → VoiceInk++ returns to that input, pastes, uses that app's auto-send setting, and restores your later workspace.

The target belongs to the individual recording. Starting another recording or focusing another app does not release it.

## Ethan's recommended setup

This is the setup Ethan actually uses—not an exhaustive menu of possibilities.

### 1. Put two controls under your thumb

Use a mouse with at least two programmable buttons. Ethan uses a **Logitech G502 X LIGHTSPEED** because it is light, comfortable, smooth over its USB receiver, and highly configurable.

In **Logitech G HUB**:

- Map one side button to your normal VoiceInk++ toggle shortcut.
- Map a second side button—your **Next button**—to the standard macOS **Next Track** media action.

VoiceInk++ intercepts that Next Track event only while it can stop or retarget a recording. When idle, the media key continues to work normally.

### 2. Copy the fast VoiceInk++ stack

Ethan's current configuration is:

- **Transcription:** Deepgram Nova-3 Tuned (Local Proxy)
- **AI provider/model:** OpenAI · gpt-5.5
- **Fast direct-paste Modes:** AI enhancement off
- **Language:** Automatic
- **Paste method:** Default
- **Audio input:** the best available microphone (Ethan currently uses Digital Mic)
- **Auto-send:** Return in the Codex app, Claude desktop, ChatGPT, and the terminal/editor hosts used by Codex CLI or Claude Code; deliberately off in Chrome

Ethan's local Deepgram proxy is personal infrastructure and is not included in this repository. Use your own compatible Deepgram setup or another supported transcription model, and provide your own provider credentials. Copy the pattern—especially the safe per-app auto-send choices—rather than blindly enabling Return everywhere.

### 3. Learn the two-button rhythm

- **Finish here:** stop normally to use the input focused now.
- **Send it back:** press the Next button while recording to use the input where recording began.
- **Second chance:** after a normal stop, focus another input and press the Next button while the result is still loading. Then keep working elsewhere.

That is the whole idea: stay in the flow. Something is always happening.

## Codex and Claude Code support

All three Next-button routes work with agent inputs. The important distinction is who owns the editable macOS input:

| Agent surface | What VoiceInk++ locks | Auto-send route |
| --- | --- | --- |
| **Codex desktop** | The exact Codex composer | Verified Codex Send/System Events/humanized-Return fallbacks |
| **Codex CLI** | The exact terminal or editor input hosting the CLI | That host app's foreground paste and Return behavior |
| **Claude Code** | The exact Terminal, iTerm, Ghostty, VS Code, Cursor, or other host input | That host app's foreground paste and Return behavior |
| **Claude desktop** | The exact Claude composer | Standard verified foreground paste and Return behavior |

For a CLI agent, the recorder intentionally shows the **host app icon**—for example, Terminal or VS Code—because that app owns the real input. Create a VoiceInk++ Mode for the host app, enable Return only where automatic submission is safe, and use the Next button exactly as you would in Codex desktop. No Codex or Claude plugin, shell hook, or process-name detection is required.

## What the recorder shows

The compact recorder panel appears on every connected monitor and keeps its information spatially consistent:

```text
[ Mode ] [ waveform ] [ current focused app ] [ locked destination ]
```

- Routine “Recording” text stays out of the way; visible text is reserved for real warnings and errors.
- The current app and locked destination are separate, so you can see both what you are doing and where the transcript will land.
- The destination remains visible through transcription and updates immediately after a successful second-chance retarget.
- Delivery errors are surfaced instead of being silently reported as success.

## More flow-first features

- Record a new thought while earlier recordings are still transcribing.
- Keep each recording's Mode, input, auto-send key, and delivery state isolated.
- Paste and auto-send through a verified foreground destination, including bounded ChatGPT/Codex fallbacks.
- Restore the workspace you moved to after delivery finishes.
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
- [Use the self-improving Codex/Claude Code learnings skill](.agents/skills/learnings/SKILL.md)
- [Review update guidance](UPDATING.md)
- [Report a VoiceInk++ issue](https://github.com/EthanSK/VoiceInkPlusPlus/issues)

## Project status

VoiceInk++ is a personal, opinionated fork being shared in public. The destination workflows are intentionally specific and regression-protected; changes to them should preserve all three routes rather than collapsing them into one toggle.

There is no VoiceInk++ Homebrew cask or public binary release at present. The upstream `voiceink` cask and downloads install the upstream product, not this fork.

## Origin and license

VoiceInk++ is built on [VoiceInk](https://github.com/Beingpax/VoiceInk) by [Pax/Beingpax](https://github.com/Beingpax). The native macOS foundation, model integrations, and much of the broader application come from that project; VoiceInk++ adds Ethan's opinionated agent workflow, destination routing, overlapping-session behavior, recorder UI, and delivery hardening.

This repository is licensed under the [GNU General Public License v3.0](LICENSE). VoiceInk and related names belong to their respective owners; VoiceInk++ is Ethan's independent fork.
