# Learnings

Per-repo institutional memory for fixes. Every entry below is a real bug we hit + how we solved it. Check this file BEFORE attempting a same-looking fix. Read [FAILED_APPROACHES.md](FAILED_APPROACHES.md) as the mandatory negative-evidence companion before retrying a mechanism that previously compiled, passed tests, or returned API success without satisfying the real app.

Maintained by the public, self-improving `learnings` skill at `.agents/skills/learnings/SKILL.md`. Codex discovers that canonical folder directly; Claude Code follows `.claude/skills/learnings` to the same skill. Newer entries and the failure ledger may explicitly supersede an older entry whose initial evidence was later disproved; never select a historical implementation by version number alone.

## Format

Each entry looks like:

```
---
**Date:** YYYY-MM-DDTHH:MM:SSZ
**Trigger:** <voice N / message snippet / null>
**Symptom:** <what was visible>
**Root cause:** <what we actually found>
**Fix:** <file:line + short prose>
**Commit:** <implementation SHA>
**Guard:** <test / lint / watchdog / comment that prevents regression — or 'none'>
---
```

## Entries

(newest first)

---
**Date:** 2026-07-31T21:07:21Z
**Trigger:** Urgent delegated report that VoiceInk++ was frozen on Transcribing and the current transcript must be recovered before any restart.
**Symptom:** VoiceInk++ stayed on Transcribing with a beachball after GPT Live had already finalized the current transcript.
**Root cause:** The AppleScript paste option called NSAppleScript.executeAndReturnError synchronously on MainActor; System Events timed out with Apple Event -1712 after 120 seconds, blocking the recorder UI and shortcut event tap while delivery—not transcription—was stuck.
**Fix:** Commit 2d9aae2 routes AppleScript paste through BoundedAppleScriptRunner off-main with a two-second hard deadline, terminates the helper at expiry, logs bounded timing, and never retries an indeterminate paste; recovered transcript/history/clipboard were preserved before release.
**Commit:** 2d9aae28a7ffbb9f4790677bad1d1f970aadc398
**Guard:** Exact Mini canonical Xcode action compiled then stalled in TestManager; direct xcrun xctest named and passed all 81 tests including boundedAppleScriptRunnerKillsTimedOutHelper and appleScriptPasteUsesTheBoundedOffMainRunner. Signed v2.0.270 is installed with CDHash dacd6cc1288a0c0dc8706bac968aa8126a3a6a04, deep/strict signing and Automation=true; live mitigation remains pasteMethod=default/useAppleScriptPaste=0.
---


---
**Date:** 2026-07-31T01:25:16Z
**Trigger:** Ethan authorized the normal v2.0.269 release path and physical triple-click/cancellation validation.
**Symptom:** Primary triple-click clipboard finalization and retained cancellation needed a uniquely versioned signed release plus a real helper path that could clear dictation ownership without resuming YouTube.
**Root cause:** The VoiceInk implementation was complete, but the companion native host initially omitted finish-dictation-preserving-playback from its explicit app-to-Chrome forwarding whitelist; source tests alone could not prove the installed cross-process route.
**Fix:** VoiceInk++ release commit dab647f ships build 269; helper commits 876fbda and c665e8f add the preserving stop lifecycle and native forwarding. The live combined helper artifact preserved the primary checkout's rapid-restart targeting work while leaving its tracked dirt untouched.
**Commit:** dab647f29d9d42e53f1cc2ea678d02073e56afe5
**Guard:** Mac Mini canonical Xcode action built then stalled in TestManager; fresh direct xcrun xctest named and passed all 79 tests. Signed v2.0.269 is installed with CDHash 0db84228c97b45f81867e3376004f7877950c97b, deep/strict signing and Automation=true. A real DistributedNotificationCenter-to-menu-app-to-native-host-to-Chrome smoke paused one live tab, then logged depthWas=1 depthNow=0, playbackCommand=none, playback-preserved, and no resume. Genuine G502 triple-click plus retained/empty cancellation remain physical acceptance gates.
---


---
**Date:** 2026-07-31T00:14:57Z
**Trigger:** Additive triple-click, partial-cancellation retention, playback-preservation, and recording-state assistant-mute requirements from task 019fb560-6dea-7ba0-9d94-0b20e6f9d458
**Symptom:** Primary had only single-stop and double-pause outcomes, so there was no safe gesture that finalized to clipboard without delivery; canceling an in-flight transcription could also lose already-produced text.
**Root cause:** Gesture state did not distinguish one continuous triple sequence from separate doubles, completion policy was coupled to paste destinations, and playback ownership clearing inside a cancellable delayed task could be skipped by a rapid next recording.
**Fix:** Commit 13020841d799f260204838fe50ca8d24e4eafbcb adds per-session clipboard-only completion, serialized genuine triple-click handling, no Mode response/paste/Return, synchronous playback-ownership clearing plus a playback-preserving bridge edge, and canceledWithResult clipboard/history retention for provider finals or saved HUD partials.
**Commit:** 13020841d799f260204838fe50ca8d24e4eafbcb
**Guard:** Focused coordinator/cancellation/source-contract tests, parsing of every modified Swift file, git diff --check, and repository-skill validation pass locally; Mini Xcode execution and physical triple/playback/cancel acceptance remain required before release.
---


---
**Date:** 2026-07-30T21:33:01Z
**Trigger:** Ethan asked for one Markdown document that her agent can use to reproduce his VoiceInk++ setup
**Symptom:** A friend cannot reproduce Ethan's GPT realtime setup from a settings export alone
**Root cause:** VoiceInk++ exports intentionally omit provider credentials, per-Mode modeConfigurationsV2 overrides the global model picker, and GPT Live Transcribe is currently shipped on codex/gpt-live-transcribe rather than public main
**Fix:** Added ETHAN_VOICEINK_SETUP.md with a secret-free start-to-finish handoff, exact inspected Mode/provider settings, branch pin, provider alternatives, mouse mapping, permissions, and acceptance tests
**Commit:** a8366f0
**Guard:** Credential-pattern scan, Markdown diff check, official OpenAI reference reachability, remote branch SHA verification, and per-Mode acceptance checklist
---


---
**Date:** 2026-07-29T18:17:23Z
**Trigger:** Ethan reported that starting recording B before A finished caused the previous transcription to paste and asked for logging on the next occurrence.
**Symptom:** A rapid-overlap report could not be diagnosed later because the managed delivery trace was ephemeral and omitted the full recording, streaming, and pipeline lineage.
**Root cause:** The trace lived only under /tmp and retained delivery events without every immutable generation, sequence, recording-session, transcription, audio-file, final-length, and digest boundary needed to distinguish late job A from stale text delivered as job B.
**Fix:** Commit 4561588 made live-delivery-trace.sh persist privacy-bounded daily mode-0600 logs for seven days and allowlisted the complete job/provider/delivery lifecycle while redacting provider error bodies and excluding transcript text.
**Commit:** 4561588
**Guard:** bash -n, git diff --check, quick_validate.py, a redaction fixture, verified 0700/0600 permissions, and a real complete generation 2 sequence 44 trace through pipeline removal with no transcript fields.
---


---
**Date:** 2026-07-29T17:57:44Z
**Trigger:** Ethan reported that immediately starting another recording pasted or replaced it with the previous message and supplied the 18:47-18:48 history screenshot.
**Symptom:** A rapid Primary A-stop then B-start appeared to paste A as B and suggested the previous transcript had been reused.
**Root cause:** The correlated v2.0.268 run had distinct immutable WAVs and jobs: A stopped at 18:47:53.621, B started at 18:47:54.170, and A's 131-character final completed at 18:47:54.480 while B was recording. B's separate 4.441-second WAV was effectively silent (mean -42.9 dB, max -29.2 dB), produced zero committed segments, and its completed-audio fallback also returned empty. A was late-but-correct delivery; B never produced text.
**Fix:** Investigation only: preserve FIFO delivery and the rule that starting B does not cancel A. Diagnose this symptom by correlating start/stop/final timestamps, immutable audio identity, audio level, and history status before changing job ownership or dropping an earlier Primary result.
**Commit:** investigation-only
**Guard:** The physical evidence showed four distinct WAV basenames and hashes around rows 5025-5028; existing eagerStreamingFinalsMayFinishInReverseButDeliverInRecordingOrder and one-shot audio-identity tests preserve ordered non-reused results. The managed live-delivery trace remains the acceptance tool for any future case where B contains real speech but receives A's digest.
---


---
**Date:** 2026-07-29T17:04:57Z
**Trigger:** When adding or repairing an OpenAI Realtime transcription provider, run .agents/skills/learnings/scripts/openai-transcription-probe.swift with synthetic PCM24k and WAV before building or changing the installed model.
**Symptom:** GPT Live Transcribe was implemented and unit-tested, but the first real WebSocket session update was rejected before audio could stream.
**Root cause:** The Realtime connection URL incorrectly used gpt-live-transcribe as the session model. A transcription model belongs only at audio.input.transcription.model; the dedicated connection must use ?intent=transcription.
**Fix:** Open the WebSocket at wss://api.openai.com/v1/realtime?intent=transcription, then send the transcription session.update with gpt-live-transcribe, 24 kHz PCM, xhigh delay, languages, prompt, and validated keywords. Keep gpt-transcribe on the file endpoint as the empty-live fallback.
**Commit:** 33729ea847a338858329542d86454676178ba8dd
**Guard:** A privacy-bounded synthetic live probe produced session.updated, 14-15 real deltas, and a non-empty completed transcript; the completed-WAV probe also accepted languages[] and keywords[] and returned non-empty text. Mac Mini direct xcrun xctest named and passed all 73 tests at 33729ea after the canonical TestManager stall. Signed v2.0.268 is installed with PID 99337, CDHash 592df3ac0104d33a22a913dc97f6e58e957ca371, deep/strict signing, Automation=true, all seven Modes on gpt-live-transcribe/realtime/en, and official VoiceInk unchanged. Physical microphone/HUD/final-delivery acceptance remains pending.
---


---
**Date:** 2026-07-27T19:45:33Z
**Trigger:** Ethan asked for Primary double-press pause/resume to leave YouTube and other media alone because he wants to control playback himself while capture is paused.
**Symptom:** Pausing microphone capture posted `recordingStopped` and resumed `PlaybackController`, which could start YouTube or another paused source; resuming capture posted `recordingStarted` and paused playback again.
**Root cause:** The original pause implementation modeled an in-session capture pause as a temporary recording stop followed by a new recording start, even though the WAV, realtime provider, destination, and HUD remain one continuous session.
**Fix:** Commit 194c1dd removes playback-controller and YouTube-helper lifecycle actions from successful in-session pause/resume. VoiceInk++ may still lift its optional system-output mute while capture is paused and restore that mute when capture resumes; only actual recording start and final stop/cancel own the paired media/YouTube-helper lifecycle.
**Commit:** 194c1dd5e8dc0fcb93ef75aa48040252aad14580
**Guard:** Mac Mini canonical Debug Xcode test action compiled before the known TestManager stall; fresh direct `xcrun xctest` named and passed all 70 tests, including `capturePauseResumeNeverControlsPlaybackOrYouTubeHelper`, paused-audio gating, Primary isolation, realtime HUD-only, and both Next routes. Signed v2.0.267 is installed with PID 24561 and CDHash acff3194dd84b88c427f2169770c5409fcbe0aaf; deep/strict signing and Automation=true verify, and `/Applications/VoiceInk.app` remained byte-identical. A physical double-click/media observation remains pending and must confirm playback does not change on either transition.
---


---
**Date:** 2026-07-26T19:39:25Z
**Trigger:** Ethan reported that a rapid new recording after stopping the previous one sometimes did not paste, did not appear to transcribe, or pasted the older result.
**Symptom:** Rapidly starting and stopping a new realtime recording while an older result was still finishing could leave delivery missing, delayed, or apparently paired with the older transcript.
**Root cause:** AssemblyAI provider finalization still began only when the serial post-processing queue reached that job. An older job could therefore keep a stopped session socket open while a newer recording connected, and final completion timing was not separately bound from FIFO delivery timing.
**Fix:** Commit 3776298 gives each streaming recording one audio-bound, one-shot finalization task; AssemblyAI starts provider commit/close at stop, while the serial queue awaits that exact result and still delivers immutable jobs in recording order. Startup completion, cancellation, empty-final batch fallback, Primary/Next routing, and shared-resource guards remain independent.
**Commit:** 3776298fd04e6ffd251f76302358050303291b3e
**Guard:** Fresh Mac Mini direct xcrun xctest passed all 69 named tests, including reverse provider completion with FIFO delivery, one-shot audio identity rejection, per-session cancellation, startup-before-commit ordering, reset drain, immutable job identity, empty-final fallback, realtime HUD-only, Primary isolation, and both Next-route guards. Physical rapid A/B AssemblyAI trace remains the release acceptance gate.
---


---
**Date:** 2026-07-26T19:05:28Z
**Trigger:** Ethan's screenshot showed no Universal Pro 3 under Custom and he asked for Soniox, Universal, and other configured transcription models in one list.
**Symptom:** AI Models > Custom showed only the Deepgram proxy, so connected Universal-3.5 Pro, Universal-2, and Soniox appeared to be missing even though they were configured and usable.
**Root cause:** The third catalog tab was hard-coded to render only OpenAI-compatible CustomCloudModel endpoints; connected provider models were visible only by drilling into Cloud provider panels.
**Fix:** Commit 772e1d6 renames the tab Configured and lists every model from providers with stored credentials alongside custom endpoints, sorting models used by any Mode first and marking Universal-3.5 Pro In use.
**Commit:** 772e1d6602f0026e8e306a6d2bdb7d3081523e9d
**Guard:** Mac Mini direct xcrun xctest named and passed all 65 tests including configuredCatalogListsEveryModelFromConnectedProviders after the canonical TestManager stall. Signed v2.0.265 is installed with CDHash 2a60d81bef187d9d714a8ca2528812ba172a6782, deep/strict signing and Automation=true; Computer Use visibly confirmed Universal-3.5 Pro, Soniox V5, Universal-2, and Deepgram in Configured.
---


---
**Date:** 2026-07-26T00:05:14Z
**Trigger:** Ethan asked to replay roughly 20 prior recordings, rank AssemblyAI against Soniox, and tell him which is better.
**Symptom:** The provider choice needed same-audio evidence rather than vendor claims after AssemblyAI Universal-3.5 Pro max-accuracy became usable.
**Root cause:** On the latest 20 meaningful saved dictations, the models were often equivalent but had different short-utterance and latency tradeoffs; the corpus contained only three Vocabulary terms and did not materially stress proper-noun prompting.
**Fix:** Keep the result as a measured comparison, not a universal winner: normalized text matched on 7/20; conservative review scored Soniox 4 clear wins, AssemblyAI 2, and 14 ties or audio-uncertain cases. Soniox database-recorded post-stop median was 265 ms versus AssemblyAI termination median 934 ms; AssemblyAI p95 was 1.797 s versus Soniox 3.890 s because Soniox had two very-short-clip outliers. AssemblyAI remains selected only because Ethan explicitly requested the live test.
**Commit:** b4d6495
**Guard:** Private report voiceink-realtime-stt-comparison-1785023509121.json is mode 0600 under /private/tmp and contains 20 successful universal-3-5-pro/max_accuracy/en/no-prompt comparisons. Do not publish transcripts or promote either model from this narrow corpus; treat unauditioned disagreements as ties and rerun a proper Vocabulary-heavy corpus before a durable default decision.
---


---
**Date:** 2026-07-26T00:04:01Z
**Trigger:** Ethan requested a same-recording quality and latency comparison and continued using VoiceInk++ during the long run.
**Symptom:** A 20-recording Soniox-versus-AssemblyAI comparison stopped at sample 12 with Unauthorized Connection: Too many concurrent sessions while Ethan used VoiceInk++ live.
**Root cause:** The account concurrency boundary can overlap the private comparison WebSocket with a real VoiceInk++ recording, and the first harness opened the next session immediately after close with no contention retry or report resume.
**Fix:** Commit b4d6495 makes the private harness await WebSocket close, yield with bounded backoff only for the exact concurrency error, resume successful row IDs from an existing mode-0600 report, and exclude sub-half-second history artifacts.
**Commit:** b4d6495
**Guard:** The interrupted report resumed without retranscribing ten completed rows, yielded twice to a live VoiceInk++ session, then completed 20/20 with universal-3-5-pro, max_accuracy, en, Vocabulary keyterms, and no contextual prompt. Node syntax, dry-run corpus checks, skill validation, and diff checks pass.
---


---
**Date:** 2026-07-26T00:04:01Z
**Trigger:** Ethan authorized reusing the AssemblyAI key already configured on his Mac Mini and asked to use the new realtime model.
**Symptom:** AssemblyAI Universal-3.5 Pro max-accuracy was implemented in v2.0.264, but the live Mac still used Soniox because its AssemblyAI credential and per-Mode selection were absent.
**Root cause:** VoiceInk++ LOCAL_BUILD stores provider keys as UserDefaults Data, all seven modeConfigurationsV2 records override the top-level model, and WhisperPrompt.init rewrites an empty English TranscriptionPrompt to its stock greeting on launch.
**Fix:** Securely piped the already-authorized AssemblyAI credential from the paired Mini without exposing it, proved universal-3-5-pro/max_accuracy/en with one saved-audio endpoint probe, switched all seven Modes plus CurrentTranscriptionModel, preserved every auto-send field, and neutralized the inherited sample as an explicit blank English custom prompt that AssemblyAI trims to nil.
**Commit:** 5c22c13
**Guard:** Installed signed v2.0.264 remained CDHash 38ff5592981cc6590c500ba3a8a3c326173b5f01 with Automation=true; post-restart defaults show 7/7 universal-3-5-pro realtime en with Enter preserved, and PID 97722 logged Streaming start requested model=Universal-3.5 Pro then a non-empty 122-character final. Never expose or record provider credentials.
---


