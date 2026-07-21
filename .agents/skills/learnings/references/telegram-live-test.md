# Telegram live delivery test

Use this procedure to distinguish routing failures from Telegram exact-input resolution, insertion, and auto-send failures. Run only against disposable Telegram content.

**Accepted pinned baseline (2026-07-21):** installed v2.0.245 physically passed both
`recordingStart` and `focusedDuringTranscription` in Telegram 12.9 build 282526 Saved Messages while
Terminal remained frontmost. Both traces used `visualIdentity=true`, verified exact insertion, then
`route=telegramTargetedHIDReturn verification=verifiedCleared`. This does not replace rerunning the
procedure after a change and does not prove foreground Primary or wrong-chat rejection.

**Current candidate (v2.0.247):** the full header digest was proven unstable because Telegram's
lower status/activity row changes independently. Replay identity now remains exact but hashes only
the audited avatar plus primary-title row. A trace may log that dynamic-only full-header drift was
accepted; it must still report matching stable chat identity at every irreversible boundary. The
candidate is not accepted until both background routes are physically rerun.

## Prepare Saved Messages safely

1. Start the repository trace:

   ```sh
   bash .agents/skills/learnings/scripts/live-delivery-trace.sh start
   bash .agents/skills/learnings/scripts/live-delivery-trace.sh status
   ```

2. Ask Ethan to open **Saved Messages**, or use the `computer-use` skill when UI control is explicitly in scope. Before an agent takes focus, clicks, types, or presses a key, follow the `macos-heads-up-notification` skill and warn Ethan. Never improvise private Accessibility mutations when Computer Use refuses the target.
3. For the audited visual-identity fallback, verify VoiceInk++ is enabled in **System Settings → Privacy & Security → Screen & System Audio Recording**. Do not request or toggle permission during a recording. Missing permission must produce a fail-closed trace, never a weaker wrapper/geometry fallback.
4. Verify the selected search result and open chat are actually labelled **Saved Messages** before pressing Return or typing. Telegram search once selected an unrelated public channel; a matching-looking search result is not sufficient.
5. Ethan must manually send this harmless seed message in Saved Messages:

   ```text
   VoiceInk Telegram disposable context anchor
   ```

   The seed makes the disposable target unmistakable during manual verification. Current Telegram may still expose no readable AX chat anchors; in that case require `visualCaptureArmed=true` and later `visualIdentity=true`. Never accept an empty AX context without the audited visual proof.
6. Focus the now-empty Saved Messages composer. Do not use a real conversation as a fallback test target.

## Foreground primary-stop scenario

Keep Telegram and the Saved Messages composer frontmost throughout this scenario:

1. Press the **primary button** to start recording.
2. Dictate a harmless distinctive test sentence.
3. Press the same **primary button** to stop. Do not press Next.
4. Wait for delivery and auto-send to finish.

Accept only a trace that proves all of the following:

- the stop route is `destination=focusedAtStop` with `targetCaptured=true`;
- `pipeline: about to DELIVER` carries `targetAutoSend=enter destination=focusedAtStop`;
- the exact Telegram input resolves/restores instead of logging `Focused input restore could not uniquely resolve the saved exact input`;
- insertion succeeds and the foreground auto-send line ends with `success=true`;
- the intended Saved Messages composer is cleared and the message appears there.

`Focused input restore BEGIN` identifies the foreground resolver. `paste: target restore failed; copied transcription to clipboard` means delivery failed before paste even if routing and Mode selection were correct.

## True-background Next-while-recording scenario

Reset to the empty Saved Messages composer, then:

1. Press the primary button and dictate a harmless distinctive sentence.
2. While still recording, press the **Next button once**. This stops into `recordingStart`.
3. Immediately press Command-Tab away from Telegram and remain elsewhere until delivery resolves.
4. Require `destination=recordingStart targetCaptured=true`, the same Telegram identity/insertion/Send proof listed below, a cleared composer, and unchanged foreground.

## True-background second-chance scenario

Reset to the empty Saved Messages composer, then:

1. Press the primary button, dictate a harmless distinctive sentence, and press the primary button again for a normal stop.
2. While the newest result is still transcribing, keep the Telegram composer focused and press the **Next button once**. This is the `focusedDuringTranscription` second chance.
3. **Immediately press Command-Tab away from Telegram** and remain in the other app for at least five seconds. Moving away only after delivery does not test background behavior.
4. Do not refocus Telegram until the trace records the final result.

Require these acceptance lines (IDs and PIDs vary):

```text
paste retarget: ... destination=focusedDuringTranscription targetCaptured=true
pipeline: about to DELIVER ... targetAutoSend=enter destination=focusedDuringTranscription
Captured Telegram exact-input identity ... visualCaptureArmed=true
Telegram retained exact input prepared with matching chat identity ... axAnchors=false visualIdentity=true
paste: background text verified success=true
paste: background auto-send finished success=true ... route=telegramTargetedHIDReturn verification=verifiedCleared
```

If readable AX anchors are available, the preparation line may instead report `axAnchors=true visualIdentity=false`; one of those independent identity routes must be true. The visual route also requires no earlier missing-permission, unstable-capture, unaudited-tuple, or changed-digest rejection.

Also require the final delivery line's `frontmostPid` to differ from Telegram's target PID, and verify Telegram received and sent the text without becoming frontmost. If Telegram stayed frontmost, `Focused input restore BEGIN` appeared, or target/frontmost PIDs match, only the foreground route was exercised.

## Wrong-chat fail-closed scenario

Run this only when two disposable Telegram chats are available; never risk a real conversation.

1. Capture and second-chance-latch the Saved Messages composer as above.
2. Before delivery, switch Telegram internally to the other disposable chat, then Command-Tab away.
3. Require AX-anchor or visual-digest mismatch/rejection in the trace and **zero insertion or Send action in either unintended composer**.

Expected failure evidence includes `Telegram visual identity revalidation rejected changed stable chat identity or dimensions`, `Telegram retained-input preparation rejected a changed or unreadable visual chat identity`, `Telegram retained-input preparation rejected hidden, changed, or internally unfocused chat`, `saved Telegram chat identity changed before insertion`, or another explicit exact-chat resolution failure. A subsequent `paste: background text verified success=true` or semantic Send line is a test failure. A dynamic-only full-header change with the exact stable avatar/title digest may be accepted and is not by itself a wrong-chat rejection. If a second disposable chat is unavailable, mark this scenario **not tested**.

## Read and close the trace

```sh
bash .agents/skills/learnings/scripts/live-delivery-trace.sh show 300
bash .agents/skills/learnings/scripts/live-delivery-trace.sh stop
bash .agents/skills/learnings/scripts/live-delivery-trace.sh status
```

Interpret the route, captured destination, `targetAutoSend`, resolver, insertion result, verification, target PID, and final frontmost PID together. Message appearance alone is not proof, and a warning may reflect a verification defect rather than a failed Return. Preserve only the minimal metadata needed for a durable learning; never copy dictated transcript text into skill evidence.
