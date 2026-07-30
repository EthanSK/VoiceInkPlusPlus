# Copy Ethan's VoiceInk++ setup

This is a start-to-finish handoff for an agent configuring VoiceInk++ on another person's Mac.
It records Ethan's live settings as inspected on **2026-07-30**, but it never includes Ethan's API
keys, Keychain data, vocabulary, transcripts, or other private content.

## Goal

Reproduce Ethan's low-latency dictation workflow:

- GPT Live Transcribe streams partial text into the black VoiceInk++ recorder HUD.
- VoiceInk++ performs one final paste and optional Return only after recording stops.
- The primary mouse button starts/stops normal dictation.
- A separate Next button can preserve an exact destination while the user keeps working elsewhere.
- Soniox V5, AssemblyAI Universal-3.5 Pro, and Deepgram Nova 3 remain available as alternatives.

The target is Ethan's **VoiceInk++** fork, not upstream VoiceInk.

## Why a blind settings copy does not work

There are three important traps:

1. **API keys are intentionally excluded from VoiceInk++ settings exports.** Importing Ethan's JSON
   can copy model definitions and Modes, but the recipient must add her own provider keys through
   the VoiceInk++ UI.
2. **Each Mode overrides the global model.** Changing only `CurrentTranscriptionModel` can leave every
   real app Mode on its previous provider. Configure and verify every Mode.
3. **GPT Live Transcribe is not on the public `main` branch yet.** Use the public
   `codex/gpt-live-transcribe` branch at commit `2e30c9a` or newer. That commit includes the required
   connection fix `33729ea`. A build from current `main`, upstream VoiceInk, or the wrong application
   will not show the GPT model.

## Rules for the setup agent

- Use the recipient's own provider accounts and API keys. Never ask Ethan to send his keys and never
  copy his Keychain.
- Enter keys only into VoiceInk++'s secure provider UI. Do not place them in this document, Git,
  shell commands, screenshots, logs, or chat messages.
- Export/back up any existing VoiceInk++ settings before changing them.
- Do not replace or delete `/Applications/VoiceInk.app`; VoiceInk++ is a separate app.
- Do not enable automatic Return in a browser, terminal, or chat until the recipient understands
  that stopping a recording can immediately submit the text.
- Test with disposable inputs. Do not test exact delivery in a valuable Notion page, task board,
  production terminal, or important chat.

## 1. Install the correct VoiceInk++ source

Requirements:

- macOS 14.4 or later
- Full Xcode installation and Xcode Command Line Tools
- Git, Swift, and internet access for the first build

Run:

```sh
git clone https://github.com/EthanSK/VoiceInkPlusPlus.git
cd VoiceInkPlusPlus
git fetch origin codex/gpt-live-transcribe
git switch --track origin/codex/gpt-live-transcribe
git merge-base --is-ancestor 33729ea HEAD
make local
open ~/Downloads/VoiceInkPlusPlus.app
```

The `git merge-base` command must exit successfully. The built bundle is
`~/Downloads/VoiceInkPlusPlus.app`, displayed as **VoiceInk++**, with bundle identifier
`com.ethansk.VoiceInkPlusPlus`.

If GPT Live Transcribe is missing from **Settings → AI Models**, stop and verify the branch, commit,
and running app identity. Do not recreate it as a generic custom multipart model: it requires the
dedicated realtime WebSocket integration.

Ethan's inspected installation was VoiceInk++ **v2.0 build 268**. The recipient does not need that
exact build number if she builds a newer commit containing `33729ea`.

## 2. Grant macOS permissions

On first launch, grant:

- **Microphone** — required to record.
- **Accessibility** — required for paste and exact-input routing.

Review these in **System Settings → Privacy & Security** if a prompt was dismissed.

Additional permissions are route-specific:

- **Automation → System Events** may be requested by the AppleScript paste method.
- **Automation → Terminal/iTerm** is needed only for exact native terminal-session delivery.
- **Screen Recording** is needed only for VoiceInk++'s pinned Telegram exact-chat identity fallback.

