# Intended-Speech Filtering Plan

## Goal

Keep Ethan's intended dictation while rejecting audio reproduced by the Mac and, where confidence is strong enough, other speakers such as a video presenter. This is not a promise of perfect separation: Mac playback and an unrelated external speaker are different signal problems and need different evidence.

No production filtering should silently delete audio. The original WAV remains the recovery source, filtering is opt-in and feature-flagged, and uncertain classifications fail open until a representative physical corpus proves a stricter policy safe.

## Current capture path

1. `Recorder` selects one configured Core Audio input device and starts `CoreAudioRecorder` without changing the system default device.
2. `CoreAudioRecorder` uses AUHAL (`kAudioUnitSubType_HALOutput`) with input enabled and output disabled. Hardware samples are downmixed to mono, linearly resampled to 16 kHz, and converted to PCM16.
3. The same PCM16 bytes are written to the per-recording WAV and forwarded through `onAudioChunk`.
4. `VoiceInkEngine` buffers chunks until the selected realtime provider is ready, then forwards them unchanged. Non-realtime providers receive the completed WAV.
5. The current realtime path has no playback-reference stream, speaker identity, music classifier, or local streaming VAD in front of the provider. Existing Silero/FluidAudio VAD is used by selected local batch models; VAD answers “is this speech?”, not “is this Ethan?”.

The practical insertion point is therefore after the raw WAV sink and before the realtime-provider callback. That preserves recovery audio while allowing a separate filtered PCM stream for transcription.

## What each technique can and cannot solve

| Technique | Useful for | Cannot reliably solve | Privacy | Typical added latency / risk |
| --- | --- | --- | --- | --- |
| Playback pause or mute | Deterministically prevents audible Mac playback from reaching the mic | External TV/phone speech; playback helpers that miss an app; speaking while playback continues | Local | Lowest processing cost, but interrupts playback |
| VAD (Silero/provider VAD) | Silence, weak noise, speech boundaries | A presenter is speech too; music with vocals may also activate it | Local for FluidAudio; provider-side otherwise | FluidAudio uses 256 ms analysis hops; false rejection rises with high thresholds |
| Music/speech classification | Instrumental music and “music present” evidence | Spoken narration, podcasts, news, lyrics, or Ethan speaking over music | Apple Sound Analysis can stay local | Apple classifier supports 0.5–15 s windows (3 s default); hard gating would be too blunt |
| Acoustic echo cancellation (AEC) | Mac playback that leaks acoustically from speakers into the selected mic, including simultaneous Ethan speech | Audio from a TV/phone with no digital reference; a bad/misaligned reference | Local if implemented in VoiceInk++ | WebRTC AEC uses synchronized ~10 ms capture/render frames; device latency and clock drift must be handled |
| Voice enrollment / target-speaker diarization | Other human speakers, including external presenter narration | A recording of Ethan's own voice; very short/quiet/overlapped speech; perfect identity assurance | Local with FluidAudio; enrollment embedding is biometric-like data and needs explicit delete controls | Pinned FluidAudio Sortformer default is about 1.04 s; false rejection must be measured per mic/environment |
| Source separation / speech enhancement | Reducing stationary noise or isolating vocals from music | Determining whether a vocal belongs to Ethan; cleanly separating two overlapping speakers in every room | Usually local, model-dependent | Higher CPU/latency and can introduce speech artifacts |
| Device voice isolation / directional microphone | Rejecting off-axis room sound before VoiceInk++ receives it | Proving who spoke; availability and processing vary by microphone/device/app | Device-local | Lowest app complexity, but the current direct AUHAL path cannot assume macOS Mic Mode processing is active |
| Keyword gate | Explicit “Codex”/wake-word workflows | Natural dictation without a required keyword; background audio containing the keyword | Local possible | Low-to-moderate latency but high interaction cost and missed-intent risk |
| Transcript/style classifier | Flagging suspiciously polished text after transcription | Speaker identity; Ethan may intentionally dictate polished prose | Text leaves only according to the chosen provider | High semantic false-positive risk; never use as a deletion gate |

## Recommended layered architecture

### 1. Prove Apple voice processing in an isolated harness

Apple documents `AVAudioIONode.setVoiceProcessingEnabled` as removing audio played from the device from incoming audio. It requires both input and output nodes in voice-processing mode and an engine rendering to the audio device, so it is not a one-line property on the current input-only AUHAL recorder.

Build a disposable harness first. With the same selected microphone and output device, compare raw AUHAL and Apple voice-processed capture for:

- another app playing speech and music;
- Ethan speaking alone;
- Ethan speaking over playback;
- speakers, headphones, and output-device changes;
- default-device/output volume, fidelity, and latency remaining unchanged.

Do not replace the current recorder unless this proves that other-process playback is cancelled, Ethan's speech remains intact, and no output/default-device regression occurs.

### 2. If Apple voice processing is insufficient, prototype an explicit playback reference

On the repository's macOS deployment floor, public Core Audio process taps are available. Create a private, global mono tap excluding VoiceInk++ with `CATapDescription.muteBehavior = .unmuted`; keep the reference in memory only. Feed timestamp-aligned render frames and microphone frames to WebRTC Audio Processing/AEC3 near the HAL boundary.

