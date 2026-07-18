import Foundation
import SwiftUI
import os

enum RecordingPasteDestination: Equatable {
    case recordingStart
    case focusedAtStop
    case focusedDuringTranscription
}

/// One user-confirmation pulse in the recorder bar. The token belongs to the
/// recording session so every mirrored monitor panel sees the same action, and
/// the icon is derived from the destination route at the moment it is chosen.
struct RecorderIconActionPulse: Equatable {
    enum Icon: Equatable {
        case currentFocus
        case lockedDestination
    }

    let id: UUID
    let icon: Icon

    init(destination: RecordingPasteDestination, id: UUID = UUID()) {
        self.id = id
        switch destination {
        case .focusedAtStop:
            icon = .currentFocus
        case .recordingStart, .focusedDuringTranscription:
            icon = .lockedDestination
        }
    }
}

struct RecordingPasteTarget {
    let destination: RecordingPasteDestination
    let focusedInput: FocusLockService.Target?
    // The destination and its complete Mode are one atomic per-session choice.
    // In particular, the transcription-time Next Track route is a second chance:
    // Ethan can stop normally, focus a different input, press Next Track while the
    // transcript is still loading, then leave that app. The later app switch must
    // not replace any part of this target app's formatting/output/Return behavior.
    let mode: ModeConfig?
    var autoSendKey: AutoSendKey { mode?.autoSendKey ?? .none }

    init(
        destination: RecordingPasteDestination,
        focusedInput: FocusLockService.Target?,
        mode: ModeConfig? = nil
    ) {
        self.destination = destination
        self.focusedInput = focusedInput
        self.mode = mode
    }
}

/// The one atomic handoff from retargetable transcription state into immutable
/// post-processing and delivery state. The second-chance Next route remains open
/// through transcription and trigger-word selection, then this value freezes both
/// the exact input and the complete Mode before formatting or enhancement begins.
/// A later focus/button event must not combine an old Mode with a new destination.
struct RecordingDeliveryDecision {
    let pasteTarget: RecordingPasteTarget
    let postProcessingMode: ModeConfig?
}