Restart VoiceInk++ after changing a permission if macOS does not apply it immediately.

## 3. Configure the two mouse buttons

Ethan uses a Logitech G502 X LIGHTSPEED and Logitech G HUB, but any programmable mouse with the same
outputs can work.

### Primary button

In VoiceInk++:

- **Settings → Primary Shortcut:** modifier-only `Shift + Control + Option`
- **Shortcut mode:** `Toggle`

In G HUB, Ethan's upper side thumb control runs a `speech to text` macro that taps those three
modifiers. This is the primary button: one press starts recording and one press stops it. A double
press during recording pauses/resumes capture.

### Next button

Map a different physical mouse control to the standard macOS **Next Track** media action.

Do not map it as raw Mouse Button 5 merely because it is described as “forward,” and do not add a
second VoiceInk++ keyboard shortcut for it. VoiceInk++ listens for the macOS Next Track event. While
the black recorder/transcription bar is visible, VoiceInk++ consumes that event; after the bar hides,
it returns to ordinary media control.

## 4. Add the recipient's provider keys

Open **Settings → AI Models**. Add and verify only the providers she wants to use.

For Ethan's current default, add an **OpenAI API key** from the recipient's own funded API account.
A ChatGPT subscription is not the same thing as API credit. The key must have access to both:

- `gpt-live-transcribe` for realtime streaming
- `gpt-transcribe` for completed-audio fallback when a live session finishes without usable text

Optional alternatives require their own funded accounts and keys:

- Soniox
- AssemblyAI
- Deepgram

VoiceInk++'s settings export will not provide any of these keys.

## 5. Configure Ethan's active GPT realtime preset

In the model picker, select:

| Setting | Value |
| --- | --- |
| Provider | OpenAI |
| Displayed model | GPT Live Transcribe |
| Stored model name | `gpt-live-transcribe` |
| Realtime transcription | On |
| Language | English (`en`) |
| AI enhancement | Off |
| Output | Paste |
| Text formatting | Off |
| Clipboard context | Off |
| Selected-text context | On |
| Screen-capture context | Off |
| Auto-send | Return for Ethan's agent/chat Modes; choose deliberately for the recipient |

VoiceInk++ automatically supplies these implementation settings; do not add them as custom fields:

- Realtime endpoint: `wss://api.openai.com/v1/realtime?intent=transcription`
- Transcription model inside the session: `gpt-live-transcribe`
- Accuracy delay: `xhigh`
- Audio: PCM16 mono at 24 kHz
- Turn detection: off; the physical stop finalizes the utterance
- Empty/failed live fallback: `gpt-transcribe` at `/v1/audio/transcriptions`
- Language hint: `en`
- Vocabulary: up to 100 validated VoiceInk++ Vocabulary entries sent as keywords

Do not put `gpt-live-transcribe` in the WebSocket URL. It belongs inside the transcription session
update; using it as the connection model is rejected by the API.

Realtime words remain inside VoiceInk++'s black HUD. They must not be written provisionally into the
destination app. On stop, VoiceInk++ delivers exactly one final result.

Provider reference: [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription).

## 6. Recreate the Modes

Every one of Ethan's seven inspected Modes used the GPT preset above. Their common settings were:

```text
transcription model: gpt-live-transcribe
realtime: true
language: en
AI enhancement: false
configured enhancement provider/model: OpenAI / gpt-5.5 (inactive while enhancement is off)
text formatting: false
clipboard context: false
selected-text context: true
screen-capture context: false
output: paste
auto-send: enter
```

Create only the Modes relevant to the recipient. Select each installed application through the UI
instead of assuming its bundle identifier is identical across app versions.