---
**Date:** 2026-07-25T22:25:00Z
**Trigger:** Ethan asked whether a slightly slower but higher-quality real-time model could beat Soniox V5 while keeping post-stop waits bounded.
**Symptom:** “Real-time” can be mistaken for a guarantee that stop latency never grows, and provider model names conceal whether VoiceInk++ actually supports their quality controls and Vocabulary.
**Root cause:** Current official APIs expose different quality-first streaming controls. AssemblyAI Universal-3.5 Pro Streaming offers `max_accuracy`, contextual prompting, and keyterms, but VoiceInk++ still registers `universal-3-pro` and the pinned LLMkit adapter recognizes only that older name, does not send the new `mode`, and would omit keyterms for an unrecognized 3.5 name. Speechmatics Enhanced is already wired with custom Vocabulary and a fixed two-second `max_delay`; its official guidance says four seconds reaches Batch-equivalent accuracy and two seconds is roughly one-percent below Batch. OpenAI `gpt-realtime-whisper` offers `high`/`xhigh` delay tuning but requires a dedicated Realtime integration and does not support prompt steering. Deepgram Nova-3 already streams with `en-GB` and keyterms, whereas Flux is optimized for conversational turn-taking rather than long-form dictation. Streaming normally keeps up while speech is arriving, so post-stop work is mainly the unfinalized tail; it is not an absolute bound when the network/provider falls behind or VoiceInk++ receives an empty final and invokes its existing completed-audio Batch fallback.
**Fix:** Investigation only. Keep Soniox V5 as the accepted default until identical real microphone recordings prove a replacement. Test Speechmatics Enhanced at the current two-second delay as the lowest-effort quality comparator, and treat AssemblyAI Universal-3.5 Pro Streaming `max_accuracy` as the strongest quality-first integration candidate. Measure stop-to-final p50/p95, proper-noun/Vocabulary accuracy, punctuation/edit burden, empty-final/fallback rate, and cost.
**Commit:** investigation-only
**Guard:** Never call a vendor universally better from its own benchmark. Before selecting AssemblyAI 3.5, update the registry and streaming adapter deliberately and prove the exact model, `max_accuracy`, prompt, and keyterm parameters in a sanitized endpoint test. Before changing Speechmatics delay, expose or deliberately set it and test real long dictation; do not infer a guaranteed stop bound from partial HUD text.
---

---
**Date:** 2026-07-25T21:58:00Z
**Trigger:** Ethan reported another apparent paste-plus-Return miss in Claude and asked for a Computer Use investigation of Claude Code.
**Symptom:** Foreground Primary delivery in Claude appeared intermittent even though VoiceInk++ logged both the paste command and Return event as posted.
**Root cause:** The reported surface was Claude Desktop 1.24012.9 in Code mode (`/Applications/Claude.app`, PID 52609), not Claude Code inside a terminal/editor host. The correlated 22:53:50 run selected `primaryCurrentInput`, resolved `targetAutoSend=enter`, posted Command-V, waited 100 ms, and posted one humanized HID Return while Claude remained frontmost; Computer Use then showed the submitted message and Claude responding. In the disposable Claude task, a settable prompt plus labelled Send control accepted ordinary Return both while idle and while another response was running; adding a draft during the latter changed Stop to Send and Return submitted the steering prompt. Claude therefore does not require a different key. The remaining unobserved boundary is whether its Electron prompt has consumed Command-V by the time VoiceInk++ posts Return; event-post success alone cannot prove that.
**Fix:** Investigation only; no runtime behavior changed. Keep Claude Desktop separate from Claude Code host testing, preserve the running bounded delivery trace, and correlate the next visible miss with composer/Send state before changing the generic Primary delay or event route.
**Commit:** investigation-only
**Guard:** Disposable Computer Use probes visibly submitted and cleared the Claude prompt in idle and in-flight states without touching Ethan's active task. Do not add a Claude-specific Primary path: Primary must remain base-current-input. If a later trace proves the prompt still contains the transcript after Return, compare the current 100 ms settle with upstream VoiceInk's 500 ms delay using a uniquely numbered signed build and repeated physical foreground tests.
---


---
**Date:** 2026-07-25T18:57:39Z
**Trigger:** Ethan asked for the live website URL and for Claude Opus 5 to review and improve the already signed-off public launch.
**Symptom:** The public Pages route lab still claimed Primary locked the exact input focused at stop, duplicated route copy in JavaScript, and hid the two Next routes when JavaScript was unavailable.
**Root cause:** The public site predated the primaryCurrentInput isolation contract, and the same routing explanation was maintained separately in HTML, JavaScript, and README without contract-level validation.
**Fix:** Commit b9783c4 makes HTML the three-route source of truth, keeps Primary base-current-input at final delivery, limits exact ownership to Next, adds progressive enhancement and accessibility fixes, and aligns README, agent support, permissions, source-only guidance, and pause/resume copy.
**Commit:** b9783c430175535dbe194f05a71c1887d9fb8812
**Guard:** Static-site validator, html-validate, node --check, markdown-link-check, structured-file checks, local HTTP checks, and diff checks passed. GitHub Pages built from main/docs with HTTPS; live HTML/CSS/JS hashes match local b9783c4 and the custom 404 returns the intended page. Personal-Chrome visual QA was unavailable because the only verified personal window was an unrelated LinkedIn tab on Ethan's active display.
---


---
**Date:** 2026-07-25T18:18:37Z
**Trigger:** Ethan reported the normal stop delay was a bit too long and the failure bar overlapped the heightened real-time block; it should appear above it.
**Symptom:** After adding Primary double-press pause/resume, an ordinary single-press stop felt noticeably delayed, and a warning/error bar overlapped the expanded real-time transcript recorder block.
**Root cause:** VoiceInk++ used Ethan's full 0.8-second macOS double-click preference as its stop-decision delay. Separately, NotificationManager reserved a fixed 34pt recorder height even though the real-time mini HUD occupies 97pt before bottom padding and stacked cards can extend it further.
**Fix:** Commit 4f71b77 caps only the Primary pause gesture at the shorter of the system interval and 0.45 seconds, preserves faster system preferences, and routes notification placement through shared mini-recorder layout metrics for compact, real-time, assistant, and stacked-card envelopes.
**Commit:** 4f71b77
**Guard:** Exact Mac Mini candidate passed all 62 named direct xcrun xctest tests after the canonical locally signed Xcode action compiled then hit the known TestManager stall. New guards prove the 0.8-to-0.45 cap and 16pt notification clearance above one real-time HUD and stacked cards; all existing pause, Primary isolation, Next, realtime HUD-only, Codex/Telegram, and Terminal tests passed. Signed v2.0.263 is installed with CDHash ec64bc2689d79c5fdff4004e597d245db4483d98, deep/strict signing and Automation=true. Ethan then physically confirmed on v2.0.263 that Primary pause/resume still worked and the resumed recording finalized and delivered its transcript, proving the shorter decision window preserved the gesture and post-resume stop path. Separate physical observation of paused-audio/media exclusion and warning-bar clearance remains pending.
---


---
**Date:** 2026-07-25T17:59:10Z
**Trigger:** Ethan asked for a double-click of the Primary trigger while recording to pause temporarily, then another double-click to continue so music could play without being transcribed.
**Symptom:** The Primary mouse button could only start or finalize dictation, so Ethan could not pause mid-recording to listen to music or read without that interval entering the WAV/realtime transcript.
**Root cause:** The Primary shortcut manager had no double-press decision window or paused capture state, and Recorder/CoreAudioRecorder exposed only start/stop rather than an atomic callback gate plus resumable AUHAL capture.
**Fix:** Commit 681e605 adds a macOS-double-click-bounded Primary single-versus-double decision, pause/resume inside the same recording session, atomically gated AUHAL/WAV/realtime callbacks, media and YouTube-helper resume/pause pairing, mirrored amber pause HUD, and pending-stop cancellation before Next; all Primary/Next delivery routes remain unchanged.
**Commit:** 681e60528fe943eacaec6275fee3157682af30d4
**Guard:** Mac Mini canonical Xcode action built but hit the known TestManager stall; direct xcrun xctest named and passed all 59 tests, including new Primary double-press, paused-audio gating, Next-while-paused, modifier, realtime-HUD-only, Primary isolation, Codex/Telegram, Terminal, and second-chance guards. Signed v2.0.262 is installed with CDHash 6e8cf87efa239c203582888b997769494884518e, deep/strict signing and Automation=true. Ethan then physically confirmed the Primary double-press pause/resume gesture worked in a real dictated test on v2.0.262; separate observation of paused-audio exclusion and media/YouTube transitions remains pending.
---


---
**Date:** 2026-07-24T18:43:35Z
**Trigger:** Ethan requested a daily update check, default on, with a disable switch and a notification saying there is a VoiceInk update.
**Symptom:** VoiceInk++ needed a default-on daily upstream update alert that remains review-only and can be disabled in Settings.
**Root cause:** Sparkle installation is deliberately inactive in the commercial-free local fork, and wholesale upstream merges are unsafe because VoiceInk++ diverges in destination, delivery, provider, and UI contracts.
**Fix:** Commit 87165bd replaces the unused Sparkle controller with a 24-hour GitHub latest-release check, deduplicated native notification plus in-app fallback, and a Daily VoiceInk Update Checks Settings toggle; checks never install, merge, or replace either app.
**Commit:** 87165bdc31532cfe4e0d35278eef7a849c361ce2
**Guard:** Fresh Mini candidate passed 52 named direct xcrun xctest tests after the canonical TestManager stall. Signed v2.0.261 is installed with CDHash c0e19e79f02e81bb168f90013d220fd5b454bb1a, deep/strict signing and Automation=true. Launch wrote VIPPLastDailyUpdateCheck; upstream returned v2.0 and VIPPLastNotifiedUpstreamRelease remained absent, proving no false alert. Exact delivery stayed enabled and /Applications/VoiceInk.app was untouched.
---


---
**Date:** 2026-07-24T17:48:57Z
**Trigger:** Ethan: remember this version. It also works for Telegram.
**Symptom:** VoiceInk++ needed a durable working checkpoint after repeated Codex and Telegram latch regressions.
**Root cause:** Signed v2.0.259 preserves the pinned Telegram 12.9/282526 exact-chat identity and one-shot targeted-HID-Return route while adding only the independent ChatGPT build-5828 audit.
**Fix:** No additional runtime change: preserve v2.0.259 commit 049efc7 as the accepted Codex-and-Telegram recordingStart checkpoint.
**Commit:** 049efc7133bf96530ebbff0a965e48e86bb4fbaf
**Guard:** Ethan confirmed Telegram worked. The correlated v2.0.259 trace captured the exact Telegram composer and privacy-bounded visual identity, selected recordingStart, revalidated matching chat identity while OBS remained frontmost, verified background insertion, issued one telegramTargetedHIDReturn, and verified composer clear with success=true verification=verifiedCleared. This proves Telegram recordingStart only; focusedDuringTranscription and wrong-chat rejection remain separate.
---


---
**Date:** 2026-07-24T17:45:18Z
**Trigger:** Ethan reported Codex Next-button latch pasted but no longer sent at all on v2.0.258.
**Symptom:** v2.0.258 inserted a recordingStart transcript into the exact background ChatGPT-hosted Codex composer but never submitted it.
**Root cause:** ChatGPT.app updated to 26.721.31836 build 5828 with Chromium 150.0.7871.128; the bounded tree still exposed exactly one unlabelled idle Send candidate, but the fail-closed audited tuple list ended at build 5813 and rejected it before action.
**Fix:** Commit 049efc7 adds only the exact build-5828 tuple plus wrong-build and wrong-Chromium rejection tests; Primary, insertion, focus preparation, generic Return, verification, and other apps remain unchanged.
**Commit:** 049efc7133bf96530ebbff0a965e48e86bb4fbaf
**Guard:** Signed v2.0.259 passed all 46 named Mini tests. Ethan's 2026-07-24 recordingStart retest verified exact background insertion while Chrome stayed frontmost, resolved FooterActions Send twice, issued one skyLightTargetedSendClick, and this exact dictated message visibly arrived in Codex; post-state remained unreadable/indeterminate, so visible submission is part of acceptance and focusedDuringTranscription remains separate.
---


---
**Date:** 2026-07-24T17:11:26Z
**Trigger:** Ethan reported another failed Codex latch test and asked to return to the earlier unreliable-but-working behavior.
**Symptom:** Signed v2.0.257 selected recordingStart with an exact Codex target and a non-empty Soniox final, but inserted nothing because exact delivery aborted before resolver, paste, or Send.
**Root cause:** The correlated trace failed at the read-only system keyboard-focus snapshot: macOS returned no readable focused element across the prior three-attempt 50 ms window. A separate v257 attempt reached the later saved-wrapper resolver, so these are distinct failure stages.
**Fix:** Commit 5652c3b keeps Primary, exact identity, insertion, and Send unchanged; it makes the focus snapshot return immediately on success but tolerate transient unavailability for nine attempts across at most 200 ms, and adds privacy-safe resolver-stage diagnostics. Signed v2.0.258 is installed with CDHash 3e48da503f346e1eea88b62c4f5c2cc3617a716e.
**Commit:** 5652c3b
**Guard:** Fresh Mac Mini direct xcrun xctest named and passed all 46 tests, including exactNextDeliveryToleratesTransientSystemFocusReadUnavailability, primaryDeliveryUsesOnlyBaseVoiceInkSystemFocusedCommands, secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt, and realtimeStreamingRemainsRecorderHUDOnlyUntilFinalDelivery. Physical Codex latch acceptance remains pending and must agree with the live trace.
---


---
**Date:** 2026-07-24T16:45:54Z
**Trigger:** Ethan asked whether Soniox could be configured for a UK accent.
**Symptom:** Soniox V5 was visibly configured as generic English, so it was unclear whether VoiceInk++ should send a regional `en-GB` locale for Ethan's British accent.
**Root cause:** Soniox's current official language-hints contract accepts ISO language codes and publishes English only as `en`; it exposes no accent or regional-English parameter. VoiceInk++ and its pinned LLMkit adapter therefore correctly send `language_hints=["en"]` with strict English restriction. `en-GB` is not in SonioxProvider's supported-language list and would be normalized back to a supported fallback before a recording.
**Fix:** No runtime change: the active `com.ethansk.VoiceInkPlusPlus` defaults and all seven Mode overrides already select Soniox V5 real-time with `selectedLanguage=en`, which is the strongest documented English configuration. Soniox handles regional accents within its English model; arbitrary context could describe a UK setting but is not a documented accent selector and is not used as one.
**Commit:** investigation-only; installed v2.0.257 implementation unchanged
**Guard:** Before changing a Soniox language value, check the official supported-language and language-hints docs plus `SonioxProvider.languageCodes`; do not copy Deepgram's BCP-47 `en-GB` value into Soniox.
---

---
**Date:** 2026-07-24T16:45:53Z
**Trigger:** Ethan reported “couldn't verify the saved background input” and no pasted result from the Codex latch behavior.
**Symptom:** Installed v2.0.257 captured Codex as the locked destination, but a Next-while-recording attempt inserted nothing and surfaced the saved-background-input warning.
**Root cause:** The correlated trace selected `recordingStart`, captured the exact Codex `AXTextArea`, and received a non-empty 85-character Soniox final. Delivery then failed before any text insertion or Send lookup because `prepareBackgroundDelivery` could not re-resolve the saved Codex element/window after another app became frontmost. The current coarse error does not distinguish an unreadable retained window/wrapper from a rejected context fingerprint.
**Fix:** Investigation only: keep the exact-input failure closed and isolate the next repair to saved Codex element/window re-resolution diagnostics. Do not change Soniox, targeted Unicode, or Return/Send handling for this symptom because none of those stages ran.
**Commit:** investigation-only; installed v2.0.257 implementation unchanged
**Guard:** Correlated trace at 2026-07-24 17:36:15–17:36:25 BST proves `recordingStart`, `targetCaptured=true`, Soniox `finalChars=85`, then `Background exact-input preparation could not resolve the saved element/window`; require resolver-stage diagnostics and a physical build-5813 Next-route rerun before any implementation is accepted.
---

---
**Date:** 2026-07-24T01:08:55Z
**Trigger:** Ethan reported v2.0.255 was not reliably pressing Enter in Codex, suggested a small delay, then physically confirmed v2.0.257: 'Okay, it's working.'
**Symptom:** VoiceInk++ v2.0.255 could paste into the current Codex composer but ordinary Primary Return was intermittent or absent.
**Root cause:** The base current-input route had no intentional post-paste settle: live v255 timing could put Return only about 31 ms behind Command-V, while upstream VoiceInk deliberately allows 500 ms for the destination to consume the paste.
**Fix:** Commit bd6beae keeps Primary structurally isolated and generic, but adds one bounded 100 ms wait between confirmed Command-V posting and the Mode's ordinary HID auto-send; v2.0.257 was built, signed, installed, and Ethan confirmed that normal Primary paste plus Return worked.
**Commit:** bd6beae
**Guard:** Mac Mini direct xcrun xctest named and passed all 45 tests. Installed v2.0.257 CDHash 9664c70e1c4af3939da269b445ebda2f04bb4b0a produced two consecutive primaryCurrentInput traces with targetCaptured=false, appSpecificDelivery=false, commandPosted, and settleMs=100 before Ethan said it was working. This accepts only foreground Primary in Codex; it does not accept either Next route.
---


