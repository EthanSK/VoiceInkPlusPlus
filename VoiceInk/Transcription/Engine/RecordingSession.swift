import Foundation
import SwiftUI
import os

enum RecordingPasteDestination: Equatable {
    case recordingStart
    case primaryCurrentInput
    case focusedDuringTranscription

    /// Primary is intentionally base VoiceInk: it follows the system keyboard focus
    /// at delivery and never owns an exact input or app-specific delivery mechanism.
    var usesBaseCurrentInputDelivery: Bool {
        self == .primaryCurrentInput
    }

    /// Exact, app-specific resolution belongs only to a physical Next-button latch.
    /// Keeping this policy on the enum makes it impossible for a Primary target to
    /// enter Telegram/OpenAI/Terminal delivery merely because a caller supplied one.
    var usesAppSpecificExactDelivery: Bool {
        switch self {
        case .recordingStart, .focusedDuringTranscription:
            true
        case .primaryCurrentInput:
            false
        }
    }
}

/// One recording's post-transcription side-effect policy.
///
/// This is deliberately independent from `RecordingPasteDestination`: Primary and
/// the two Next routes still own where a normal delivery goes. A genuine Primary
/// triple-click chooses no paste destination at all. It completes the same audio and
/// transcription pipeline, then leaves the usable result on the clipboard without
/// issuing Command-V, Return, a custom command, or a recorder response.
enum RecordingCompletionDisposition: Equatable {
    case normalDelivery
    case clipboardOnly
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
        case .primaryCurrentInput:
            icon = .currentFocus
        case .recordingStart, .focusedDuringTranscription:
            icon = .lockedDestination
        }
    }
}