// ═══════════════════════════════════════════════════════════════════════════════
// RecordingSession — one in-flight "voice capture → transcription → paste" job.
// ═══════════════════════════════════════════════════════════════════════════════
//
// FORK FEATURE (record-while-transcribing, 2026-06-28):
// VoiceInkEngine used to be SINGLE-FLIGHT — exactly one recording lifecycle existed
// at a time, and the STOP press AWAITED the whole transcription pipeline INLINE on
// the MainActor before the mic could be used again. That inline await is what blocked
// the user from starting a new dictation while the previous one was still uploading /
// transcribing.
//
// We now model each capture as an independent RecordingSession object. The engine owns
// a COLLECTION of these (`@Published var sessions`). The mic (the single shared
// `Recorder`) is only ever owned by the ONE session that is currently `.recording`;
// every other session in the collection has already stopped capturing and is somewhere
// in the transcription pipeline. So the user can stop session A (mic frees instantly),
// start session B, and A keeps transcribing in the background on a serial queue.
//
// ── SESSION STATE MACHINE ──────────────────────────────────────────────────────
//
//        ┌───────────┐  stop press / key-up   ┌──────────────┐
//        │ .recording│ ─────────────────────► │ .transcribing│
//        └───────────┘  (mic released here)   └──────────────┘
//              ▲                                      │
//   start press│                                      │ transcription returns text,
//   (new sess) │                                      │ enhancement runs (if enabled)
//              │                                      ▼
//        (engine creates                       ┌──────────────┐
//         a fresh session)                     │  .delivering │  paste / respond / cmd
//                                              └──────────────┘
//                                                     │ delivery finished
//                                                     ▼
//                                              ┌──────────────┐
//                                              │    .done     │  → removed from `sessions`
//                                              └──────────────┘     (UI animates it out)
//
//   • .recording    — actively capturing audio. THE mic owner. At most ONE session is
//                     ever in this phase (the one-active-recording invariant below).
//   • .transcribing — audio captured, pipeline running (network upload / whisper /
//                     fluidaudio transcription). Mic already released.
//   • .delivering   — transcription (and optional AI enhancement) done; the result is
//                     being pasted / responded / sent to a custom command. The pipeline
//                     drives the recorder UI state through .enhancing then delivery.
//   • .done         — terminal. The engine removes the session from `sessions`; SwiftUI
//                     animates the card out and the stack collapses.
//
// NOTE: the pipeline internally also surfaces the legacy RecordingState (.transcribing
// / .enhancing) for the per-session status display; Phase here is the coarse lifecycle
// the engine + stack UI key off. We keep both: Phase for collection/stack management,
// the per-session liveRecordingState for the card's spinner/waveform rendering.
//
// ── ONE-ACTIVE-RECORDING INVARIANT (HARD RULE) ─────────────────────────────────
// At most ONE session in `sessions` may have phase == .recording at any time. This is
// enforced at the only two mutation sites:
//   1. VoiceInkEngine.toggleRecord START branch refuses to create a new .recording
//      session if `activeRecordingSession != nil` (defensive assert; the toggle path
//      already guarantees it because a press while one is recording STOPS it instead).
//   2. The STOP branch transitions the active session OUT of .recording (→.transcribing)
//      BEFORE any new session can be created.
// Why it matters: the shared `Recorder` is a single mic owner. Two `.recording` sessions
// would both think they own the mic and fight over start/stop + media pause/resume.
//
// ── ObservableObject ───────────────────────────────────────────────────────────
// Each card in the stacked recorder UI observes ITS OWN session, so phase /
// liveRecordingState / partialTranscript changes redraw only that card. The engine's
// `sessions` array is @Published for add/remove (stack grows/shrinks); the per-session
// @Published members drive each individual card's content.
@MainActor
final class RecordingSession: ObservableObject, Identifiable, RecorderStateProvider {
    enum Phase: Equatable {
        case recording
        case transcribing
        case delivering
        case done
    }

    // Stable identity for SwiftUI ForEach + per-card cancel routing (engine.cancelSession(id:)).
    let id = UUID()

    // Coarse lifecycle phase (drives stack membership / which card is the base). @Published
    // so the owning engine's array observers and this session's card both react.
    @Published var phase: Phase

    // Fine-grained recorder UI state for THIS card (idle/recording/transcribing/enhancing).
    // The pipeline pushes .enhancing here via onStateChange; the card's RecorderStatusDisplay
    // reads it to show the right spinner/waveform. Conforms to RecorderStateProvider so the
    // existing MiniRecorderView / NotchRecorderView can render a single session unchanged.
    @Published var liveRecordingState: RecordingState

    // Live streaming partial (only meaningful while .recording — only the recording session
    // streams partial transcripts from its realtime session).
    @Published var partialTranscript: String = ""

    // ── VIPP (skip-mode-processing feature) — per-session ONE-SHOT bypass flag ──
    //
    // WHAT: when true, THIS recording's pipeline skips ALL of the active Mode's
    // post-transcription processing and pastes the RAW verbatim transcript instead. Two
    // things get bypassed (both at the engine's runPipeline closure resolution site):
    //   1. AI ENHANCEMENT — the `enhancementConfiguration` closure returns nil, so the
    //      pipeline's "enhance" branch is skipped entirely (no LLM round-trip, no rewrite).
    //   2. The mode's CUSTOM COMMAND / SCRIPT (and `.respond` mode) — the
    //      `outputConfiguration` closure is rewritten to a plain `.paste` config with
    //      customCommand stripped, so TranscriptionDelivery takes the raw-paste branch
    //      instead of deliverCustomCommand / deliverResponse.
    //
    // WHY ON RecordingSession (not a global setting): the bypass must be PER-SESSION and
    // ONE-SHOT. The user decides DURING a given recording that this one should be raw; it
    // must NOT alter their default Mode/settings, and the very next recording (a fresh
    // RecordingSession, which initializes this back to false) behaves normally again.
    // Putting it here means it travels with the exact capture it applies to — even with
    // record-while-transcribing, where session A (raw) and session B (normal) can be in
    // flight simultaneously, each carries its own flag and the pipeline reads the right one.
    //
    // WHEN IT'S READ: the engine's runPipeline resolves the enhancement/output closures at
    // pipeline-run time (after STOP), so toggling the button any time BEFORE the pipeline's
    // enhancement/delivery step is honored. @Published so the recorder card's toggle button
    // re-renders its on/off (subdued vs amber) state the instant it flips.
    @Published private var skipPostProcessingValue: Bool = false
    @Published private var resolvedSkipPostProcessing: Bool? = nil