---
**Date:** 2026-07-24T00:23:43Z
**Trigger:** Ethan requested stripping VoiceInk++ of payments, Pro purchase prompts, and related commercial notifications.
**Symptom:** VoiceInk++ still contained upstream Pro purchase, trial, license-validation, affiliate-promotion, and remote promotional-announcement surfaces that are irrelevant to Ethan's personal fork.
**Root cause:** The fork inherited VoiceInk's commercial distribution layer and onboarding license gate even though VoiceInk++ is independently configured and has no need to sell or validate Pro access.
**Fix:** Removed the commercial managers, views, onboarding gate, transcript trial-expiry injection, affiliate and upgrade promotions, remote announcement runtime, commercial localizations, and Polar dependency; preserved functional errors, recorder feedback, macOS notifications, and Sparkle updates; migrated legacy onboarding stage license to trust.
**Commit:** 3590c3648d6bcbbf12dc86e3ee2afed79b47e193
**Guard:** CommercialFreeDistributionTests scans project membership and source for forbidden commercial runtime symbols; README and UPDATING document the commercial-free distribution contract. Exact signed v2.0.255 passed 45 named xctest tests, deep/strict signature validation, Automation entitlement inspection, and bundle-string audit before install.
---


---
**Date:** 2026-07-23T23:47:35Z
**Trigger:** Ethan reported that Soniox realtime Primary pasted without Return and sometimes appeared not to paste after the HUD-only release.
**Symptom:** Post-install v2.0.254 traces in Codex issued the ordinary Primary Cmd-V plus immediate HID Return, while otherwise identical Chrome Primary traces pasted non-empty finals and ended with `targetAutoSend=none` / `autoSend=none`.
**Root cause:** Primary was correctly isolated from exact/latch delivery, but the saved Chrome Mode still had `autoSendKey=none` under the historical “TOO DANGEROUS” preference. Realtime finalization and destination routing cannot manufacture Return when the resolved current-app Mode explicitly disables it.
**Fix:** Configuration-only: after Ethan explicitly superseded that safety preference, the Chrome Mode was changed to `autoSendKey=enter` and VoiceInk++ v2.0.254 was restarted. All seven saved Modes now use Soniox V5 realtime, English, paste output, and Enter; Next-button code and the signed binary are unchanged.
**Commit:** configuration-only; installed implementation `e1a1108` unchanged
**Guard:** Diagnose these paths independently: `finalChars=0` requires completed-file fallback; non-empty `primaryCurrentInput` plus `targetAutoSend=none` requires checking the resolved Mode; non-empty `targetAutoSend=enter` must log the immediate HID auto-send. Never “fix” either case by sending Primary through app-specific exact delivery.
---

---
**Date:** 2026-07-23T23:36:13Z
**Trigger:** Ethan reported that Primary sometimes pasted without Return or did not paste when stopping Soniox realtime while still speaking.
**Symptom:** A very short Soniox V5 realtime Primary recording could stop with finalChars=0, causing a blank paste attempt or no useful paste even though ordinary Primary routing remained correct.
**Root cause:** StreamingTranscriptionSession treated every successful stopAndGetFinalText return, including empty or whitespace text, as a completed final and therefore bypassed the existing completed-file fallback.
**Fix:** Build 254 classifies empty realtime finals as incomplete and runs the same audio through the provider batch path before the unchanged base Primary paste plus Mode Return; non-empty realtime finals remain immediate and Next-button delivery code is untouched.
**Commit:** e1a1108c01a6d1326b35e902bcc1c59390439bf1
**Guard:** Mac Mini direct xcrun xctest named and passed all 43 tests including emptyRealtimeFinalFallsBackInsteadOfDeliveringBlankText, realtimeStreamingRemainsRecorderHUDOnlyUntilFinalDelivery, Primary isolation, and both Next ownership guards. Signed v2.0.254 is installed with CDHash 834dcfdd83c3ad85e066c8883f2723740736276e; physical empty-final fallback still needs a naturally reproduced short stop.
---


---
**Date:** 2026-07-23T15:44:12Z
**Trigger:** Ethan confirmed: Soniox partials stay in the black float and final paste/send happens once on stop.
**Symptom:** The proposed Soniox real-time design would mirror provisional speech into another app while recording, although the simpler desired behavior is to keep live text in VoiceInk++ and paste only once on stop.
**Root cause:** An earlier dictated request was interpreted as destination-side live drafting; Ethan later explicitly corrected it before that e19a123-through-2332296 experiment was physically accepted.
**Fix:** Build 253 stays on the pre-draft lineage, documents HUD-only partials, adds intent comments, and guards that partial callbacks update recorder state while TranscriptionPipeline performs one final delivery. The exact committed source was built/tested on the Mac Mini, bundle-preserving transferred, signed with the stable local identity plus Automation entitlement, and installed as VoiceInk++ v2.0.253.
**Commit:** e802c9c
**Guard:** A fresh direct xcrun xctest run named and passed all 42 tests, including realtimeStreamingRemainsRecorderHUDOnlyUntilFinalDelivery, Primary isolation, Next ownership, and secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt. Installed v2.0.253 has CDHash d23da19ac75cc36b4cb4f7cd845a957779135def, passes deep/strict signing, retains Automation=true, contains no RealtimeInputDraftSession symbol, and left /Applications/VoiceInk.app byte-identical. Physical Soniox HUD/final delivery and both Next routes remain pending and must not be inferred from tests.
---


---
**Date:** 2026-07-23T00:37:25Z
**Trigger:** Ethan asked whether the other voice model was working and required it to be selected only after a real successful test.
**Symptom:** Soniox real-time initially looked as though it timed out, so every active Mode remained on tuned Deepgram with real-time disabled.
**Root cause:** The first standalone probe waited for the WebSocket connection to emit finished after sending Soniox <fin>, but Soniox intentionally keeps that stream open; VoiceInk++ correctly treats the committed final token after <fin> as completion.
**Fix:** A corrected funded-account probe sent synthetic non-private speech to Soniox stt-rt-v5, received a committed non-empty 69-character transcript in 4.99 seconds, and all seven live Mode records plus CurrentTranscriptionModel were switched to Soniox V5 stt-async-v5 with real-time enabled before launching v2.0.249. Ethan's first real microphone recording then connected in 0.426 seconds and produced a committed 99-character final transcript 0.320 seconds after stop.
**Commit:** runtime configuration on installed v2.0.249 source 5c85c78
**Guard:** After launch, defaults prove 7/7 Mode records select stt-async-v5 with isRealtimeTranscriptionEnabled=true; the app resolves that pair to stt-rt-v5. The live microphone trace confirms the streaming provider itself. That run's later Telegram exact-input resolution failure is separate delivery evidence and must not be misdiagnosed as a Soniox failure.
---


---
**Date:** 2026-07-22T00:33:19Z
**Trigger:** Ethan reported Transcribing was stuck and urgently requested rollback, suspecting the newly selected model.
**Symptom:** VoiceInk++ stayed on Transcribing for minutes after otherwise working v2.0.248 delivery changes.
**Root cause:** The active com.ethansk.VoiceInkPlusPlus modeConfigurationsV2 entries all overrode CurrentTranscriptionModel with Soniox V5 (stt-async-v5) and real-time enabled. Soniox accepted the WebSocket, then returned 'Organization balance exhausted'; the socket disconnected and batch fallback waited for its network timeout. Inspecting the legacy com.prakashjoshipax.VoiceInk preference domain falsely suggested tuned Deepgram was active.
**Fix:** Operational configuration rollback only: after a five-second heads-up and cooperative quit, set all seven VoiceInk++ modes plus CurrentTranscriptionModel to deepgram-nova-3-tuned-(local-proxy), set real-time false for every mode, live-tested the local proxy with synthetic speech (HTTP 200 in 1.57s), then relaunched the unchanged signed v2.0.248 app.
**Commit:** configuration-only; installed implementation 6ea179f unchanged
**Guard:** For a stuck Transcribing report, inspect the active bundle domain com.ethansk.VoiceInkPlusPlus and decode every modeConfigurationsV2 selectedTranscriptionModelName/isRealtimeTranscriptionEnabled before changing code or downgrading the binary. Correlate StreamingTranscriptionService's 'Streaming start requested model=' and server error; CurrentTranscriptionModel alone is not authoritative when a Mode override exists. Switch providers only after a direct live endpoint transcription succeeds.
---


---
**Date:** 2026-07-23T00:37:25Z
**Trigger:** Ethan required that while the floating black bar is visible the Next button must never go to the next song.
**Symptom:** A Next-button press intended for VoiceInk++ could advance media when the black recorder/transcription bar was still visible but the newest session was no longer internally eligible to latch.
**Root cause:** The event tap tied ownership to exact-route eligibility and the exact-delivery flag instead of the user-visible recorder-panel lifetime, so timing at the delivery cutoff could leak the same physical press to Next Song.
**Fix:** RecordingShortcutManager now consumes both halves of every Next Track press while any recorder panel is visible; eligible presses still perform their existing route and ineligible presses are no-ops. Build 249 updates the destination contracts and version.
**Commit:** 5c85c78e41e364f46cbbfffb160ba30dfd0fcb11
**Guard:** Mac Mini Xcode build plus fresh direct xcrun xctest named and passed all 40 tests, including nextTrackNeverPassesThroughWhileRecorderPanelIsVisible and secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt. Signed v2.0.249 installed with CDHash 51208b063ef424977b1d0aff6a6a1144f24cc6bf; physical G HUB test remains pending.
---


---
**Date:** 2026-07-21T23:22:09Z
**Trigger:** Ethan asked whether recording could start without dismissing an open right-click/context menu.
**Symptom:** Opening a right-click context menu and pressing the modifier-only Primary shortcut dismissed the menu when recording began.
**Root cause:** ShortcutMonitor detected the Shift-Control-Option chord but returned every flagsChanged event downstream, so the foreground app also received the completed chord that VoiceInk++ had already consumed logically.
**Fix:** Use a pure modifier-sequence reducer that suppresses only the completed owned chord and full-chord repeats; forward partial modifiers and every release so other apps remain balanced and no modifier can stick.
**Commit:** 75f63475b4533ceaa4b882b13fc36284f0284faf
**Guard:** primaryModifierChordSuppressesOnlyTheCompletedPress passed in the 39-test Mini run. Signed v2.0.247 is installed; physical context-menu preservation remains pending.
---


---
**Date:** 2026-07-21T23:22:09Z
**Trigger:** Ethan reported Telegram latch regression after the earlier accepted v2.0.245 result.
**Symptom:** The pinned Telegram exact-chat route could reject the same Saved Messages composer because the retained full header digest changed.
**Root cause:** A privacy-safe live probe kept the Telegram window dimensions fixed but observed eight full-header pixel hashes in about one second; the crop included Telegram's dynamic status/activity row even though the avatar and primary title row were unchanged.
**Fix:** Hash only the audited avatar plus primary title row, still byte-for-byte and tuple/layout pinned; retain full-header digest only as drift telemetry and keep every existing exact editor/window/internal-focus boundary.
**Commit:** 009743fbf3774e84b09bcdf264fd0c310497ec24
**Guard:** Dynamic-status and changed-title digest tests passed in the 39-test Mini run. Signed v2.0.247 is installed, but Telegram physical background routes and wrong-chat rejection remain pending.
---


---
**Date:** 2026-07-21T23:22:09Z
**Trigger:** Ethan reported that Codex latch Send regressed on v2.0.246.
**Symptom:** v2.0.246 latched and inserted into the exact background ChatGPT-hosted Codex composer, but auto-send reported that no semantic Send control was available.
**Root cause:** The running host updated to ChatGPT.app 26.715.70719 build 5650 with Chromium 150.0.7871.124; the sole idle unlabelled action remained present, but the fail-closed audited tuple list ended at builds 5551 and 5591, so candidate classification stayed auditedUnlabelled=0.
**Fix:** Add only the exact ChatGPT build-5650 tuple after offline source plus runtime AX diagnostics proved the existing idle-Send versus labelled-Stop boundary.
**Commit:** eb1cb8fd01e0f91f9f10242e004fe80d132a8322
**Guard:** Positive build-5650 and future-build-5651 rejection tests passed in the 39-test Mini run. Signed v2.0.247 from 60d9d6d is installed with CDHash 781f46d54dc1cd1e41e951a2d834a27c9d66e081. Ethan then physically confirmed the `recordingStart` Next route: while VS Code remained frontmost, the trace proved exact background insertion, resolved and invoked the audited FooterActions Send control, and this dictated message arrived in Codex. Post-action AX state was unreadable/indeterminate, so do not generalize that verifier result or mark the distinct `focusedDuringTranscription` second-chance route accepted yet.
---


---
**Date:** 2026-07-21T22:23:17Z
**Trigger:** Ethan reported that starting a new transcription after or while the previous one transcribed could sometimes paste the old value and requested race hardening.
**Symptom:** Starting a new recording while the previous result was still transcribing could appear to paste the older result, and prior traces could not prove whether audio, result, and delivery still belonged to one job.
**Root cause:** The engine had no immutable cross-stage job identity; duplicate starts could be scheduled before session creation, reset cancelled only the retained tail while older tasks could remain alive, a new generation could begin before cancelled work unwound, very fast stops could reread mutable Mode/model defaults, and late streaming preparation could attach an older callback to a newer recorder. A follow-up audit also found that speculative Whisper/FluidAudio preload and cleanup could cross another live session's shared-resource ownership.
**Fix:** Commit ad064a0 adds generation plus sequence plus recording-session plus transcription plus normalized-audio lineage, synchronous start reservation, per-job frozen audio/model/request/streaming state, reset invalidation and a drain barrier, stale-delivery refusal, and privacy-safe ID/length/digest logs. Commit 8562411 adds the shared-model lifecycle boundary: overlap skips speculative preload, task-specific cleanup requires zero remaining sessions plus current lineage, cleanup is a start barrier, and full reset drains cancelled jobs before teardown. Commit 5e12598 corrects only the Swift Testing assertion wrappers.
**Commit:** 85624110232d04143ff9a0cf8d1cf61349dd7a94
**Guard:** The exact v2.0.246 candidate at 8562411 was freshly compiled on the Mac Mini. The canonical Xcode action compiled but stalled in its UI runner; direct xcrun xctest against that exact Debug bundle named and passed all 38 tests, including seven lineage/overlap/reset cases and the shared-resource ownership case. Runtime acceptance still requires a live overlapping A/B trace proving distinct audio-result-delivery tuples.
---


---
**Date:** 2026-07-21T01:00:07Z
**Trigger:** Ethan physically exercised both Telegram Next-button routes in Saved Messages on installed v2.0.245 and confirmed that they submitted successfully while another app remained frontmost.
**Symptom:** v2.0.244 could preserve and revalidate Telegram's exact background composer through a privacy-bounded visual identity, but Telegram exposed no AX Send control and ignored the ordinary two-event process-targeted Return used by earlier experiments.
**Root cause:** Telegram 12.9 build 282526 accepts background Return only when the already-verified composer receives a HID-system event source sequence with an empty modifier-state boundary, Return down/up, and restoration of the live combined-session modifier state. The exact chat still cannot be inferred from Telegram's hidden background AX tree, so the pinned visual-header digest and retained editor/window boundary remain mandatory before insertion and Return.
**Fix:** Commits e200052 and 99a596b add one Telegram-only, one-shot `telegramTargetedHIDReturn` route after fresh visual chat-identity revalidation. Signed v2.0.245 is installed with Screen Recording enabled. Live Saved Messages traces prove both `recordingStart` and `focusedDuringTranscription`: `visualIdentity=true`, exact background insertion verified, Terminal remained frontmost, the Telegram composer cleared, and auto-send finished `success=true verification=verifiedCleared` in 66 ms and 40 ms respectively.
**Commit:** 99a596b9641ab0c27491704c6f3c1a77004e1a43
**Guard:** The canonical Mini Xcode action built and then stalled in TestManager; a fresh direct `xcrun xctest` run named and passed all 30 tests. Installed v2.0.245 has CDHash `9857ba882d2ff2f9064edcf79f055dd9e7dccdd1`, passes deep/strict signing, retains Automation=true, and left `/Applications/VoiceInk.app` untouched. This accepts only both background Next routes for pinned Telegram 12.9/282526 Saved Messages. Foreground Primary and wrong-chat fail-closed remain physically untested, and the HID sequence must never become a generic process-targeted Return fallback.
---


---
**Date:** 2026-07-20T21:54:29Z
**Trigger:** Ethan designated v2.0.243 as the checkpoint and chose Telegram as the next compatibility target.
**Symptom:** v2.0.243 kept Primary usable but both tested Telegram Next routes failed before insertion because the saved Telegram window could not be re-resolved after backgrounding.
**Root cause:** Telegram 12.9 build 282526 exposes a parentless message AXTextArea and no readable selected-chat title in that window's AX descendants, so the generic saved-window resolver could neither prove ownership nor safely identify the selected chat after backgrounding.
**Fix:** Commits bc060a2 and 4fa8ec9 add an isolated Telegram path: exactly one same-PID enclosing window may own the parentless composer; readable AX chat anchors are preferred, otherwise only the pinned Telegram tuple and header-crop SHA-256 identity may cross the gate; identity is revalidated before one-shot AXSelectedText insertion and an explicit labelled Send. Signed v2.0.244 is installed with exact delivery enabled, while v2.0.243 remains the rollback checkpoint.
**Commit:** 4fa8ec9a10ecdc68f57f2c71314ad20d23272e52
**Guard:** The canonical Mini runner compiled but stalled before named tests; a fresh Debug direct xcrun xctest run named and passed all 29 tests, including secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt and the Telegram identity/insertion tests. Installed v2.0.244 has CDHash 98859c850d863e194281355fc4384a867f795d98, passed deep/strict verification, retains Automation=true, and left official VoiceInk build 202 untouched. Do not accept Telegram until Saved Messages physically proves Primary plus both Next routes, no focus theft, Send clear/reset, and wrong-chat rejection where safely available.
---


