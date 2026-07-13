import Foundation
import SwiftUI
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

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            rebuildVisiblePanel(previousStyle: oldValue)
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?

    private weak var engine: VoiceInkEngine?
    private var recorder: Recorder?

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
        setupNotifications()
    }

    // MARK: - Recorder Panel Management

    private func showRecorderPanel() {
        guard let engine = engine, let recorder = recorder else { return }

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
                    // Cancel ("X") button → discard the active recording/transcription
                    // with NO paste, then resume any paused media. cancelRecording()
                    // is the existing clean teardown path (engine.cancelRecording →
                    // recorder.stopRecording → resumeMedia) followed by dismiss.
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
            notchWindowManager?.show()
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
                    // Cancel ("X") button → discard the active recording/transcription
                    // with NO paste, then resume any paused media. Same clean teardown
                    // path as the notch panel above.
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
            miniWindowManager?.show()
        }
    }

    private func hideRecorderPanel() {
        switch recorderPanelStyle {
        case .notch:
            notchWindowManager?.hide()
        case .mini:
            miniWindowManager?.hide()
        }
    }

    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) {
        guard isRecorderPanelVisible else { return }

        switch previousStyle {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(
        modeId: UUID? = nil,
        stopPasteDestination: RecordingPasteDestination = .focusedAtStop
    ) async {
        guard let engine = engine else { return }

        vippLog.info("toggleRecorderPanel: enter panelVisible=\(self.isRecorderPanelVisible, privacy: .public) state=\(String(describing: engine.recordingState), privacy: .public) modeId=\(modeId?.uuidString ?? "nil", privacy: .public)")

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording:
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
                SoundManager.shared.playStartSound()
                await engine.toggleRecord(modeId: modeId)
            case .idle:
                // .idle now also covers "a previous session is transcribing in the
                // background but none is actively recording" (derived state falls back to
                // .idle so the record shortcut stays usable). If there are in-flight
                // sessions OR the user is starting fresh, a toggle here STARTS a new
                // recording — UNLESS the assistant is awaiting a follow-up, which takes
                // precedence as before.
                if engine.assistantSession.canSendFollowUp {
                    SoundManager.shared.playStartSound()
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else if !engine.sessions.isEmpty {
                    // Background transcription(s) in flight → start ANOTHER recording.
                    SoundManager.shared.playStartSound()
                    await engine.toggleRecord(modeId: modeId)
                } else {
                    await dismissRecorderPanel()
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            SoundManager.shared.playStartSound()
            isRecorderPanelVisible = true
            await engine.toggleRecord(modeId: modeId)
        }
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
        let assistantVisible = engine.assistantSession.isVisible
        if hasSessions || assistantVisible {
            vippLog.info("dismissRecorderPanel: SUPPRESSED — sessions=\(engine.sessions.count, privacy: .public) assistantVisible=\(assistantVisible, privacy: .public) (keep bar visible)")
            return
        }

        // VIPPDebug: this is the recorder-bar HIDE site. Logging state here tells us
        // WHY the bar vanished. With the guard above, by here there are no sessions and
        // no assistant, so this is a clean post-delivery dismiss.
        vippLog.info("dismissRecorderPanel: HIDE bar (state=\(String(describing: engine.recordingState), privacy: .public))")

        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    // Force-hide the panel regardless of in-flight sessions. Used by the explicit
    // cancel/reset paths which have already torn the sessions down (or want to).
    private func forceDismissRecorderPanel() async {
        guard let engine = engine else { return }
        vippLog.info("forceDismissRecorderPanel: HIDE bar unconditionally (state=\(String(describing: engine.recordingState), privacy: .public))")
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        // resetRecordingSession() empties `sessions`, so the guarded dismiss would hide
        // anyway, but force-hide to be unambiguous on launch.
        await forceDismissRecorderPanel()
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
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
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
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