    var skipPostProcessing: Bool {
        get { resolvedSkipPostProcessing ?? skipPostProcessingValue }
        set {
            // The toggle remains live while recording/transcribing, but the first
            // post-transcription decision freezes it. Ignore later UI/programmatic
            // writes so the amber state can never claim a bypass the pipeline missed.
            guard resolvedSkipPostProcessing == nil else { return }
            skipPostProcessingValue = newValue
        }
    }

    var canChangeSkipPostProcessing: Bool {
        resolvedSkipPostProcessing == nil
    }

    func resolveSkipPostProcessingForPostProcessing() -> Bool {
        if let resolvedSkipPostProcessing {
            return resolvedSkipPostProcessing
        }
        let resolved = skipPostProcessingValue
        resolvedSkipPostProcessing = resolved
        return resolved
    }

    // The recorded audio file for this session. Set at record-start, consumed by the pipeline.
    var audioURL: URL?

    // Final transcript text once the pipeline completes (kept for potential future use /
    // debugging; delivery already pastes it).
    var transcript: String?

    // The target is captured before recording starts and belongs to this exact session so
    // another recording can safely begin while this one is still transcribing.
    @Published var recordingStartFocusedInput: FocusLockService.Target? // Published because a no-caret app/task fallback can be promoted asynchronously to its one exact capture-time composer, and the destination icon must then appear immediately.
    // Mode is captured from the same recording-start app identity as the input. The
    // capture-bound task currently preserves only app/default Mode because no exact
    // browser-tab identity exists; no caller may replace it by re-reading global Mode
    // after Ethan has switched apps or tabs.
    private(set) var recordingStartModeSnapshot: ModeConfig?
    var recordingStartModeResolutionTask: Task<ModeConfig?, Never>?
    // No-caret ChatGPT/Codex/Claude capture performs one bounded, capture-time-bound
    // promotion after the microphone starts. Keep that one task on the session so an
    // extremely short Next stop can await its existing result after releasing the mic;
    // it must never rediscover a later task/composer at stop or delivery time.
    var recordingStartPromotionTask: Task<FocusLockService.Target?, Never>?
    // Terminal/iTerm native identity begins from the same synchronous recording-start
    // decision but must not delay microphone startup. Next-while-recording transfers
    // this already-running task to the final paste decision; primary normal stop
    // cancels it because that route owns only its independent stop-time input.
    var recordingStartTerminalEnrichmentTask:
        Task<FocusLockService.Target, Never>?
    @Published var pasteTarget: RecordingPasteTarget // Published so the icon remains visible after stop and immediately follows a Next Track retarget while transcription is still loading.
    @Published private(set) var iconActionPulse: RecorderIconActionPulse?
    // Second chance belongs only to a primary-button normal stop and is consumed by
    // its first successful Next latch. A fresh/recordingStart session starts closed;
    // otherwise a Next-stopped result could be retargeted as though it were a normal
    // stop, or repeated Next presses could keep moving one pending transcript.
    private(set) var acceptsPasteRetargeting = false
    private var triggerWordModeOverride: ModeConfig?
    private var resolvedDeliveryDecision: RecordingDeliveryDecision?
    // Primary stop and second-chance Next capture the input synchronously, while their
    // capture-bound Mode/target refinements can finish asynchronously. Browser URL Mode
    // is deliberately excluded until tab identity is provable. Keep one token anyway:
    // if second chance replaces the target while an older refinement is suspended, the
    // older result can never overwrite it.
    private var pendingPasteTargetModeResolutionID: UUID?
    private var pendingPasteTargetModeResolutionTask: Task<ModeConfig?, Never>?
    private var pendingPasteTargetEnrichmentTask:
        Task<FocusLockService.Target, Never>?
    private var pendingPasteTargetEnrichmentCapture:
        FocusLockService.Target?
    // Refinements adopt themselves in detached MainActor watchers. Delivery never
    // awaits a cancellation-ignoring stale task: second chance replaces the token
    // immediately, and a late completion can only observe that it lost ownership.
    private var pendingPasteTargetModeAdoptionTask: Task<Void, Never>?
    private var pendingPasteTargetEnrichmentAdoptionTask: Task<Void, Never>?

