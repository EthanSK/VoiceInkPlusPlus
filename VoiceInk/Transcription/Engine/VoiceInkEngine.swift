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

    // Whisper/FluidAudio managers are shared even though jobs are per-session. A
    // cleanup task is therefore a resource barrier: a new recording waits for it,
    // and one session may never clean or preload through another live session.
    private var resourceCleanupTask: Task<Void, Never>?
    private var isResettingRecordingSession = false

    // Reservation across requestRecordPermission → startNewSession scheduling. Without
    // this synchronous token, two rapid Primary start events can both observe no active
    // session before either scheduled MainActor task appends one, creating two mic owners.
    private var recordingStartReservation = RecordingStartReservation()

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

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")
    // VIPPDebug: see RecorderUIManager for the filter predicate. Tracks the stop→
    // transcribe state transition and every cancellation request so we can attribute
    // who/when poisons an in-flight pipeline.
    let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
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
        return .retargeted
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
        stopPasteDestination: RecordingPasteDestination = .focusedAtStop
    ) async {
        // Mid-start re-press: the active session is still starting → cancel it.
        if let active = activeRecordingSession, active.liveRecordingState == .starting {
            await cancelSession(active)
            return
        }

        if let active = activeRecordingSession {
            // ── STOP branch ──────────────────────────────────────────────────────────
            // The mic owner stops. We flip its phase .recording→.transcribing, release the
            // mic (recorder.stopRecording), build its Transcription record, and ENQUEUE the
            // pipeline on the serial queue. CRITICAL: we do NOT await the pipeline here —
            // that inline await is exactly what blocked the next start in the old engine.
            // The function returns as soon as the mic is free, so a record press right after
            // can immediately START a new session.
            switch stopPasteDestination {
            case .recordingStart:
                let focusedInput = active.recordingStartFocusedInput
                active.pasteTarget = RecordingPasteTarget(
                    destination: .recordingStart,
                    focusedInput: focusedInput,
                    mode: ModeRuntimeResolver.modeSnapshot(
                        forPasteTargetBundleIdentifier: focusedInput?.bundleIdentifier
                    )
                )
            case .focusedAtStop:
                let focusedInput = FocusLockService.shared.captureFocusedInput()
                let continuity = active.recordingStartForegroundContinuity
                let continuityIsUnbroken = continuity.map {
                    ActiveWindowService.shared.primaryForegroundContinuityIsUnbroken($0)
                } ?? false
                active.pasteTarget = RecordingPasteTarget(
                    destination: .focusedAtStop,
                    focusedInput: focusedInput,
                    mode: ModeRuntimeResolver.modeSnapshot(
                        forPasteTargetBundleIdentifier: focusedInput?.bundleIdentifier
                            ?? (continuityIsUnbroken ? continuity?.bundleIdentifier : nil)
                    ),
                    primaryForegroundContinuity: continuity
                )
            case .focusedDuringTranscription:
                preconditionFailure("A transcription-time target can only be selected after recording has stopped")
            }

            // Publish the feedback token only after the selected route has owned
            // its per-session target. All mirrored recorder windows observe this
            // same session and therefore pulse in sync without re-reading focus.
            active.signalDestinationAction(stopPasteDestination)

            vippLog.info("toggleRecord: STOP session \(active.id.uuidString, privacy: .public) → .transcribing destination=\(String(describing: stopPasteDestination), privacy: .public) targetCaptured=\(active.pasteTarget.focusedInput != nil, privacy: .public) primaryContinuity=\(active.pasteTarget.primaryForegroundContinuity.map { ActiveWindowService.shared.primaryForegroundContinuityIsUnbroken($0) } ?? false, privacy: .public) shouldCancel=\(active.shouldCancel, privacy: .public)")

            active.phase = .transcribing
            active.liveRecordingState = .transcribing
            active.partialTranscript = ""
            active.startID = UUID() // invalidate the start handshake token (it has fully started)
            recomputeDerivedState()

            await recorder.stopRecording()
            // ── MEDIA RESUME-BETWEEN-SESSIONS NUANCE ──
            // recorder.stopRecording() schedules resumeMedia()/unmuteSystemAudio(). If the
            // user immediately starts session B, recorder.startRecording() will pauseMedia()/
            // muteSystemAudio() again. So media may briefly resume in the gap between stop and
            // the next start — that's acceptable and self-consistent: the single Recorder is
            // only ever owned by the single active recording session, so its pause/resume
            // bracketing always pairs with exactly one recording at a time.

            if let audioURL = active.audioURL {
                if !active.shouldCancel {
                    // Build the pending Transcription record and enqueue the pipeline.
                    let transcription = makeRecordingTranscription(
                        for: audioURL,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

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

            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let useCase: RecordingSession.UseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            if !useCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            let recordingStartFocusedInput = FocusLockService.shared.captureFocusedInput(allowApplicationFallback: true) // Capture before asynchronous setup. Electron may expose only AXWebArea while the shortcut is down, so preserve the owning app for Next Track.
            let recordingStartForegroundContinuity = ActiveWindowService.shared
                .capturePrimaryForegroundContinuity(
                    preferredInput: recordingStartFocusedInput
                )

            requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if granted {
                        await self.startNewSession(
                            startRequestID: startRequestID,
                            modeId: modeId,
                            useCase: useCase,
                            recordingStartFocusedInput: recordingStartFocusedInput,
                            recordingStartForegroundContinuity: recordingStartForegroundContinuity
                        )
                    } else {
                        self.recordingStartReservation.cancel(startRequestID)
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
        recordingStartForegroundContinuity: PrimaryForegroundContinuity?
    ) async {
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
            vippLog.notice("startNewSession: stale or duplicate START refused requestID=\(startRequestID.uuidString, privacy: .public)")
            return
        }

        let startID = startRequestID
        let session = RecordingSession(
            phase: .recording,
            useCase: useCase,
            startID: startID,
            recordingStartFocusedInput: recordingStartFocusedInput,
            recordingStartForegroundContinuity: recordingStartForegroundContinuity
        )
        // Born .recording but we drive it through .starting → .recording during the handshake.
        session.liveRecordingState = .starting

        // Append to the collection so the card appears immediately (shows the .starting state).
        sessions.append(session)
        recomputeDerivedState()

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

        do {
            let fileName = "\(UUID().uuidString).wav"
            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
            session.audioURL = permanentURL

            // Buffer audio chunks until the streaming session (if any) is ready to receive them.
            let pendingChunks = OSAllocatedUnfairLock(initialState: [Data]())
            self.recorder.onAudioChunk = { data in
                pendingChunks.withLock { $0.append(data) }
            }

            session.liveRecordingState = .starting
            recomputeDerivedState()

            try await self.recorder.startRecording(toOutputFile: permanentURL)

            // Re-press / cancel / panel-gone guard: if this is no longer the live start, abort.
            guard session.startID == startID,
                  self.activeRecordingSession === session,
                  self.recorderUIManager?.isRecorderPanelVisible ?? false,
                  !session.shouldCancel else {
                activeModeTask.cancel()
                let shouldKeepRecordingFile = session.shouldCancel
                if session.startID == startID {
                    await self.recorder.stopRecording()
                    if !shouldKeepRecordingFile {
                        session.audioURL = nil
                    }
                    self.removeSession(session)
                }
                return
            }

            session.liveRecordingState = .recording
            session.phase = .recording
            recomputeDerivedState()
            if session.recordingStartFocusedInput == nil {
                session.recordingStartFocusedInput = FocusLockService.shared.captureFocusedInput(allowApplicationFallback: true) // Retry only if even the owning application could not be captured during the shortcut event.
            }
            FocusLockService.shared.showRecordingStartInput(session.recordingStartFocusedInput) // Show the saved destination only after microphone recording really started, never when post-recording transcription begins.

            await activeModeTask.value

            guard session.liveRecordingState == .recording,
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
                try? FileManager.default.removeItem(at: permanentURL)
                session.audioURL = nil
                self.removeSession(session)
                await self.cleanupResourcesIfUnused(
                    retiringOwnerIsCurrent: true,
                    reason: "recording had no selected model"
                )
                await self.recorderUIManager?.dismissRecorderPanel()
                return
            }

            session.transcriptionConfiguration = transcriptionConfiguration

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
                            session.partialTranscript = partial
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
                guard session.liveRecordingState == .recording,
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
            if let recordedFile = session.audioURL {
                try? FileManager.default.removeItem(at: recordedFile)
            }
            session.audioURL = nil
            self.removeSession(session)
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
                self.vippLog.notice("pipeline queue DISCARD before run \(discardedIdentity.logDescription, privacy: .public) taskCancelled=\(Task.isCancelled, privacy: .public)")
            },
            operation: { [weak self] _ in
                guard let self else { return }
                await self.runPipeline(for: job)
                self.transcriptionJobRegistry.remove(identity)
                self.vippLog.info("pipeline remove \(identity.logDescription, privacy: .public)")
            }
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
                return session.resolvePasteTargetForDelivery()
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
            // Per-session UI state: drive this session's card spinner (.enhancing etc.).
            onStateChange: { [weak self, weak session] state in
                guard let session else { return }
                session.liveRecordingState = state
                // Keep the engine's derived state fresh ONLY if this session is the active
                // recording one (it never is during the pipeline, but be defensive).
                self?.recomputeDerivedState()
            },
            shouldCancel: { [weak self, weak session] in
                guard let self else { return false }
                // Per-session cancel: poisoned id OR this session's own cancel flag.
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (session?.shouldCancel ?? false)
            },
            isDeliveryAuthorized: jobIsCurrent,
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
    //   • .transcribing / .delivering → poison its pipeline id so its result is DISCARDED
    //     (not pasted). The pipeline's defensive gates still deliver a finished 200 if text
    //     is already in hand (see TranscriptionPipeline) — that's intentional: we never throw
    //     away words the user already got transcribed. The card is removed when the pipeline
    //     unwinds; here we just flag + mark it cancelling.
    func cancelSession(_ session: RecordingSession) async {
        // VIPPDebug: poison point. For a recording session this is a clean discard; for an
        // in-flight one it inserts into canceledPipelineTranscriptionIDs which the pipeline's
        // shouldCancel() gate reads to discard the result (subject to the "don't discard a
        // finished 200" defensive gates).
        vippLog.info("cancelSession: \(session.id.uuidString, privacy: .public) phase=\(String(describing: session.phase), privacy: .public) liveState=\(String(describing: session.liveRecordingState), privacy: .public)")

        session.shouldCancel = true
        session.transcriptionSession?.cancel()

        switch session.phase {
        case .recording:
            // Mic owner. Stop capture, persist a canceled record, drop the card.
            session.startID = UUID() // invalidate start handshake
            session.clearContext()
            await recorder.stopRecording()
            await finishCanceledRecording(session)
            removeSession(session)
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

    // Persist a "canceled" Transcription record for a session whose recording was aborted.
    private func finishCanceledRecording(_ session: RecordingSession) async {
        guard let audioURL = session.audioURL,
              FileManager.default.fileExists(atPath: audioURL.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: audioURL)
        let transcription = makeRecordingTranscription(
            for: audioURL,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
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