This fallback is more controllable but materially larger: it needs system-audio recording permission, tap/aggregate-device lifecycle, resampling, timestamp alignment, drift compensation, 10 ms framing, and strict teardown. It must never record the playback reference, change output routing, mute playback, or introduce a system-wide virtual audio device.

### 3. Add a local target-speaker score

The pinned FluidAudio dependency already contains Core ML streaming diarization, WeSpeaker embeddings, speaker enrollment, and Sortformer. Prototype both of these on the same corpus:

- Sortformer enrollment for stable realtime speaker slots (default approximately 1.04 s latency, four-speaker limit).
- VAD-segmented WeSpeaker embedding comparison for direct Ethan/not-Ethan confidence.

Store only an explicitly enrolled local embedding by default, not reusable raw enrollment audio. Give it a visible reset/delete control. Run inference off the audio callback on a bounded serial worker.

### 4. Fuse evidence; do not make one weak signal authoritative

For each buffered PCM region:

1. Preserve the raw region in the WAV.
2. Apply proven AEC when a synchronized Mac-playback reference exists.
3. Compute VAD, target-speaker, and optional music/playback scores.
4. Keep high-confidence Ethan speech with pre-roll and hangover padding.
5. Suppress only high-confidence non-Ethan/playback residue. Pass uncertain audio through and record privacy-safe aggregate counters, never transcript or audio.

YouTube/media playback state may increase suspicion or help select an AEC path, but it must never hard-mute the transcription stream by itself: Ethan can speak while a video is playing.

### 5. Keep upstream-provider features auxiliary

- OpenAI realtime transcription supports input noise reduction, but noise reduction is not speaker identity. The current `gpt-live-transcribe` session config has no noise-reduction field and explicitly disables turn detection; any provider-field experiment needs the existing synthetic endpoint probe before a settings or release change.
- Provider VAD controls chunking and silence boundaries, not who spoke.
- Batch `gpt-4o-transcribe-diarize` supports known-speaker reference samples and is useful as an evaluation comparator or optional final batch mode, but it is not the current low-latency `gpt-live-transcribe` stream and sends enrollment/audio to the provider.

## Validation plan before production filtering

### Phase A — isolated probes, no VoiceInk++ install

1. Test Apple voice processing against other-app system playback with a disposable capture harness.
2. If it fails, test an unmuted Core Audio process tap plus AEC on synchronized synthetic echo before any live room capture.
3. Benchmark FluidAudio enrollment/diarization locally without changing the active transcription provider.

### Phase B — representative local corpus

With Ethan's explicit participation, collect short labelled samples for every current microphone/environment:

- Ethan clean, quiet, fast, far-field, and near-field;
- presenter-only YouTube/podcast speech at several volumes;
- instrumental music and music with vocals;
- Ethan speaking over presenter audio and over music;
- the same presenter played from a phone/TV (no Mac playback reference);
- speakers versus headphones;
- rapid start/stop, pause/resume, sleep/wake, and CPU-load cases.

Measure intended-speech retention, background-word leakage, overlap handling, transcript accuracy, p50/p95 added latency, CPU/energy, and model/tap failure recovery. Choose thresholds from this corpus, not synthetic audio alone.

### Phase C — opt-in shadow mode

Ship only score collection first. Raw audio continues to the provider unchanged. Log timestamps, model timings, score buckets, and proposed keep/drop durations, but never audio, transcript text, enrollment vectors, or playback contents. Confirm the queue, pause/resume, recovery drafts, and Primary/Next delivery routes are unchanged.

### Phase D — opt-in filtering

Enable filtered-provider audio only after shadow results show no intended-speech loss. Keep:

- raw WAV/history recovery;
- immediate fail-open on classifier/AEC/tap/model errors;
- a one-click disable switch;
- explicit enrollment deletion;
- a visible indicator when filtering is active;
- a privacy-safe per-recording summary of retained/suppressed duration.

Do not make filtering default-on until physical acceptance covers the full corpus. Never use filtered audio as the only recovery artifact.

## macOS/device boundary

Prefer acoustic prevention when it is available: close microphone placement, a directional mic, and a supported device's own voice-isolation/beamforming can improve every downstream model without new cloud exposure. They are not identity controls, and VoiceInk++'s direct AUHAL capture cannot assume Control Center Mic Mode processing is applied. Test the exact selected input and preserve the existing device choice; do not silently change the default microphone, sample rate, or system audio route.

## Evidence used

- Apple SDK `AVAudioIONode.h`: voice processing removes device playback from input but requires both I/O nodes and a running device-rendering engine.
- Apple SDK `CATapDescription.h` and `AudioHardwareTapping.h`: public process taps are available on macOS 14.2+, can capture a mono global mix, and can remain unmuted.
- Apple Sound Analysis runtime probe: the built-in classifier exposes 303 labels including `speech`, `music`, and `singing`; supported windows span 0.5–15 s and default to 3 s.
- FluidAudio revision `3c6e79f1d74411cae1f3daf50260dd19a585dc2d`: local VAD, WeSpeaker embeddings, streaming diarization, speaker enrollment, and Sortformer default latency documentation.
- WebRTC Audio Processing API: AEC consumes near-end capture plus reverse/render frames in approximately 10 ms blocks and requires render/capture delay accounting.
- OpenAI Realtime documentation: input noise reduction improves noisy-input perception/VAD, while VAD itself controls speech chunking; batch diarization separately supports known-speaker references.