    /// The saved destination normally owns post-processing. An explicit spoken
    /// trigger-word Mode remains the intentional higher-priority override; keeping it
    /// on the session avoids falling back to unrelated global focus state.
    var postProcessingMode: ModeConfig? {
        resolvedDeliveryDecision?.postProcessingMode
            ?? triggerWordModeOverride
            ?? pasteTarget.mode
    }

    // ── Per-session bits migrated OFF the old engine singletons ──
    // Previously these were single-flight members on VoiceInkEngine; now each session
    // carries its own so two sessions (one recording, one transcribing) never share state.

    // Streaming/file transcription session prepared at record-start, used by the pipeline.
    var transcriptionSession: TranscriptionSession?
    // Mode-resolved transcription engine settings captured at record-start (so the pipeline
    // uses the config that was active WHEN this recording started, not whatever is active now).
    var transcriptionConfiguration: TranscriptionRuntimeConfiguration?
    // App/window context snapshot store for AI enhancement context.
    var contextStore: RecordingContextSnapshotStore?
    // Background tasks capturing the above context; cancelled when the session ends.
    var contextTasks: [Task<Void, Never>] = []

    // Whether this capture is a brand-new dictation or an assistant follow-up turn. Mirrors
    // the engine's old RecordingUseCase; kept per-session because two sessions could in
    // principle have different use cases.
    enum UseCase: Equatable {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool { self == .assistantFollowUp }
    }
    var useCase: UseCase

    // The Transcription model id this session's pipeline runs against. Used as the cancel
    // "poison" key (canceledPipelineTranscriptionIDs) so cancelling THIS session can't
    // discard another session's finished 200.
    var pipelineTranscriptionID: UUID?

    // Identity token for the record-start handshake (the async start path checks this is
    // still the live start before transitioning to .recording — guards against a re-press
    // cancelling a not-yet-started session). Replaces the old engine activeRecordingStartID.
    var startID: UUID

    // Per-session cancel flag. Replaces the old GLOBAL engine `shouldCancelRecording`. The
    // pipeline's shouldCancel() gate reads this for ITS session only, so cancelling session
    // A never poisons session B.
    var shouldCancel: Bool = false

    // Stable creation timestamp for deterministic stack ordering (oldest at the bottom/base
    // in mini; newest nearest the pill in notch). The `sessions` array is also kept in
    // creation order, but createdAt makes the intent explicit + survives any reordering.
    let createdAt: Date

    init(
        phase: Phase = .recording,
        useCase: UseCase = .newSession,
        startID: UUID = UUID(),
        recordingStartFocusedInput: FocusLockService.Target? = nil
    ) {
        self.phase = phase
        // A session is born recording, so its live UI state starts at .recording too.
        self.liveRecordingState = (phase == .recording) ? .recording : .idle
        self.useCase = useCase
        self.startID = startID
        self.createdAt = Date()
        self.recordingStartFocusedInput = recordingStartFocusedInput
        let recordingStartMode = ModeRuntimeResolver.modeSnapshot(
            forPasteTargetBundleIdentifier:
                recordingStartFocusedInput?.bundleIdentifier,
            applicationBundleName:
                recordingStartFocusedInput?.applicationBundleName
        )
        self.recordingStartModeSnapshot = recordingStartMode
        self.pasteTarget = RecordingPasteTarget(
            destination: .recordingStart,
            focusedInput: recordingStartFocusedInput,
            mode: recordingStartMode
        )
    }

