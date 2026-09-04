# Audio capture recovery

Use for empty recordings, zero streaming chunks, and failures after audio-route or format changes.

## Diagnose the capture boundary

- Correlate the exact running build/PID, system input/output route changes, and recording lineage.
  Read an identified auto-switch script and its bounded log when relevant; do not edit or run it
  merely because it changed the route.
- Separate PCM absence from silence. A quiet microphone still produces buffers. Zero streaming
  chunks plus a WAV with zero audio bytes means capture failed before provider/delivery processing.
  Use WAV metadata, not listening to private recordings, when only frame count is needed.
- A successful provider connection, `AudioOutputUnitStart`, or preparation log is not capture proof.
  Require the first-PCM confirmation, non-zero streaming chunks, and a real partial/final result.
  Empty-buffer rejection followed by batch HTTP 400 is not by itself a provider outage.
- Device ID, nominal rate and ASBD can all match after an output-device round trip. Do not use
  equality alone to acknowledge a route invalidation; a change during setup must survive setup.

## Repair without touching shared audio

- Observe default input, default output, system output and device-list changes. Balance the exact
  Core Audio listener block/queue/address registrations on cleanup.
- Mark prepared capture stale immediately, coalesce notification bursts for idle warm preparation,
  and bypass that idle wait on an explicit Start. Preserve generation invalidation during setup.
- Never tear down active or paused capture for an output notification. Retain the pending refresh
  until stop; preserve the WAV, realtime session, pause state, media/YouTube ownership and input Mode.
- A bounded first-PCM confirmation belongs on the serial hardware queue, never MainActor or the
  audio callback. Digital silence counts. On timeout, close the input gate and stop AUHAL before
  disposing the file/unit; report a local microphone failure and leave the next start able to rebuild.
- Never change the system default device, preferred rate, routing script, OBS or CoreAudio daemon
  as a substitute for repairing VoiceInk++'s own capture lifecycle.

## Acceptance

Run the route-generation, first-PCM/reset, observer-lifecycle, idle-only refresh, sample-rate and
capture-release tests plus mandatory Primary/Next/HUD guards. Release through the standard Mini
test/sign/install gate. Then confirm an installed normal recording has non-zero PCM and realtime
partials. A physical input/output round-trip test is separate: obtain a safe, approved boundary if
it could affect OBS or other audio work, preserve the prior route, and report it untested until done.