---
**Date:** 2026-07-20T20:54:19Z
**Trigger:** Ethan clarified that v2.0.243's normal Primary route works but the latch behavior does not, designated v2.0.243 as a checkpoint, and chose Telegram as the next app to focus on.
**Symptom:** A Codex second-chance trace showed exact capture, verified background insertion, bounded Send-control resolution, and one issued action, but the post-action composer became unreadable and the user-visible latch result did not submit. The immediately following Primary current-input runs did submit. Two Telegram latch runs failed earlier, before insertion, because the saved Telegram window could not be re-resolved after it was backgrounded.
**Root cause:** The prior v2.0.243 acceptance entry incorrectly combined an ambiguous “I think it's working” report with an unreadable post-action trace and promoted an attempted Codex Send into accepted latch behavior. `verification=unreadable` plus action issuance is indeterminate, not success. The newest correlated traces distinguish the routes: Codex `focusedDuringTranscription` reached insertion/Send but failed the visible outcome; Telegram `focusedDuringTranscription` and `recordingStart` both failed at saved-window resolution; Primary `focusedAtStop` used the separate current-input compatibility path and worked.
**Fix:** No runtime mechanism changed. Reclassified signed v2.0.243 (`5475ef2`) as the reproducible **Primary-working checkpoint only** and retracted acceptance of either Next/latch route. Future Telegram work must branch from this checkpoint and remain app-specific so it cannot alter the accepted Primary compatibility path or imply that Codex latch is solved.
**Commit:** none (evidence correction; v2.0.243 implementation remains `5475ef2`)
**Guard:** Never promote `verification=unreadable`, `AXError.success`, resolved Send controls, or one issued action to route acceptance without an explicit, route-specific user result. Correlate the exact physical route and destination value. Preserve v2.0.243 as the rollback checkpoint: Primary normal stop works; Codex latch remains unresolved; Telegram currently fails exact saved-window resolution in both tested latch routes.
---

---
**Date:** 2026-07-20T20:42:32Z
**Superseded:** Ethan's route-specific correction at 2026-07-20T20:54:19Z established that only the normal Primary route worked. The Codex latch result did not submit, so this entry preserves reconstruction evidence but is not a latch acceptance record.
**Trigger:** An initially ambiguous physical result appeared to suggest that the restored Codex Next-button route was working, while Ethan noted lag-related unreliability.
**Symptom:** Later cross-app work obscured the last accepted Codex baseline, and the current ChatGPT-hosted Codex build rejected the otherwise-working audited Send path after the host updated from build 5551 to 5591.
**Root cause:** Timestamped install and user-verdict reconstruction identified commit `bfef0e4` (v2.0.238), not v2.0.236, as the accepted isolated Codex implementation. Its delivery mechanism remained valid; the current `/Applications/ChatGPT.app` host tuple had changed to version 26.715.52143 build 5591, while subsequent Telegram/Terminal/Claude changes made later cumulative candidates unsuitable as a Codex rollback.
**Fix:** Commit `5475ef2` reconstructs a clean v2.0.243 branch directly from the v2.0.238 source, adds only the audited ChatGPT build-5591 tuple and its acceptance/rejection tests, and increments the build. The signed app was installed with exact delivery enabled. Its traces prove exact capture/insertion attempts and no focus theft, but unreadable post-action state did not prove submission; the later route-specific correction rejects latch acceptance.
**Commit:** 5475ef20428ee20d78e98917a31ec30bfddc671e
**Guard:** The fresh Mini test bundle named and passed all 23 tests; the signed installed v2.0.243 artifact has CDHash `5be83c4f545772472a836306d64eded1253f1c63` and executable SHA-256 `f8f0fa0b6b29c2c533e5069e70124d6d0f732ab70b39abba57ca2da003bc231b`. Treat it as the Primary-working checkpoint and reproducible experiment floor, not accepted Codex latch support. Correlate a failed physical attempt with its exact trace before changing capture, cleanup, insertion, or the one-shot Send path, and never add a blind retry.
---

---
**Date:** 2026-07-19T22:04:03Z
**Trigger:** Ethan asked for a massive project file covering everything tried and failed in the complete session so future agents do not repeat the same approaches.
**Symptom:** Agents repeatedly retried delivery mechanisms that compiled, passed mocked tests, or returned AX/CGEvent success but failed on real Codex, ChatGPT, Telegram, or terminal surfaces; version-number rollback guesses also conflated materially different binaries.
**Root cause:** Negative evidence was fragmented across a 13–19 July task containing 207 user messages, 1,398 assistant messages, and 115 compaction checkpoints. Build 203 was reused, v2.0.207/v2.0.208 were later rejected, v2.0.233 AXPress and v2.0.234 authenticated Return produced false-success signals, and the accepted v2.0.236 observation proved only uninterrupted Primary compatibility while its complete dirty binary was not reproducible from one commit.
**Fix:** Commit 887e258 adds the 850-line FAILED_APPROACHES.md evidence ledger with a v2.0.203–v2.0.236 chronology, failed mechanisms, app-specific boundaries, HUD/release/trace regressions, DO-NOT-RETRY gates, and bounded reconsideration criteria. It corrects contradictory delivery/matrix claims and updates AGENTS.md, README.md, and the learnings skill so its check script searches rejected evidence before dated learnings.
**Commit:** 887e258
**Guard:** bash -n plus representative check.sh searches pass; quick_validate.py reports the learnings skill valid; git diff --check passes; future delivery work must read FAILED_APPROACHES.md and state what new evidence changes a recorded failure condition before retrying it.
---


---
**Date:** 2026-07-19T03:19:51Z
**Trigger:** Ethan asked why Codex Computer Use appears able to operate applications with its own mouse in the background while VoiceInk++ struggles with exact non-frontmost Codex paste and Send, and requested a Fable Five review.
**Symptom:** A visible Computer Use cursor suggested that macOS might provide an independent background mouse and keyboard-focus channel that VoiceInk++ had simply failed to use.
**Root cause:** The installed OpenAI helper does not expose a second macOS focus channel. `SyntheticAppFocusEnforcer` and `SystemFocusStealPreventer` are OpenAI `AccessibilitySupport` implementation types inside the compiled helper, not documented Apple APIs or reusable system classes. Their public Apple building blocks include `AXUIElementSetAttributeValue`, the writable `AXFocused`/`AXMain` attributes, `AXUIElementPerformAction`, and `CGEventPostToPid`; the helper also exposes private CPS focus-state notifications that do not appear in Apple's public SDK. `SkyComputerUseService` and bundled `@oai/sky` 0.4.20 combine those mechanisms with a software `VirtualCursor`, refetchable Accessibility trees, and app/window/element-targeted actions. The package is absent from the public npm registry, documents publication only to OpenAI-internal Artifactory/Azure, requires the trusted Codex `nodeRepl` runtime, and connects to a private Unix socket whose service authenticates peer/responsible-process code-signing identity; VoiceInk++ has no TeamIdentifier and does not satisfy that supported client boundary. The public Responses API `computer` tool returns UI actions for the caller's own harness to execute; it does not expose Codex's local macOS driver. The helper can make a target believe it is active and suppress or repair system focus changes, but that is synthetic internal focus orchestration, not an independent physical mouse. Computer Use normally re-snapshots and acts immediately; VoiceInk++ has the stricter delayed contract of preserving one exact composer across later tab/window/focus changes, inserting once, submitting once, and proving that the saved input cleared without bringing the app forward.
**Fix:** No runtime change was made. Do not import, extract, redistribute, or runtime-depend on OpenAI's unsupported bundled helper; borrow only the proven pattern. Public MIT alternatives now exist: `trycua/cua` provides the actively maintained Rust Cua Driver, while `tropeai/trope-cua` is a third-party rebrand/snapshot of Cua's former Swift driver and exposes `CuaDriverCore` as a Swift package. Neither is OpenAI source. Both need a narrow provenance, private-SPI, OS-version, latency, and exact-composer safety audit before any code is ported; current Cua Rust explicitly lacks the Swift synthetic AX-focus layers and retains only the reactive focus-steal layer, while Trope's fuller Swift path uses undocumented SkyLight/SLPS mechanisms. AXSwift and AXorcist are useful public AX wrappers but do not supply this complete focus orchestration. Keep VoiceInk++ on the narrow, bounded per-app delivery design: exact task/window/editor revalidation, one internal activation-state session, bounded Unicode insertion, a proven semantic Send action, fail-closed Send-versus-Stop checks, and surface-specific verification. Candidate commit `0e8d164` already implements that subset for the audited Codex package; the running ChatGPT-hosted Codex package still needs its exact tuple and live behavior proved before support can be claimed. Fable Five independently passed the static architecture but agreed that source and bundle inspection cannot replace the physical trace.
**Commit:** none (read-only installed-bundle/public-source investigation; current candidate remains `0e8d164`)
**Guard:** Never infer background safety or exact delivery from Computer Use's virtual cursor, AX/event acceptance, or a mocked action. The public `openai/codex` tree does not contain the native focus-enforcer implementation; the bundled `@oai/sky` package is not a public SDK; and the public OpenAI Computer Use API still requires a caller-owned execution harness. Do not bypass Computer Use's `com.openai.codex` policy with ad-hoc live AX probes. If evaluating Cua/Trope source, isolate the smallest mechanism, enumerate every private SPI, and prove it against VoiceInk++'s delayed exact-input contract rather than adopting a general driver wholesale. Require Ethan's disposable-task trace to prove exact insertion, one semantic Send, composer clear/reset, and unchanged system foreground before accepting Codex support.
---

---
**Date:** 2026-07-18T23:50:09Z
**Trigger:** Ethan rejected v2.0.224 after repeated Codex warning-icon and no-paste failures, corrected an unsupported guess that the remembered AX baseline was v2.0.216, and asked for the version to be reconstructed from his session conversation.
**Symptom:** The signed v2.0.224 app could read the real ChatGPT-hosted Codex `AXTextArea`, but the locked icon remained a warning and exact delivery failed or copied the transcript to the clipboard.
**Root cause:** The v2.0.224 description/placeholder relaxation still left the real composer with an incomplete bounded context fingerprint. Separately, choosing a rollback by spoken version proximity was invalid: build 203 had been reused for several binaries, and later partial successes belonged to materially different foreground, background, and compatibility engines. The decisive evidence was the timestamped user message immediately after each verified install, not the nearest-sounding version.
**Fix:** Session reconstruction separated two proven artifacts. Build 203/CDHash `715d9686a428e9c7d9a9064236f21e942901bc2b` at commit `1eabb1b` was the repeatedly celebrated three-route foreground restore/paste/Return build. Build 206/CDHash `a88d4bbe7ab463ba5a1f62509757b349d98d7f97` at source anchor `96e494e` was the first matching non-frontmost background AX build: Ethan confirmed background Codex paste and Return despite a false warning, identified Option-Space as paste-only, and later explicitly preserved v2.0.206 because it pasted into the right saved location. The byte-preserved v2.0.206 bundle was therefore restored; v2.0.216, v2.0.224, and current source were preserved.
**Commit:** none (evidence-backed operational rollback to preserved build 206; rejected v2.0.224 source is `3639f60`, and current source was not rewound)
**Guard:** Historical rollback selection must correlate the user's acceptance/failure timestamp with the immediately preceding install event and the artifact's build, CDHash, checksum, and delivery architecture. The installed app reports v2.0.206 with the expected CDHash and deep/strict-valid local signature; `/Applications/VoiceInk.app` remained byte-identical. Treat v2.0.206 as an exact-location Codex debugging floor, not universal compatibility proof.
---

---
**Date:** 2026-07-18T21:02:15Z
**Trigger:** Ethan corrected that the warning icon must remain until real app detection succeeds and requested more left/right recording-bar padding
**Symptom:** v2.0.222 showed only the current-app icon in compatibility mode, and shared ChatGPT/Codex host identity could leave exact Codex capture at a warning
**Root cause:** Locked-slot visibility was incorrectly gated by the exact-delivery flag, while selected-task identity reused the installed host surface instead of the embedded composer's product scope
**Fix:** Commit 3c44ebc keeps two slots for every active session, renders nil as the honest warning with no stale outline, separates host and task-scope surfaces for Codex inside ChatGPT.app, and adds 16-point mini-bar side padding
**Commit:** 3c44ebc
**Guard:** Mac Mini direct xctest ran all 56 named tests including compatibilityRecorderNeverAdvertisesStaleExactOwnership and Codex scope regressions; canonical Xcode test compiled then stalled in TestManager; disposable live Codex trace remains the release acceptance gate
---

---
**Date:** 2026-07-18T18:17:02Z
**Trigger:** Ethan asked to pull the completed Mac Mini VoiceInk++ work back to the MacBook and boot that build locally.
**Symptom:** A successful recursive `scp` of the signed v2.0.220 app created the bundle directories and nested payloads but silently omitted top-level `Contents/Info.plist` and `PkgInfo`, leaving an unrecognizable bundle.
**Root cause:** Raw recursive SCP did not preserve the complete macOS app-bundle layout on this transfer path; command success therefore did not prove a usable or signed candidate.
**Fix:** Re-transferred the exact Mini artifact through a `tar` archive stream, rejected the incomplete copy before installation, and required local version/build, deep/strict signature, CDHash, and Automation-entitlement verification before the five-second warned replacement. Signed v2.0.220 was installed with the exact-delivery preference still off; `/Applications/VoiceInk.app` remained unchanged.
**Commit:** 13fb3a9 (implementation; learning follow-up 769fadb)
**Guard:** Never install a transferred `.app` based on copy exit status alone. Require `Info.plist`, expected version/build, `codesign --verify --deep --strict`, the expected signing identity/CDHash, and `com.apple.security.automation.apple-events=true` both before and after installation.
---


---
**Date:** 2026-07-18T11:01:33Z
**Trigger:** Ethan directed the Mac Mini to stop monitoring, take ownership, and emulate the Codex failure locally.
**Symptom:** The exact-input candidate never landed on authoritative main, Release unit tests could not see makeTestingTarget, and Codex submit discovery missed a Chromium subtree.
**Root cause:** The prior work remained a root-snapshot candidate; the Release test action excluded a DEBUG-only seam; and Chromium exposed useful controls only through AXChildrenInNavigationOrder.
**Fix:** Rebuilt the candidate as a normal branch from d3819c12, added navigation-order fallback plus an exact audited Codex idle-Send contract behind a default-off legacy flag, and kept the internal test seam available to Release test builds.
**Commit:** 13fb3a9
**Guard:** Require the canonical Release build attempt plus all 55 named tests through the bounded Debug xctest fallback, keep exact delivery off by default, and do not install or ship without a disposable live Codex trace.
---

---
**Date:** 2026-07-18T00:20:37Z
**Trigger:** Ethan asked whether VoiceInk++ should replace his tuned Deepgram Nova-3 setup with OpenAI's new realtime speech/translation models, and whether those models are faster or better than AssemblyAI or Deepgram.
**Symptom:** The vendor names hide incompatible jobs and transports: `gpt-realtime-translate` is live speech-to-speech interpretation rather than ordinary dictation, while `gpt-realtime-whisper` requires a realtime PCM session and cannot be selected in VoiceInk++'s completed-file OpenAI-compatible request by changing only a model string. The repository also still lists AssemblyAI `universal-3-pro`, although AssemblyAI's current recommended model is `universal-3-5-pro`.
**Root cause:** VoiceInk++'s custom-provider route uploads one completed multipart recording and carries Vocabulary through the standard `prompt` field; OpenAI's GA realtime Whisper endpoint uses a dedicated streaming protocol and does not support prompt steering. Deepgram Nova-3 and AssemblyAI Universal-3.5 Pro expose native keyterm prompting, which is material to Ethan's proper-noun-heavy dictation. Separately, the built-in Deepgram batch wrapper currently accepts but does not forward `customVocabulary`; Ethan's custom local proxy is the path that extracts VoiceInk++'s marked block into repeated Nova-3 `keyterm` parameters.
**Fix:** No provider or runtime configuration was changed. Keep the tuned Deepgram proxy as the default until a same-audio evaluation proves a replacement; use `gpt-4o-transcribe` as the drop-in OpenAI quality comparator because it supports completed-file transcription plus prompt context. Treat `gpt-realtime-whisper`, `gpt-realtime-translate`, and AssemblyAI Universal-3.5 Pro as separate integration/evaluation candidates rather than silent model-name substitutions.
**Commit:** none (read-only provider/model investigation in the intentionally dirty `main` checkout)
**Guard:** Compare identical representative WAVs and identical Vocabulary across providers. Record stop-to-final p50/p95 latency, proper-noun/keyterm hit rate, omissions or hallucinations, punctuation/edit burden, and cost; do not claim a universal winner from vendor benchmarks. Before testing AssemblyAI, update and verify the stale model registry deliberately. Before testing OpenAI realtime, implement its dedicated stream and account for the lack of prompt steering. Never infer built-in Deepgram batch vocabulary support from the unused method parameter.
---

