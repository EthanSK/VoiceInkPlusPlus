# Learnings

Per-repo institutional memory for fixes. Every entry below is a real bug we hit + how we solved it. Check this file BEFORE attempting a same-looking fix.

Maintained by the public, self-improving `learnings` skill at `.agents/skills/learnings/SKILL.md`. Codex discovers that canonical folder directly; Claude Code follows `.claude/skills/learnings` to the same skill.

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