    // RecorderStateProvider conformance: the card reads `recordingState` for its spinner/
    // waveform. We expose the fine-grained liveRecordingState under that protocol name.
    var recordingState: RecordingState {
        liveRecordingState
    }

    var pasteDestinationIndicatorTarget: FocusLockService.Target? {
        switch phase {
        case .recording:
            recordingStartFocusedInput // Before stop, the icon previews the original input that a Next Track stop will select.
        case .transcribing, .delivering:
            pasteTarget.focusedInput // After stop, keep showing the real per-session target until it is delivered, failed, or retargeted.
        case .done:
            nil
        }
    }

    static func pasteDestinationOutlineIsVisible(
        phase: Phase,
        hasFrozenInput: Bool
    ) -> Bool {
        guard hasFrozenInput else { return false }
        switch phase {
        case .recording:
            return false
        case .transcribing, .delivering:
            return true
        case .done:
            return false
        }
    }

    /// The right icon is the only stable representation of the exact saved input.
    /// The left icon deliberately follows live focus and may change after a Primary
    /// stop, so its neon pulse is transient; leaving it outlined would falsely mark
    /// Ethan's later foreground app as the pending destination. A non-nil app-only
    /// recording-start fallback still has no frozen editor/window and remains
    /// unoutlined until capture-time promotion supplies `hasForegroundInput`.
    var pasteDestinationIsLocked: Bool {
        Self.pasteDestinationOutlineIsVisible(
            phase: phase,
            hasFrozenInput:
                pasteTarget.focusedInput?.hasForegroundInput == true
        )
    }

    var canAcceptSecondChancePasteRetarget: Bool {
        acceptsPasteRetargeting && pasteTarget.destination == .focusedAtStop
    }

    /// Own the stop route before any asynchronous microphone/promotion work. Only a
    /// primary normal stop opens the one-shot second-chance window; recordingStart is
    /// frozen immediately so a later Next press cannot reinterpret that completed route.
    func setStopPasteTarget(
        _ target: RecordingPasteTarget,
        finalModeResolutionTask: Task<ModeConfig?, Never>? = nil,
        finalTargetEnrichmentTask:
            Task<FocusLockService.Target, Never>? = nil
    ) {
        precondition(
            resolvedDeliveryDecision == nil,
            "A stop target cannot replace an already-issued delivery decision"
        )
        precondition(
            target.destination != .focusedDuringTranscription,
            "A transcription-time target must be selected through retargetPaste(to:)"
        )
        cancelPendingPasteTargetModeResolution()
        pasteTarget = target
        beginPendingPasteTargetRefinements(
            finalModeResolutionTask: finalModeResolutionTask,
            finalTargetEnrichmentTask: finalTargetEnrichmentTask,
            targetCapture: target.focusedInput
        )
        acceptsPasteRetargeting = target.destination == .focusedAtStop
    }

    func setRecordingStartModeSnapshot(_ mode: ModeConfig?) {
        recordingStartModeSnapshot = mode
        guard resolvedDeliveryDecision == nil,
              pasteTarget.destination == .recordingStart else {
            return
        }
        // Terminal/iTerm enrichment can finish while the capture-bound Mode lookup is
        // still suspended. Updating Mode must preserve whichever exact target the
        // session currently owns; rebuilding from `recordingStartFocusedInput` would
        // silently discard the completed native window/session identity.
        pasteTarget = RecordingPasteTarget(
            destination: .recordingStart,
            focusedInput: pasteTarget.focusedInput,
            mode: mode
        )
    }