---
**Date:** 2026-07-17T23:04:58Z
**Trigger:** Ethan asked for an immediate base-VoiceInk fallback because the exact saved-input engine had regressed Codex paste/Return and recorder responsiveness.
**Symptom:** The first fallback draft selected current-cursor delivery but still ran exact Accessibility capture at recording start and primary stop, so it could retain the same HUD/start-stop latency and destination-owned Mode work it was meant to escape.
**Root cause:** The engine switch was initially applied only at Next handling, recorder target UI, and final paste. `VoiceInkEngine.toggleRecord` still synchronously captured and resolved saved inputs before the microphone session and at normal stop, while pipeline post-processing still read the saved target Mode.
**Fix:** v2.0.219 made `VIPPExactInputDeliveryEnabled=false` a complete compatibility boundary: no saved-input capture at start/stop, Next Track passed through, current Mode owned post-processing/output, final paste plus optional Return followed the current keyboard input, and locked-target UI stayed hidden. The exact three-route engine remained compiled behind the Settings toggle for isolated repair. Ethan later live-confirmed that fallback in Codex; v2.0.223 supersedes only the hidden-slot UI contract by showing an honest warning while compatibility mode owns no exact target.
**Commit:** pending (installed v2.0.219 from the intentionally dirty `main` checkout at HEAD `d3819c1`; do not infer that HEAD alone reproduces this binary)
**Guard:** The Mac Mini direct Swift Testing run named all 54 tests and passed, including `exactInputDeliveryFlagDefaultsToLegacyAndRemainsSwitchable` and `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt`; the canonical test action compiled but its UI runner stalled and is preserved in `/private/tmp/voiceink-v219-test4.xcresult`. Installed build 219 verified deep/strict, stable signing authority, Automation=true, running PID, flag=0, and an unchanged `/Applications/VoiceInk.app`. The historical hidden-slot choice is not the current contract; v2.0.223's active two-slot regression test is authoritative.
---


---
**Date:** 2026-07-16T17:51:56Z
**Trigger:** v2.0.211 release signing gate
**Symptom:** The first signed v2.0.211 artifact passed certificate and deep/strict verification but its outer signature contained no Automation entitlement.
**Root cause:** The Mac Mini resign-local.sh still replaced the outer app signature without passing VoiceInk.local.entitlements even though the repository documentation already required it.
**Fix:** Patched the real Mini helper to accept the checked-in entitlements as argument 2, fail closed when they are missing, sign the outer app with them, and verify Automation afterward; BUILDING.md and UPDATING.md now give the exact invocation.
**Commit:** ff33fb2
**Guard:** The helper's real v2.0.211 invocation now passes deep/strict verification and dumps com.apple.security.automation.apple-events=true; the installed app was checked again after transfer.
---


---
**Date:** 2026-07-15T22:28:08Z
**Trigger:** Ethan rejected v2.0.208 and asked to revert everything after slow recorder start/stop, failed background ChatGPT Enter, and ChatGPT focus instability.
**Symptom:** v2.0.208 inherited v2.0.207 recorder latency and could paste into the saved ChatGPT composer but failed to submit it in the background; repeated live activation-state probing then destabilized ChatGPT focus and the app restarted.
**Root cause:** The v2.0.207 delivery rewrite added expensive exact-input/context work to recording decisions and removed the v2.0.206 process-targeted Return fallback. When a ChatGPT task is running, its exact composer exposes an explicit Stop control rather than a safe Send control, so the hardened route correctly had no semantic background submit action. Unit tests and AX return codes did not prove a real ChatGPT send.
**Fix:** Commit b2aeaa2 reverted native source, tests, runtime docs, and public copy exactly to the v2.0.206 baseline; the preserved signed build 206 with CDHash a88d4bbe7ab463ba5a1f62509757b349d98d7f97 was reinstalled and launched. Keep later safety knowledge as investigation guidance, but do not claim universal background Enter.
**Commit:** b2aeaa2
**Guard:** Before another delivery release, measure recorder start/stop latency and live-test the exact /Applications/ChatGPT.app surface in a disposable target. Never bypass blocked Computer Use by repeatedly posting private activation-state events to Ethan live ChatGPT process; one app-owned bounded delivery session is the maximum, and an actual cleared composer trace is required.
---


---
**Date:** 2026-07-15T15:52:35Z
**Superseded:** The complete 13–19 July audit and explicit `b2aeaa2` rollback later established that v2.0.207/v2.0.208 were rejected, not accepted releases. Preserve the safety constraints below only when independently re-proven; do not resurrect the rewrite or treat its tests/install as runtime success. See `FAILED_APPROACHES.md`.
**Trigger:** Ethan made reliable exact-input background paste and Enter the primary objective and required compatibility tracking for his main apps.
**Symptom:** Exact saved-input paste could work while Return was inconsistent or unsafe across Codex, ChatGPT quick window, Terminal/iTerm, Telegram, Chrome, Notion, and same-app different-input cases.
**Root cause:** Saved AX wrappers can be replaced or reused across windows, tabs, chats, and editors; global Mode can drift after focus changes; process-targeted Command-V or Return is not reliable submission proof; and a generic unlabelled button or whole rich-editor AXValue mutation can target the wrong control or damage content.
**Fix:** v2.0.207 freezes the exact destination plus complete Mode before post-processing, serializes delivery, re-resolves and verifies exact inputs without activating background targets, uses surface-specific one-shot submit verification, binds Terminal/iTerm text plus Return to one native window/session identity, fails Telegram on unreadable chat context, and never replaces a generic rich-editor AXValue.
**Commit:** 86b50c2
**Guard:** All 27 unit tests passed through direct xctest and the recovered canonical Xcode runner; the signed build 207 is installed. BACKGROUND_DELIVERY_TEST_MATRIX.md marks every unavailable live surface not tested until a disposable trace proves exact insertion, verified submission where supported, and no focus theft.
---


---
**Date:** 2026-07-15T15:52:35Z
**Trigger:** Ethan asked whether his custom voice model was passing vocabulary correctly to its API provider.
**Symptom:** VoiceInk++ Vocabulary terms were not reaching Ethan's custom Deepgram Nova-3 model even though built-in cloud providers received them.
**Root cause:** CloudTranscriptionService returned early for custom models before loading dictionary terms, and an OpenAI-compatible custom endpoint has no standard vocabulary field beyond the prompt carrier.
**Fix:** Custom models now receive the dictionary terms. OpenAICompatibleTranscriptionService appends a bounded, deduplicated, injection-safe VOICEINK_CUSTOM_VOCABULARY prompt block; the local adapter extracts only that final block into repeated Deepgram keyterm parameters, and provider error bodies are redacted.
**Commit:** 86b50c2
**Guard:** Unit tests prove vocabulary carriage, marker neutralization, cap/dedup behavior, and response-body redaction; a sanitized proxy probe proved marker parsing without logging terms. Live provider recognition quality remains not tested.
---


---
**Date:** 2026-07-15T15:52:35Z
**Trigger:** The v2.0.207 release audit exposed an entitlement-stripping re-sign and a stalled test launcher.
**Symptom:** The Mac Mini post-build signing helper could produce a deep/strict-valid app that had lost Automation, and the normal Xcode test launcher stalled before executing tests.
**Root cause:** Replacing the outer signature without explicitly reapplying VoiceInk/VoiceInk.local.entitlements strips com.apple.security.automation.apple-events; separately, TestManager can wedge even though the built Swift Testing bundle itself is runnable.
**Fix:** The signed v2.0.207 artifact was re-signed with VoiceInk/VoiceInk.local.entitlements and verified before installation. AGENTS.md, BUILDING.md, UPDATING.md, and the learnings skill now require outer-entitlement inspection and document direct xcrun xctest as a bounded fallback while retaining the normal Xcode runner as canonical.
**Commit:** 86b50c2
**Guard:** Require codesign deep/strict success plus outer Automation=true; require named per-test output, never the zero-test preamble; retry the canonical runner after TestManager recovery and never enable Developer Mode without Ethan direction.
---


---
**Date:** 2026-07-15T15:52:35Z
**Trigger:** Ethan requested a full upstream sweep and feature-by-feature approval instead of changes that could break VoiceInk++.
**Symptom:** A whole upstream update would collide with the exact destination and delivery implementation, while some upstream prompt changes would remove the new vocabulary carrier.
**Root cause:** At the 2026-07-15 audit the fork and upstream had diverged substantially from merge base eda0786; a trial merge produced 17 conflicts across recorder, destination, pipeline, delivery, cloud, project, and test files.
**Fix:** UPDATING.md now forbids wholesale merges, keeps the legacy Mini merge LaunchAgent disabled, and lists the approved manual-port candidates and explicit rejections. No upstream code was merged.
**Commit:** 86b50c2
**Guard:** Audit every candidate in a disposable clone or worktree, obtain Ethan approval for one feature, manually preserve destination/delivery/vocabulary guards, and run the full release matrix before publication.
---


---
**Date:** 2026-07-15T04:45:00Z
**Trigger:** Ethan asked to preserve the currently installed v2.0.206 Accessibility behavior as a rollback point because it is pasting into the right saved location.
**Symptom:** Later auto-send work risks obscuring which installed build already has the essential exact-destination paste behavior. Ethan confirmed that the running v2.0.206 reaches the intended saved input, while separately reporting that background Return remains incomplete on surfaces such as Terminal.
**Root cause:** Exact-input targeting/paste and app-specific auto-send are separate capabilities. Treating an Enter failure as proof that destination capture/paste is also broken would throw away a known-good Accessibility baseline during a rollback.
**Fix:** Preserve source commit `96e494e` plus installed `VoiceInkPlusPlus.app` build 206 as the rollback floor for the confirmed exact-location paste behavior. Its recorded installed identity is bundle `com.ethansk.VoiceInkPlusPlus`, marketing version `2.0`, build `206`, designated local-signing identity `VoiceInk Local Signing`, and CDHash `a88d4bbe7ab463ba5a1f62509757b349d98d7f97`. This baseline does not claim that background Enter or every app in the compatibility matrix works.
**Commit:** 96e494e
**Guard:** Keep destination capture/insertion tests and auto-send tests separate. If v2.0.207 delivery regresses before it is accepted, restore the preserved signed build-206 bundle rather than reconstructing its behavior, and verify version, CDHash, PID, exact-input paste, and that `/Applications/VoiceInk.app` remains untouched.
---

---
**Date:** 2026-07-14T20:31:21Z
**Trigger:** Ethan requested the version number split over two lines with larger text to use the recorder bar's top and bottom whitespace.
**Symptom:** The recorder's one-line v2.0.205 label was cramped at 8 pt and left unused vertical space, making the exact running release hard to read.
**Root cause:** RecorderVersionLabel concatenated CFBundleShortVersionString and CFBundleVersion into one compact Text view instead of treating the 40 pt bar as a two-row information slot.
**Fix:** RecorderVersionPresentation now renders v<marketing-version> above .<build-number> in a centered 10 pt semibold monospaced stack shared by every recorder panel; release docs describe the split and native build 206 was signed, installed, and relaunched.
**Commit:** 94e98b9
**Guard:** recorderVersionSplitsMarketingAndBuildAcrossTwoRows asserts 2.0 + 206 becomes v2.0 / .206 with one accessibility label; all six tests pass on the Mac Mini and installed v2.0.206 passed deep/strict signature plus live PID verification.
---


---
**Date:** 2026-07-14T20:20:54Z
**Trigger:** Ethan asked for the floating recorder app icon corresponding to the action just taken to fade in and pulsate with a neon glow: left for a normal primary-button stop and right for the secondary/Next latch behavior.
**Symptom:** The current-focus and locked-destination icons showed persistent routing state but gave no momentary confirmation of which physical button route had just fired, making a normal stop and a Next-button destination action harder to distinguish at a glance across the mirrored recorder panels.
**Root cause:** Recorder UI state exposed only the current application and saved paste target. There was no per-session action event, and deriving one later from global focus or transcription state would be ambiguous, could drift after an app switch, and would not reliably synchronize independent SwiftUI hierarchies on every display.
**Fix:** Commit `eca6bda` added a uniquely identified `RecorderIconActionPulse` owned and published by each `RecordingSession`. `focusedAtStop` emits a left/current-focus pulse after the primary stop owns its target; `recordingStart` emits a right/locked pulse for Next while recording; an accepted `focusedDuringTranscription` retarget emits that same right pulse atomically inside the successful latch. Mini and notch views on every monitor consume the shared token through a cyan fade-in/two-beat halo modifier, with a non-scaling Reduce Motion variant. Failed second-chance capture, rejected late retargets, and ordinary media pass-through do not emit a success pulse. The numbered installed release is `v2.0.205`.
**Commit:** eca6bda
**Guard:** `recorderIconPulseMapsPrimaryAndNextRoutesToSeparateIcons` asserts the route-to-icon mapping and unique event tokens; `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt` now also asserts that only an accepted second chance emits the locked pulse and a rejected late retarget cannot replace it. All five tests passed on the Mac Mini, the shared learnings skill validated, and the signed build-205 bundle was installed after the five-second warning with the official VoiceInk app untouched.
---

---
**Date:** 2026-07-14T20:04:50Z
**Trigger:** Ethan asked to show the exact app version beside Stop and reiterated that every completed VoiceInk++ change must replace the installed app after a five-second warning.
**Symptom:** Native source could change while the still-running installed app remained older, and the recorder bar exposed no build identifier. With marketing version 2.0 unchanged across builds, Ethan could not tell at a glance whether an agent had actually installed and restarted the release it claimed was current.
**Root cause:** The restart/install expectation existed in conversation history and scattered delivery notes, but it was not a numbered release invariant. Agents could treat an edit, commit, or successful build as completion without incrementing `CURRENT_PROJECT_VERSION`, replacing the signed VoiceInk++ app, or proving which binary was running.
**Fix:** Commit `bc10f8a` added `RecorderVersionLabel` immediately left of Stop in both mini and notch recorder bars and made the build number part of the visible label (`v<marketing-version>.<build-number>`). It also made per-release build increments, Mac Mini builds, the real five-second warning, signed installation at `/Applications/VoiceInkPlusPlus.app`, live identity verification, and preservation of `/Applications/VoiceInk.app` mandatory in `AGENTS.md` and the shared learnings skill. The first release under this contract is `v2.0.204`.
**Commit:** bc10f8a
**Guard:** Never reuse a build number for a different installed binary. A native source change is not shipped until the uniquely numbered signed build is installed and running after the warning; verify its bundle versions, process, CDHash/signing authority, and that the official VoiceInk app remains untouched. Validate the learnings skill whenever this release procedure changes.
---

---
**Date:** 2026-07-14T20:04:49Z
**Trigger:** Ethan made exact background-input delivery the primary objective: preserve the original input even after changing apps, windows, or focused elements, and paste plus auto-send without bringing Codex front and center.
**Symptom:** Application-level focus locks and saved `AXUIElement` wrappers were insufficient for multiple inputs/windows/tabs, while ordinary process-targeted Command-V/Return could be accepted by macOS yet ignored by Electron. Foreground fallback interrupted Ethan's current workspace and still could not prove that the intended composer alone received or submitted the text.
**Root cause:** Accessibility element wrappers can become stale or be indistinguishable from a lookalike composer after a document/tab change. Electron also requires its internal inactive-to-active notification sequence before a background editor handles targeted text/key events. Event-post success alone proves neither exact destination identity nor insertion/submission.
**Fix:** Commit `b8d9a99` saves exact window/input fingerprints with identifiers, structure, geometry, and bounded content anchors; conservatively re-resolves stale wrappers; snapshots the destination-owned Mode/auto-send decision; and adds a verified background route that prepares Electron's internal focus without changing the macOS frontmost app, types Unicode directly, verifies insertion, performs narrowly scoped auto-send, verifies submission, and restores the target app's prior internal focus. Ambiguous or failed checkpoints fall back safely or surface the transcript through the clipboard instead of guessing.
**Commit:** b8d9a99
**Guard:** A disposable two-window Codex probe proved that only the saved composer changed and submitted, the comparison composer remained unchanged, and Codex stayed backgrounded. Preserve `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt` plus the input-context fingerprint guards; a real release trace must contain `paste: background exact focus verified`, `paste: background text verified success=true`, and `paste: background auto-send finished success=true`. The later 50 ms internal-focus restoration settlement is defensive but still requires a dedicated live re-proof before claiming that post-delivery internal restoration is independently verified.
---

---
**Date:** 2026-07-14T19:14:59Z
**Trigger:** Ethan asked for a Logitech G HUB sanity check before trusting and preserving the canonical primary/Next terminology.
**Symptom:** The repository's button aliases matched Ethan's intent, but the live physical G HUB mapping had not been verified. Raw assignment inspection appeared to make the separate forward control look like ordinary Mouse Button 5, risking a new implementation that listened for the wrong event.
**Root cause:** Ethan's G502 X LIGHTSPEED exposes several distinct side and top controls. G HUB's raw profile/card data is not enough on its own to identify the resolved physical label, and the spoken word 'forward' can be confused with macOS Mouse Button 5 even though Ethan means the separate control assigned to Next Track.
**Fix:** Commit 0de10b2 records the live Desktop: Default mapping in TERMINOLOGY.md, AGENTS.md, RECORDING_DESTINATIONS.md, and the shared learnings skill: the upper side thumb control runs the speech-to-text Shift-Control-Option macro and is Primary; a different control explicitly labeled Next Track is Next; G HUB's Mouse Button 4 and Mouse Button 5 controls are separate.
**Commit:** 0de10b2
**Guard:** A read-only live check confirmed G HUB Desktop: Default was active with onboard mode off; VoiceInk++ stored modifier-only Shift-Control-Option in toggle mode; G HUB View 2 showed speech to text plus separate Mouse Button 4/5 controls, while View 1 showed Next Track. Future checks must compare the active resolved assignment diagram with VoiceInk++'s stored shortcut, then run skill validation.
---


