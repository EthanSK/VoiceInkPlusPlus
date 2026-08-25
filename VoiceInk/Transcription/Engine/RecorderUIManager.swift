import Foundation
import SwiftUI
import AppKit
import os

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Mini")
        }
    }

    static var stored: RecorderPanelStyle {
        let rawValue = UserDefaults.standard.string(forKey: "RecorderType") ?? RecorderPanelStyle.mini.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .mini
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

enum RecorderPanelLifecyclePolicy {
    enum IdleToggleAction: Equatable {
        case preservePendingStart
        case startRecording
        case dismiss
    }

    static func shouldKeepVisible(
        sessionCount: Int,
        hasPendingStart: Bool,
        hasCaptureOwner: Bool,
        assistantVisible: Bool
    ) -> Bool {
        sessionCount > 0 || hasPendingStart || hasCaptureOwner || assistantVisible
    }

    static func idleToggleAction(
        sessionCount: Int,
        hasPendingStart: Bool,
        hasCaptureOwner: Bool
    ) -> IdleToggleAction {
        // A synchronous reservation owns the next recording before its session card
        // exists. Treating that gap as truly idle can hide the panel and make the
        // recorder's post-start visibility guard discard the new recording.
        if hasPendingStart || hasCaptureOwner {
            return .preservePendingStart
        }
        return sessionCount > 0 ? .startRecording : .dismiss
    }

    /// Only a live start that still owns the microphone and loses its recorder panel
    /// is an app fault. A user cancel or an overlapping normal stop legitimately
    /// invalidates the start token and owns teardown on its own path.
    static func shouldReportUnexpectedStartupAbort(
        startTokenIsCurrent: Bool,
        sessionStillOwnsMic: Bool,
        panelIsVisible: Bool,
        canceled: Bool
    ) -> Bool {
        startTokenIsCurrent && sessionStillOwnsMic && !panelIsVisible && !canceled
    }
}

enum RecorderPanelPresentationIssueLevel: Int {
    case none
    case incomplete
    case failure

    /// A display episode may escalate from partial mirroring to total loss, but a
    /// later lower-severity observation must not add noise after the stronger warning.
    func shouldReport(_ candidate: Self) -> Bool {
        candidate.rawValue > rawValue
    }
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting, NotificationRecorderPlacementProviding {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            guard !isRestoringRecorderPanelStyle else { return }
            if !rebuildVisiblePanel(previousStyle: oldValue) {
                // A style preference is not allowed to replace a proven visible HUD
                // with a phantom one. Keep the old presentation and preference until
                // the requested style can materialize on a later explicit attempt.
                isRestoringRecorderPanelStyle = true
                recorderPanelStyle = oldValue
                isRestoringRecorderPanelStyle = false
            }
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    // This is both UI truth and the ownership boundary for recorder-only shortcuts
    // such as Next Track and Escape. Set it only after at least one materialized,
    // ordered panel intersects its screen. Incomplete mirroring warns and is repaired
    // by display events; zero real panels must never accompany an optimistic `true`.
    @Published private(set) var isRecorderPanelVisible = false

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?

    private weak var engine: VoiceInkEngine?
    private var recorder: Recorder?
    private var reportedRecorderPresentationIssue: RecorderPanelPresentationIssueLevel = .none
    private var isRestoringRecorderPanelStyle = false
    private var displayEnvironmentObservers: [NSObjectProtocol] = []

    private enum LaunchResetState {
        case pending
        case running
        case complete
    }

    private var launchResetState: LaunchResetState = .pending
    private var launchResetWaiters: [CheckedContinuation<Void, Never>] = []

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderUIManager")

    // VIPPDebug: dedicated unified-log channel for the records→transcribe→paste→hide
    // path so the fork's "transcribing briefly then bar hides, nothing pasted" bug is
    // observable. Filter with:
    //   log stream --predicate 'subsystem == "com.ethansk.VoiceInkPlusPlus" && category == "VIPPDebug"'
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    init() {}

    /// Call after VoiceInkEngine is created to break the circular init dependency.
    func configure(engine: VoiceInkEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        NotificationManager.shared.setRecorderPlacementProvider(self)
        setupNotifications()
        setupDisplayEnvironmentNotifications()
    }

    /// Returns the full bottom reservation occupied by the visible mini recorder
    /// on every mirrored display. NotificationManager uses this at presentation
    /// time so errors sit above realtime text and stacked cards instead of
    /// overlapping them. The notch style occupies the top edge and needs no
    /// bottom reservation.
    func notificationBottomReservedHeight(on screen: NSScreen) -> CGFloat? {
        guard isRecorderPanelVisible,
              recorderPanelStyle == .mini,
              let engine else {
            return nil
        }

        let baseSession = engine.activeRecordingSession ?? engine.sessions.last
        let showsAssistant = engine.assistantSession.isVisible
        guard showsAssistant || baseSession != nil else { return nil }

        let showsRealtimeTranscript =
            baseSession?.liveRecordingState.isRecordingOrPaused == true
            && baseSession?.showsRealtimeTranscriptHUD == true

        return MiniRecorderLayoutMetrics.notificationBottomReservedHeight(
            showsAssistant: showsAssistant,
            showsRealtimeTranscript: showsRealtimeTranscript,
            sessionCount: engine.sessions.count
        )
    }

    // MARK: - Recorder Panel Management

    @discardableResult
    private func showRecorderPanel(
        reason: String,
        rearmFailureNotification: Bool = false
    ) -> Bool {
        if rearmFailureNotification {
            // Every explicit Primary start deserves visible feedback if it cannot
            // begin; deduplication is only for repeated system repair events.
            reportedRecorderPresentationIssue = .none
        }
        guard let engine = engine, let recorder = recorder else {
            logger.fault("Recorder HUD presentation failed before dependencies were configured")
            reportRecorderPresentationFailureIfNeeded()
            return false
        }

        // A globally hidden application owns no WindowServer-visible panels even when
        // every NSPanel is materialized at correct screen geometry. Recover only that
        // AppKit state, without activation, before judging physical HUD visibility.
        // The helper keeps all unrelated VoiceInk++ windows ordered out.
        if RecorderPanelApplicationVisibility.prepareForHUDPresentation() {
            vippLog.info("recorder HUD: recovered hidden application without activation")
        }

        let firstReport: RecorderPanelPresentationReport
        switch recorderPanelStyle {
        case .notch:
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    // Exit ("X") button → stop with NO paste, retain original audio
                    // plus any realtime HUD draft in History, then resume paused media.
                    // Only History's explicit delete action permanently removes it.
                    onCancelTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.cancelRecording()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    },
                    // Per-card cancel for a specific background transcribing session.
                    onCancelSession: { [weak engine] id in
                        Task { @MainActor in
                            await engine?.cancelSession(id: id)
                        }
                    }
                )
            }
            firstReport = notchWindowManager?.show()
                ?? RecorderPanelPresentationReport(
                    expectedScreenCount: NSScreen.screens.count,
                    materializedPanelCount: 0,
                    visibleOnScreenPanelCount: 0
                )
        case .mini:
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    // Exit ("X") button → stop with NO paste, save a recoverable local
                    // draft, then resume paused media. Same path as the notch panel.
                    onCancelTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.cancelRecording()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    },
                    // Per-card cancel for a specific background transcribing session.
                    onCancelSession: { [weak engine] id in
                        Task { @MainActor in
                            await engine?.cancelSession(id: id)
                        }
                    }
                )
            }
            firstReport = miniWindowManager?.show()
                ?? RecorderPanelPresentationReport(
                    expectedScreenCount: NSScreen.screens.count,
                    materializedPanelCount: 0,
                    visibleOnScreenPanelCount: 0
                )
        }

        if firstReport.isComplete {
            recordSuccessfulPresentation(firstReport, reason: reason, attempt: 1)
            return true
        }

        // A second synchronous order/re-read repairs stale geometry and transiently
        // hidden reusable panels without inventing a timing delay. Initial recording
        // still requires at least one verified on-screen panel; incomplete mirroring is
        // visible and repairable rather than allowed to erase the primary function.
        let retryReport: RecorderPanelPresentationReport
        switch recorderPanelStyle {
        case .notch:
            retryReport = notchWindowManager?.show() ?? firstReport
        case .mini:
            retryReport = miniWindowManager?.show() ?? firstReport
        }

        if retryReport.isComplete {
            recordSuccessfulPresentation(retryReport, reason: reason, attempt: 2)
            return true
        }

        if retryReport.hasVisiblePanel {
            vippLog.error("recorder HUD: partial presentation reason=\(reason, privacy: .public) style=\(self.recorderPanelStyle.rawValue, privacy: .public) expected=\(retryReport.expectedScreenCount, privacy: .public) materialized=\(retryReport.materializedPanelCount, privacy: .public) visibleOnScreen=\(retryReport.visibleOnScreenPanelCount, privacy: .public)")
            reportIncompleteRecorderPresentationIfNeeded()
            return true
        }

        vippLog.fault("recorder HUD: presentation failed reason=\(reason, privacy: .public) style=\(self.recorderPanelStyle.rawValue, privacy: .public) expected=\(retryReport.expectedScreenCount, privacy: .public) materialized=\(retryReport.materializedPanelCount, privacy: .public) visibleOnScreen=\(retryReport.visibleOnScreenPanelCount, privacy: .public)")
        if !isRecorderPanelVisible {
            // A failed initial attempt may have materialized only some displays. None
            // may linger because the recording is intentionally not starting and the
            // visible-bar shortcut ownership flag remains false.
            hideRecorderPanel()
        }
        reportRecorderPresentationFailureIfNeeded()
        return false
    }

    private func recordSuccessfulPresentation(
        _ report: RecorderPanelPresentationReport,
        reason: String,
        attempt: Int
    ) {
        reportedRecorderPresentationIssue = .none
        vippLog.info("recorder HUD: presentation verified reason=\(reason, privacy: .public) style=\(self.recorderPanelStyle.rawValue, privacy: .public) attempt=\(attempt, privacy: .public) screens=\(report.expectedScreenCount, privacy: .public)")
    }

    private func reportRecorderPresentationFailureIfNeeded() {
        guard NSApp.keyWindow?.screen != nil
                || NSScreen.main != nil
                || NSScreen.screens.first != nil else {
            // Keep the report re-armed. The next display event can present it once a
            // screen exists; the privacy-safe fault log above remains authoritative.
            return
        }
        guard reportedRecorderPresentationIssue.shouldReport(.failure) else { return }
        reportedRecorderPresentationIssue = .failure
        let title = isRecorderPanelVisible
            ? String(localized: "Recorder controls could not be restored. VoiceInk++ kept the current recorder state.")
            : String(localized: "Recorder controls could not be shown. Recording did not start.")
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            playSound: false
        )
    }

    private func reportIncompleteRecorderPresentationIfNeeded() {
        guard NSApp.keyWindow?.screen != nil
                || NSScreen.main != nil
                || NSScreen.screens.first != nil else { return }
        guard reportedRecorderPresentationIssue.shouldReport(.incomplete) else { return }
        reportedRecorderPresentationIssue = .incomplete
        NotificationManager.shared.showNotification(
            title: String(localized: "Recorder controls are visible on only some displays. VoiceInk++ will retry when the display environment changes."),
            type: .error,
            playSound: false
        )
    }

    private func hideRecorderPanel() {
        switch recorderPanelStyle {
        case .notch:
            notchWindowManager?.hide()
        case .mini:
            miniWindowManager?.hide()
        }
    }

    @discardableResult
    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) -> Bool {
        // A hidden style can discard its stale manager immediately. For a visible HUD,
        // materialize and verify the replacement first; only then remove the proven old
        // panels. This makes a failed style preference transactional instead of leaving
        // Next/Escape ownership attached to zero physical windows.
        let shouldRemainVisible = isRecorderPanelVisible
        guard shouldRemainVisible else {
            destroyWindowManager(for: previousStyle)
            return true
        }

        if showRecorderPanel(reason: "recorder style changed") {
            destroyWindowManager(for: previousStyle)
            return true
        }

        destroyWindowManager(for: recorderPanelStyle)
        return false
    }

    private func destroyWindowManager(for style: RecorderPanelStyle) {
        switch style {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        }
    }

    // MARK: - Recorder Panel Management

    /// Join the one launch-cleanup boundary before Primary begins its idle debounce
    /// reservation. Shortcut monitoring can become live slightly earlier; reserving
    /// directly in the engine would let that reset invalidate the token and turn the
    /// first post-launch single press into a silent no-op.
    func reserveRecordingStartAfterLaunchReset() async -> UUID? {
        await resetOnLaunch()
        return engine?.reserveRecordingStart()
    }

    func toggleRecorderPanel(
        modeId: UUID? = nil,
        stopPasteDestination: RecordingPasteDestination = .primaryCurrentInput,
        reservedStartRequestID: UUID? = nil
    ) async {
        // The shortcut monitor can become live while launch cleanup is still draining.
        // Join that one reset instead of letting an unstructured launch task erase a
        // first recording that has already reserved or opened the microphone.
        await resetOnLaunch()
        guard let engine = engine else { return }

        vippLog.info("toggleRecorderPanel: enter panelVisible=\(self.isRecorderPanelVisible, privacy: .public) state=\(String(describing: engine.recordingState), privacy: .public) modeId=\(modeId?.uuidString ?? "nil", privacy: .public)")

        if let reservedStartRequestID,
           engine.recordingState != .idle {
            // This token came from an idle-only debounce. A different route won the
            // microphone while the timer yielded, so release the token and leave that
            // session untouched; never reinterpret a stale Start as Stop/Cancel.
            engine.cancelRecordingStartReservation(reservedStartRequestID)
            return
        }

        if let reservedStartRequestID,
           !engine.canCommitRecordingStartReservation(reservedStartRequestID) {
            // A reset can invalidate the token without materializing a session.
            // Reject it before showing a panel so a stale debounce completion can
            // never leave an idle recorder bar behind.
            engine.cancelRecordingStartReservation(reservedStartRequestID)
            return
        }

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording, .paused:
                await engine.toggleRecord(
                    modeId: modeId,
                    stopPasteDestination: stopPasteDestination
                )
            case .starting:
                // Pre-recording: a re-press here genuinely cancels a not-yet-started
                // session, so cancelling is correct.
                vippLog.info("toggleRecorderPanel: .starting → cancelRecording")
                await cancelRecording()
            case .transcribing, .enhancing:
                // ═══════════════════════════════════════════════════════════════
                // MULTI-SESSION TRANSITION (2026-06-28, record-while-transcribing).
                //
                // OLD BEHAVIOUR (the 2026-06-20 guard, preserved below for history):
                //   A toggle press while state == .transcribing/.enhancing was IGNORED.
                //   That guard existed because the stop AWAITED the whole pipeline INLINE
                //   on the MainActor; a stray re-entrant toggle during that await would
                //   fall into cancelRecording(), poison the active pipeline id, and throw
                //   away an already-returned 200 (the "transcribing blinks then nothing
                //   pasted / BrokenPipe" regression). So we ignored re-entrant toggles to
                //   protect the in-flight pipeline.
                //
                // WHY THE GUARD IS NOW OBSOLETE:
                //   Transcription no longer runs inline-awaited on the MainActor. STOP now
                //   ENQUEUES the pipeline on the engine's SERIAL transcription queue (a
                //   detached Task chain) and returns immediately. The MainActor is NOT held
                //   during transcription, so the re-entrancy hazard that motivated the guard
                //   is GONE. A toggle press during a background transcription is SAFE.
                //
                // NEW BEHAVIOUR:
                //   Crucially, this branch is only reached if engine.recordingState is
                //   .transcribing/.enhancing — and in the new engine the DERIVED
                //   recordingState reflects the ACTIVE recording session only, falling back
                //   to .idle when nothing is recording. So once a session stops and goes to
                //   the background, recordingState reads .idle and a toggle takes the .idle
                //   branch below to START A NEW SESSION (the whole point of the feature).
                //   This .transcribing/.enhancing branch therefore now only fires in the
                //   narrow window where a session's OWN live state is transcribing AND it's
                //   still the active recording session (effectively never, post-stop). We
                //   handle it by STARTING A NEW SESSION rather than ignoring — record-while-
                //   transcribing is explicitly desired and now race-free.
                // ═══════════════════════════════════════════════════════════════
                vippLog.info("toggleRecorderPanel: toggle during \(String(describing: engine.recordingState), privacy: .public) → START NEW SESSION (record-while-transcribing; serial-queue makes this safe)")
                await engine.toggleRecord(modeId: modeId)
            case .idle:
                // .idle now also covers "a previous session is transcribing in the
                // background but none is actively recording" (derived state falls back to
                // .idle so the record shortcut stays usable). If there are in-flight
                // sessions OR the user is starting fresh, a toggle here STARTS a new
                // recording — UNLESS the assistant is awaiting a follow-up, which takes
                // precedence as before.
                if let reservedStartRequestID {
                    // The idle-only Primary debounce already owns this exact start
                    // token and its FIFO delivery barrier. Commit it once instead of
                    // letting the generic pending-start guard mistake it for a
                    // duplicate press and preserve it forever.
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: engine.assistantSession.canSendFollowUp,
                        reservedStartRequestID: reservedStartRequestID
                    )
                } else if engine.assistantSession.canSendFollowUp {
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else {
                    switch RecorderPanelLifecyclePolicy.idleToggleAction(
                        sessionCount: engine.sessions.count,
                        hasPendingStart: engine.hasPendingRecordingStart,
                        hasCaptureOwner: engine.hasActiveCaptureOwner
                    ) {
                    case .preservePendingStart:
                        // The first press is already progressing through permission,
                        // resource cleanup, or a delivery lease. A second press cannot
                        // stop audio that has not started yet, but it must never hide the
                        // bar and thereby destroy the reserved recording.
                        vippLog.info("toggleRecorderPanel: idle press ignored while recording start owns reservation/capture; preserving bar")
                    case .startRecording:
                    // Background transcription(s) in flight → start ANOTHER recording.
                    await engine.toggleRecord(modeId: modeId)
                    case .dismiss:
                        await dismissRecorderPanel()
                    }
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            guard showRecorderPanel(
                reason: "recording start",
                rearmFailureNotification: true
            ) else {
                if let reservedStartRequestID {
                    engine.cancelRecordingStartReservation(reservedStartRequestID)
                }
                return
            }
            isRecorderPanelVisible = true
            await engine.toggleRecord(
                modeId: modeId,
                reservedStartRequestID: reservedStartRequestID
            )
        }
    }

    /// Genuine Primary double-click: finish the active recording through the
    /// normal transcription pipeline, but select the session's clipboard-only
    /// completion disposition. This never routes through cancel, paste, Return,
    /// or app-specific exact delivery.
    @discardableResult
    func finishRecordingToClipboard(modeId: UUID? = nil) async -> Bool {
        guard let engine,
              isRecorderPanelVisible,
              engine.recordingState.isRecordingOrPaused else {
            return false
        }
        vippLog.info("finishRecordingToClipboard: genuine Primary double-click")
        return await engine.finishActiveRecordingToClipboard(modeId: modeId)
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        // ── MULTI-SESSION VISIBILITY GUARD (2026-06-28) ──
        // The pipeline + delivery paths call dismiss when an individual job finishes. In the
        // multi-session world the panel must STAY VISIBLE while ANY session is still in flight
        // (recording or transcribing) OR the assistant is showing a response — otherwise a
        // finishing background job would yank the bar out from under a still-active recording.
        // We only actually hide when there's genuinely nothing left to show.
        let hasSessions = !engine.sessions.isEmpty
        let hasPendingStart = engine.hasPendingRecordingStart
        let hasCaptureOwner = engine.hasActiveCaptureOwner
        let assistantVisible = engine.assistantSession.isVisible
        if RecorderPanelLifecyclePolicy.shouldKeepVisible(
            sessionCount: engine.sessions.count,
            hasPendingStart: hasPendingStart,
            hasCaptureOwner: hasCaptureOwner,
            assistantVisible: assistantVisible
        ) {
            vippLog.info("dismissRecorderPanel: SUPPRESSED — sessions=\(engine.sessions.count, privacy: .public) pendingStart=\(hasPendingStart, privacy: .public) captureOwner=\(hasCaptureOwner, privacy: .public) assistantVisible=\(assistantVisible, privacy: .public) (keep bar visible)")
            return
        }

        // VIPPDebug: this is the recorder-bar HIDE site. Logging state here tells us
        // WHY the bar vanished. With the guard above, by here there are no sessions and
        // no assistant, so this is a clean post-delivery dismiss.
        vippLog.info("dismissRecorderPanel: HIDE bar (state=\(String(describing: engine.recordingState), privacy: .public))")

        isRecorderPanelVisible = false
        hideRecorderPanel()
        engine.assistantSession.reset()
    }

    // Force-hide the panel regardless of in-flight sessions. Used by the explicit
    // cancel/reset paths which have already torn the sessions down (or want to).
    private func forceDismissRecorderPanel() async {
        guard let engine = engine else { return }
        vippLog.info("forceDismissRecorderPanel: HIDE bar unconditionally (state=\(String(describing: engine.recordingState), privacy: .public))")
        isRecorderPanelVisible = false
        hideRecorderPanel()
        engine.assistantSession.reset()
    }

    func resetOnLaunch() async {
        switch launchResetState {
        case .complete:
            return
        case .running:
            await withCheckedContinuation { continuation in
                launchResetWaiters.append(continuation)
            }
            return
        case .pending:
            launchResetState = .running
        }

        guard let engine = engine else {
            launchResetState = .pending
            let waiters = launchResetWaiters
            launchResetWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        // resetRecordingSession() empties `sessions`, so the guarded dismiss would hide
        // anyway, but force-hide to be unambiguous on launch.
        await forceDismissRecorderPanel()
        launchResetState = .complete
        let waiters = launchResetWaiters
        launchResetWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        // VIPPDebug: explicit cancel site. After Fix above, this should ONLY fire for a
        // genuine user cancel (Esc / close button) or pre-transcription states — NOT
        // from a stray toggle during .transcribing. If you see this while state is
        // .transcribing/.enhancing on a NORMAL dictation, an unintended caller leaked in.
        vippLog.info("cancelRecording: CANCEL requested (state=\(String(describing: engine.recordingState), privacy: .public))")
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStopRecorderForAudioDeviceLossNotification),
            name: .stopRecorderForAudioDeviceLoss,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
    }

    private func setupDisplayEnvironmentNotifications() {
        observeDisplayEnvironmentNotification(
            center: .default,
            name: NSApplication.didChangeScreenParametersNotification
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            observeDisplayEnvironmentNotification(
                center: workspaceCenter,
                name: name
            )
        }
    }

    private func observeDisplayEnvironmentNotification(
        center: NotificationCenter,
        name: Notification.Name
    ) {
        let observer = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // NSWorkspace delivery is not expressed as actor isolation in its API.
            // Queue on the main run loop and make the MainActor hop explicit so Swift 6
            // cannot enter AppKit window code through an off-actor selector thunk.
            Task { @MainActor in
                self?.handleRecorderDisplayEnvironmentChange(notification)
            }
        }
        displayEnvironmentObservers.append(observer)
    }

    private func handleRecorderDisplayEnvironmentChange(_ notification: Notification) {
        guard RecorderPanelPresentationPolicy.shouldRemirror(
            isLogicallyVisible: isRecorderPanelVisible
        ) else { return }

        // Physical display state is authoritative while the HUD owns recorder
        // controls. Re-run the idempotent nonactivating presentation on every relevant
        // system event so a wake, unplug, or rearrangement cannot require a second
        // recording to repair the black bar.
        _ = showRecorderPanel(reason: notification.name.rawValue)
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            // VIPPDebug: explicit dismiss (Esc / DismissMiniRecorderIntent). This IS the
            // intended cancel path for an in-flight transcription, so cancelling here is
            // correct (unlike the re-entrant toggle path, which we now ignore).
            vippLog.info("handleDismissRecorderPanelNotification: explicit dismiss (state=\(String(describing: self.engine?.recordingState), privacy: .public))")
            switch engine?.recordingState {
            case .starting, .recording, .paused, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }

    @objc public func handleStopRecorderForAudioDeviceLossNotification() {
        Task { @MainActor in
            guard let engine else { return }
            switch engine.recordingState {
            case .recording, .paused:
                // Preserve the old device-loss contract: finish the captured audio as
                // a normal Primary current-input result, but never let a delayed event
                // toggle from idle into an unintended new recording.
                await engine.toggleRecord(
                    stopPasteDestination: .primaryCurrentInput
                )
            case .starting:
                // No stable capture exists to finalize yet; safely retain/cancel any
                // partial startup state rather than waiting forever for a vanished mic.
                await cancelRecording()
            case .idle, .transcribing, .enhancing, .busy:
                vippLog.info("audio device loss: explicit stop ignored because no live capture owns the microphone")
            }
        }
    }
}