| Ethan's Mode | Inspected application | Bundle identifier | Ethan's auto-send |
| --- | --- | --- | --- |
| Codex | Codex | `com.openai.codex` | Return |
| terminal enter | Apple Terminal | `com.apple.Terminal` | Return |
| claude enter | Claude desktop | `com.anthropic.claudefordesktop` | Return |
| chat | ChatGPT | `com.openai.chat` | Return |
| Chrome warning Mode | Google Chrome | `com.google.Chrome` | Return |
| producer player | Ethan's Producer Player | `com.ethansk.producerplayer` | Return |
| Default | Every unmatched app | none | Return |

The last three values are an exact snapshot, not a universal recommendation:

- The recipient probably does not have Producer Player, so omit that Mode.
- Ethan's Chrome Mode name warns that automatic submission may be dangerous, yet its live setting is
  currently Return. Use `None` for Chrome unless she explicitly wants browser forms/chats submitted.
- A Default Mode with Return can submit text in any unmatched app. A safer first-time setup uses
  `None` for Default and enables Return only in tested agent/chat Modes.

`gpt-5.5` is selected as Ethan's enhancement model, but enhancement is disabled in all Modes. It has
no effect on the active transcription path. The recipient can leave enhancement unconfigured unless
she intentionally wants a slower rewrite stage.

## 7. Match the remaining VoiceInk++ preferences

Ethan's inspected values were:

| Setting | Ethan's value | Friend-safe note |
| --- | --- | --- |
| Exact Saved-Input Delivery | On | Required for the two Next-button latch routes |
| Recorder style | Mini/default | Shows the mirrored black HUD |
| Paste method | AppleScript | Use Default first unless her keyboard layout needs AppleScript |
| Restore clipboard after paste | Off | Transcript remains on the clipboard |
| Mute audio while recording | Off | Does not change system output |
| Pause media while recording | Off | Playback stays under the user's control |
| Middle-click recording | Off | The programmable primary button owns recording |
| Audio input mode | Custom Device | Choose her own best available microphone |
| Ethan's selected mic hint | Built-in / `Digital Mic` | Do not copy a device UID from another Mac |

AppleScript paste tells System Events to issue Command-V. If it fails or produces an Automation
prompt, grant the requested permission or switch **Paste Method** to **Default**. Default uses
simulated Command-V events and is normally the more portable choice.

## 8. Add Vocabulary

Add names, projects, acronyms, and unusual proper nouns under VoiceInk++ Vocabulary. Do not copy
Ethan's personal dictionary unless he intentionally provides it.

Provider handling:

- GPT Live Transcribe receives up to 100 validated entries as `keywords`.
- Soniox receives the deduplicated Vocabulary list through its V5 streaming client.
- AssemblyAI Universal-3.5 Pro receives up to 100 bounded entries as `keyterms_prompt`.
- Built-in Deepgram Nova 3 does not currently provide the same verified completed-file vocabulary
  path as Ethan's private tuned proxy.

## 9. Alternative model presets

These are built into the GPT branch; do not create them as generic custom models.

### Soniox V5 realtime

| Setting | Value |
| --- | --- |
| Provider | Soniox |
| Displayed model | Soniox V5 |
| Stored completed-audio model | `stt-async-v5` |
| Realtime model selected automatically | `stt-rt-v5` |
| Realtime transcription | On |
| Language | English (`en`) |

Soniox exposes English as `en`; it has no documented `en-GB` accent switch. A funded account is
required. An exhausted balance can connect and then leave the recorder stuck while fallback waits.

### AssemblyAI Universal-3.5 Pro realtime

| Setting | Value |
| --- | --- |
| Provider | AssemblyAI |
| Displayed model | Universal-3.5 Pro |
| Stored model | `universal-3-5-pro` |
| Realtime transcription | On |
| Language | English (`en`) |
| Quality mode selected automatically | `max_accuracy` |

VoiceInk++ uses AssemblyAI's v3 streaming endpoint with PCM16 at 16 kHz and supplies language,
prompt, and Vocabulary keyterms during the handshake. Old names such as `universal-3-pro` and
`u3-rt-pro` are migrated; use `universal-3-5-pro` for a new setup.

