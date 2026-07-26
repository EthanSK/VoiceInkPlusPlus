# Real-time provider A/B test

Read this reference when Ethan asks to compare Soniox V5 with another real-time
transcription provider using his saved VoiceInk++ recordings.

## Safety and scope

- Use saved recordings only when Ethan explicitly asks for a provider comparison.
- The script performs transcription only. It never invokes VoiceInk++ delivery,
  changes a Mode, pastes, sends Return, or interacts with another app.
- The AssemblyAI key must be entered and verified inside VoiceInk++ under
  **AI Models → Cloud → AssemblyAI**. Never request that Ethan paste the key into
  chat. The script reads the local secure preference in memory and never prints,
  writes, exports, or passes the key through argv or the environment.
- Reports contain private dictated text. Keep them under `/private/tmp`, mode
  `0600`, and never commit or upload them.
- Replaying a WAV to a streaming provider sends that private audio to the
  provider and incurs provider usage. Confirm the user requested that comparison.

## Procedure

1. Verify the installed VoiceInk++ build and current provider from a live
   `Streaming start requested model=` trace. Do not infer it from source.
2. Confirm the candidate provider key is connected. For a missing AssemblyAI key,
   direct Ethan to **AI Models → Cloud → AssemblyAI** and wait.
3. Inventory the corpus without contacting a provider:

   ```sh
   node .agents/skills/learnings/scripts/compare-realtime-stt.mjs \
     --limit 20 \
     --dry-run
   ```

4. Run one sanitized or explicitly authorized saved-audio probe first:

   ```sh
   node .agents/skills/learnings/scripts/compare-realtime-stt.mjs --limit 1
   ```

   Require a non-empty `assemblyAI.transcript`, the exact
   `universal-3-5-pro`/`max_accuracy` configuration in the report, and no API
   error before running the full corpus.

5. Run the requested corpus:

   ```sh
   node .agents/skills/learnings/scripts/compare-realtime-stt.mjs --limit 20
   ```

   The script replays the original 16 kHz mono PCM16 WAVs at real-time pace,
   pairs the new AssemblyAI output with the original live Soniox V5 transcript,
   excludes sub-half-second history artifacts that cannot provide a meaningful
   speech comparison, and prints the private JSON report path when complete.
   If Ethan uses AssemblyAI in VoiceInk++ during the run, the provider may
   temporarily reject the harness with `Too many concurrent sessions`. The
   harness yields and retries that exact transient error. To resume an
   interrupted run without resending successful recordings, pass its existing
   private report path back through `--output`.

6. Compare the pairings blind where practical. Score:

   - obvious semantic nonsense or omitted clauses;
   - proper nouns, technical vocabulary, and VoiceInk++ Dictionary terms;
   - false insertions, repetitions, and cut-off endings;
   - punctuation and likely editing burden;
   - stop-to-final latency, while distinguishing provider finalization from
     delivery latency.

   Text-only sensibility is not ground truth. Listen to the source WAV for
   decisive disagreements, and label uncertain cases as ties rather than
   inventing certainty.

7. Do not switch every Mode merely because one model wins vendor benchmarks or
   a small corpus. First report wins/ties/losses and latency, then follow Ethan's
   explicit switching request with a preferences backup, exact model/language/
   real-time verification, a cooperative restart when required, and a real live
   microphone trace.

## Prompting boundary

The script defaults to Vocabulary keyterms without `TranscriptionPrompt`.
AssemblyAI recommends establishing a baseline before enabling its beta
contextual prompt. Pass `--include-prompt` only when the saved prompt is
deliberately relevant to the dictation corpus; a generic or stale prompt makes
the comparison less representative.
