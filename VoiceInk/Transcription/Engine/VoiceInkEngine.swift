import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

/// Runtime payload for one registry-approved queue identity. Audio, transcription
/// configuration, streaming session, and SwiftData record are captured once when the
/// mic has stopped. The mutable RecordingSession remains only for the deliberately
/// late-bound destination/Mode retarget and per-session UI/cancellation state.
private struct QueuedTranscriptionJob {
    let identity: TranscriptionJobIdentity
    let recordingSession: RecordingSession
    let transcription: Transcription
    let audioURL: URL
    let transcriptionConfiguration: TranscriptionRuntimeConfiguration
    let transcriptionSession: TranscriptionSession?
}

// ═══════════════════════════════════════════════════════════════════════════════
// VoiceInkEngine — MULTI-SESSION refactor (record-while-transcribing, 2026-06-28)
// ═══════════════════════════════════════════════════════════════════════════════
//
// WHAT CHANGED vs the old single-flight engine:
//   OLD: one `currentSession`/`recordedFile`/`shouldCancelRecording`/`partialTranscript`
//        set, and STOP awaited `runPipeline` INLINE before the mic could be reused.
//   NEW: a COLLECTION of RecordingSession objects (`sessions`). At most one is
//        `.recording` (owns the mic); the rest are transcribing/delivering in the
//        background. STOP no longer awaits the pipeline — it ENQUEUES the pipeline on
//        a SERIAL FIFO queue and returns immediately, freeing the mic for a new record.
//
// See RecordingSession.swift for the per-session state machine + the one-active invariant.
//
// ── CONCURRENCY: SERIAL FIFO transcription queue (NOT concurrent) ──────────────
// Transcription jobs run one-at-a-time on a chained-Task serial queue. This is a
// DELIBERATE correctness decision, not a perf compromise:
//   • WhisperTranscriptionService reuses a single mutable `whisperContext`, and
//     `whisperModelManager.whisperContext` is a SHARED singleton actor. setLanguage /
//     setPrompt then fullTranscribe are sequential stateful mutations on ONE shared
//     context — running two whisper jobs concurrently would interleave language/prompt
//     state and corrupt output.
//   • `whisperModelManager.cleanupResources()` / `serviceRegistry.cleanup()` release the
//     SHARED model — concurrent jobs would tear each other's model down mid-transcribe.
//   • FluidAudio also loads a single shared model.
//   • The cloud/Deepgram path COULD be concurrency-safe, but the provider is chosen
//     per-job and we can't assume it, so a single serial queue is the only universally
//     safe choice.
//   • The UX goal is STILL met: the new RECORDING starts immediately (mic frees the
//     instant the prior session stops); only the transcription WORK queues behind
//     earlier jobs. Serial = simplest race-free correctness.
//
// ── DELIVERY ORDERING: FIFO for free ───────────────────────────────────────────
// We deliver/paste results in RECORDING (FIFO) order so pasted text stays in the order
// the user spoke. Because transcription itself is serial FIFO, completion order already
// EQUALS recording order — so the serial transcription queue gives FIFO delivery for
// free with NO separate delivery reorder buffer required.
// NOTE: RecorderStateProvider conformance is declared in VoiceInkEngine+Protocols.swift
// (extension VoiceInkEngine: RecorderStateProvider {}). We intentionally do NOT repeat it
// here — the engine already exposes `recordingState` + `partialTranscript` (the protocol
// requirements) as @Published members below, so the extension's conformance is satisfied.
@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    enum PendingPasteRetargetResult {
        case noPendingTranscription
        case noFocusedInput
        case retargeted
    }


    // ── Session collection (drives the UI stack) ──
    // Ordered oldest→newest (creation order). The base/active recording card renders from
    // the .recording session; transcribing cards stack above it. @Published so the stack
    // container redraws on add/remove.
    @Published var sessions: [RecordingSession] = []

    // ── DERIVED compat state ──
    // Existing single-card UI (the active MiniRecorderView/NotchRecorderView via the
    // window managers) + RecorderUIManager + the shortcut gate all read `recordingState`
    // and `partialTranscript` off the engine. We KEEP those as DERIVED values so nothing
    // downstream has to change to keep compiling.
    //
    // IMPORTANT DESIGN CHOICE (shortcut-gate safety): `recordingState` reflects ONLY the
    // ACTIVE recording session's state, else `.idle` — it does NOT report `.transcribing`
    // when there is no active recording. Rationale: RecordingShortcutManager.canHandleShort
    // cutAction() BLOCKS a record toggle whenever recordingState is .transcribing/.enhancing/
    // .busy. If the derived state reported `.transcribing` while a background job ran, the
    // user could NOT start a new recording — which would defeat this entire feature. The
    // stacked-card UI shows the "transcribing…" cards directly off each session.phase, so
    // the derived engine state never needs to surface .transcribing for the stack to render.
    // (Per-card status spinners read the session's own liveRecordingState, not this.)
    @Published var recordingState: RecordingState = .idle

    // Live partial of the ACTIVE recording session (only the recording session streams partials).
    // REALTIME CONTRACT: this is recorder-HUD presentation state, never a provisional draft in
    // another app. Destination mutation happens exactly once with the provider's final text through
    // TranscriptionPipeline after stop; do not add paste, range ownership, or draft cleanup here.
    @Published var partialTranscript: String = ""

    var pasteDestinationIndicatorTarget: FocusLockService.Target? {
        activeRecordingSession?.pasteDestinationIndicatorTarget
    }

    // RecorderStateProvider fallback used only by the assistant-only card. Real
    // recording UI observes RecordingSession, which owns the per-action pulse.
    var iconActionPulse: RecorderIconActionPulse? { nil }

    // VIPP (skip-mode-processing feature): RecorderStateProvider now requires a settable
    // `skipPostProcessing`. The REAL per-session flag lives on each RecordingSession (that's
    // what the live recorder card binds to). The engine only conforms to RecorderStateProvider
    // for the "assistant-only fallback card" (rendered after the producing session is gone),
    // where a per-recording bypass is meaningless. So this is an inert stub: it satisfies the
    // protocol but is never consumed by the pipeline (the pipeline reads session.skipPostProcessing
    // directly). Kept settable + harmless so the generic view's toggle compiles on the fallback
    // card without affecting any real recording.
    var skipPostProcessing: Bool = false

    // ── Pipeline cancel-poisoning ──
    // Set of Transcription ids whose pipeline result must be DISCARDED (per-session cancel).
    // Keyed by RecordingSession.pipelineTranscriptionID so cancelling one session can never
    // discard another's finished 200. (The old global shouldCancelRecording flag is gone;
    // cancel is now per-session via RecordingSession.shouldCancel + this set.)
    private var canceledPipelineTranscriptionIDs = Set<UUID>()

    // ── Serial transcription queue + immutable lineage registry ──
    // Each enqueue appends to a MainActor Task chain: the new job awaits the previous
    // tail before running. The registry binds one session id, SwiftData transcription id,
    // exact audio URL, and monotonic sequence before that wait begins. This guarantees:
    //   (a) FIFO order — jobs run in the order they were enqueued (= recording order), and
    //   (b) full serialization — each pipeline fully finishes (transcribe→enhance→deliver)
    //       before the next begins, so they never share the whisper/fluidaudio model.
    // Waiting tasks revalidate membership after `previous.value`: cancellation of a
    // Task<Void, Never> wait does not throw. A reset invalidates the generation and
    // cancels every retained task, not only the newest tail.
    private let transcriptionJobQueue = SerialTranscriptionJobQueue()
    private var transcriptionJobRegistry = TranscriptionJobRegistry()
    private var primaryQueuedAutoSendTracker = PrimaryQueuedAutoSendTracker()
    private let activeRecordingDeliveryBarrier = ActiveRecordingDeliveryBarrier()

    // Whisper/FluidAudio managers are shared even though jobs are per-session. A
    // cleanup task is therefore a resource barrier: a new recording waits for it,
    // and one session may never clean or preload through another live session.
    private var resourceCleanupTask: Task<Void, Never>?
    private var isResettingRecordingSession = false

    // Reservation across requestRecordPermission → startNewSession scheduling. Without
    // this synchronous token, two rapid Primary start events can both observe no active
    // session before either scheduled MainActor task appends one, creating two mic owners.
    private var recordingStartReservation = RecordingStartReservation()

    /// Recorder-panel visibility must include the synchronous start lifecycle, not
    /// only materialized session cards. An older pipeline may finish while this token
    /// is waiting on permission, cleanup, or a delivery lease.
    var hasPendingRecordingStart: Bool {
        recordingStartReservation.pendingID != nil
    }

    /// Includes both a start reservation and a materialized recording session. This
    /// closes the tiny consumed-reservation-to-session-card boundary for UI decisions.
    var hasActiveCaptureOwner: Bool {
        activeRecordingDeliveryBarrier.isDeliveryBlocked
    }

    let recorder = Recorder()
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline
    private let recoveryJournalStore: RecordingRecoveryJournalStore

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")
    // VIPPDebug: see RecorderUIManager for the filter predicate. Tracks the stop→
    // transcribe state transition and every cancellation request so we can attribute
    // who/when poisons an in-flight pipeline.
    let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil,
        recoveryJournalStore: RecordingRecoveryJournalStore = RecordingRecoveryJournalStore()
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        self.recoveryJournalStore = recoveryJournalStore
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        // Standalone-fork identity: Recordings live under the new bundle id's App Support folder.
        // Must stay in sync with the same path string in VoiceInk.swift + the other Recordings sites.
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ethansk.VoiceInkPlusPlus")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    /// Keep the last safely shown HUD text with the audio lineage, never with an
    /// external destination. A later crash can therefore restore local History without
    /// guessing at focus or delivering into an app the user may no longer be using.
    private func persistRecoveryJournal(
        for session: RecordingSession,
        realtimeDraftText: String?
    ) {
        guard var entry = session.recoveryJournalEntry else { return }
        entry.update(
            realtimeDraftText: realtimeDraftText,
            inputDevice: session.recordingInputDevice
        )
        do {
            try recoveryJournalStore.persist(entry)
            session.recoveryJournalEntry = entry
        } catch {
            // Preserve the previous complete atomic snapshot. It remains enough to
            // recover the WAV; this best-effort update must not interrupt capture.
            logger.error("Could not update active recording recovery journal id=\(entry.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// A journal is only disposable once the History row referencing the same WAV has
    /// been saved. If removal itself fails, launch recovery recognizes the existing URL
    /// and clears the stale marker without creating a second History entry.
    private func clearRecoveryJournal(for session: RecordingSession) {
        guard let entry = session.recoveryJournalEntry else { return }
        do {
            try recoveryJournalStore.remove(entry)
            session.recoveryJournalEntry = nil
        } catch {
            logger.error("Could not remove recording recovery journal id=\(entry.id.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// Startup failures normally own no useful audio, but never assume a failed delete
    /// made that true. If the file survives, retaining its journal lets the next launch
    /// repair and surface every frame that did reach disk instead of losing it silently.
    private func discardUnusableRecordingAndJournal(for session: RecordingSession) {
        guard let audioURL = session.audioURL else {
            clearRecoveryJournal(for: session)
            return
        }
        do {
            try FileManager.default.removeItem(at: audioURL)
            session.audioURL = nil
            clearRecoveryJournal(for: session)
        } catch {
            logger.error("Could not remove failed-start audio; retaining crash recovery journal id=\(session.recoveryJournalEntry?.id.uuidString ?? "unknown", privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Session Accessors

    /// The one session currently capturing audio (mic owner), if any. By the one-active
    /// invariant there is at most one. nil ⇒ no recording in progress (idle OR only
    /// background transcriptions running).
    var activeRecordingSession: RecordingSession? {
        sessions.first { $0.phase == .recording }
    }

    /// The most-recent in-flight transcribing/delivering session (the "top card"). Used as
    /// the cancel target when no session is actively recording.
    private var topInFlightSession: RecordingSession? {
        sessions.last { $0.phase == .transcribing || $0.phase == .delivering }
    }

    func retargetMostRecentPendingTranscriptionToFocusedInput() -> PendingPasteRetargetResult {
        guard let session = sessions.last(where: {
            ($0.phase == .transcribing || $0.phase == .delivering) && $0.acceptsPasteRetargeting
        }) else {
            vippLog.info("paste retarget: no pending transcription still accepts destination changes")
            return .noPendingTranscription
        }

        guard let focusedInput = FocusLockService.shared.captureFocusedInput() else {
            FocusLockService.shared.showPendingPasteInputUnavailable()
            vippLog.info("paste retarget: pending session \(session.id.uuidString, privacy: .public) kept existing destination because no editable input is focused")
            return .noFocusedInput
        }

        let didRetarget = session.retargetPaste(
            to: RecordingPasteTarget(
                destination: .focusedDuringTranscription,
                focusedInput: focusedInput,
                mode: ModeRuntimeResolver.modeSnapshot(
                    forPasteTargetBundleIdentifier: focusedInput.bundleIdentifier
                )
            )
        )
        guard didRetarget else {
            vippLog.info("paste retarget: pending session \(session.id.uuidString, privacy: .public) reached delivery before its destination could change")
            return .noPendingTranscription
        }

        // Success is communicated by the published per-session destination icon
        // switching in place. Keep text reserved for failures; a toast here made the
        // compact recorder noisy and duplicated the much clearer icon transition.
        vippLog.info("paste retarget: pending session \(session.id.uuidString, privacy: .public) destination=focusedDuringTranscription targetCaptured=true")
        beginTerminalPasteTargetEnrichment(
            for: session,
            captured: focusedInput
        )
        return .retargeted
    }

    private func beginTerminalPasteTargetEnrichment(
        for session: RecordingSession,
        captured: FocusLockService.Target
    ) {
        guard FocusLockService.shared.requiresNativeTerminalSessionBinding(
            for: captured
        ) else {
            return
        }
        let task = Task { @MainActor in
            await FocusLockService.shared
                .completingTerminalAutomationTarget(for: captured)
        }
        // This enriches the already accepted exact Next decision; it never recaptures
        // whichever app or Terminal tab happens to be focused when the task finishes.
        session.beginPasteTargetEnrichment(
            captured: captured,
            task: task
        )
    }

    /// Recompute the DERIVED compat `recordingState` + `partialTranscript` from the active
    /// recording session. See the big comment on `recordingState` for why we deliberately
    /// fall back to `.idle` (NOT a transcribing session's state) when nothing is recording.
    private func recomputeDerivedState() {
        if let active = activeRecordingSession {
            recordingState = active.liveRecordingState
            partialTranscript = active.partialTranscript
        } else {
            // No active recording. Background jobs may still be transcribing, but we report
            // .idle so the record shortcut stays usable (can start a new dictation).
            recordingState = .idle
            partialTranscript = ""
        }
    }

    /// Remove a finished/aborted session from the collection + recompute derived state.
    /// SwiftUI animates the card out (transition on the `sessions` array).
    private func removeSession(_ session: RecordingSession) {
        session.phase = .done
        session.clearContext()
        sessions.removeAll { $0.id == session.id }
        recomputeDerivedState()
    }

    /// Toggles capture for the existing mic-owning session without finalizing its
    /// audio or changing its paste destination. Pause/resume is deliberately not a
    /// fourth delivery route: only the later single Primary stop or Next stop chooses
    /// how this same session is delivered.
    @discardableResult
    func toggleRecordingPause() async -> Bool {
        guard let session = activeRecordingSession else {
            vippLog.info("recording pause toggle ignored because no active session owns the mic")
            return false
        }

        let previousState = session.liveRecordingState
        do {
            switch previousState {
            case .recording:
                try await recorder.pauseRecording()
                guard activeRecordingSession === session,
                      session.phase == .recording,
                      session.liveRecordingState == previousState,
                      !session.shouldCancel else {
                    return false
                }
                session.liveRecordingState = .paused
                vippLog.info("recording pause toggle: session \(session.id.uuidString, privacy: .public) capture=paused playback=unchanged")

            case .paused:
                try await recorder.resumeRecording()
                guard activeRecordingSession === session,
                      session.phase == .recording,
                      session.liveRecordingState == previousState,
                      !session.shouldCancel else {
                    return false
                }
                session.liveRecordingState = .recording
                vippLog.info("recording pause toggle: session \(session.id.uuidString, privacy: .public) capture=resumed playback=unchanged")

            default:
                vippLog.info("recording pause toggle ignored for liveState=\(String(describing: previousState), privacy: .public)")
                return false
            }
            recomputeDerivedState()
            return true
        } catch {
            logger.error("Recording pause toggle failed state=\(String(describing: previousState), privacy: .public) error=\(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: previousState == .paused
                    ? String(localized: "Recording could not resume")
                    : String(localized: "Recording could not pause"),
                type: .error
            )
            return false
        }
    }

    /// Finalizes the active recording as a one-shot clipboard result. This is the
    /// genuine Primary triple-click route: it is neither cancel/discard nor any of
    /// the three paste destinations. The session still transcribes normally, while
    /// the pipeline's completion disposition guarantees no paste or auto-send.
    @discardableResult
    func finishActiveRecordingToClipboard(modeId: UUID? = nil) async -> Bool {
        guard let active = activeRecordingSession,
              active.liveRecordingState.isRecordingOrPaused,
              !active.shouldCancel else {
            vippLog.info("clipboard-only finish ignored because no active recording owns the mic")
            return false
        }

        await toggleRecord(
            modeId: modeId,
            stopPasteDestination: .primaryCurrentInput,
            completionDisposition: .clipboardOnly,
            stopPlaybackDisposition: .preserveCurrentPlayback
        )
        return true
    }

    // MARK: - Toggle Record

    // The single entry point for the record shortcut / record button. Behaviour:
    //   • A session is actively RECORDING → STOP it (move to .transcribing + enqueue its
    //     pipeline on the serial queue, NON-blocking). Mic frees immediately.
    //   • The active session is mid-START handshake (.starting) → cancel that not-yet-
    //     started session (re-press during the brief start window).
    //   • Otherwise (idle OR only background transcriptions running) → START a fresh
    //     active session.
    func toggleRecord(
        modeId: UUID? = nil,
        isAssistantFollowUp: Bool = false,
        stopPasteDestination: RecordingPasteDestination = .primaryCurrentInput,
        completionDisposition: RecordingCompletionDisposition = .normalDelivery,
        stopPlaybackDisposition: RecordingStopPlaybackDisposition = .restoreOwnedPlayback
    ) async {
        // Mid-start re-press: the active session is still starting → cancel it.
        if let active = activeRecordingSession, active.liveRecordingState == .starting {
            await cancelSession(active)
            return
        }

        if let active = activeRecordingSession {
            // A completed older normal Primary job may paste while this capture is live,
            // but its Return is suppressed so the two recordings remain one FIFO cohort.
            // Every other side effect remains blocked. Release capture ownership only
            // after this stop path freezes/enqueues the active session's immutable job
            // (or safely cancels), so a tail Return can never overtake this recording.
            defer {
                activeRecordingDeliveryBarrier.endCapture(owner: active.id)
                reportUnresolvedPrimaryAutoSendIfQueueDrained()
            }

            // ── STOP branch ──────────────────────────────────────────────────────────
            // The mic owner stops. We flip its phase .recording→.transcribing, release the
            // mic (recorder.stopRecording), build its Transcription record, and ENQUEUE the
            // pipeline on the serial queue. CRITICAL: we do NOT await the pipeline here —
            // that inline await is exactly what blocked the next start in the old engine.
            // The function returns as soon as the mic is free, so a record press right after
            // can immediately START a new session.
            active.completionDisposition = completionDisposition
            switch stopPasteDestination {
            case .recordingStart:
                let focusedInput = active.recordingStartFocusedInput
                active.pasteTarget = RecordingPasteTarget(
                    destination: .recordingStart,
                    focusedInput: focusedInput,
                    // Native Terminal identity enrichment updates this same atomic
                    // target while recording; keep its already frozen Mode.
                    mode: active.pasteTarget.mode
                )
            case .primaryCurrentInput:
                // PRIMARY IS BASE VOICEINK. Do not capture a Telegram/OpenAI/Terminal
                // wrapper here and do not snapshot an app-specific Mode. The eventual
                // system Cmd-V and generic Return follow whichever keyboard input and
                // Mode are current at delivery. Only a later physical Next press may
                // replace this with an exact focusedDuringTranscription target.
                active.discardPasteTargetEnrichment()
                active.pasteTarget = RecordingPasteTarget(
                    destination: .primaryCurrentInput,
                    focusedInput: nil
                )
            case .focusedDuringTranscription:
                preconditionFailure("A transcription-time target can only be selected after recording has stopped")
            }

            // Publish the feedback token only after the selected route has owned
            // its per-session target. All mirrored recorder windows observe this
            // same session and therefore pulse in sync without re-reading focus.
            if completionDisposition == .normalDelivery {
                active.signalDestinationAction(stopPasteDestination)
            }

            vippLog.info("toggleRecord: STOP session \(active.id.uuidString, privacy: .public) → .transcribing destination=\(String(describing: stopPasteDestination), privacy: .public) targetCaptured=\(active.pasteTarget.focusedInput != nil, privacy: .public) deliveryPolicy=\(stopPasteDestination.usesBaseCurrentInputDelivery ? "baseCurrentInput" : "exactNextLatch", privacy: .public) shouldCancel=\(active.shouldCancel, privacy: .public)")

            active.phase = .transcribing
            active.liveRecordingState = .transcribing
            // Realtime remains HUD-only while capture is live. At the irreversible
            // stop boundary, however, persist the last HUD text beside the original
            // WAV before starting asynchronous finalization. This is local recovery
            // state only: it never creates or mutates a destination-app draft. A
            // genuine Primary triple-click therefore leaves a reopenable draft even
            // if the provider or app exits before the final clipboard result arrives.
            active.recoverablePartialTranscript = active.partialTranscript
            active.partialTranscript = ""
            active.startID = UUID() // invalidate the start handshake token (it has fully started)
            recomputeDerivedState()

            await recorder.stopRecording(
                playbackDisposition: stopPlaybackDisposition
            )
            // ── MEDIA RESUME-BETWEEN-SESSIONS NUANCE ──
            // recorder.stopRecording() schedules resumeMedia()/unmuteSystemAudio(). If the
            // user immediately starts session B, recorder.startRecording() will pauseMedia()/
            // muteSystemAudio() again. So media may briefly resume in the gap between stop and
            // the next start — that's acceptable and self-consistent: the single Recorder is
            // only ever owned by the single active recording session, so its pause/resume
            // bracketing always pairs with exactly one recording at a time.

            if let audioURL = active.audioURL {
                if !active.shouldCancel {
                    // Build and save the recoverable record before enqueueing the
                    // asynchronous pipeline. `.recoverableDraft` distinguishes a
                    // durable audio/HUD snapshot from an empty legacy pending row;
                    // normal completion will replace it with `.completed`.
                    let hasRealtimeDraft = !active.recoverablePartialTranscript
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    let transcription = makeRecordingTranscription(
                        for: audioURL,
                        text: "",
                        duration: 0,
                        recordingInputDevice: active.recordingInputDevice,
                        realtimeDraftText: active.recoverablePartialTranscript,
                        preservesOriginalAudioForRecovery: completionDisposition == .clipboardOnly,
                        transcriptionStatus: completionDisposition == .clipboardOnly || hasRealtimeDraft
                            ? .recoverableDraft
                            : .pending
                    )
                    modelContext.insert(transcription)
                    var savedRecordingDraft = false
                    do {
                        try modelContext.save()
                        savedRecordingDraft = true
                    } catch {
                        logger.error("Failed to persist stopped recording draft before transcription: \(error, privacy: .public)")
                    }
                    if savedRecordingDraft {
                        // The persisted History row now owns this exact WAV. Do not
                        // remove its crash journal before that save boundary succeeds.
                        clearRecoveryJournal(for: active)
                        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                    }

                    active.pipelineTranscriptionID = transcription.id
                    enqueueTranscription(for: active, transcription: transcription)
                } else {
                    // Cancelled while recording → save a canceled record, no pipeline.
                    await finishCanceledRecording(active)
                    removeSession(active)
                }
            } else {
                // No file captured (e.g. start failed). Just tear the session down.
                if !active.shouldCancel {
                    logger.error("❌ No recorded file found after stopping recording")
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Recording failed: no audio file was captured"),
                        type: .error
                    )
                }
                active.transcriptionSession?.cancel()
                removeSession(active)
                await cleanupResourcesIfUnused(
                    retiringOwnerIsCurrent: true,
                    reason: "recording stopped without an audio file"
                )
            }
        } else {
            // ── START branch ─────────────────────────────────────────────────────────
            // Reserve synchronously before the permission callback schedules another
            // MainActor task. A second rapid start press in this gap is ignored rather
            // than becoming a second session that points at the same shared Recorder.
            assert(activeRecordingSession == nil, "one-active-recording invariant violated")
            guard !isResettingRecordingSession else {
                vippLog.notice("toggleRecord: START ignored while a full recording reset is draining old jobs")
                return
            }
            guard let startRequestID = recordingStartReservation.reserve() else {
                vippLog.notice("toggleRecord: duplicate START ignored while an earlier start request is pending")
                return
            }
            // Begin before the permission/start task yields. Otherwise an older result
            // can finish in the few-millisecond reservation-to-session gap and paste
            // after Ethan has already pressed Primary to begin the next dictation.
            activeRecordingDeliveryBarrier.beginCapture(owner: startRequestID)

            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let useCase: RecordingSession.UseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            if !useCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            // This passive recording-start capture exists solely for a possible Next
            // stop. A normal Primary stop discards it structurally and never enters an
            // app-specific resolver, even though the user could choose Next later.
            let recordingStartFocusedInput = FocusLockService.shared
                .captureRecordingStartInputSnapshot()
            let recordingStartIdentityTask: Task<
                FocusLockService.Target,
                Never
            >?
            if let recordingStartFocusedInput,
               FocusLockService.shared.requiresNativeTerminalSessionBinding(
                   for: recordingStartFocusedInput
               ) {
                // Begin beside microphone startup, never in front of it. Delivery
                // awaits this same bounded decision-token task if Next is pressed
                // before Terminal finishes returning its exact window/TTY pair.
                recordingStartIdentityTask = Task { @MainActor in
                    await FocusLockService.shared
                        .completingTerminalAutomationTarget(
                            for: recordingStartFocusedInput
                        )
                }
            } else {
                recordingStartIdentityTask = nil
            }

            requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        await self.startNewSession(
                            startRequestID: startRequestID,
                            modeId: modeId,
                            useCase: useCase,
                            recordingStartFocusedInput:
                                recordingStartFocusedInput,
                            recordingStartIdentityTask:
                                recordingStartIdentityTask
                        )
                    } else {
                        recordingStartIdentityTask?.cancel()
                        self.recordingStartReservation.cancel(startRequestID)
                        self.activeRecordingDeliveryBarrier.endCapture(owner: startRequestID)
                        self.reportUnresolvedPrimaryAutoSendIfQueueDrained()
                        self.logger.error("Recording permission denied")
                    }
                }
            }
        }
    }

    // MARK: - Start a fresh session

    // Creates a brand-new RecordingSession, drives the same start handshake the old engine
    // used (permission already granted, recorder.startRecording, mode config apply, streaming
    // session prepare, model preload), and appends it to `sessions` with phase .recording.
    private func startNewSession(
        startRequestID: UUID,
        modeId: UUID?,
        useCase: RecordingSession.UseCase,
        recordingStartFocusedInput: FocusLockService.Target?,
        recordingStartIdentityTask: Task<FocusLockService.Target, Never>?
    ) async {
        let startWaitBeganAt = Date()
        let startWasDeferred = activeRecordingDeliveryBarrier.isCaptureStartBlocked
        if startWasDeferred {
            vippLog.info("record start: DEFERRED while an older delivery lease completes requestID=\(startRequestID.uuidString, privacy: .public)")
        }
        let captureMayStart = await activeRecordingDeliveryBarrier
            .waitUntilCaptureMayStart {
                self.recordingStartReservation.pendingID == startRequestID
                    && !self.isResettingRecordingSession
            }
        if startWasDeferred {
            let elapsedMilliseconds = Int(
                Date().timeIntervalSince(startWaitBeganAt) * 1_000
            )
            vippLog.info("record start: RESUMED captureMayStart=\(captureMayStart, privacy: .public) waitMs=\(elapsedMilliseconds, privacy: .public) requestID=\(startRequestID.uuidString, privacy: .public)")
        }
        guard captureMayStart else {
            recordingStartIdentityTask?.cancel()
            recordingStartReservation.cancel(startRequestID)
            activeRecordingDeliveryBarrier.endCapture(owner: startRequestID)
            reportUnresolvedPrimaryAutoSendIfQueueDrained()
            vippLog.notice("startNewSession: START reservation canceled while waiting for an older delivery requestID=\(startRequestID.uuidString, privacy: .public)")
            return
        }

        // Cleanup yields while shared model managers release memory. Keep the start
        // reservation owned across that wait so no second start can overtake it, then
        // revalidate the token before creating a session or touching shared resources.
        if let resourceCleanupTask {
            await resourceCleanupTask.value
        }

        // Consume the exact reservation before creating the session. MainActor isolation
        // makes this an atomic handoff: stale permission callbacks and duplicate start
        // events cannot append another mic owner.
        guard recordingStartReservation.consume(startRequestID),
              activeRecordingSession == nil else {
            recordingStartIdentityTask?.cancel()
            activeRecordingDeliveryBarrier.endCapture(owner: startRequestID)
            reportUnresolvedPrimaryAutoSendIfQueueDrained()
            vippLog.notice("startNewSession: stale or duplicate START refused requestID=\(startRequestID.uuidString, privacy: .public)")
            return
        }

        let startID = startRequestID
        let session = RecordingSession(
            phase: .recording,
            useCase: useCase,
            startID: startID,
            recordingStartFocusedInput: recordingStartFocusedInput
        )
        guard activeRecordingDeliveryBarrier.transferCapture(
            from: startRequestID,
            to: session.id
        ) else {
            recordingStartIdentityTask?.cancel()
            // Normally a failed transfer means reset already removed the reservation.
            // Defensively release it anyway: a duplicate destination owner must not
            // strand the start token and block every later delivery forever.
            activeRecordingDeliveryBarrier.endCapture(owner: startRequestID)
            reportUnresolvedPrimaryAutoSendIfQueueDrained()
            vippLog.fault("startNewSession: capture ownership transfer refused requestID=\(startRequestID.uuidString, privacy: .public) sessionID=\(session.id.uuidString, privacy: .public)")
            return
        }
        // Born .recording but we drive it through .starting → .recording during the handshake.
        session.liveRecordingState = .starting

        // Append to the collection so the card appears immediately (shows the .starting state).
        sessions.append(session)
        recomputeDerivedState()

        if let recordingStartIdentityTask,
           let recordingStartFocusedInput {
            session.beginPasteTargetEnrichment(
                captured: recordingStartFocusedInput,
                task: recordingStartIdentityTask
            )
        }

        let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) { [weak self, weak session] in
            guard let self, let session else { return false }
            // Only keep applying config while THIS session is still the live start.
            return session.startID == startID && !session.shouldCancel && self.sessions.contains(where: { $0.id == session.id })
        }

        // The app/default Mode is applied synchronously before beginApplyingConfiguration
        // returns; capture that provisional transcription configuration immediately.
        // If the user stops during an asynchronous browser-URL lookup, this session still
        // owns its own model/language/prompt rather than falling back later to session B's
        // globally current Mode.
        session.transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
            transcriptionModelManager: self.transcriptionModelManager
        )
        session.showsRealtimeTranscriptHUD =
            session.transcriptionConfiguration?.isRealtimeEnabled == true

        do {
            let fileName = "\(UUID().uuidString).wav"
            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
            session.audioURL = permanentURL

            // The Core Audio writer finalizes RIFF/data lengths only on close. Create
            // durable lineage before AUHAL can write a frame, otherwise a force-quit
            // could leave usable PCM with neither a valid header nor a History row.
            // A missing journal is a recovery guarantee failure, so do not start capture.
            session.recoveryJournalEntry = try recoveryJournalStore.begin(audioURL: permanentURL)

            // Buffer audio chunks until the streaming session (if any) is ready to receive them.
            let pendingChunks = OSAllocatedUnfairLock(initialState: [Data]())
            self.recorder.onAudioChunk = { data in
                pendingChunks.withLock { $0.append(data) }
            }

            session.liveRecordingState = .starting
            recomputeDerivedState()

            session.recordingInputDevice = try await self.recorder.startRecording(
                toOutputFile: permanentURL
            )
            persistRecoveryJournal(for: session, realtimeDraftText: nil)

            // Re-press / cancel / panel-gone guard: if this is no longer the live start, abort.
            let startTokenIsCurrent = session.startID == startID
            let sessionStillOwnsMic = self.activeRecordingSession === session
            let panelIsVisible = self.recorderUIManager?.isRecorderPanelVisible ?? false
            let shouldReportUnexpectedAbort = RecorderPanelLifecyclePolicy
                .shouldReportUnexpectedStartupAbort(
                    startTokenIsCurrent: startTokenIsCurrent,
                    sessionStillOwnsMic: sessionStillOwnsMic,
                    panelIsVisible: panelIsVisible,
                    canceled: session.shouldCancel
                )
            guard startTokenIsCurrent,
                  sessionStillOwnsMic,
                  panelIsVisible,
                  !session.shouldCancel else {
                activeModeTask.cancel()
                let shouldKeepRecordingFile = session.shouldCancel
                if shouldReportUnexpectedAbort {
                    vippLog.fault("startNewSession: recorder start aborted because its panel disappeared tokenCurrent=\(startTokenIsCurrent, privacy: .public) sessionOwnsMic=\(sessionStillOwnsMic, privacy: .public) panelVisible=\(panelIsVisible, privacy: .public) canceled=\(session.shouldCancel, privacy: .public) sessionID=\(session.id.uuidString, privacy: .public)")
                } else {
                    // A rapid stop/cancel can settle while recorder startup is returning.
                    // That path already owns its teardown and is not a recording failure.
                    vippLog.info("startNewSession: recorder startup superseded by normal lifecycle tokenCurrent=\(startTokenIsCurrent, privacy: .public) sessionOwnsMic=\(sessionStillOwnsMic, privacy: .public) panelVisible=\(panelIsVisible, privacy: .public) canceled=\(session.shouldCancel, privacy: .public) sessionID=\(session.id.uuidString, privacy: .public)")
                }
                if session.startID == startID {
                    await self.recorder.stopRecording()
                    if !shouldKeepRecordingFile {
                        self.discardUnusableRecordingAndJournal(for: session)
                    }
                    self.removeSession(session)
                    self.activeRecordingDeliveryBarrier.endCapture(owner: session.id)
                    self.reportUnresolvedPrimaryAutoSendIfQueueDrained()
                }
                if shouldReportUnexpectedAbort {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Recording stopped before startup completed"),
                        type: .error
                    )
                }
                return
            }

            session.liveRecordingState = .recording
            session.phase = .recording
            recomputeDerivedState()
            if session.recordingStartFocusedInput == nil {
                let retryTarget = FocusLockService.shared
                    .captureFocusedInputSnapshot(
                        allowApplicationFallback: true
                    )
                session.recordingStartFocusedInput = retryTarget
                session.pasteTarget = RecordingPasteTarget(
                    destination: .recordingStart,
                    focusedInput: retryTarget,
                    mode: ModeRuntimeResolver.modeSnapshot(
                        forPasteTargetBundleIdentifier:
                            retryTarget?.bundleIdentifier
                    )
                )
                if let retryTarget {
                    beginTerminalPasteTargetEnrichment(
                        for: session,
                        captured: retryTarget
                    )
                }
            }
            FocusLockService.shared.showRecordingStartInput(session.recordingStartFocusedInput) // Show the saved destination only after microphone recording really started, never when post-recording transcription begins.

            await activeModeTask.value

            guard session.liveRecordingState.isRecordingOrPaused,
                  self.activeRecordingSession === session,
                  session.startID == startID,
                  !session.shouldCancel else {
                return
            }

            // Begin app/window context capture for AI enhancement.
            self.startRecordingContextCapture(for: session)

            guard let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: self.transcriptionModelManager
            ) else {
                NotificationManager.shared.showNotification(title: String(localized: "No AI Model Selected"), type: .error)
                await self.recorder.stopRecording()
                discardUnusableRecordingAndJournal(for: session)
                self.removeSession(session)
                self.activeRecordingDeliveryBarrier.endCapture(owner: session.id)
                self.reportUnresolvedPrimaryAutoSendIfQueueDrained()
                await self.cleanupResourcesIfUnused(
                    retiringOwnerIsCurrent: true,
                    reason: "recording had no selected model"
                )
                await self.recorderUIManager?.dismissRecorderPanel()
                return
            }

            session.transcriptionConfiguration = transcriptionConfiguration
            session.showsRealtimeTranscriptHUD =
                self.serviceRegistry.shouldUseRealtimeTranscription(
                    for: transcriptionConfiguration
                )

            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) {
                let streamingSession = self.serviceRegistry.createSession(
                    for: transcriptionConfiguration,
                    onPartialTranscript: { [weak self, weak session] partial in
                        Task { @MainActor in
                            guard let self, let session,
                                  session.startID == startID,
                                  session.liveRecordingState == .recording else {
                                return
                            }
                            // Streaming callbacks only repaint the black recorder HUD. Writing
                            // partials into a destination creates a second mutable draft, races
                            // Ethan's edits/focus, and duplicates the single final delivery below.
                            session.partialTranscript = partial
                            self.persistRecoveryJournal(
                                for: session,
                                realtimeDraftText: partial
                            )
                            // Mirror to the engine's derived partial only while this is the
                            // active recording session (it always is here, but be explicit).
                            if self.activeRecordingSession?.id == session.id {
                                self.partialTranscript = partial
                            }
                        }
                    }
                )
                session.transcriptionSession = streamingSession
                let realCallback = try await streamingSession.prepare(
                    configuration: transcriptionConfiguration
                )

                // `prepare` is async. Session A may have stopped and session B may now
                // own the shared Recorder while this await was suspended. Never install
                // A's callback into B's recorder: that would route B's microphone chunks
                // into A's streaming provider and is a direct old/new transcript race.
                guard session.liveRecordingState.isRecordingOrPaused,
                      self.activeRecordingSession === session,
                      session.startID == startID,
                      !session.shouldCancel else {
                    streamingSession.cancel()
                    return
                }

                if let realCallback {
                    self.recorder.onAudioChunk = realCallback
                    let buffered = pendingChunks.withLock { chunks -> [Data] in
                        let result = chunks
                        chunks.removeAll()
                        return result
                    }
                    for chunk in buffered { realCallback(chunk) }
                }
            } else {
                session.transcriptionSession = nil
                self.recorder.onAudioChunk = nil
                pendingChunks.withLock { $0.removeAll() }
            }

            // Best-effort model preload so the eventual transcribe is fast. Use this
            // recording's frozen model; rereading the global Mode here lets a newer
            // overlapping recording choose which model an older session preloads. The
            // model managers are shared, so never preload B through A's running/queued
            // pipeline. B will load on demand once the serial queue reaches it.
            let modelForPreload = transcriptionConfiguration.model
            Task { @MainActor [weak self, weak session] in
                guard let self, let session,
                      self.activeRecordingSession === session,
                      SharedTranscriptionResourcePolicy.allowsSpeculativePreload(
                          liveSessionCount: self.sessions.count
                      ) else {
                    self?.vippLog.info("pipeline preload SKIPPED because another recording/transcription session owns shared resources")
                    return
                }

                if modelForPreload.provider == .whisper {
                    let model = modelForPreload
                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                       self.whisperModelManager.whisperContext == nil {
                        do {
                            try await self.whisperModelManager.loadModel(localWhisperModel)
                        } catch {
                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                        }
                    }
                } else if let fluidAudioModel = modelForPreload as? FluidAudioModel {
                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(for: fluidAudioModel)
                }
            }

        } catch {
            activeModeTask.cancel()
            self.logger.error("Recording failed to start: \(error, privacy: .public)")
            await self.recorder.stopRecording()
            session.transcriptionSession?.cancel()
            discardUnusableRecordingAndJournal(for: session)
            self.removeSession(session)
            self.activeRecordingDeliveryBarrier.endCapture(owner: session.id)
            self.reportUnresolvedPrimaryAutoSendIfQueueDrained()
            await self.cleanupResourcesIfUnused(
                retiringOwnerIsCurrent: true,
                reason: "recording failed to start"
            )
            NotificationManager.shared.showNotification(title: String(localized: "Recording failed to start"), type: .error)
            await self.recorderUIManager?.dismissRecorderPanel()
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture(for session: RecordingSession) {
        session.clearContext()

        let store = RecordingContextSnapshotStore()
        session.contextStore = store
        session.contextTasks = RecordingContextCaptureService.startCapture(into: store)
    }

    // MARK: - Serial Transcription Queue

    // Enqueue this session's pipeline onto the serial FIFO queue. The registry rejects
    // duplicate session/transcription/audio ownership before any Task is created. The
    // actual job captures audio, model/request configuration, and streaming session now;
    // runPipeline never reconstructs them from later global or recorder state.
    private func enqueueTranscription(for session: RecordingSession, transcription: Transcription) {
        guard let audioURL = session.audioURL?.standardizedFileURL,
              transcription.audioFileURL == audioURL.absoluteString,
              let transcriptionConfiguration = session.transcriptionConfiguration,
              let identity = transcriptionJobRegistry.register(
                  recordingSessionID: session.id,
                  transcriptionID: transcription.id,
                  audioURL: audioURL
              ) else {
            let reason = "A stopped recording could not be bound to one unique audio/transcription job"
            transcription.text = String(format: String(localized: "Transcription Failed: %@"), reason)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            NotificationManager.shared.showNotification(
                title: String(localized: "Transcription failed: recording session identity was inconsistent"),
                type: .error
            )
            vippLog.fault("pipeline enqueue REFUSED session=\(session.id.uuidString, privacy: .public) transcriptionID=\(transcription.id.uuidString, privacy: .public) audioFile=\(session.audioURL?.lastPathComponent ?? "nil", privacy: .public) hasConfiguration=\(session.transcriptionConfiguration != nil, privacy: .public)")
            removeSession(session)
            return
        }

        let job = QueuedTranscriptionJob(
            identity: identity,
            recordingSession: session,
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            transcriptionSession: session.transcriptionSession
        )
        // Realtime provider finalization and user-visible delivery have different
        // ordering requirements. AssemblyAI should commit/close this stopped
        // recording's socket immediately so recording B can connect without building
        // up stale sessions; the serial queue still awaits this exact one-shot result
        // and delivers A, then B, using their immutable job identities.
        job.transcriptionSession?.beginFinalization(audioURL: audioURL)
        vippLog.info("pipeline enqueue \(identity.logDescription, privacy: .public) model=\(transcriptionConfiguration.model.displayName, privacy: .public)")

        transcriptionJobQueue.enqueue(
            identity,
            isCurrent: { [weak self, weak session, weak transcription] queuedIdentity in
                guard let self, let session, let transcription else { return false }
                return self.transcriptionJobRegistry.contains(queuedIdentity)
                    && session.id == queuedIdentity.recordingSessionID
                    && session.pipelineTranscriptionID == queuedIdentity.transcriptionID
                    && session.audioURL?.standardizedFileURL == queuedIdentity.audioURL
                    && transcription.id == queuedIdentity.transcriptionID
                    && transcription.audioFileURL == queuedIdentity.audioURL.absoluteString
                    && self.sessions.contains(where: { $0 === session })
            },
            onDiscard: { [weak self] discardedIdentity in
                guard let self else { return }
                self.transcriptionJobRegistry.remove(discardedIdentity)
                self.reportUnresolvedPrimaryAutoSendIfQueueDrained()
                self.vippLog.notice("pipeline queue DISCARD before run \(discardedIdentity.logDescription, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
            },
            operation: { [weak self] _ in
                guard let self else { return }
                await self.runPipeline(for: job)
                self.transcriptionJobRegistry.remove(identity)
                self.reportUnresolvedPrimaryAutoSendIfQueueDrained()
                self.vippLog.info("pipeline remove \(identity.logDescription, privacy: .public)")
            }
        )
    }

    /// Resolve whether this normal Primary paste owns the cohort's one auto-send.
    ///
    /// The serial queue already guarantees paste order. This policy inspects every
    /// retained successor identity at the delivery lease—not merely the queue's tail—
    /// and suppresses Return only when the immediately following jobs are still live,
    /// ordinary Primary paste deliveries. Any exact Next route or other side-effect
    /// policy breaks the cohort. A successor that fails after this boundary may leave
    /// the earlier text pasted but unsent; deliberately never compensate with a late
    /// Return because Primary owns no exact input to verify by then.
    private func queuedPrimaryAutoSendResolution(
        for job: QueuedTranscriptionJob,
        originalKey: AutoSendKey,
        outputMode: ModeOutputMode,
        destination: RecordingPasteDestination
    ) -> PrimaryQueuedAutoSendResolution {
        let currentWasCanceled = job.recordingSession.shouldCancel
            || canceledPipelineTranscriptionIDs.contains(
                job.identity.transcriptionID
            )
        if destination == .primaryCurrentInput,
           outputMode == .paste,
           currentWasCanceled {
            // Cancellation can arrive during the 100 ms paste-settle interval after
            // the pipeline's earlier cancel gates. The paste already posted, but the
            // irreversible Return still has a safe last boundary and must be skipped.
            return .canceledCurrent(originalKey)
        }

        let currentIsEligible = destination == .primaryCurrentInput
            && outputMode == .paste
            && job.recordingSession.completionDisposition == .normalDelivery
            && !job.recordingSession.skipPostProcessing
            && !job.recordingSession.useCase.isAssistantFollowUp
            && !currentWasCanceled

        let newerCandidates = transcriptionJobRegistry
            .newerIdentities(after: job.identity)
            .map { identity in
                PrimaryQueuedAutoSendCandidate(
                    enqueueSequence: identity.enqueueSequence,
                    isEligiblePrimaryPaste: isEligiblePrimaryQueueSuccessor(
                        identity
                    )
                )
            }

        let resolution = PrimaryQueuedAutoSendPolicy.resolve(
            originalKey: originalKey,
            currentIsEligiblePrimaryPaste: currentIsEligible,
            newerCandidates: newerCandidates,
            // Any newer capture owner is continuation intent before Return-down. In
            // the narrow opposite-lease race this is still only a start reservation;
            // after startup it is the actual recording session. Both mean Ethan has
            // begun adding to the current Primary cohort, so the older Return waits.
            newerRecordingStartPending: activeRecordingDeliveryBarrier
                .isDeliveryBlocked
        )
        if currentIsEligible {
            // The resolver is called only after this Primary Command-V succeeded.
            // Tracking therefore never warns for a paste that fell back to clipboard.
            primaryQueuedAutoSendTracker.observeSuccessfulPrimaryPaste(
                sequence: job.identity.enqueueSequence,
                resolution: resolution
            )
        }
        return resolution
    }

    private func isEligiblePrimaryQueueSuccessor(
        _ identity: TranscriptionJobIdentity
    ) -> Bool {
        guard transcriptionJobRegistry.contains(identity),
              let session = sessions.first(where: {
                  $0.id == identity.recordingSessionID
              }),
              session.pipelineTranscriptionID == identity.transcriptionID,
              session.audioURL?.standardizedFileURL == identity.audioURL,
              session.phase == .transcribing || session.phase == .delivering,
              session.pasteTarget.destination == .primaryCurrentInput,
              session.completionDisposition == .normalDelivery,
              !session.skipPostProcessing,
              !session.useCase.isAssistantFollowUp,
              !session.shouldCancel,
              !canceledPipelineTranscriptionIDs.contains(
                  identity.transcriptionID
              ) else {
            return false
        }

        // A custom command/response is an independent action, not another paste that
        // the cohort's final Return could submit. Primary still resolves its Mode live;
        // this snapshot is used only to decide whether the queued job currently joins
        // the consecutive paste cohort, never to freeze or replace its later Mode.
        return ModeRuntimeResolver.pasteTargetOutputConfiguration(
            mode: session.postProcessingMode
        ).outputMode == .paste
    }

    private func reportUnresolvedPrimaryAutoSendIfQueueDrained() {
        let unresolved = primaryQueuedAutoSendTracker
            .takeUnresolvedIfQueueDrained(
                hasOutstandingSuccessor: !transcriptionJobRegistry.isEmpty
                    || activeRecordingDeliveryBarrier.isDeliveryBlocked
            )
        guard !unresolved.isEmpty else { return }

        let sequences = unresolved.map { String($0) }.joined(separator: ",")
        vippLog.notice("paste: queued Primary auto-send remained unsent after queue drained suppressedSequences=\(sequences, privacy: .public) compensatingReturn=false")
        NotificationManager.shared.showNotification(
            title: String(localized: "Queued transcription was pasted but left unsent because the final queued recording didn’t complete a normal Primary paste"),
            type: .warning,
            duration: 8.0,
            playSound: false
        )
    }

    // MARK: - Pipeline Dispatch

    // Run the full transcribe→enhance→deliver pipeline for ONE immutable job. Only
    // destination/Mode retarget state remains intentionally late-bound on the owning
    // RecordingSession. Audio/config/transcription identity can never be read from B.
    private func runPipeline(for job: QueuedTranscriptionJob) async {
        let session = job.recordingSession
        let transcription = job.transcription
        let transcriptionID = job.identity.transcriptionID
        session.phase = .delivering // pipeline is running; mark past pure-transcribing
        session.liveRecordingState = .transcribing

        let jobIsCurrent: @MainActor () -> Bool = { [weak self, weak session, weak transcription] in
            guard let self, let session, let transcription else { return false }
            return !Task.isCancelled
                && self.transcriptionJobRegistry.contains(job.identity)
                && session.pipelineTranscriptionID == job.identity.transcriptionID
                && session.audioURL?.standardizedFileURL == job.audioURL
                && transcription.id == job.identity.transcriptionID
                && transcription.audioFileURL == job.audioURL.absoluteString
                && self.sessions.contains(where: { $0 === session })
        }
        let jobShouldCancel: @MainActor () -> Bool = { [weak self, weak session] in
            guard let self else { return false }
            return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                || (session?.shouldCancel ?? false)
        }

        vippLog.info("pipeline run START \(job.identity.logDescription, privacy: .public)")

        await pipeline.run(
            transcription: transcription,
            audioURL: job.audioURL,
            transcriptionConfiguration: job.transcriptionConfiguration,
            jobIdentity: job.identity,
            formattingConfiguration: { [weak session] in
                ModeRuntimeResolver.pasteTargetTranscriptionFormattingConfiguration(
                    mode: session?.postProcessingMode
                )
            },
            session: job.transcriptionSession,
            triggerWordModeSelection: { [weak self, weak session] text in
                guard let selection = self?.selectTriggerWordModeIfNeeded(for: text) else {
                    return nil
                }
                session?.applyTriggerWordModeOverride(selection.mode)
                return selection.processedText
            },
            enhancementConfiguration: { [weak self, weak session] in
                guard let self else { return nil }
                // ── VIPP (skip-mode-processing feature) — BYPASS POINT #1: AI enhancement ──
                // If THIS session is flagged one-shot raw, return nil so the pipeline's
                // enhancement branch (which is gated on a non-nil config) is skipped
                // entirely — no LLM round-trip, no rewrite. The raw transcript flows
                // straight to delivery. The flag is read HERE, at pipeline-run time (after
                // STOP), so toggling the button any time before this is honored.
                if session?.skipPostProcessing == true {
                    self.vippLog.info("pipeline: skipPostProcessing ON → AI enhancement BYPASSED (raw transcript)")
                    return nil
                }
                guard let enhancementService = self.enhancementService,
                      let aiService = enhancementService.getAIService() else {
                    return nil
                }
                return ModeRuntimeResolver.pasteTargetEnhancementConfiguration(
                    mode: session?.postProcessingMode,
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: { [weak session] in
                await MainActor.run {
                    session?.contextStore?.snapshot
                }
            },
            pasteTarget: { [weak session] in
                guard let session else {
                    preconditionFailure("The recording session must exist until its delivery target is resolved")
                }
                return await session.resolvePasteTargetForDelivery()
            },
            outputConfiguration: { [weak session] in
                let resolved = ModeRuntimeResolver.pasteTargetOutputConfiguration(
                    mode: session?.postProcessingMode
                )
                // ── VIPP (skip-mode-processing feature) — BYPASS POINT #2: mode script ──
                // If THIS session is flagged one-shot raw, rewrite the output config to a
                // plain `.paste` with the customCommand stripped. That forces
                // TranscriptionDelivery down its raw-paste branch instead of
                // deliverCustomCommand (the Mode's script) or deliverResponse (`.respond`).
                // We keep the same `mode` (for metadata/name) but drop BOTH the post-processing
                // action AND the auto-send: autoSendKey is forced to `.none` so the mode's
                // Enter-after-paste does NOT fire under skip. Result: the raw verbatim transcript
                // is pasted with NO mode custom-command/script AND NO auto-send Enter.
                if session?.skipPostProcessing == true {
                    return OutputRuntimeConfiguration(
                        mode: resolved.mode,
                        outputMode: .paste,
                        autoSendKey: .none,
                        customCommand: nil
                    )
                }
                return resolved
            },
            // ── VIPP (skip-mode-processing feature) — AUTHORITATIVE bypass flag ──
            // Resolve the owning session's one-shot flag at pipeline-run time and hand it to
            // the pipeline as a plain Bool. This is the LOAD-BEARING signal: the pipeline uses
            // it to force a raw `.paste` for delivery AND to skip enhancement, independent of
            // the closures above. Root-cause note for the "script still ran" bug: relying on
            // the outputConfiguration closure's rewrite alone was fragile; this explicit flag
            // makes the bypass deterministic from resolve → pipeline → delivery. Read here
            // (weak session) at run time so a button toggle any time before STOP is honored.
            skipPostProcessing: { [weak session] in
                session?.skipPostProcessing == true
            },
            completionDisposition: { [weak session] in
                session?.completionDisposition ?? .normalDelivery
            },
            recoverablePartialTranscript: { [weak session] in
                session?.recoverablePartialTranscript ?? ""
            },
            // Per-session UI state: drive this session's card spinner (.enhancing etc.).
            onStateChange: { [weak self, weak session] state in
                guard let session else { return }
                session.liveRecordingState = state
                // Keep the engine's derived state fresh ONLY if this session is the active
                // recording one (it never is during the pipeline, but be defensive).
                self?.recomputeDerivedState()
            },
            // Per-session cancel: poisoned id OR this session's own cancel flag.
            shouldCancel: jobShouldCancel,
            isDeliveryAuthorized: jobIsCurrent,
            acquireDeliveryLease: { [weak self] policy in
                guard let self else { return false }
                let wasBlocked = self.activeRecordingDeliveryBarrier.isDeliveryBlocked
                    && policy == .exclusive
                if wasBlocked {
                    self.vippLog.info("pipeline: delivery DEFERRED while newer recording is active \(job.identity.logDescription, privacy: .public)")
                }
                let acquired = await self.activeRecordingDeliveryBarrier.acquireDelivery(
                    owner: job.identity.transcriptionID,
                    policy: policy
                ) {
                    jobIsCurrent() && !jobShouldCancel()
                }
                if wasBlocked || !acquired
                    || (policy == .primaryPasteDuringCapture
                        && self.activeRecordingDeliveryBarrier.isDeliveryBlocked) {
                    self.vippLog.info("pipeline: delivery lease resolved policy=\(String(describing: policy), privacy: .public) activeRecording=\(self.activeRecordingDeliveryBarrier.isDeliveryBlocked, privacy: .public) acquired=\(acquired, privacy: .public) authorized=\(jobIsCurrent(), privacy: .public) canceled=\(jobShouldCancel(), privacy: .public) \(job.identity.logDescription, privacy: .public)")
                }
                return acquired
            },
            releaseDeliveryLease: { [weak self] in
                self?.activeRecordingDeliveryBarrier.releaseDelivery(
                    owner: job.identity.transcriptionID
                )
            },
            resolveQueuedPrimaryAutoSend: { [weak self] key, outputMode, destination in
                guard let self else { return .unchanged(key) }
                return self.queuedPrimaryAutoSendResolution(
                    for: job,
                    originalKey: key,
                    outputMode: outputMode,
                    destination: destination
                )
            },
            onQueuedPrimaryAutoSendIssued: { [weak self] in
                self?.primaryQueuedAutoSendTracker.observePrimaryAutoSendIssued(
                    sequence: job.identity.enqueueSequence
                )
            },
            onCancel: { [weak self, streamingSession = job.transcriptionSession] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: streamingSession)
            },
            onDismiss: { [weak self, weak session] in
                guard let self, let session else { return }
                // Only the pipeline owning the TOP/most-recent card should be allowed to
                // dismiss the whole panel; but in practice each pipeline's onDismiss fires
                // at its own completion. We dismiss the panel only when removing the LAST
                // session leaves the collection empty (handled in removeSession + the
                // RecorderUIManager visibility logic). Here we just no-op the per-pipeline
                // dismiss; final hide is decided after removal below.
                _ = session
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: session.useCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        vippLog.info("pipeline run END \(job.identity.logDescription, privacy: .public) status=\(transcription.transcriptionStatus ?? "nil", privacy: .public) finalChars=\(transcription.text.count, privacy: .public) finalDigest=\(TranscriptionLineageDigest.make(transcription.enhancedText ?? transcription.text), privacy: .public)")

        // Pipeline finished (delivered, failed, or canceled). Capture the result, release
        // shared model resources, drop the poison key, and remove the session from the stack.
        session.transcript = transcription.text
        canceledPipelineTranscriptionIDs.remove(transcriptionID)
        session.transcriptionSession = nil

        await finishRecorderSession()
        // Release shared model resources only when this lineage still owns retirement
        // and no recording or queued pipeline remains. A newer session may already be
        // recording while this older pipeline finishes; cleaning here used to unload or
        // cancel the resources that newer session had just prepared.
        let retiringOwnerIsCurrent = !Task.isCancelled
            && transcriptionJobRegistry.contains(job.identity)
        removeSession(session)
        await cleanupResourcesIfUnused(
            retiringOwnerIsCurrent: retiringOwnerIsCurrent,
            reason: "pipeline finished"
        )

        // If the panel is now empty (no sessions + no assistant response), let the UI manager
        // hide it. We trigger a generic dismiss; RecorderUIManager only actually hides when
        // there is nothing left to show.
        if sessions.isEmpty {
            await recorderUIManager?.dismissRecorderPanel()
        }
    }

    private func selectTriggerWordModeIfNeeded(
        for text: String
    ) -> (mode: ModeConfig, processedText: String)? {
        guard let (triggeredMode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
            return nil
        }

        ModeManager.shared.setActiveConfiguration(triggeredMode)
        return (triggeredMode, processedText)
    }

    // MARK: - Cancellation

    // Public cancel from the RecorderUIManager / shortcuts. Targets:
    //   • the ACTIVE recording session if one is recording, else
    //   • the most-recent in-flight transcribing/delivering session (top card).
    // This preserves the old "cancel button aborts what's live" UX in the multi-session world.
    func cancelRecording() async {
        if let active = activeRecordingSession {
            await cancelSession(active)
        } else if let top = topInFlightSession {
            await cancelSession(top)
        } else {
            // Nothing to cancel — just recompute derived state.
            recomputeDerivedState()
        }
    }

    // Per-card cancel entry point wired to the per-session "X" (engine.cancelSession(id:)).
    func cancelSession(id: UUID) async {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        await cancelSession(session)
    }

    // Cancel a SPECIFIC session. Behaviour depends on its phase:
    //   • .recording / .starting → stop the mic, save a "canceled" record, remove the card.
    //   • .transcribing / .delivering → poison its pipeline id so normal delivery is
    //     forbidden. The pipeline retains any finished result or saved realtime HUD partial
    //     in history + clipboard, but never pastes or auto-sends it. An empty cancellation
    //     remains a distinct ordinary canceled record. The card is removed when the pipeline
    //     unwinds; here we just flag + mark it cancelling.
    func cancelSession(_ session: RecordingSession) async {
        // VIPPDebug: poison point. For a recording session this is a clean discard; for an
        // in-flight one it inserts into canceledPipelineTranscriptionIDs which the pipeline's
        // shouldCancel() gate reads to prevent delivery and retain any recoverable result.
        vippLog.info("cancelSession: \(session.id.uuidString, privacy: .public) phase=\(String(describing: session.phase), privacy: .public) liveState=\(String(describing: session.liveRecordingState), privacy: .public)")

        session.shouldCancel = true
        session.transcriptionSession?.cancel()
        // A pipeline waiting behind another active recording must wake immediately
        // to observe this session-local cancellation instead of lingering until the
        // unrelated capture ends.
        activeRecordingDeliveryBarrier.notifyStateChange()

        switch session.phase {
        case .recording:
            // Mic owner. Leaving the active UI is not permanent deletion. Snapshot
            // any realtime HUD words, finalize the WAV, and persist both in History;
            // the user can replay/retranscribe there and only History's explicit
            // delete action removes the file.
            session.startID = UUID() // invalidate start handshake
            session.recoverablePartialTranscript = session.partialTranscript
            session.partialTranscript = ""
            session.clearContext()
            await recorder.stopRecording()
            await finishCanceledRecording(session)
            removeSession(session)
            activeRecordingDeliveryBarrier.endCapture(owner: session.id)
            reportUnresolvedPrimaryAutoSendIfQueueDrained()
            await cleanupResourcesIfUnused(
                retiringOwnerIsCurrent: true,
                reason: "active recording was canceled"
            )

        case .transcribing, .delivering:
            // In-flight job. Poison its pipeline id; the running pipeline will pick this up
            // at its next shouldCancel() gate. The card stays until the pipeline unwinds and
            // removeSession() fires in runPipeline's tail (or here if there's no live pipeline).
            if let pipelineID = session.pipelineTranscriptionID {
                vippLog.info("cancelSession: POISONING pipeline id \(pipelineID.uuidString, privacy: .public)")
                canceledPipelineTranscriptionIDs.insert(pipelineID)
            } else {
                // No pipeline started yet (queued but not running) → just drop the card.
                removeSession(session)
            }
            session.liveRecordingState = .idle
            recomputeDerivedState()

        case .done:
            removeSession(session)
        }
    }

    // Full reset (launch / hard reset): cancel everything, clear the queue, drop all sessions.
    func resetRecordingSession() async {
        guard !isResettingRecordingSession else {
            vippLog.notice("resetRecordingSession: duplicate reset ignored while the first reset is draining")
            return
        }
        isResettingRecordingSession = true
        defer { isResettingRecordingSession = false }

        // A reset is a hard lineage boundary. Invalidate membership first, then cancel
        // every retained queue task (running and waiting). Waiting Task<Void, Never>
        // jobs still recheck generation after their previous tail returns, and a running
        // pipeline must pass isDeliveryAuthorized before it can paste completed text.
        recordingStartReservation.invalidate()
        activeRecordingDeliveryBarrier.reset()
        primaryQueuedAutoSendTracker.reset()
        transcriptionJobRegistry.invalidateAll()
        transcriptionJobQueue.cancelAll()

        for session in sessions {
            session.shouldCancel = true
            session.transcriptionSession?.cancel()
            session.clearContext()
        }
        sessions.removeAll()
        canceledPipelineTranscriptionIDs.removeAll()
        partialTranscript = ""
        assistantSession.reset()
        recordingState = .idle
        await recorder.stopRecording()
        // Cancellation is cooperative. Do not tear down shared managers while an old
        // provider/model call is still unwinding; the queue's reset barrier also keeps
        // any future generation behind this same boundary.
        await transcriptionJobQueue.waitUntilIdle()
        await cleanupResources()
        await finishRecorderSession()
    }

    // Persist a no-delivery recording exit. The red X leaves the active UI but does not
    // delete captured work: original audio and any realtime HUD draft remain in History.
    // Permanent deletion is the separate, confirmed History action.
    private func finishCanceledRecording(_ session: RecordingSession) async {
        guard let audioURL = session.audioURL,
              FileManager.default.fileExists(atPath: audioURL.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: audioURL)
        let draft = session.recoverablePartialTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let transcription = makeRecordingTranscription(
            for: audioURL,
            text: draft.isEmpty ? Transcription.canceledTranscriptionText : draft,
            duration: duration,
            recordingInputDevice: session.recordingInputDevice,
            realtimeDraftText: draft,
            preservesOriginalAudioForRecovery: true,
            transcriptionStatus: draft.isEmpty ? .canceled : .canceledWithResult
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            clearRecoveryJournal(for: session)
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        recordingInputDevice: RecordingInputDeviceSnapshot? = nil,
        realtimeDraftText: String? = nil,
        preservesOriginalAudioForRecovery: Bool = false,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            recordingInputDevice: recordingInputDevice,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            realtimeDraftText: realtimeDraftText,
            preservesOriginalAudioForRecovery: preservesOriginalAudioForRecovery,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
              mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    private func cleanupResourcesIfUnused(
        retiringOwnerIsCurrent: Bool,
        reason: String
    ) async {
        let liveSessionCount = sessions.count
        guard SharedTranscriptionResourcePolicy.allowsCleanup(
            liveSessionCount: liveSessionCount,
            retiringOwnerIsCurrent: retiringOwnerIsCurrent
        ) else {
            vippLog.info("cleanupResources: DEFERRED reason=\(reason, privacy: .public) liveSessions=\(liveSessionCount, privacy: .public) retiringOwnerIsCurrent=\(retiringOwnerIsCurrent, privacy: .public)")
            return
        }
        await cleanupResources()
    }

    func cleanupResources() async {
        if let resourceCleanupTask {
            await resourceCleanupTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.notice("cleanupResources: releasing model resources")
            await self.whisperModelManager.cleanupResources()
            await self.serviceRegistry.cleanup()
            self.logger.notice("cleanupResources: completed")
        }
        resourceCleanupTask = task
        await task.value
        resourceCleanupTask = nil
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