### Deepgram Nova 3 realtime

| Setting | Value |
| --- | --- |
| Provider | Deepgram |
| Displayed model | Nova 3 |
| Stored model | `nova-3` |
| Realtime transcription | On |
| Language | English (`en`) |

This is the portable Deepgram option for a friend.

Ethan also has this custom definition:

```text
display name: Deepgram Nova-3 Tuned (Local Proxy)
endpoint: http://127.0.0.1:51337/v1/audio/transcriptions
model name: nova-3-tuned
multilingual: true
```

That endpoint is Ethan's private local proxy and is **not included in the public repository**. It
will fail on another Mac unless a compatible proxy is separately installed, funded, and running on
port 51337. Do not copy it as though it were a hosted provider. Use built-in Nova 3 instead.

## 10. Verify the setup end to end

Perform these checks in disposable inputs:

1. Select GPT Live Transcribe in every intended Mode, with realtime on and language `en`.
2. Start recording. Confirm live partial text appears in the black VoiceInk++ HUD before stopping.
3. Stop with the primary button. Confirm one final transcript pastes into the currently focused input.
4. In a Mode with Return enabled, confirm it submits once. In a Mode with Return disabled, confirm it
   only pastes.
5. Start a second recording immediately after stopping the first. Confirm the two final results stay
   distinct and no earlier transcript replaces the newer one.
6. With Exact Saved-Input Delivery on, test **Next while recording**: begin in disposable input A,
   move elsewhere, press Next, and confirm the final result returns to A without stealing focus.
7. Test **second chance**: primary stop, focus disposable input B while transcription is still
   loading, press Next once, move elsewhere, and confirm delivery goes to B.
8. If testing Terminal/iTerm, use a disposable shell prompt and confirm the required Automation
   permission before relying on exact native delivery.

For a GPT run, VoiceInk++ logs should identify `Streaming start requested model=GPT Live Transcribe`
and finish with a nonzero final character count. Never treat a model appearing in the picker as proof
that its API key, billing, streaming connection, paste, and Return all work.

## Troubleshooting

### Imported settings look correct, but transcription fails

Add and verify the recipient's own provider API key. Keys are deliberately absent from settings
exports.

### Changing the global model has no effect

Open every Mode and change its transcription model. Mode settings override the global selection.

### GPT Live Transcribe is absent

Verify that the running bundle is VoiceInk++ from `codex/gpt-live-transcribe` at `2e30c9a` or newer,
and that commit `33729ea` is an ancestor. Current public `main` and upstream VoiceInk are not the
required build.

### Realtime text does not appear

Check that realtime is enabled in the active Mode, the correct provider key is valid, the account is
funded, and the Mode language is supported. Do not infer these from the top-level model picker.

### The recorder stays on Transcribing

Check the active Mode's provider and the first streaming/provider error. A zero-character live final
should fall back to completed-audio transcription; invalid credentials, missing model access, poor
connectivity, or an exhausted provider balance can make that fallback fail or wait.

### Paste works but Return does not

Confirm the active app's Mode has Auto-send set to Return. For ordinary primary-stop delivery, the
input must still own normal keyboard focus. Exact Next routes have stricter app-specific verification
and may fail closed instead of submitting an uncertain target.

## Final acceptance checklist

- [ ] Correct VoiceInk++ fork and GPT branch installed
- [ ] Microphone and Accessibility granted
- [ ] Recipient's own OpenAI API key added and verified
- [ ] GPT Live Transcribe selected in every intended Mode
- [ ] Realtime on, English `en`, enhancement off, output Paste
- [ ] Primary mouse control emits Shift-Control-Option and uses Toggle mode
- [ ] Separate Next button emits macOS Next Track
- [ ] Auto-send explicitly chosen per app
- [ ] Short realtime recording shows HUD partials and produces one correct final delivery
- [ ] Rapid-overlap recording test preserves each result
- [ ] Both Next-button destination routes tested if Exact Saved-Input Delivery is enabled