    func retargetPaste(
        to target: RecordingPasteTarget,
        finalModeResolutionTask: Task<ModeConfig?, Never>? = nil,
        finalTargetEnrichmentTask:
            Task<FocusLockService.Target, Never>? = nil
    ) -> Bool {
        guard canAcceptSecondChancePasteRetarget,
              target.destination == .focusedDuringTranscription else {
            return false
        }
        // Consume the latch at the same decision boundary as the target replacement.
        // A failed capture never calls this method, so Ethan can still focus an input
        // and retry; after one successful latch, later Next presses must pass through.
        acceptsPasteRetargeting = false
        cancelPendingPasteTargetModeResolution()
        pasteTarget = target
        beginPendingPasteTargetRefinements(
            finalModeResolutionTask: finalModeResolutionTask,
            finalTargetEnrichmentTask: finalTargetEnrichmentTask,
            targetCapture: target.focusedInput
        )
        // This method is the successful second-chance latch boundary. Emit only
        // after the target was accepted; a failed/no-input Next press must keep
        // its warning behavior and never flash a misleading success pulse.
        if target.destination == .focusedDuringTranscription {
            signalDestinationAction(target.destination)
        }
        return true
    }

    func signalDestinationAction(_ destination: RecordingPasteDestination) {
        iconActionPulse = RecorderIconActionPulse(destination: destination)
    }

    func applyTriggerWordModeOverride(_ mode: ModeConfig) {
        precondition(
            resolvedDeliveryDecision == nil,
            "Trigger-word mode selection must finish before delivery resolves"
        )
        triggerWordModeOverride = mode
    }

    func resolveDeliveryDecision() -> RecordingDeliveryDecision {
        if let resolvedDeliveryDecision {
            return resolvedDeliveryDecision
        }
        // Production waits through resolveDeliveryDecisionAfterPendingModeResolution.
        // Keep this synchronous entry point deterministic for targets with no browser
        // refinement (and unit tests); if a caller bypasses the async boundary, freeze
        // the already captured app/default Mode rather than letting a late task mutate
        // an issued delivery decision.
        cancelPendingPasteTargetModeResolution()
        // This is the one post-transcription cutoff. Close second chance and snapshot
        // input plus Mode together before any destination-dependent formatting,
        // enhancement, output action, or Return decision is resolved.
        acceptsPasteRetargeting = false
        let decision = RecordingDeliveryDecision(
            pasteTarget: pasteTarget,
            postProcessingMode: triggerWordModeOverride ?? pasteTarget.mode
        )
        resolvedDeliveryDecision = decision
        return decision
    }

    /// Give already-completed capture-bound refinements a bounded scheduling chance,
    /// then freeze. Their watchers have been running throughout transcription; an
    /// unfinished Terminal lookup fails closed later instead of delaying delivery, and
    /// a cancellation-ignoring stale Mode task can never hang a second-chance target.
    func resolveDeliveryDecisionAfterPendingModeResolution() async
        -> RecordingDeliveryDecision {
        for _ in 0..<3 where pendingPasteTargetModeResolutionID != nil {
            await Task.yield()
        }
        return resolveDeliveryDecision()
    }