---
**Date:** 2026-07-14T18:51:36Z
**Trigger:** Ethan asked for a cross-session terminology audit and clarified that pressing the same primary/thumb/toggle button to stop must never paste into the old recording-start input.
**Symptom:** “Toggle,” “same button,” “normal button,” “secondary behavior,” “latch,” and “start of transcription” had been used for different controls or timing routes. The repo standardized Next-button aliases but never defined the primary button, while Git history still contained both the primary shortcut's `.toggle` mode and the rejected Next-destination toggle experiment.
**Root cause:** The behavior evolved from a long-press experiment into two physical buttons, then briefly into a Next toggle, then back to one-click timing routes. Without a timing-based glossary, later agents could merge primary normal stop, recording-time Next, and post-stop second chance or treat the recording-start input as a normal-stop fallback.
**Fix:** Commit `055b39e` added `TERMINOLOGY.md` with the canonical alias and timing tables plus the historical audit, linked it from README.md, AGENTS.md, RECORDING_DESTINATIONS.md, and UPDATING.md, and taught the shared Codex/Claude learnings skill the same mapping. The hard rule is now explicit: primary again selects only `focusedAtStop`; only Next while recording selects `recordingStart`; Next after a primary normal stop selects `focusedDuringTranscription`.
**Commit:** 055b39e
**Guard:** Future destination work must read TERMINOLOGY.md and restate physical control + timing + destination before changing code. Static inspection confirms `VoiceInkEngine` assigns `.focusedAtStop` and `.recordingStart` in separate switch branches, while delivery permits application fallback only for `.recordingStart`; skill validation, shell syntax checks, link checks, and `git diff --check` passed.
---

---
**Date:** 2026-07-14T00:53:13Z
**Trigger:** Ethan asked to add Codex and Claude Code support, consolidate Next-button aliases, and make project learnings self-improving.
**Symptom:** Codex and Claude Code needed explicit Next-button support without risking the accepted three-route destination behavior.
**Root cause:** Codex CLI and Claude Code do not own separate macOS editable inputs; the terminal or editor host owns the Accessibility element and therefore must also own the per-session Mode and auto-send decision. Codex desktop remains the distinct verified composer case.
**Fix:** Documented the host-input compatibility model in README.md, RECORDING_DESTINATIONS.md, and GitHub Pages; standardized the public Next button term; added one canonical self-improving repository skill shared by Codex and Claude Code. Native delivery code was intentionally unchanged.
**Commit:** 00066dd
**Guard:** The existing secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt contract remains untouched; the skill preserves all three routes and aliases; static site, HTML, CSS, JS, skill, and script validation pass.
---


---
**Date:** 2026-07-13T22:31:45Z
**Trigger:** Ethan clarified—again—that normal stop followed by Next Track during transcription is a separate second-chance workflow, not the recording-start Next Track stop route
**Symptom:** A pending session could correctly replace its input with `destination=focusedDuringTranscription`, yet paste-time Return could still disappear after Ethan moved to another app. This made the destination icon look latched while auto-send behaved as though it belonged to whichever app was current when the network response finished.
**Root cause:** Commit `cba45ba` correctly made `RecordingSession.pasteTarget` mutable until delivery, but the target stored only the Accessibility input. `TranscriptionPipeline` continued resolving `OutputRuntimeConfiguration.autoSendKey` from the global live Mode later. Therefore the input belonged to the retargeted app while Return could belong to a subsequent app—two halves of one user decision were sourced from different moments.
**Fix:** `RecordingPasteTarget` now owns the destination app's resolved `autoSendKey` alongside its focused input. All three selection routes capture that pair: normal stop, recording-start Next Track stop, and the distinct post-stop Next Track retarget. Immediately before delivery, the pipeline atomically resolves the latest per-session target and replaces the live global auto-send value with the target-owned value; one-shot raw/skip still forcibly disables auto-send. Moving elsewhere after the second-chance press can no longer remove the selected input's Return behavior.
**Commit:** `1eabb1b` (`Fix second-chance transcription retarget auto-send`)
**Live validation:** On the installed PID `8961`, two separate post-stop retargets at 2026-07-13 23:43:29 and 23:43:43 logged `destination=focusedDuringTranscription`, later resolved `targetAutoSend=enter`, changed the OpenAI composer after System Events Return, and ended with `foreground auto-send finished success=true`. Ethan then repeated “This is a test” three times and confirmed the workflow works.
**Guard:** The canonical second-chance scenario is: stop normally → transcription begins → focus a new editable input → press Next Track once → optionally move to another app → finished text pastes and uses the newly selected input's configured auto-send. This is not a toggle and not the recording-start route. `secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt` asserts that `.enter` travels with the retargeted target. Future agents must read this entry, root `AGENTS.md`, and `RECORDING_DESTINATIONS.md` before changing Next Track behavior.
---

---
**Date:** 2026-07-13T21:56:37Z
**Trigger:** Ethan reported that auto-Enter worked in Terminal but not in ChatGPT/Codex, then clarified that he may be actively using the Mac while focus diagnostics run
**Symptom:** The retargeted Codex composer received the transcript and the mode correctly selected `autoSendKey: enter`, but the text remained unsent. The live route restored Codex, failed to restore VS Code with `NSRunningApplication.activate`, then logged `AXConfirm result=0` as success even though the composer did nothing. Earlier, an instantaneous foreground CGEvent pair had also been ignored by the same Electron editor while Terminal accepted it.
**Root cause:** macOS accepting an Accessibility action or synthetic event is not proof that an Electron editor handled it. `AXConfirm` is not a generic text-area Return, and back-to-back private-state key-down/up events were not sufficiently physical for this composer. Workspace restoration also relied on a single activation call whose `false` result was only logged. Separately, focus can legitimately change during inspection because Ethan is using the computer; treat that as the first hypothesis rather than declaring contradictory app behavior.
**Fix:** Removed the background `AXConfirm` route. Delivery keeps the locked destination verified and frontmost through paste and auto-send, then restores the prior app through a shared, awaited `NSWorkspace.openApplication` fallback. For `com.openai.codex` / `com.openai.chat`, plain Enter first presses a tightly scoped nearby **Send** button, otherwise uses System Events `key code 36`, then tries one HID-state CGEvent with a 30 ms down/up interval only when the exact composer text remains unchanged. If the text is still identical, VoiceInk++ leaves it in place and shows the existing auto-send error. Other apps use the humanized foreground HID route and retain the bounded redundant plain-Enter retry.
**Commit:** pending (`codex/recording-destination-routing`, unstaged)
**Guard:** Never treat `AXConfirm == success`, event posting, or activation acceptance as delivery proof. Keep OpenAI composer verification bounded to its saved editor, recheck the expected frontmost PID before each key route, and restore the prior app only after Return finishes. Ethan may be concurrently using the Mac: preserve focus if he moves it, prefer logs over invasive UI probes, and announce any unavoidable focus-changing test. This concurrent-use rule is also persisted in `~/.codex/AGENTS.md`.
---

---
**Date:** 2026-07-13T21:05:28Z
**Trigger:** Ethan reproduced normal stop → Next Track during transcription → move to another app before delivery; the retargeted Codex input received the paste but did not submit, and VoiceInk++ dragged Codex front and left it there
**Symptom:** The locked target and Mode were both correct (`destination=focusedDuringTranscription`, `autoSend=enter`). The live log showed the exact Codex `AXTextArea` restored, Codex made frontmost, and two ordinary Return events posted, yet Codex handled neither event. The user's current app was displaced even though submission still failed.
**Root cause:** The prior foreground fix treated `NSWorkspace.frontmostApplication == targetPID` plus a matching system-wide Accessibility element as proof that a raw keyboard event would be handled. The 22:05:28 trace disproved that assumption: Electron can accept activation/focus restoration while its editor still ignores synthetic global Return. Keeping the destination frontmost for the 500 ms settle delay therefore added disruption without making delivery reliable.
**Fix:** This attempted `AXConfirm` route was installed for the 22:26 test, which disproved it: Codex ignored the action even though AX returned success. Superseded by the verified OpenAI-composer/System Events route in the newer entry above.
**Commit:** pending (`codex/recording-destination-routing`, unstaged)
**Guard:** Do not use PID-targeted Command-V/Return for Electron, and do not treat `AXConfirm` as a generic editor Return. The live build must be installed after the five-second warning, signed with the stable VoiceInk++ identity, and its next real retarget trace must show which OpenAI composer route ran.
---

---
**Date:** 2026-07-13T20:51:40Z
**Trigger:** Ethan asked for the recorder to distinguish the app focused now from the per-session app owned by Next Track, and to communicate transcription retargeting through the icon instead of a success toast
**Symptom:** The right-hand Mode icon consumed the slot needed for current-focus feedback. The single destination icon showed only the saved/locked target, so it was impossible to compare current focus with where Next Track would deliver. Pressing Next Track during transcription did update the published target, but also displayed a redundant “Pending transcription target…” text notification.
**Root cause:** Recorder layout exposed Mode and one paste-target icon but no independent current-app signal. `VoiceInkEngine.retargetMostRecentPendingTranscriptionToFocusedInput` explicitly called the informational notification even though `RecordingSession.pasteTarget` was already `@Published` and drove the icon transition.
**Fix:** Mode moved immediately left of the waveform. The right side now shows two distinct app icons in order: current keyboard/frontmost app, then the per-session locked/Next Track paste destination. `ActiveWindowService.currentApplication` updates even while Mode-follow is suppressed by a focus lock, and AX input capture updates it for non-activating panels such as ChatGPT. A successful transcription-time Next Track retarget now communicates solely by switching the locked destination icon; failure to capture an editable input still shows warning text.
**Commit:** pending (`codex/recording-destination-routing`, unstaged)
**Guard:** Do not merge the two icons: current focus and owned paste destination answer different questions. Keep successful retarget feedback visual and quiet; keep error/warning text visible. Both mini and notch recorder layouts—and every mirrored monitor panel—must preserve the same left-to-right order.
---

---
**Date:** 2026-07-13T20:34:20Z
**Trigger:** Ethan live-tested Next Track after the foreground-paste routing fix; the transcript reached the saved Codex input but the configured Return did not submit it
**Symptom:** Paste succeeded and the saved mode was configured with `autoSendKey: enter`, but no Return was handled. The delivery code still logged `targeted auto-send posted`, falsely implying success.
**Root cause:** Commit `744c2ce` changed delayed auto-send from an ordinary foreground `CGEvent` to `CGEvent.postToPid` because that version of delivery restored the user's previous app before the 500 ms auto-send delay. Current delivery intentionally keeps the saved destination frontmost, so the process-targeted workaround was no longer needed. More importantly, PID-targeted Return has the same Electron/VS Code false-success behavior as PID-targeted Command-V: macOS accepts the post without guaranteeing that the app handles it.
**Fix:** Before auto-send, `TranscriptionDelivery` verified that the saved destination was frontmost and called the same awaited `FocusLockService.restoreFocus` again if it was not. `CursorPaster.performAutoSend` required the expected foreground PID and posted ordinary global Return events. This removed PID-targeted delivery, but the later 22:05 live trace proved that foreground/raw Return could still be ignored and that leaving the destination frontmost was disruptive. Superseded by the semantic-background fix above.
**Commit:** pending (`codex/recording-destination-routing`, unstaged)
**Guard:** Never use `CGEvent.postToPid` for transcript paste or auto-send in Electron/VS Code workflows. “Posted” is not proof of delivery. A completed VoiceInk++ code fix is not complete until the new build is installed and running at `/Applications/VoiceInkPlusPlus.app`; before every restart/replacement, show the macOS notification “VoiceInk++ will restart in 5 seconds” and wait the full five seconds. Never replace `/Applications/VoiceInk.app`.
---

---
**Date:** 2026-07-13T20:24:34Z
**Trigger:** Ethan live-tested the recording-start Next Track route and the transcription-time retarget route on 2026-07-13; both pasted into the intended inputs
**Symptom:** Next Track correctly stopped recording and the capsule showed the saved app icon, but the icon disappeared as soon as transcription began and the transcript sometimes never reached the saved input. Logs falsely ended with `commandPosted`, making the failed delivery look successful.
**Root cause:** The accepted one-click behavior was commit `cba45ba` (`Allow paste retargeting during transcription`). The later toggle experiment `671b4c7` was exactly reverted by `bed22b7`; the regression was introduced afterward by `b694eac`, which replaced verified foreground activation plus ordinary Command-V with `CGEvent.postToPid` background paste. macOS can accept posting the event without VS Code/Electron accepting the paste. Separately, Mini/Notch UI explicitly gated the destination icon on `recordingState == .recording`, even though the target remained owned by `RecordingSession`, so the UI misleadingly hid it at `.transcribing`.
**Fix:** Restored the exact routing contract: normal stop selects the input focused at stop; Next Track while recording stops once and selects the recording-start input; Next Track while the newest result is loading replaces that pending session's destination with the input focused then; there is no toggle. `TranscriptionDelivery.paste` now always calls `FocusLockService.restoreFocus`, waits for the saved app to become genuinely frontmost, restores/verifies the target, then calls the ordinary no-PID `CursorPaster.startPasteAtCursor`. Auto-send also uses verified foreground delivery after the follow-up live test recorded above. The per-session destination icon now stays visible through transcription/delivery, follows a transcription-time retarget, and remains on compact background chips. Recorder panels are mirrored on every `NSScreen`; routine recording-success text is removed; capture/transcription/focus/paste failures remain visible. Built and signed on the Mac Mini, installed as VoiceInk++ only, and live-confirmed by Ethan with both paste routes.
**Commit:** pending (`codex/recording-destination-routing`, unstaged)
**Guard:** `CursorPaster.startPasteAtCursor` no longer accepts a target PID, so transcript paste cannot silently drift back to the false-success background path. Inline comments name the VS Code repro; `RECORDING_DESTINATIONS.md` records the three routes and foreground-paste invariant; `pendingPasteTargetCanChangeUntilDeliveryResolvesIt` passed on the Mac Mini. Neither Command-V nor Return may use process-targeted delivery; the newer entry above owns the current auto-send route.
---

---
**Date:** 2026-07-11T19:29:32Z
**Trigger:** Ethan 2026-07-11: 'double-hit Escape works but the slider/timer going down doesnt stop / doesnt disappear instantly'
**Symptom:** Cancelling a dictation via Escape: double-hitting Escape cancels the recording, but the recorder overlay's countdown 'slider/timer' keeps going down / lingers on screen instead of disappearing instantly. Also required a double-tap to cancel at all.
**Root cause:** RecorderPanelShortcutManager.handleEscapeShortcut() implemented an upstream two-stage double-tap-Escape confirm: the FIRST Esc only showed a 'Press Esc again to cancel' HUD (AppNotificationView, whose bottom edge is a progress-bar Rectangle that shrinks full-width->0 over the 1.5s duration = the 'slider/timer going down'); only a SECOND Esc within 1.5s called cancelRecording(). The lingering: on the confirming second Esc, cancelRecording() tore down the recorder panel but NEVER dismissed the confirm HUD — NotificationManager's own 1.5s dismissTimer kept running, so the countdown slider stayed on screen AFTER the cancel already happened.
**Fix:** Rewrote handleEscapeShortcut() so a SINGLE Escape immediately calls recorderUIManager.cancelRecording() (engine.cancelRecording -> discard/no-paste/resume-media -> dismissRecorderPanel orderOut, instant) plus a belt-and-braces NotificationManager.shared.dismissNotification() so no HUD countdown lingers. Removed the dead double-tap state (firstEscapePressTime/escapeDoublePressThreshold/escapeTimeoutTask/resetEscapeState). Idempotent: 2nd Esc is a no-op via the isRecorderPanelVisible guard in handleRecorderPanelShortcut. An explicit user-bound .cancelRecorder shortcut still takes precedence; the red X cancel button unchanged.
**Commit:** bb23665
**Guard:** isRecorderPanelVisible guard makes repeat Esc idempotent; reuses the existing cancelRecording teardown (no new path); thorough WHY comment at the fix site naming the upstream double-tap confirm + lingering-HUD bug so it doesn't regress on future upstream merges
---

---
**Date:** 2026-06-30T21:17:30Z
**Trigger:** Telegram/voice task 2026-06-30
**Symptom:** ChatGPT floating companion/quick-access window does not activate VoiceInk++ per-app mode (no auto-Enter) and menu-bar Mode indicator stays wrong; works fine from ChatGPT main window
**Root cause:** ChatGPT floating window is a .nonactivatingPanel — takes keyboard focus WITHOUT changing NSWorkspace.frontmostApplication or firing didActivateApplicationNotification. ActiveWindowService resolved the current app for per-app mode ONLY from frontmostApplication (beginApplyingConfiguration, ActiveWindowService.swift:155) + that notification (observer line 45), so it never saw ChatGPT (com.openai.chat) while the panel was focused.
**Fix:** Added accessibilityFocusedApplication() to ActiveWindowService: system-wide AX focused element (AXUIElementCreateSystemWide -> kAXFocusedUIElementAttribute) -> AXUIElementGetPid -> NSRunningApplication. beginApplyingConfiguration now prefers AX-focused app, falls back to frontmostApplication when AX untrusted / no element / focus is VoiceInk's own non-activating recorder panel. AX focus DOES follow into non-activating panels; safe/additive since for ordinary windows AX-focused app == frontmost app. Reuses pattern from FocusLockService.captureCandidate.
**Commit:** 0b81de1
**Guard:** Documented as a preserved fork patch in UPDATING.md so it survives upstream merges; thorough inline comments at the fix site explaining the non-activating-panel problem
---