struct RecordingPasteTarget {
    let destination: RecordingPasteDestination
    let focusedInput: FocusLockService.Target?
    // An exact destination and its complete Mode are one atomic per-session choice,
    // but only for the two Next-button routes. Primary deliberately owns neither:
    // it follows the current system input and current Mode like base VoiceInk.
    // In particular, the transcription-time Next route is a second chance:
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
        // Structural regression guard: even if a future caller accidentally passes a
        // Telegram/OpenAI wrapper or Mode for Primary, discard both here. App-specific
        // state is valid only after the physical Next button selected an exact route.
        self.focusedInput = destination.usesAppSpecificExactDelivery
            ? focusedInput
            : nil
        self.mode = destination.usesAppSpecificExactDelivery ? mode : nil
    }

    func resolvedAutoSendKey(currentInputKey: AutoSendKey) -> AutoSendKey {
        destination.usesBaseCurrentInputDelivery ? currentInputKey : autoSendKey
    }
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
//   • .recording    — owns the open capture session. THE mic owner. Its fine-grained
//                     live state is normally `.recording`, or `.paused` while AUHAL
//                     is temporarily stopped but the same WAV/stream remains open.
//                     At most ONE session is ever in this phase.
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

    // Live streaming partial (only meaningful while phase == .recording — only this
    // session streams partials). While liveRecordingState == .paused, the last partial
    // stays frozen in the HUD and no new audio reaches the provider.
    @Published var partialTranscript: String = ""

    // Make the realtime HUD visible as soon as the frozen Mode selects a streaming
    // provider. A network/Wi-Fi handshake may delay the first Soniox partial, but the
    // recorder must still communicate that live transcription is active. The empty
    // state renders only an ellipsis; it is never treated as transcript content.
    @Published var showsRealtimeTranscriptHUD = false

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
    @Published var skipPostProcessing: Bool = false

    // A genuine Primary triple-click sets this one-shot value before the session
    // leaves `.recording`. It must travel with this exact session because another
    // recording may already exist while this one finishes in the FIFO pipeline.
    // Unlike the separate raw/skip toggle, clipboard-only completion still applies
    // the session's normal formatting/enhancement; it changes only the final side
    // effect so no destination app is touched.
    var completionDisposition: RecordingCompletionDisposition = .normalDelivery

    // Realtime partials normally exist only in the recorder HUD and are cleared when
    // capture stops. Keep one private per-session snapshot so an explicit cancel while
    // the provider is finalizing can retain words already shown to the user instead of
    // replacing them with the generic canceled marker. This value is never delivered
    // normally and never crosses into another recording's lineage.
    var recoverablePartialTranscript: String = ""

    // The recorded audio file for this session. Set at record-start, consumed by the pipeline.
    var audioURL: URL?

    // Final transcript text once the pipeline completes (kept for potential future use /
    // debugging; delivery already pastes it).
    var transcript: String?

    // The target is captured before recording starts and belongs to this exact session so
    // another recording can safely begin while this one is still transcribing.
    @Published var recordingStartFocusedInput: FocusLockService.Target? // Published because an initially invalid shortcut-time capture can be replaced once microphone recording begins, and the destination icon must then appear immediately.
    @Published var pasteTarget: RecordingPasteTarget // Published so the icon remains visible after stop and immediately follows a Next Track retarget while transcription is still loading.
    @Published private(set) var iconActionPulse: RecorderIconActionPulse?
    private(set) var acceptsPasteRetargeting = true
    private var pasteTargetEnrichment: (
        captured: FocusLockService.Target,
        task: Task<FocusLockService.Target, Never>
    )?
    private var triggerWordModeOverride: ModeConfig?

    /// Next-button destinations own post-processing atomically. Primary is deliberately
    /// different: like base VoiceInk, it follows whichever Mode is current while the
    /// result is processed and delivered. An explicit trigger-word Mode remains the
    /// intentional higher-priority override for either policy.
    var postProcessingMode: ModeConfig? {
        if let triggerWordModeOverride {
            return triggerWordModeOverride
        }
        if pasteTarget.destination.usesBaseCurrentInputDelivery {
            return ModeManager.shared.currentEffectiveConfiguration
        }
        return pasteTarget.mode
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
        self.pasteTarget = RecordingPasteTarget(
            destination: .recordingStart,
            focusedInput: recordingStartFocusedInput,
            mode: ModeRuntimeResolver.modeSnapshot(
                forPasteTargetBundleIdentifier: recordingStartFocusedInput?.bundleIdentifier
            )
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

    func retargetPaste(to target: RecordingPasteTarget) -> Bool {
        guard acceptsPasteRetargeting else { return false }
        // A recording-start Terminal lookup belongs only to that older decision.
        // Cancel and detach it before second chance replaces the target so its late
        // window/TTY result can never overwrite the newly focused input.
        discardPasteTargetEnrichment()
        pasteTarget = target
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
        triggerWordModeOverride = mode
    }

    func beginPasteTargetEnrichment(
        captured: FocusLockService.Target,
        task: Task<FocusLockService.Target, Never>
    ) {
        guard acceptsPasteRetargeting,
              pasteTarget.focusedInput.map({
                  FocusLockService.shared.representsSameCaptureDecision(
                      $0,
                      captured
                  )
              }) == true else {
            task.cancel()
            return
        }
        pasteTargetEnrichment = (captured, task)

        // Update the recording preview as soon as the bounded lookup settles. Delivery
        // also awaits this same task, closing the very-fast Next-stop race without
        // delaying microphone startup or starting a second identity lookup.
        Task { @MainActor [weak self] in
            let completed = await task.value
            self?.applyPasteTargetEnrichment(
                captured: captured,
                completed: completed
            )
        }
    }

    private func applyPasteTargetEnrichment(
        captured: FocusLockService.Target,
        completed: FocusLockService.Target
    ) {
        guard acceptsPasteRetargeting,
              pasteTarget.focusedInput.map({
                  FocusLockService.shared.representsSameCaptureDecision(
                      $0,
                      captured
                  )
              }) == true else {
            return
        }
        if phase == .recording,
           pasteTarget.destination == .recordingStart {
            recordingStartFocusedInput = completed
        }
        pasteTarget = RecordingPasteTarget(
            destination: pasteTarget.destination,
            focusedInput: completed,
            mode: pasteTarget.mode
        )
        if pasteTargetEnrichment.map({
            FocusLockService.shared.representsSameCaptureDecision(
                $0.captured,
                captured
            )
        }) == true {
            pasteTargetEnrichment = nil
        }
    }

    func discardPasteTargetEnrichment() {
        pasteTargetEnrichment?.task.cancel()
        pasteTargetEnrichment = nil
    }

    func resolvePasteTargetForDelivery() async -> RecordingPasteTarget {
        // The task began at the physical input decision and is hard-bounded by the
        // AppleScript runner. Await only that existing task before freezing delivery;
        // never recapture whichever Terminal tab or app is focused now.
        while let pending = pasteTargetEnrichment {
            let completed = await pending.task.value
            applyPasteTargetEnrichment(
                captured: pending.captured,
                completed: completed
            )
            if pasteTargetEnrichment.map({
                FocusLockService.shared.representsSameCaptureDecision(
                    $0.captured,
                    pending.captured
                )
            }) == true {
                pasteTargetEnrichment = nil
            }
        }
        acceptsPasteRetargeting = false // Delivery resolves exactly once; a later media-key press must pass through rather than falsely claiming it changed an already-issued paste.
        return pasteTarget
    }

    // Cancel + tear down this session's background context capture. Safe to call multiple times.
    func clearContext() {
        discardPasteTargetEnrichment()
        contextTasks.forEach { $0.cancel() }
        contextTasks.removeAll()
        contextStore = nil
    }
}