    private func beginPendingPasteTargetRefinements(
        finalModeResolutionTask: Task<ModeConfig?, Never>?,
        finalTargetEnrichmentTask: Task<FocusLockService.Target, Never>?,
        targetCapture: FocusLockService.Target?
    ) {
        guard finalModeResolutionTask != nil
                || finalTargetEnrichmentTask != nil else {
            return
        }
        let resolutionID = UUID()
        pendingPasteTargetModeResolutionID = resolutionID
        pendingPasteTargetModeResolutionTask = finalModeResolutionTask
        pendingPasteTargetEnrichmentTask = finalTargetEnrichmentTask
        pendingPasteTargetEnrichmentCapture = finalTargetEnrichmentTask == nil
            ? nil
            : targetCapture

        if let finalModeResolutionTask {
            pendingPasteTargetModeAdoptionTask = Task { @MainActor [weak self] in
                let resolvedMode = await finalModeResolutionTask.value
                guard let self,
                      self.pendingPasteTargetModeResolutionID == resolutionID,
                      self.resolvedDeliveryDecision == nil else { return }
                self.pasteTarget = RecordingPasteTarget(
                    destination: self.pasteTarget.destination,
                    focusedInput: self.pasteTarget.focusedInput,
                    mode: resolvedMode
                )
                self.pendingPasteTargetModeResolutionTask = nil
                self.pendingPasteTargetModeAdoptionTask = nil
                self.clearPendingPasteTargetTokenIfFinished(
                    resolutionID: resolutionID
                )
            }
        }

        if let finalTargetEnrichmentTask, let targetCapture {
            pendingPasteTargetEnrichmentAdoptionTask = Task { @MainActor [weak self] in
                let enrichedTarget = await finalTargetEnrichmentTask.value
                guard let self,
                      self.pendingPasteTargetModeResolutionID == resolutionID,
                      self.resolvedDeliveryDecision == nil,
                      self.pasteTarget.focusedInput.map({
                          FocusLockService.shared.representsSameCaptureDecision(
                              $0,
                              targetCapture
                          )
                      }) == true,
                      FocusLockService.shared.representsSameCaptureDecision(
                          enrichedTarget,
                          targetCapture
                      ) else { return }
                self.pasteTarget = RecordingPasteTarget(
                    destination: self.pasteTarget.destination,
                    focusedInput: enrichedTarget,
                    mode: self.pasteTarget.mode
                )
                self.pendingPasteTargetEnrichmentTask = nil
                self.pendingPasteTargetEnrichmentCapture = nil
                self.pendingPasteTargetEnrichmentAdoptionTask = nil
                self.clearPendingPasteTargetTokenIfFinished(
                    resolutionID: resolutionID
                )
            }
        }
    }

    private func clearPendingPasteTargetTokenIfFinished(
        resolutionID: UUID
    ) {
        guard pendingPasteTargetModeResolutionID == resolutionID,
              pendingPasteTargetModeResolutionTask == nil,
              pendingPasteTargetEnrichmentTask == nil else {
            return
        }
        pendingPasteTargetModeResolutionID = nil
    }

    private func cancelPendingPasteTargetModeResolution() {
        pendingPasteTargetModeResolutionTask?.cancel()
        pendingPasteTargetEnrichmentTask?.cancel()
        pendingPasteTargetModeAdoptionTask?.cancel()
        pendingPasteTargetEnrichmentAdoptionTask?.cancel()
        pendingPasteTargetModeResolutionTask = nil
        pendingPasteTargetEnrichmentTask = nil
        pendingPasteTargetEnrichmentCapture = nil
        pendingPasteTargetModeAdoptionTask = nil
        pendingPasteTargetEnrichmentAdoptionTask = nil
        pendingPasteTargetModeResolutionID = nil
    }

    func cancelRecordingStartTerminalEnrichment() {
        recordingStartTerminalEnrichmentTask?.cancel()
        recordingStartTerminalEnrichmentTask = nil
    }

    func cancelRecordingStartPromotion() {
        recordingStartPromotionTask?.cancel()
        recordingStartPromotionTask = nil
    }

    func cancelRecordingStartModeResolution() {
        recordingStartModeResolutionTask?.cancel()
        recordingStartModeResolutionTask = nil
    }

    // Cancel + tear down only background context capture. Recording-start composer and
    // Mode resolution have independent lifetimes; microphone startup intentionally
    // resets context once and must not cancel those session-bound decisions.
    func clearContext() {
        contextTasks.forEach { $0.cancel() }
        contextTasks.removeAll()
        contextStore = nil
    }

    // Terminal session cleanup. Safe to call repeatedly after success, cancellation,
    // or startup failure; unlike clearContext(), this owns every outstanding task.
    func clearSessionResources() {
        cancelRecordingStartPromotion()
        cancelRecordingStartTerminalEnrichment()
        cancelRecordingStartModeResolution()
        cancelPendingPasteTargetModeResolution()
        clearContext()
    }
}