---
**Date:** 2026-06-30T19:43:04Z
**Trigger:** Ethan task 2026-06-30: idle-miss record hotkey bug
**Symptom:** After Mac idle ~30-60 min, first few presses of the global record hotkey do nothing (must press ~4x) and the start of speech is clipped (no pre-roll buffer).
**Root cause:** VoiceInk++ is a background/accessory app. The record-hotkey CGEventTap's run-loop source lives on the MAIN run loop (ShortcutMonitor.installEventTap -> CFRunLoopGetMain). With NO ProcessInfo activity assertion anywhere, macOS App Nap throttles the main run loop while idle -> tap stops being serviced -> macOS disables the slow tap -> the in-callback tapDisabledByTimeout re-enable is REACTIVE (only fires once an event reaches the dead tap), so the waking press(es) get consumed re-arming the tap instead of starting a recording. Separately, the AUHAL capture unit was only prepared on init/device-change (never on wake), so the first recording after idle cold-started the unit and clipped the first words (no pre-roll ring buffer).
**Fix:** 3 prongs: (1) New VoiceInk/Services/AppNapGuard.swift holds an app-lifetime ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep) so App Nap can't throttle the run loop (Mac can still idle-sleep); inited first in VoiceInkApp.init via _ = AppNapGuard.shared. (2) ShortcutMonitor.ensureEventTapHealthy(reason:) PROACTIVELY checks CGEvent.tapIsEnabled and re-enables, or reinstallEventTap() if the Mach port is invalid (CFMachPortIsValid); RecordingShortcutManager wires it to NSWorkspace didWake/screensDidWake/sessionDidBecomeActive + a 15s watchdog Timer on RunLoop.main .common. (3) Recorder.swift adds an NSWorkspace.didWakeNotification observer that re-prepares the AUHAL (schedulePrepareForCurrentDevice reason=wake) so capture is warm on the first post-wake press.
**Commit:** PR #8 squash-merged to main
**Guard:** Thorough inline comment blocks at each fix site naming the App-Nap-throttles-main-run-loop mechanism + reactive-vs-proactive tap re-enable + cold-start clipping. ensureEventTapHealthy guards on shortcuts non-empty + CFMachPortIsValid; watchdog uses tapIsEnabled fast-path (no reinstall unless needed). Wake re-prepare skips when deviceManager.isRecordingActive. AppNapGuard deliberately avoids .latencyCritical (overkill) and allows idle system sleep so we don't keep the Mac awake. Project uses PBXFileSystemSynchronizedRootGroup so new AppNapGuard.swift auto-compiles. NOT built on MBP (codesign dialogs) — Mini builds+signs. Base official VoiceInk untouched.
---

---
**Date:** 2026-06-28T16:14:55Z
**Trigger:** Ethan task 2026-06-28: skip-mode-processing button doesn't skip the script
**Symptom:** skip-mode-processing button engaged (orange) but the Mode's custom-command/SCRIPT still ran after transcription (AI enhancement was bypassed, but deliverCustomCommand still fired)
**Root cause:** skip was encoded ONLY indirectly by rewriting VoiceInkEngine.runPipeline's outputConfiguration closure to .paste; TranscriptionDelivery.deliver routes purely on request.output.outputMode and had NO skip flag, so any path where the final output value reached delivery as .customCommand (the fragile closure-rewrite-to-delivery hop) still ran the script. No script path exists outside TranscriptionDelivery.deliverCustomCommand (confirmed).
**Fix:** Made skip AUTHORITATIVE and DETERMINISTIC: thread an explicit skipPostProcessing Bool from session → pipeline.run → TranscriptionDelivery.Request. Pipeline now FORCES outputForDelivery to raw .paste (customCommand nil) when skip is on, and gates enhancement/respond on it. TranscriptionDelivery.deliver short-circuits to the raw paste() branch when request.skipPostProcessing (bypassing deliverCustomCommand AND deliverResponse) regardless of outputMode. Also (Codex finding #2) skip now bypasses trigger-word mode-switching, paragraph formatting, and word-replacement so the transcript is truly RAW. Decisive VIPPDebug logs added at pipeline resolve + delivery decision.
**Commit:** 50d0dab
**Guard:** Belt-and-braces: bypass enforced at BOTH the pipeline output-resolution site AND the delivery router (request.skipPostProcessing). New default-valued params keep single callers compiling. VIPPDebug logs: 'pipeline: skipPostProcessing RESOLVED=true', 'pipeline: skip ON → output FORCED to raw .paste', 'deliver: skipPostProcessing ON → FORCING raw paste' confirm in Console.
---

---
**Date:** 2026-06-28T15:55:13Z
**Trigger:** Feature: skip-mode-processing one-shot toggle button next to Cancel
**Symptom:** Needed a one-shot way to skip the active Mode's post-processing (AI enhancement + custom-command/script) for a SINGLE dictation and paste the raw transcript, without changing default settings
**Root cause:** Feature, not a bug: post-processing is decided per-pipeline-run via the enhancementConfiguration + outputConfiguration closures resolved in VoiceInkEngine.runPipeline; there was no per-recording escape hatch
**Fix:** Added @Published skipPostProcessing to RecordingSession (per-session, one-shot) + to RecorderStateProvider protocol (settable) + inert stub on VoiceInkEngine. New RecorderSkipProcessingButton (bolt.slash toggle, amber when engaged) placed right of RecorderCancelButton in Mini/NotchRecorderView, bound directly to observed session's flag. BYPASS at VoiceInkEngine.runPipeline closures: enhancementConfiguration returns nil + outputConfiguration rewritten to plain .paste (customCommand stripped, autoSendKey kept) when session.skipPostProcessing==true. Pipeline reads flag at run time so toggling during recording is honored.
**Commit:** pending
**Guard:** Single bypass point at the two closure-resolution sites in runPipeline (covers BOTH enhancement and script); raw text still flows through normal paste() + state transitions; thorough VIPP comments on per-session/one-shot semantics + the two numbered bypass points
---

---
**Date:** 2026-06-28T01:18:00Z
**Trigger:** Feature: pause YouTube on dictation start, resume on stop
**Symptom:** YouTube video playing in Chrome did not pause when starting a VoiceInk++ dictation (PlaybackController/MediaRemote can't reliably reach a Chrome YouTube tab)
**Root cause:** PlaybackController only covers Spotify/Apple Music/MediaRemote now-playing apps; Chrome YouTube tabs are not reachable that way
**Fix:** Added VoiceInk/Notifications/RecordingActivityNotifier.swift posting DistributedNotificationCenter names com.ethansk.voiceink.recordingStarted/Stopped; posted from Recorder.swift at the same sites as pauseMedia() (success branch of startRecording) and resumeMedia() (in stopRecording). The youtube-spotify-media-key menu bar app observes these and pause/resumes the playing YouTube tab via its Chrome extension. Complementary to PlaybackController, not a replacement.
**Commit:** pending
**Guard:** Hooks at the single Recorder start/stop chokepoint so multi-session (record-while-transcribing) and cancel all funnel correctly; thorough comments on the cross-app DistributedNotificationCenter contract + 'cancel==stop at recorder layer'. Helper app guards resume with 'only resume what we paused'.
---

---
**Date:** 2026-06-28T00:00:00Z
**Trigger:** Feature: record-while-transcribing (decoupled capture from transcription)
**Symptom:** Could not start a NEW dictation while the previous one was still transcribing; pressing record during .transcribing was ignored.
**Root cause:** VoiceInkEngine was SINGLE-FLIGHT — its toggleRecord STOP branch AWAITED runPipeline INLINE on the MainActor before the mic could be reused, and RecorderUIManager's re-entrancy guard ignored toggles during .transcribing/.enhancing (to protect that inline-awaited pipeline from a stray cancel).
**Fix:** Refactored engine to a @Published [RecordingSession] collection (new RecordingSession.swift). STOP now flips the session to .transcribing and ENQUEUES its pipeline on a SERIAL FIFO transcription queue (a chained Task<Void,Never> on the MainActor: each enqueue awaits the previous tail then runs runPipeline(for:)) instead of awaiting inline — mic frees instantly. Serial (NOT concurrent) is mandatory because whisperModelManager.whisperContext is a shared singleton actor + cleanupResources tears down the shared model; serial ⇒ completion order == recording order ⇒ FIFO delivery for free. Derived recordingState reflects ONLY the active recording session, falling back to .idle when none recording (CRITICAL: RecordingShortcutManager.canHandleShortcutAction blocks toggles when state is .transcribing, so reporting .idle keeps the record shortcut usable mid-transcription). RecorderUIManager guard now STARTS a new session on toggle-during-transcribing. UI: stacked recorder cards — Mini stacks transcribing cards UPWARD off a bottom-anchored base (offset y = -cardSpacing*indexFromBottom); Notch keeps the pill + stacks "transcribing…" chips beneath it. Per-card cancel via engine.cancelSession(id:); cancel poisoning keyed per-session by pipelineTranscriptionID.
**Commit:** PR #3 merged to main (squash 4133454). Fixup 9b1e48c removed a redundant RecorderStateProvider conformance on the VoiceInkEngine class line that broke the Mini build with "redundant conformance" — conformance already lived in VoiceInkEngine+Protocols.swift. Built + installed on MBP via Mini signing flow (Authority=VoiceInk Local Signing, CFBundleVersion 201).
**Guard:** one-active-recording invariant asserted in toggleRecord START branch; extensive comments on the serial-queue why-not-concurrent rationale, FIFO delivery, derived-state shortcut-gate safety, media resume-between-sessions nuance, and the RecorderUIManager guard transition. LESSON: don't re-declare a protocol conformance on the class line when an extension already declares it (Swift errors as redundant).
---

---
**Date:** 2026-06-26T18:06:00Z
**Trigger:** Feature request: add cancel button to abort recording
**Symptom:** Wanted a Cancel (X) button next to Stop in recorder panels to abort/discard a recording or in-flight transcription without pasting
**Root cause:** No cancel control existed in the UI, though mid-flight cancellation infra already existed in the engine
**Fix:** Added shared RecorderCancelButton (red xmark) to MiniRecorderView + NotchRecorderView via RecorderComponents.swift; wired closure through Mini/Notch WindowManager + RecorderUIManager.cancelRecording() -> VoiceInkEngine.cancelRecording(). Reused existing cancel path: in-flight transcription IDs go to canceledPipelineTranscriptionIDs and shouldCancel() gate discards text (no paste); runs same recorder.stopRecording() so playbackController.resumeMedia()+unmuteSystemAudio() resume paused media. Button hidden at idle/busy; idempotent.
**Commit:** PR#2 merged to main
**Guard:** Button only shown while recording/transcribing; engine idle branch makes cancel idempotent; reuses stop teardown so media-resume path is identical
---

---
**Date:** 2026-06-26T00:00:00Z
**Trigger:** Cancel-recording-button task 2026-06-26
**Symptom:** No user-facing way to ABORT/discard a running recording or in-flight transcription without it pasting text; only Stop (finish+transcribe+paste) existed.
**Root cause:** A clean cancel teardown already existed in the codebase (RecorderUIManager.cancelRecording → VoiceInkEngine.cancelRecording) but was only reachable via Esc / the conditional grey close button — there was no dedicated cancel control in the recorder panels.
**Fix:** Added red `RecorderCancelButton` (xmark) in RecorderComponents.swift next to Stop in BOTH MiniRecorderView and NotchRecorderView, wired via a new `onCancelTapped` closure threaded through MiniWindowManager/NotchWindowManager to the EXISTING cancelRecording() path. That path poisons the in-flight pipeline (result discarded, never pasted), calls recorder.stopRecording() — the SAME stop path normal Stop uses, which resumes paused media (playbackController.resumeMedia()) + unmutes — clears state, dismisses the panel. Commit 3837de4 (PR #2).
**Guard:** `shouldShowCancelButton` only renders the button for .starting/.recording/.transcribing/.enhancing (hidden at .idle/.busy, idempotent if pressed); reuses the already-tested cancel teardown instead of a new one; thorough inline comments explain discard-not-deliver + media-resume.
---
**Date:** 2026-06-23T23:35:07Z
**Trigger:** Deep-research task on VoiceInk++ media pause/resume reliability (2026-06-23)
**Symptom:** Media (Spotify/Music/browser/podcast) doesn't reliably pause on dictation record-start or resumes wrong on stop; sometimes STARTS playback that wasn't playing
**Root cause:** resumeMedia() simulated the NX_KEYTYPE_PLAY HID media key = a STATE-BLIND TOGGLE; with stale async-MediaRemote-listener state it toggled the wrong way (started unpaused media, or failed to resume). Resume guard also depended on the live listener observing isPlaying==false which lags, so resume silently bailed.
**Fix:** Rewrote PlaybackController as a state machine (idle -> pausedByUs(source) -> idle) that records EXACTLY what it paused and re-issues an EXPLICIT play to only that source. Fallback ladder: (1) Spotify/Apple Music via AppleScript player-state + explicit pause/play (new AppleScriptMediaControl.swift); (2) cross-app MediaRemote-adapter explicit pause()/play() via the entitled /usr/bin/perl host (works on macOS 26 where direct framework access is gated since 15.4); (3) removed the HID toggle entirely. Nothing-playing => do nothing.
**Commit:** efbdd85
**Guard:** Inline comments document the state machine + macOS-26 perl-host rationale; no-toggle invariant; isAppStillRunning guards resume against quit-mid-recording
---

---
**Date:** 2026-06-21T23:06:52Z
**Trigger:** Ethan task 2026-06-22: make focus-lock automatic (no gesture) — mouse-button ⇧⌃⌥ pulse can't be held
**Symptom:** Manual stop-hold focus-lock gesture (long-press ⇧⌃⌥) never engages for Ethan because his record trigger is a MOUSE BUTTON that pulses the modifier combo as a ~0.1s tap he physically cannot hold, so the start-field restore never fired.
**Root cause:** The whole focus-lock 'paste into the field I started in' feature was gated behind a HOLD gesture (stop-hold timer crossing longPressThreshold). A mouse-button modifier pulse always reads as a short tap → lock never armed → restoreFocusToLock() always a no-op.
**Fix:** Made the decision AUTOMATIC at paste time, no gesture. captureCandidate() at record-start still persists the start field. In TranscriptionDelivery.paste(), new FocusLockService.isEditableElementFocused() reads the frontmost app's AX focused element role/subrole: editable role (AXTextField/AXTextArea/AXComboBox/AXSearchField) or settable-string kAXValue → paste at cursor; ambiguous (AXWebArea/AXGroup/AXScrollArea/AXUnknown/web/Electron) → bias TRUE (paste at cursor, never hijack); clearly non-text (AXButton/AXMenuItem/AXImage/AXStaticText/AXCheckBox/AXRadioButton/AXLink/AXList/AXRow/AXCell/AXWindow/AXApplication/etc.) or NO focused element → restore to start candidate. Self-excludes com.ethansk.VoiceInkPlusPlus (falls back to next regular app). Auto path arms the lock pre-dismiss (flips @Published isLockActive → amber FocusLockIndicator shows ~280ms) then performAutoRestoreToCandidate() does the AX focus-set UNCONDITIONALLY (same-pid divergence from restoreFocusToLock's no-op, since focus may be on a non-editable element in the same app). Any AX failure → ambiguous → true (safe, no hijack). Old gesture plumbing left intact but secondary.
**Commit:** 659c9f8
**Guard:** isEditableElementFocused biases hard to true on uncertainty (only hijacks when CONFIDENT nothing editable focused); performAutoRestoreToCandidate documented same-pid divergence; VIPPDebug 'focuslock: AUTO-decide editableFocused=<bool> ...' log line at the decision; os_log type-safety self-checked (all interpolations local vars or ?? wrapped, role bridged CFString→String?→unwrapped). MBP cannot build (codesign) — Mini builds.
---

---
**Date:** 2026-06-21T20:42:37Z
**Trigger:** Ethan task 2026-06-21: stop-hold focus-lock doesn't work for modifier-only ⇧⌃⌥ (live-log confirmed STOP short-tap dur=0.10..0.14)
**Symptom:** Stop-hold focus-lock never engaged for Ethan's modifier-only ⇧⌃⌥ toggle shortcut; every stop logged as a ~0.10s short-tap → no lock, so 'paste into the field I started in' never triggered.
**Root cause:** For a modifier-only shortcut the monitor synthesises a key-up almost immediately (~0.1s) regardless of how long the keys are physically held. That spurious early key-up took the short-tap branch and CANCELLED the 0.45s stop-hold threshold timer before it could fire, so promoteToLock() never ran.
**Fix:** RecordingShortcutModeHandler now captures whether the active record Shortcut is modifierOnly + its modifier mask at STOP key-down (via new shortcutForAction closure). For modifier-only shortcuts the STOP key-up is IGNORED for the lock decision (does NOT cancel the timer); the threshold timer fires at longPressThreshold and decides by LIVE NSEvent.modifierFlags (new FocusLockService.requiredModifiersStillHeld(required:) isSuperset check) — required modifiers still held ⇒ promoteToLock, released ⇒ clearCandidate. KEY shortcuts keep the old reliable-key-up timing path. UI: FocusLockIndicator now shows a lock.fill glyph + amber tint when isLockActive so the locked mode is visibly distinct.
**Commit:** 6add5a0
**Guard:** Big modifier-only ~0.1s key-up comment blocks at the STOP key-down timer + STOP key-up branch + requiredModifiersStillHeld(); reset clears currentStopIsModifierOnly/currentStopRequiredModifiers; START press also clears them to prevent leak. New VIPPDebug line: 'focuslock: STOP threshold reached → modifiers still held=<bool> (required=<raw>, current=<raw>) → promoteToLock|tap'. MBP cannot build (codesign) — Mini builds.
---

---
**Date:** 2026-06-21T00:02:09Z
**Trigger:** Ethan task 2026-06-21: move focus-lock decision from start to stop press for toggle+tap gesture
**Symptom:** Focus-lock 'paste into the field I started in' never triggered for Ethan because the long-press lock decision was on the START press, but his gesture is a modifier-only TOGGLE (⇧⌃⌥, toggle mode): TAP to start, TAP to stop. The start tap never crossed longPressThreshold so the lock never armed.
**Root cause:** OLD model armed the promote-timer on the START key-down. In toggle+tap usage the start press is a quick tap → timer cancelled at start key-up → lock never armed → restoreFocusToLock() always a no-op.
**Fix:** Moved the lock decision from START to STOP. START press: ALWAYS captureCandidate() and PERSIST it for the whole session (do NOT clearCandidate on start key-up). STOP press (key-down, where startsFreshRecording==false): arm a stop-hold threshold timer; if combo still held at longPressThreshold → promoteToLock() (paste into original field); short tap → clearCandidate (normal cursor paste). Added currentPressStartedRecording flag so handleKeyUp knows start-vs-stop side. Added FocusLockService.stopHoldDecisionPending + a bounded grace-wait in TranscriptionDelivery.paste() for the rare fast-transcription race. Mirrored the old promote-timer pattern (weak self + isShortcutPressed/activeRecordingShortcutAction guards). Did NOT touch the same-pid no-op regression guard in restoreFocusToLock().
**Commit:** 71e6dc9
**Guard:** Big START→STOP model comment blocks at every changed site (handler longPressLockTask doc, handleKeyDown start+stop branches, handleKeyUp start-vs-stop resolve, FocusLockService captureCandidate persist note, TranscriptionDelivery grace-wait). New VIPPDebug lines: RECORD START captured candidate (persisting), STOP press arming stop-hold timer, STOP long-hold→promoteToLock, STOP short-tap→clearCandidate. Filter: subsystem==com.ethansk.VoiceInkPlusPlus category==VIPPDebug. MBP cannot build (codesign) — Mini builds.
---

---
**Date:** 2026-06-20T23:11:34Z
**Trigger:** nope it just failed exactly same again check (2026-06-21)
**Symptom:** VoiceInk++ records, bar shows 'transcribing' briefly then hides without pasting; nothing inserted
**Root cause:** Local Deepgram proxy (127.0.0.1:51337) returned HTTP 500 'Deepgram API key is not configured' — the keychain item 'voiceink-deepgram-tuned-proxy/deepgramAPIKey' it resolves the key from was MISSING (deleted/lost), and config.json deepgram_api_key + plist env were empty, so transcribe failed → empty text → deliver status=failed → dismissRecorderPanel HIDE. NOT the Swift cancel-while-transcribing path (that rebuild chased the wrong bug).
**Fix:** Wrote the valid Deepgram key into the proxy config.json 'deepgram_api_key' (proxy reloads config every request → instant, no restart, avoids flaky launchd→keychain read), chmod 600; also restored the keychain item with -T /usr/bin/security. Confirmed via curl probe: 'key not configured' 500 gone.
**Commit:** a7cb2f3
**Guard:** VIPPDebug os_log across the deliver path (subsystem com.ethansk.VoiceInkPlusPlus) — 'cloud upload END status=500' + 'transcribe FAILED' pinpoint a proxy/key failure instantly; live-capture with: log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus"' --level debug
---

---
**Date:** 2026-06-20T22:45:55Z
**Trigger:** Ethan task 2026-06-20: VoiceInk++ records → transcribing briefly → bar hides → nothing pastes, mixed 200/500-BrokenPipe at proxy
**Symptom:** VoiceInk++ records → 'transcribing' shows for a blink → recorder bar hides instantly → NOTHING pasted. Proxy (127.0.0.1:51337) logs a MIX of 200 (real text returned) and 500 BrokenPipeError (client closed conn early). bf2347e focus-lock broadened guard already shipped yet bug persisted → focus lock NOT the live cause.
**Root cause:** Re-entrancy in the recorder state machine. HYBRID key-up stops recording via RecorderUIManager.toggleRecorderPanel → engine.toggleRecord → runPipeline awaits the cloud upload INLINE on the MainActor. The await frees the MainActor, so a stray record-shortcut event (key-repeat / quick re-press for the next dictation / hybrid key-up re-dispatch / modifier-combo interruption) re-enters toggleRecorderPanel while state==.transcribing and hit 'case .starting,.transcribing,.enhancing: await cancelRecording()'. That ran requestRecordingCancellation() → inserted the active pipeline id into canceledPipelineTranscriptionIDs → the pipeline's post-transcribe shouldCancel() gate threw away the already-returned 200 text via finishCanceledTranscription() and dismissed the bar; the in-flight URLSession upload (child of the cancelled Task) was torn down → proxy saw BrokenPipe 500. Clean runs (no stray event in the brief window) → 200 + paste. Hence the observed mix.
**Fix:** RecorderUIManager.toggleRecorderPanel: split the '.starting,.transcribing,.enhancing → cancelRecording' case. .starting still cancels (genuine pre-record cancel); .transcribing/.enhancing now IGNORE the re-entrant toggle (return) so an in-flight transcription can't be aborted by a stray event — explicit cancel still works via Esc/close (handleDismissRecorderPanelNotification, onCloseTapped). Defensive guard in TranscriptionPipeline: the post-transcribe + pre-delivery shouldCancel() gates now only discard when the returned/final text is EMPTY; a late cancel that races in after a finished 200 delivers the text instead of eating it. Added VIPPDebug os_log (subsystem com.ethansk.VoiceInkPlusPlus category VIPPDebug) across the whole path.
**Commit:** uncommitted (Mini builds)
**Guard:** Big comment block at RecorderUIManager fix site naming the re-entrancy + inline-await window; pipeline non-empty-text guard commented as defensive sibling; VIPPDebug logging at every stage (stop, transcribe start/success/fail+isCancelled, requestRecordingCancellation poison point, deliver branch, paste len+restore decision, every bar HIDE) so the next build reveals the exact sequence. Filter: log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus" && category == "VIPPDebug"'
---

---
**Date:** 2026-06-20T21:56:32Z
**Trigger:** Ethan task 2026-06-20: VoiceInk++ records but never pastes, waveform disappears
**Symptom:** VoiceInk++ records but never pastes — waveform disappears, transcribes fine but NOTHING inserted (esp. record-then-click-into-a-field-in-same-app, the #785 flow). REGRESSION of the 3733622 fix.
**Root cause:** FocusLockService.restoreFocusToLock() no-op guard from 3733622 was too NARROW: it only skipped the restore dance when locked app still frontmost AND CFEqual(liveElement, capturedElement). But AXUIElement identity is NOT stable across record->click-into-field: at delivery the focused element is the CORRECT field but a DIFFERENT AXUIElement ref than captured at key-down, so CFEqual fails -> code concludes 'focus moved' -> runs target.app.activate() + AXUIElementSetAttributeValue(kAXFocusedUIElement, staleElement) right before Cmd+V -> paste swallowed. Base VoiceInk lacks this code so base works.
**Fix:** Broadened the guard in restoreFocusToLock(): early-return no-op whenever the SAME app is still frontmost (NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid), WITHOUT the CFEqual element-identity check. Dropped the element check entirely (it is the misfiring part). Restore dance now runs ONLY when a genuinely DIFFERENT app is frontmost (real long-press->switch-app case). Also: gave OpenAICompatibleTranscriptionService a dedicated URLSession with timeoutIntervalForRequest=180 / timeoutIntervalForResource=300 (was URLSession.shared default 60s) to stop intermittent BrokenPipe/500 mid-proxy-retry.
**Commit:** ff011b3
**Guard:** Big comment block at fix site naming this as a regression of 3733622, citing the record->click-in / #785 workflow and why the CFEqual element check was dropped (AX identity unstable). Verifiable log line preserved: 'restoreFocusToLock: same app frontmost — no-op, normal paste' fires on next normal-dictation test.
---

---
**Date:** 2026-06-16T23:52:08Z
**Trigger:** Ethan task 2026-06-17 (rebrand fork to VoiceInk++ standalone)
**Symptom:** Fork shared bundle id com.prakashjoshipax.VoiceInk with official VoiceInk → TCC permission + UserDefaults/prefs + Application Support + keychain collisions; couldn't install both apps side-by-side with separate permissions
**Root cause:** Forked app kept upstream identity: PRODUCT_BUNDLE_IDENTIFIER, CFBundleDisplayName, and hardcoded App Support / keychain identity strings all pointed at com.prakashjoshipax.VoiceInk, so macOS treated the fork and the official app as the SAME app for TCC/prefs/storage
**Fix:** Rebranded to standalone app VoiceInk++: bundle id -> com.ethansk.VoiceInkPlusPlus (tests .Tests/.UITests), PRODUCT_NAME -> VoiceInkPlusPlus (build-path-safe, builds VoiceInkPlusPlus.app), CFBundleDisplayName -> VoiceInk++ (user-visible). Moved self-storage identity to new id: App Support dir + Recordings subdir (VoiceInk.swift, VoiceInkEngine, TranscriptionAutoCleanupService, AudioFileTranscriptionService/Manager) and keychain service (KeychainService). Updated TEST_HOST, product PBXFileReference path, xcscheme BuildableName, Makefile local/run app paths. User-facing titles: window title + 'Quit VoiceInk++' menu items; system app menu/About/Dock auto-derive from CFBundleDisplayName.
**Commit:** 962339b
**Guard:** Comments at every changed identity site explaining the standalone-fork split; UPDATING.md documents new id + DR (identifier com.ethansk.VoiceInkPlusPlus) for Mini resign-local.sh; iCloud container + lowercase OSLog subsystems DELIBERATELY left as upstream id (CloudKit inert under LOCAL_BUILD; logger labels are cosmetic) with inline comments
---

---
**Date:** 2026-06-16T23:09:30Z
**Trigger:** Ethan task 2026-06-17: short-press dictation pastes nothing regression
**Symptom:** Normal short/hold dictation transcribes fine but pastes NOTHING — recorder shows 'transcribing', disappears, no text inserted. Accessibility + Input Monitoring both granted (not a permissions issue).
**Root cause:** Default record mode is HYBRID; natural push-to-talk = HOLD the hotkey for the whole utterance, almost always >450ms longPressThreshold. That hold PROMOTED a Feature-A focus lock even for ordinary single-field dictation where the user never moved focus. At delivery restoreFocusToLock() ran the full restore dance (NSRunningApplication.activate() + AXUIElementSetAttributeValue kAXFocusedUIElement to the element captured 450ms+ earlier). By delivery that captured element is often STALE (field re-rendered / AX identity changed), so forcing focus + re-activating right before the Cmd+V CGEvent created a focus race that SWALLOWED the paste.
**Fix:** VoiceInk/Modes/FocusLockService.swift restoreFocusToLock(): (1) hardened top guard to a provable no-op 'guard isLockActive, let target = lockedTarget else { return false }'. (2) Added regression guard: read LIVE system-wide focused element + frontmost app; if locked app still frontmost AND live focused element == captured element (CFEqual), user never moved -> do NOTHING and let normal paste run. activate()+AX-focus-set now fires ONLY when focus genuinely moved away (real long-press->click-elsewhere flow).
**Commit:** 3733622
**Guard:** Big inline comment block at the fix site naming the bug + why touching focus when unmoved is pure downside; CFEqual identity check (not Swift == on AXUIElement); early-return no-op documented as load-bearing ('do not move focus-touching code above it'). captureCandidate() only READS focus (AXUIElementCopyAttributeValue), never moves it. Could NOT build on MBP (codesign dialogs) — Mini builds + re-signs.
---

---
**Date:** 2026-06-17T00:00:00Z
**Trigger:** Ethan task — recorder-UI indicator for long-press focus-lock mode
**Symptom:** No on-screen signal that the CURRENT recording is in the long-press "lock the start field" capture mode (Feature A). Ethan wanted a caption above the waveform that reads exactly "Using input from voice start" when the lock is on, and nothing when it's a normal short-press recording.
**Root cause:** FocusLockService exposed lock state only as a COMPUTED `isLockActive { lockedTarget != nil }` — not observable from SwiftUI, so the recorder views couldn't react to it.
**Fix:** Made FocusLockService an ObservableObject with a `@Published private(set) var isLockActive` STORED mirror (computed props never fire objectWillChange). All lock mutation now routes through one chokepoint `setLockedTarget(_:)` (only writer of both `lockedTarget` + `isLockActive`), called from promoteToLock()/clearLock() — invariant isLockActive == (lockedTarget != nil). New reusable `FocusLockIndicator` view in RecorderComponents.swift (`@ObservedObject FocusLockService.shared`) renders a small footnote-weight white-opacity-0.55 caption only when active, collapses to nothing otherwise. Wired ABOVE the waveform in BOTH recorders: MiniRecorderView (extra row above `controlBar`, which holds the AudioVisualizer) and NotchRecorderView (new `focusLockIndicatorRow` above `mainRow`; pillHeight grows by `focusLockIndicatorHeight` only while active + non-collapsed so it never forces the hidden notch open). Clears automatically because clearLock() at delivery/end flips isLockActive false.
**Commit:** 1b0ab77
**Guard:** Single-writer setLockedTarget invariant + thorough comments; indicator gated to active-only so short-press recordings show nothing; @MainActor keeps @Published writes on the SwiftUI-observed thread. NOTE: could not build on MBP (codesign dialogs) — Mac Mini builds + verifies.
---
**Date:** 2026-06-16T21:47:32Z
**Trigger:** RecordingShortcutManager compile-error fix task
**Symptom:** Code analyzer flagged 'Cannot find ShortcutStore/VoiceInkEngine/RecorderUIManager/ShortcutMonitor etc.' + 'canHandleShortcutAction cannot be used on type Self' in RecordingShortcutManager.swift after Feature A focus-lock landed
**Root cause:** SourceKit single-file analysis false positives — those types all exist elsewhere in the module (ShortcutStore.swift, VoiceInkEngine.swift, etc.) and resolve fine at module-compile time. The static-func-vs-computed-property 'canHandleShortcutAction' is also unambiguous to swiftc. Only genuine issue was a real macOS-14 deprecation.
**Fix:** Ignore the per-file Cannot-find/Self false positives (do NOT redefine those symbols). The one real fix: replace deprecated NSRunningApplication.activate(options: [.activateIgnoringOtherApps]) with no-arg .activate() in FocusLockService.swift line ~186.
**Commit:** aef078b
**Guard:** Inline comment at the activate() call site explaining the macOS-14 deprecation + why NSApplication.activate(ignoringOtherApps:) elsewhere is a different API
---

---
**Date:** 2026-06-16T00:00:00Z
**Trigger:** Ethan task 2026-06-16 (long-press focus lock + robust double-Enter)
**Symptom:** (B) On a lagging Mac the single auto-Enter sometimes doesn't register so the dictated message never submits — worse on longer transcripts.
**Root cause:** TranscriptionDelivery posted exactly ONE Return via CGEvent after paste; under load (esp. while the field is still settling a long pasted string) that keystroke can be dropped, so nothing submits.
**Fix:** CursorPaster.performAutoSend now posts Return once, then a SECOND Return after a length-scaled delay (base 120ms + 0.4ms/char, capped 600ms) for plain `.enter` only. Safe because after the first Enter submits the field is empty so the 2nd is a no-op, but if the 1st was dropped the 2nd still submits. Shift/Cmd+Enter stay single-fire. In-process CGEvent (key code 36/0x24), re-checks AXIsProcessTrusted before retry. Commit fae3930.
**Guard:** Tunable named constants (doubleEnterBaseDelay/PerCharDelay/MaxDelay) with rationale comments; second fire gated to `key == .enter`.
---
**Date:** 2026-06-16T00:00:00Z
**Trigger:** Ethan task 2026-06-16 (long-press focus lock + robust double-Enter)
**Symptom:** (A) Wanted: focus a field, long-press record, look away while talking, have the transcript land back in the ORIGINAL field — but #785 frontmost-follow always pastes into wherever you end up.
**Root cause:** By design #785 re-resolves the target at delivery from the frontmost app; there was no way to pin delivery to the field you started in.
**Fix:** New FocusLockService (@MainActor). At record-start key-down, capture AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElement) + owning app. If the hotkey is held > 450ms (longPressThreshold) the capture is promoted to a lock; short press discards it (default path). While locked, ActiveWindowService suppresses the #785 follow. At delivery, re-activate the app (NSRunningApplication.activate) + AXUIElementSetAttributeValue(appElement, kAXFocusedUIElement, stored) before paste, then clear the lock. Wired in RecordingShortcutModeHandler (key-down capture+timer, key-up resolve, reset() teardown) and TranscriptionDelivery (restore before paste, clear after incl. non-paste outcomes). Commit 718a720.
**Guard:** Graceful fallback to default delivery when AX denied / app terminated / element stale (each logged). Reuses existing Accessibility grant (paste needs it anyway). reset()/deliver() clear the lock so it can't leak across sessions. Edge case: apps that don't expose a focused AX element simply never arm a lock.
---
**Date:** 2026-06-15T23:56:32Z
**Trigger:** Ethan task 2026-06-16 (issues #785/#784)
**Symptom:** VoiceInk pastes into the right app but applies the WRONG Mode's auto-send key (issue #785); also nil-resolution left a stale Mode active (issue #784)
**Root cause:** Active Mode was resolved ONLY at record-start from NSWorkspace.frontmostApplication; Ethan starts recording then switches apps, so the Mode never followed the real target app. nil branch had no else, retaining the prior Mode.
**Fix:** Added NSWorkspace.didActivateApplicationNotification observer in ActiveWindowService.start() (wired from VoiceInk.swift app init) that re-runs the same app-config->default->neutral resolution on every frontmost change, including mid-recording (recorder is .nonactivatingPanel so it doesn't steal frontmost). Added else { setActiveConfiguration(nil) } for the neutral fallback. Refactored shared logic into resolveAndApplyConfiguration.
**Commit:** 570a6fa
**Guard:** Thorough comments at start()/handleFrontmostAppActivation/resolveAndApplyConfiguration; ignores own bundle id + nil bundle id; [weak self] in observer + async hop to avoid retain cycle / actor violation
---
