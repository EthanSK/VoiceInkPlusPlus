import Foundation
import AppKit
import os

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            refreshShortcutMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }
    
    private var engine: VoiceInkEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    // MARK: - Helper Properties
    private var canHandleShortcutAction: Bool {
        Self.canHandleShortcutAction(for: engine.recordingState)
    }
    
    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?

    // ── Event-tap health monitoring (idle-miss bug fix) ──────────────────────────
    // After the Mac has been idle for a while (App Nap throttling the main run loop) or
    // after a system sleep/wake, the global record-hotkey CGEventTap can be left disabled.
    // The reactive in-callback re-enable only fires once an event reaches the tap — so the
    // FIRST press after idle gets eaten re-arming it instead of starting a recording
    // (Ethan: "I have to press record ~4 times"). We proactively re-arm the tap on
    // wake/unlock and via a low-frequency watchdog so the next press always works.
    private var eventTapHealthObservers: [NSObjectProtocol] = []
    private var eventTapWatchdog: Timer?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingShortcutManager")

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"
        
        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing &&
        recordingState != .enhancing &&
        recordingState != .busy
    }

    init(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId, stopPasteDestination in
                await recorderUIManager.toggleRecorderPanel(
                    modeId: modeId,
                    stopPasteDestination: stopPasteDestination
                )
            },
            toggleRecordingPause: {
                await engine.toggleRecordingPause()
            },
            setActiveRecordingCompletionDisposition: { disposition in
                engine.setActiveRecordingCompletionDisposition(disposition)
            },
            setActiveRecordingAutoSendDisposition: { disposition in
                engine.setActiveRecordingAutoSendDisposition(disposition)
            },
            finishRecordingToClipboard: { modeId in
                await recorderUIManager.finishRecordingToClipboard(modeId: modeId)
            },
            finishRecordingWithoutAutoSend: { modeId in
                await recorderUIManager.finishRecordingWithoutAutoSend(modeId: modeId)
            },
            pendingClipboardOnlySessionID: { engine.pendingClipboardOnlySessionID },
            selectPendingClipboardOnlyCompletion: { sessionID in
                engine.selectPendingClipboardOnlyCompletion(sessionID: sessionID)
            },
            applyPendingPrimaryCompletionGesture: { sessionID, action in
                engine.applyPendingPrimaryCompletionGesture(
                    sessionID: sessionID,
                    action: action
                )
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            reserveRecordingStart: {
                await recorderUIManager.reserveRecordingStartAfterLaunchReset()
            },
            cancelRecordingStartReservation: { requestID in
                engine.cancelRecordingStartReservation(requestID)
            },
            startReservedRecording: { requestID, modeId in
                await recorderUIManager.toggleRecorderPanel(
                    modeId: modeId,
                    reservedStartRequestID: requestID
                )
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }

        // Start proactively re-arming the hotkey event tap on wake/unlock + via a watchdog
        // so a long idle period can't leave the record hotkey dead on the first press.
        setupEventTapHealthMonitoring()
    }

    // MARK: - Event-tap health monitoring (idle-miss bug fix)

    private func setupEventTapHealthMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        // System wake from sleep, displays waking, and the login session becoming active
        // are all moments when the CGEventTap may have been disabled by macOS. Re-check it.
        let notifications: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for name in notifications {
            let observer = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Hop to the MainActor explicitly: NSWorkspace delivers on .main but the
                // closure isn't statically @MainActor-isolated.
                MainActor.assumeIsolated {
                    self?.shortcutMonitor.ensureEventTapHealthy(reason: name.rawValue)
                }
            }
            eventTapHealthObservers.append(observer)
        }

        // Belt-and-suspenders watchdog: every 15s confirm the tap is still enabled. This
        // catches any disable that didn't coincide with a wake notification. AppNapGuard
        // keeps the main run loop alive so this timer actually fires while idle. Cheap:
        // CGEvent.tapIsEnabled is a fast local check, no re-install unless actually needed.
        let watchdog = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shortcutMonitor.ensureEventTapHealthy(reason: "watchdog")
            }
        }
        // .common mode so it keeps firing during menu tracking / modal run loops.
        RunLoop.main.add(watchdog, forMode: .common)
        eventTapWatchdog = watchdog

        logger.notice("Event-tap health monitoring active (wake/unlock observers + 15s watchdog)")
    }

    private func teardownEventTapHealthMonitoring() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in eventTapHealthObservers {
            workspaceCenter.removeObserver(observer)
        }
        eventTapHealthObservers = []
        eventTapWatchdog?.invalidate()
        eventTapWatchdog = nil
    }

    private func refreshShortcutMonitoring() {
        removeAllMonitoring()
        
        refreshShortcutMonitor()
        setupMiddleClickMonitoring()
    }
    
    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000 // ms to ns
                    try await Task.sleep(nanoseconds: delay)
                    
                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }
                    
                    Task { @MainActor in
                        guard self.canHandleShortcutAction else { return }
                        await self.recorderUIManager.toggleRecorderPanel()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }
    
    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut = secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    guard let mode = self.recordingMode(for: action) else { return }
                    self.logger.info("Recording shortcut key-down action=\(String(describing: action), privacy: .public) mode=\(mode.rawValue, privacy: .public) recordingState=\(String(describing: self.engine.recordingState), privacy: .public) route=primaryCurrentInput")
                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleKeyUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            },
            onModifierOnlySequenceProgress: { [weak self] action, eventTime in
                MainActor.assumeIsolated {
                    guard let self,
                          action == .primaryRecording,
                          self.engine.recordingState == .idle else {
                        return
                    }
                    // Read only. Partial modifiers and every release still pass to the
                    // foreground app unchanged; this merely preserves the exact
                    // composer before Electron transiently reports an ancestor at the
                    // completed Shift-Control-Option chord.
                    FocusLockService.shared
                        .stageRecordingStartInputBeforeShortcutCompletion(
                            eventTime: eventTime
                        )
                }
            },
            onNextTrackKeyDown: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    // Next owns a different physical gesture and destination route.
                    // Cancel the delayed single-Primary decision first so it cannot
                    // fire after Next has already stopped the same recording.
                    self.shortcutModeHandler.cancelPendingPrimaryDecisions()

                    if self.engine.recordingState.isRecordingOrPaused,
                       self.recorderUIManager.isRecorderPanelVisible {
                        self.logger.info("Next Track key-down consumed recordingState=\(String(describing: self.engine.recordingState), privacy: .public) route=recordingStart")
                        Task { @MainActor [weak self] in
                            await self?.recorderUIManager.toggleRecorderPanel(
                                stopPasteDestination: .recordingStart
                            )
                        }
                        return true // Consume the entire press so the recording-start stop never also advances media.
                    }

                    switch self.engine.retargetMostRecentPendingTranscriptionToFocusedInput() {
                    case .retargeted:
                        self.logger.info("Next Track key-down consumed route=focusedDuringTranscription result=retargeted")
                        return true
                    case .noFocusedInput:
                        self.logger.info("Next Track key-down consumed route=focusedDuringTranscription result=noFocusedInput targetUnchanged=true")
                        return true
                    case .noPendingTranscription:
                        if Self.shouldConsumeNextTrackWithoutEligibleRoute(
                            isRecorderPanelVisible:
                                self.recorderUIManager.isRecorderPanelVisible
                        ) {
                            // The visible recorder bar is the user-facing ownership
                            // boundary. A session may already have latched or crossed
                            // its delivery cutoff, but leaking this physical press to
                            // Music would turn an attempted VoiceInk++ action into an
                            // unrelated Next Song action.
                            self.logger.info("Next Track key-down consumed because the recorder panel is visible, but no session remains eligible for a destination change")
                            return true
                        }
                        self.logger.info("Next Track key-down passed through because no recording or retargetable transcription is active")
                        return false
                    }
                }
            }
        )
    }

    static func shouldConsumeNextTrackWithoutEligibleRoute(
        isRecorderPanelVisible: Bool
    ) -> Bool {
        // An ineligible press is intentionally a consumed no-op until the black
        // recorder/transcription bar closes. Internal timing must never decide
        // whether Ethan's latch attempt unexpectedly advances media.
        isRecorderPanelVisible
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openHistoryWindow:
            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: engine.modelContext.container,
                engine: engine
            )
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()
        
        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()
        
        shortcutModeHandler.reset()
    }
    
    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured = primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured = secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }
    
    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }
    
    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            teardownEventTapHealthMonitoring()
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

/// Pure timing state for Primary presses while no recording owns the microphone.
///
/// Starting capture immediately makes an accidental double-click briefly create a
/// session, pause media, and enter the cancellation path. Delay only the idle start:
/// click one reserves the forthcoming capture, click two inside the same bounded
/// window cancels that reservation, and extra clicks in the consumed burst are
/// ignored. Recording-time stop/clipboard/pause classification remains entirely in
/// `PrimaryRecordingPressCoordinator` below.
struct PrimaryIdleStartPressCoordinator {
    enum Decision: Equatable {
        case deferStart(generation: Int)
        case cancelPendingStart
        case continuePendingCompletionGesture(generation: Int)
        case finishPendingCompletionWithoutAutoSend(generation: Int)
        case ignoreCompletedDoublePress
        case ignoreCompletedQuadruplePress
        case performOverdueStart
    }

    private struct PendingStart {
        let eventTime: TimeInterval
        let generation: Int
    }

    private struct PendingCompletionContinuation {
        let eventTime: TimeInterval
        let generation: Int
        let completedPressCount: Int
    }

    let startDecisionInterval: TimeInterval
    let multiPressContinuationInterval: TimeInterval
    private var nextGeneration = 0
    private var pendingStart: PendingStart?
    private var completedDoublePressAt: TimeInterval?
    private var pendingCompletionContinuation: PendingCompletionContinuation?
    private var completedQuadruplePressAt: TimeInterval?

    var hasPendingStart: Bool {
        pendingStart != nil
    }

    func isPendingStart(generation: Int) -> Bool {
        pendingStart?.generation == generation
    }

    init(
        startDecisionInterval: TimeInterval,
        multiPressContinuationInterval: TimeInterval? = nil
    ) {
        self.startDecisionInterval = startDecisionInterval
        self.multiPressContinuationInterval = multiPressContinuationInterval
            ?? startDecisionInterval
    }

    mutating func registerPress(eventTime: TimeInterval) -> Decision {
        if let pendingCompletionContinuation {
            let elapsed = eventTime - pendingCompletionContinuation.eventTime
            if elapsed >= 0, elapsed <= multiPressContinuationInterval {
                switch pendingCompletionContinuation.completedPressCount {
                case 2:
                    self.pendingCompletionContinuation = PendingCompletionContinuation(
                        eventTime: eventTime,
                        generation: pendingCompletionContinuation.generation,
                        completedPressCount: 3
                    )
                    return .continuePendingCompletionGesture(
                        generation: pendingCompletionContinuation.generation
                    )
                case 3:
                    self.pendingCompletionContinuation = nil
                    completedQuadruplePressAt = eventTime
                    return .finishPendingCompletionWithoutAutoSend(
                        generation: pendingCompletionContinuation.generation
                    )
                default:
                    break
                }
            }
            self.pendingCompletionContinuation = nil
        }

        if let completedQuadruplePressAt {
            let elapsed = eventTime - completedQuadruplePressAt
            if elapsed >= 0, elapsed <= multiPressContinuationInterval {
                return .ignoreCompletedQuadruplePress
            }
            self.completedQuadruplePressAt = nil
        }

        if let completedDoublePressAt {
            let elapsed = eventTime - completedDoublePressAt
            if elapsed >= 0, elapsed <= startDecisionInterval {
                return .ignoreCompletedDoublePress
            }
            self.completedDoublePressAt = nil
        }

        if let pendingStart {
            let elapsed = eventTime - pendingStart.eventTime
            self.pendingStart = nil
            if elapsed >= 0, elapsed <= startDecisionInterval {
                completedDoublePressAt = eventTime
                return .cancelPendingStart
            }
            completedDoublePressAt = nil
            // The sleep task normally commits first. If MainActor scheduling is
            // delayed, preserve click one's promised start instead of silently
            // reinterpreting a slow second click as cancellation.
            return .performOverdueStart
        }

        nextGeneration += 1
        pendingStart = PendingStart(
            eventTime: eventTime,
            generation: nextGeneration
        )
        return .deferStart(generation: nextGeneration)
    }

    /// Only a click pair already bound to a real pending transcription may continue
    /// toward the four-click no-auto-send route. With no eligible result, idle click
    /// three retains the original consumed-double behavior and never gains a meaning.
    mutating func armPendingCompletionContinuation() -> Bool {
        guard let completedDoublePressAt else { return false }
        self.completedDoublePressAt = nil
        pendingCompletionContinuation = PendingCompletionContinuation(
            eventTime: completedDoublePressAt,
            generation: nextGeneration,
            completedPressCount: 2
        )
        return true
    }

    mutating func consumeDeferredStart(generation: Int) -> Bool {
        guard pendingStart?.generation == generation else { return false }
        pendingStart = nil
        return true
    }

    mutating func reset() {
        pendingStart = nil
        completedDoublePressAt = nil
        pendingCompletionContinuation = nil
        completedQuadruplePressAt = nil
    }
}

/// Pure timing state for the Primary button's recording-time click gesture.
///
/// The first press cannot stop immediately because it is indistinguishable from
/// the first half of a double press. It therefore owns one bounded deferred
/// normal stop. A matching second press consumes that pending stop and begins a
/// deferred clipboard-only finish; it cannot finalize immediately because a third
/// consecutive press in the same macOS-bounded sequence means Pause instead. That
/// third press also arms one full-system-interval continuation: a fourth press
/// finalizes the same session through normal Primary paste with auto-send suppressed.
/// A
/// press while already paused waits through only the short second-press window: one
/// press resumes, while two presses finish the same session as clipboard-only.
/// Once an interval expires, the next press begins a fresh gesture, so two separate
/// double-clicks can never be bridged into a triple-click. This coordinator never
/// chooses a paste target; the eventual single stop remains `.primaryCurrentInput`.
struct PrimaryRecordingPressCoordinator {
    // Ethan's global macOS double-click preference is intentionally generous
    // (0.8s), but applying that entire interval to a recording stop makes every
    // ordinary Primary stop feel stalled. Multi-click actions are deliberate mouse
    // gestures, so retain faster system preferences while capping only this
    // VoiceInk++ first-to-second decision window at a responsive interval.
    static let maximumSecondPressInterval: TimeInterval = 0.45

    // Karabiner maps Corsair F19 and both Razer DPI controls (F21/F22) to the
    // same modifier-only Primary chord after their physical releases. When two
    // controls are released together it can therefore emit two complete chords,
    // but its exclusive HID grab means VoiceInk++ cannot recover which control
    // produced either one. Coalesce only a mechanically near-simultaneous burst:
    // this cap stays far below a deliberate double-click, whose second press must
    // still reach the clipboard/pause coordinator, and click three must still
    // reach the pause route.
    static let maximumDuplicatePrimaryChordInterval: TimeInterval = 0.09

    static func secondPressInterval(
        systemDoubleClickInterval: TimeInterval
    ) -> TimeInterval {
        min(systemDoubleClickInterval, maximumSecondPressInterval)
    }

    /// Once click two has already canceled the deferred normal stop, there is no
    /// stop-latency cost to honoring the user's real macOS multi-click interval for
    /// click three. Ethan's current system interval is 0.8s; using the 0.45s normal-
    /// stop cap for this continuation made a deliberate triple unnecessarily harsh.
    static func triplePressContinuationInterval(
        systemDoubleClickInterval: TimeInterval
    ) -> TimeInterval {
        systemDoubleClickInterval
    }

    static func duplicatePrimaryChordInterval(
        normalStopDecisionInterval: TimeInterval
    ) -> TimeInterval {
        min(
            maximumDuplicatePrimaryChordInterval,
            normalStopDecisionInterval / 3
        )
    }

    enum Decision: Equatable {
        case startOrCancelImmediately
        case deferNormalStop(generation: Int)
        case deferPausedResume(generation: Int)
        case deferClipboardFinish(generation: Int)
        case finishPausedClipboardImmediately
        case togglePause
        case finishWithoutAutoSend
        case ignoreCompletedGesture
        case performOverdueNormalStop
        case performOverduePausedResume
        case performOverdueClipboardFinish
    }

    private struct PendingStop {
        let eventTime: TimeInterval
        let generation: Int
    }

    private struct PendingClipboardFinish {
        let eventTime: TimeInterval
        let generation: Int
    }

    private struct PendingPausedResume {
        let eventTime: TimeInterval
        let generation: Int
    }

    private struct PendingNoAutoSendFinish {
        let eventTime: TimeInterval
    }

    let normalStopDecisionInterval: TimeInterval
    let triplePressContinuationInterval: TimeInterval
    private var nextGeneration = 0
    private var pendingStop: PendingStop?
    private var pendingPausedResume: PendingPausedResume?
    private var pendingClipboardFinish: PendingClipboardFinish?
    private var pendingNoAutoSendFinish: PendingNoAutoSendFinish?
    private var completedMultiPressAt: TimeInterval?

    init(doublePressInterval: TimeInterval) {
        self.normalStopDecisionInterval = doublePressInterval
        self.triplePressContinuationInterval = doublePressInterval
    }

    init(
        normalStopDecisionInterval: TimeInterval,
        triplePressContinuationInterval: TimeInterval
    ) {
        self.normalStopDecisionInterval = normalStopDecisionInterval
        self.triplePressContinuationInterval = triplePressContinuationInterval
    }

    var hasPendingNormalStop: Bool {
        pendingStop != nil
    }

    var hasPendingClipboardFinish: Bool {
        pendingClipboardFinish != nil
    }

    var hasPendingPausedResume: Bool {
        pendingPausedResume != nil
    }

    var hasPendingNoAutoSendFinish: Bool {
        pendingNoAutoSendFinish != nil
    }

    mutating func registerPress(
        recordingState: RecordingState,
        eventTime: TimeInterval
    ) -> Decision {
        if let pendingNoAutoSendFinish {
            let elapsed = eventTime - pendingNoAutoSendFinish.eventTime
            self.pendingNoAutoSendFinish = nil
            if elapsed >= 0, elapsed <= triplePressContinuationInterval {
                completedMultiPressAt = eventTime
                return .finishWithoutAutoSend
            }
            // Pause already committed at click three. Once its full continuation
            // interval expires, this press is a fresh paused gesture below.
        }

        if let completedMultiPressAt {
            let elapsed = eventTime - completedMultiPressAt
            if elapsed >= 0, elapsed <= normalStopDecisionInterval {
                return .ignoreCompletedGesture
            }
            self.completedMultiPressAt = nil
        }

        if recordingState == .paused {
            if let pendingPausedResume {
                let elapsed = eventTime - pendingPausedResume.eventTime
                self.pendingPausedResume = nil
                if elapsed >= 0, elapsed <= normalStopDecisionInterval {
                    // Paused capture already expresses the triple-click action, so
                    // click two can finalize Won't paste immediately. Suppress any
                    // bounce/extra press after that consumed double gesture.
                    completedMultiPressAt = eventTime
                    return .finishPausedClipboardImmediately
                }
                // The timer should normally have resumed capture already. If the
                // MainActor was delayed, honor the promised single-press Resume
                // instead of reinterpreting a slow second press as Won't paste.
                return .performOverduePausedResume
            }

            // A press immediately after the recording-time triple must begin a new
            // paused gesture rather than inherit click four from the old sequence.
            pendingStop = nil
            pendingClipboardFinish = nil
            nextGeneration += 1
            pendingPausedResume = PendingPausedResume(
                eventTime: eventTime,
                generation: nextGeneration
            )
            return .deferPausedResume(generation: nextGeneration)
        }

        guard recordingState == .recording else {
            resetGesture()
            return .startOrCancelImmediately
        }

        if let pendingClipboardFinish {
            let elapsed = eventTime - pendingClipboardFinish.eventTime
            self.pendingClipboardFinish = nil
            if elapsed >= 0, elapsed <= triplePressContinuationInterval {
                pendingNoAutoSendFinish = PendingNoAutoSendFinish(
                    eventTime: eventTime
                )
                return .togglePause
            }
            // The sleep task should normally have committed the double-click
            // clipboard finish. If MainActor was delayed, preserve that promised
            // action instead of reinterpreting a late third press as Pause.
            return .performOverdueClipboardFinish
        }

        if let pendingStop {
            let elapsed = eventTime - pendingStop.eventTime
            self.pendingStop = nil
            if elapsed >= 0, elapsed <= normalStopDecisionInterval {
                nextGeneration += 1
                pendingClipboardFinish = PendingClipboardFinish(
                    eventTime: eventTime,
                    generation: nextGeneration
                )
                return .deferClipboardFinish(generation: nextGeneration)
            }
            // The sleep task should normally have committed this already. If the
            // MainActor was delayed, fail toward the promised single-stop action
            // instead of silently converting a slow pair into a pause.
            return .performOverdueNormalStop
        }

        nextGeneration += 1
        pendingStop = PendingStop(
            eventTime: eventTime,
            generation: nextGeneration
        )
        return .deferNormalStop(generation: nextGeneration)
    }

    mutating func consumeDeferredStop(generation: Int) -> Bool {
        guard pendingStop?.generation == generation else { return false }
        pendingStop = nil
        return true
    }

    mutating func consumeDeferredPausedResume(generation: Int) -> Bool {
        guard pendingPausedResume?.generation == generation else { return false }
        pendingPausedResume = nil
        return true
    }

    mutating func consumeDeferredClipboardFinish(generation: Int) -> Bool {
        guard pendingClipboardFinish?.generation == generation else { return false }
        pendingClipboardFinish = nil
        return true
    }

    mutating func cancelPendingStop() {
        resetGesture()
    }

    private mutating func resetGesture() {
        pendingStop = nil
        pendingPausedResume = nil
        pendingClipboardFinish = nil
        pendingNoAutoSendFinish = nil
        completedMultiPressAt = nil
    }
}

/// Filters only the second complete Primary chord in one mechanically
/// near-simultaneous burst. It deliberately anchors on the last accepted chord,
/// not a rejected duplicate, so a burst cannot keep extending the suppression
/// window and consume a later intentional click.
struct PrimaryShortcutDuplicateChordCoalescer {
    let interval: TimeInterval
    private(set) var lastAcceptedEventTime: TimeInterval?

    mutating func shouldCoalesce(
        action: ShortcutAction,
        mode: RecordingShortcutManager.Mode,
        eventTime: TimeInterval
    ) -> Bool {
        guard action == .primaryRecording, mode == .toggle else {
            return false
        }

        if let lastAcceptedEventTime {
            let elapsed = eventTime - lastAcceptedEventTime
            if elapsed >= 0, elapsed < interval {
                return true
            }
        }

        lastAcceptedEventTime = eventTime
        return false
    }

    mutating func reset() {
        lastAcceptedEventTime = nil
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?, RecordingPasteDestination) async -> Void
    private let toggleRecordingPause: @MainActor () async -> Bool
    private let setActiveRecordingCompletionDisposition: @MainActor (
        RecordingCompletionDisposition
    ) -> Void
    private let setActiveRecordingAutoSendDisposition: @MainActor (
        RecordingAutoSendDisposition
    ) -> Void
    private let finishRecordingToClipboard: @MainActor (UUID?) async -> Bool
    private let finishRecordingWithoutAutoSend: @MainActor (UUID?) async -> Bool
    private let pendingClipboardOnlySessionID: @MainActor () -> UUID?
    private let selectPendingClipboardOnlyCompletion: @MainActor (UUID) -> Bool
    private let applyPendingPrimaryCompletionGesture: @MainActor (
        UUID,
        PendingPrimaryCompletionGestureAction
    ) -> Bool
    private let cancelRecording: @MainActor () async -> Void
    private let reserveRecordingStart: @MainActor () async -> UUID?
    private let cancelRecordingStartReservation: @MainActor (UUID) -> Void
    private let startReservedRecording: (@MainActor (UUID, UUID?) async -> Void)?
    // Feature A (2026-06-21): resolve the active Shortcut for an action so we can read
    // whether it's modifier-only + its required modifier mask. See the STOP-hold logic.
    private let shortcutForAction: @MainActor (ShortcutAction) -> Shortcut?

    // VIPPDebug: VoiceInk++-only diagnostic logger (NOT the base voiceink logger).
    // Surfaces the press lifecycle — key-down capture, long-press timer arm/fire,
    // key-up short-vs-long resolution — so we can correlate the shortcut handler's
    // view of the press against FocusLockService's lock lifecycle in one stream.
    // Subsystem matches FocusLockService.vippLog so a single predicate catches both.
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    private var shortcutPressStartTime: TimeInterval?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?

    // Feature A (new START→STOP model): remembers whether the CURRENTLY-held press
    // was the one that STARTED the recording (true) or the one STOPPING it (false).
    // Computed once on key-down (from startsFreshRecording) and read on key-up so the
    // key-up handler knows which side it is:
    //   • START key-up  → leave the captured candidate ALONE (it must persist).
    //   • STOP  key-up  → resolve short-tap (clearCandidate) vs long-hold (keep; the
    //                     stop-hold timer already promoted it).
    private var currentPressStartedRecording = false

    // Feature A (modifier-only STOP-hold, 2026-06-21): captured at the STOP key-down so
    // the threshold timer + the key-up handler know how to resolve the gesture.
    //   • currentStopIsModifierOnly: is the active record shortcut modifier-only (⇧⌃⌥)?
    //     If so, the ~0.1s spurious key-up must NOT cancel the timer or decide the
    //     gesture — the timer decides by LIVE modifier state instead.
    //   • currentStopRequiredModifiers: the required modifier mask of that shortcut, read
    //     from its Shortcut definition (so we don't hardcode ⇧⌃⌥). Used at threshold to
    //     ask NSEvent.modifierFlags "are these still physically held?".
    private var currentStopIsModifierOnly = false
    private var currentStopRequiredModifiers: NSEvent.ModifierFlags = []

    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var lastShortcutPressTime: Date?
    private var primaryIdleStartCoordinator: PrimaryIdleStartPressCoordinator
    private var primaryPressCoordinator: PrimaryRecordingPressCoordinator
    private var primaryDuplicateChordCoalescer: PrimaryShortcutDuplicateChordCoalescer
    private var primaryStartDecisionTask: Task<Void, Never>?
    private var pendingPrimaryCompletionTarget: (generation: Int, sessionID: UUID)?
    private var pendingPrimaryStartReservation: (
        generation: Int,
        requestID: UUID,
        modeId: UUID?
    )?
    private var primaryGestureDecisionTask: Task<Void, Never>?
    private var primaryPauseTransitionTask: Task<Bool, Never>?
    private var suppressPrimaryIdlePressUntil: TimeInterval?

    // Feature A (focus lock) — NEW START→STOP DECISION MODEL (2026-06-21).
    //
    // WHY THIS CHANGED: Ethan's actual gesture is a modifier-only TOGGLE (⇧⌃⌥ in
    // toggle mode): he TAPS to start recording and TAPS again to stop. He does NOT
    // push-to-talk hold. Under the OLD model the long-press "lock the start field"
    // decision was made on the START press — but in toggle+tap usage the start press
    // is a quick tap, so the lock NEVER armed and his "paste into the field I started
    // in" workflow was impossible to trigger.
    //
    // NEW MODEL: the lock decision moves to the STOP press.
    //   • START press: ALWAYS captureCandidate() (snapshot the focused field) and
    //     KEEP that candidate alive for the whole recording. No lock armed yet, no
    //     timer on start. The candidate persists — it is NOT cleared on start key-up.
    //   • STOP press: decide long-hold vs short-tap.
    //       - long-hold (combo held ≥ longPressThreshold) → promoteToLock() so
    //         delivery restores focus to the captured candidate (paste into original).
    //       - short-tap → clearCandidate(), no lock, normal paste at cursor.
    //
    // TIMING SUBTLETY (toggle mode): the STOP fires on key-DOWN — recording stops and
    // transcription begins IMMEDIATELY on the stop key-down, before we know whether
    // it's a hold or a tap (the hold is only known later, at the stop key-up, or when
    // the threshold timer fires). So on the STOP key-down we ARM this timer; if the
    // combo is still held at longPressThreshold it fires and calls promoteToLock().
    // Transcription takes ~1–2s and the paste waits for it, so this timer normally
    // fires BEFORE delivery → the lock flag is set in time for restoreFocusToLock().
    // This same Task field is reused for that stop-side timer (only one is ever live).
    private var longPressLockTask: Task<Void, Never>?

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?, RecordingPasteDestination) async -> Void,
        toggleRecordingPause: @escaping @MainActor () async -> Bool = { false },
        setActiveRecordingCompletionDisposition: @escaping @MainActor (
            RecordingCompletionDisposition
        ) -> Void = { _ in },
        setActiveRecordingAutoSendDisposition: @escaping @MainActor (
            RecordingAutoSendDisposition
        ) -> Void = { _ in },
        finishRecordingToClipboard: @escaping @MainActor (UUID?) async -> Bool = { _ in false },
        finishRecordingWithoutAutoSend: @escaping @MainActor (UUID?) async -> Bool = { _ in false },
        pendingClipboardOnlySessionID: @escaping @MainActor () -> UUID? = { nil },
        selectPendingClipboardOnlyCompletion: @escaping @MainActor (UUID) -> Bool = { _ in false },
        applyPendingPrimaryCompletionGesture: @escaping @MainActor (
            UUID,
            PendingPrimaryCompletionGestureAction
        ) -> Bool = { _, _ in false },
        cancelRecording: @escaping @MainActor () async -> Void,
        reserveRecordingStart: @escaping @MainActor () async -> UUID? = { UUID() },
        cancelRecordingStartReservation: @escaping @MainActor (UUID) -> Void = { _ in },
        startReservedRecording: (@MainActor (UUID, UUID?) async -> Void)? = nil,
        shortcutForAction: @escaping @MainActor (ShortcutAction) -> Shortcut? = { _ in nil },
        primaryDoublePressInterval: TimeInterval = PrimaryRecordingPressCoordinator.secondPressInterval(
            systemDoubleClickInterval: NSEvent.doubleClickInterval
        ),
        primaryStartDebounceInterval: TimeInterval? = nil,
        primaryTriplePressInterval: TimeInterval = PrimaryRecordingPressCoordinator.triplePressContinuationInterval(
            systemDoubleClickInterval: NSEvent.doubleClickInterval
        ),
        primaryDuplicateChordInterval: TimeInterval? = nil
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.toggleRecordingPause = toggleRecordingPause
        self.setActiveRecordingCompletionDisposition = setActiveRecordingCompletionDisposition
        self.setActiveRecordingAutoSendDisposition = setActiveRecordingAutoSendDisposition
        self.finishRecordingToClipboard = finishRecordingToClipboard
        self.finishRecordingWithoutAutoSend = finishRecordingWithoutAutoSend
        self.pendingClipboardOnlySessionID = pendingClipboardOnlySessionID
        self.selectPendingClipboardOnlyCompletion = selectPendingClipboardOnlyCompletion
        self.applyPendingPrimaryCompletionGesture = applyPendingPrimaryCompletionGesture
        self.cancelRecording = cancelRecording
        self.reserveRecordingStart = reserveRecordingStart
        self.cancelRecordingStartReservation = cancelRecordingStartReservation
        self.startReservedRecording = startReservedRecording
        self.shortcutForAction = shortcutForAction
        self.primaryIdleStartCoordinator = PrimaryIdleStartPressCoordinator(
            startDecisionInterval: primaryStartDebounceInterval ?? primaryDoublePressInterval,
            multiPressContinuationInterval: primaryTriplePressInterval
        )
        self.primaryPressCoordinator = PrimaryRecordingPressCoordinator(
            normalStopDecisionInterval: primaryDoublePressInterval,
            triplePressContinuationInterval: primaryTriplePressInterval
        )
        self.primaryDuplicateChordCoalescer = PrimaryShortcutDuplicateChordCoalescer(
            interval: primaryDuplicateChordInterval ??
                PrimaryRecordingPressCoordinator.duplicatePrimaryChordInterval(
                    normalStopDecisionInterval: primaryDoublePressInterval
                )
        )
    }

    func reset() {
        cancelPendingPrimaryDecisions()
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        currentPressStartedRecording = false
        currentStopIsModifierOnly = false
        currentStopRequiredModifiers = []
        // Feature A (focus lock): a full reset (monitor restart, accidental-start
        // cancel) must tear down any pending stop-hold timer AND any captured/locked
        // focus so a stale lock can't leak into the next recording.
        longPressLockTask?.cancel()
        longPressLockTask = nil
        FocusLockService.shared.setStopHoldDecisionPending(false)
        FocusLockService.shared.clearLock()
    }

    func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        let isPrimaryToggleGesture =
            action == .primaryRecording && mode == .toggle
        if Self.shouldApplyShortcutPressCooldown(
            action: action,
            mode: mode
        ),
           let lastTrigger = lastShortcutPressTime,
           Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown {
            return
        }

        guard !isShortcutPressed else {
            return
        }

        // Held-chord repeats are already rejected by ShortcutMonitor and the
        // isShortcutPressed guard. This separate boundary handles a second full
        // chord produced when equivalent physical Primary controls are released
        // together. It must run before PrimaryRecordingPressCoordinator so the
        // duplicate can neither cancel `.starting` nor turn one intended stop
        // into pause. The narrow event-tap-time interval leaves ordinary single,
        // deliberate double, and genuine triple routes structurally unchanged.
        if primaryDuplicateChordCoalescer.shouldCoalesce(
            action: action,
            mode: mode,
            eventTime: eventTime
        ) {
            let previous = primaryDuplicateChordCoalescer.lastAcceptedEventTime ?? eventTime
            let elapsedMilliseconds = max(0, eventTime - previous) * 1_000
            vippLog.info("shortcut: coalesced near-simultaneous duplicate Primary chord dtMs=\(elapsedMilliseconds, privacy: .public) windowMs=\(self.primaryDuplicateChordCoalescer.interval * 1_000, privacy: .public)")
            return
        }

        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutCanCancelAccidentalStart = canCurrentShortcutPressCancelAccidentalStart
        lastShortcutPressTime = Date()
        shortcutPressStartTime = eventTime

        if isPrimaryToggleGesture {
            await handlePrimaryToggleKeyDown(
                eventTime: eventTime,
                modeId: modeId
            )
            return
        }

        if mode == .toggle {
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId, .primaryCurrentInput)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId, .primaryCurrentInput)
            }
            return
        }

        // Feature A (focus lock): does THIS key-down START a fresh recording?
        // Only a key-down that begins recording (recorder not currently visible,
        // and we're not toggling-off a hands-free session) is the START press.
        // The STOP press has startsFreshRecording == false (recorder is visible /
        // we're toggling off a hands-free session) and is handled further down.
        let startsFreshRecording = !isRecorderVisible() && !isHandsFreeRecording
        // Remember which side this press is, for the matching key-up resolution.
        currentPressStartedRecording = startsFreshRecording
        // Clear the STOP-side modifier-only flags up-front so a prior STOP's values can
        // never leak into a fresh START press; the STOP branch recomputes them below.
        currentStopIsModifierOnly = false
        currentStopRequiredModifiers = []
        if startsFreshRecording {
            // START PRESS (new model): ALWAYS snapshot the currently-focused field and
            // KEEP it alive for the whole recording. This is the only instant the
            // original field is reliably still focused — Ethan may click away
            // immediately after starting. We do NOT arm any lock or timer here; the
            // long-hold-vs-tap decision is deferred to the STOP press (see below).
            // We also do NOT clear this candidate on the start key-up — it must
            // persist through the entire recording so the STOP press can promote it.
            FocusLockService.shared.captureCandidate()

            // VIPPDebug: START press routed here and triggered captureCandidate(). The
            // detailed "RECORD START → captured candidate …" line (with pid+bundle) is
            // emitted inside FocusLockService.captureCandidate(); this line just marks
            // that the shortcut handler took the start path. No lock/timer armed here.
            vippLog.info("shortcut: START press → captureCandidate() (candidate will persist for session) action=\(String(describing: action), privacy: .public)")

            // Defensive: if a stale stop-timer somehow survived from a prior session,
            // tear it down so it can't fire against this new recording.
            longPressLockTask?.cancel()
            longPressLockTask = nil
        } else {
            // STOP PRESS (new model): this key-down ENDS the recording. In toggle mode
            // recording stops + transcription begins right now, on this key-down —
            // before we know whether Ethan is doing a quick TAP-to-stop or a deliberate
            // long-HOLD-to-stop. The hold is only known later (at this press's key-up,
            // or when the threshold timer below fires).
            //
            // So we ARM a threshold timer here on the STOP key-down: if the combo is
            // STILL held when longPressThreshold elapses, we promoteToLock() — pinning
            // delivery to the field captured back at the START press. Because
            // transcription takes ~1–2s and the paste waits for it, this timer normally
            // fires BEFORE delivery, so the lock flag is set in time for
            // restoreFocusToLock().
            //
            // ── THE MODIFIER-ONLY ~0.1s KEY-UP PROBLEM (2026-06-21 fix) ──────────────
            // Ethan's shortcut is MODIFIER-ONLY (⇧⌃⌥, toggle mode). For a bare modifier
            // combo there is no real key press — the monitor synthesises a "key-up"
            // almost IMMEDIATELY (~0.1s) regardless of how long he physically keeps the
            // keys down. Under the old code that spurious early key-up always took the
            // "short-tap" branch in handleKeyUp and CANCELLED this timer before it could
            // reach 0.45s — so the lock NEVER engaged. Every stop logged as
            // `STOP short-tap (dur≈0.10) → no lock`.
            //
            // FIX: capture whether the active shortcut is modifier-only + its required
            // modifier mask NOW (at STOP key-down). If it IS modifier-only, the key-up
            // handler will NOT cancel this timer or decide the gesture — instead the
            // timer is allowed to fire at the threshold and decides by LIVE PHYSICAL
            // MODIFIER STATE (NSEvent.modifierFlags): required modifiers still held ⇒
            // genuine long-hold ⇒ lock; released ⇒ real tap ⇒ no lock. For a normal
            // KEY shortcut the OS key-up IS reliable, so we keep the old timing path
            // (key-up cancels the timer for a sub-threshold tap) — the same timer just
            // additionally re-checks live modifier state when it fires, which is correct
            // either way.
            //
            // Mirrors the OLD start-side promote-timer pattern: [weak self] + the
            // isShortcutPressed / activeRecordingShortcutAction race guards so a key-up
            // that lands exactly as the timer fires can't promote a released press
            // (these guards apply to the KEY-shortcut path; for modifier-only we
            // deliberately don't rely on isShortcutPressed since the synthetic key-up
            // already cleared it — see below).
            longPressLockTask?.cancel()

            // Resolve the active shortcut so we know how to interpret the upcoming
            // key-up. shortcutForAction reads the live Shortcut definition from storage.
            let activeShortcut = shortcutForAction(action)
            currentStopIsModifierOnly = activeShortcut?.isModifierOnly ?? false
            // Required modifier mask for the live-state check (for Ethan: ⇧⌃⌥). Falls
            // back to empty if we can't resolve the shortcut — the live-state check then
            // safely refuses to lock (requiredModifiersStillHeld returns false on empty).
            currentStopRequiredModifiers = activeShortcut?.modifierFlags ?? []
            // Snapshot for the timer closure (avoid capturing self.* mutable state).
            let isModifierOnly = currentStopIsModifierOnly
            let requiredModifiers = currentStopRequiredModifiers

            // Mark the stop-hold decision as PENDING so delivery's paste() can do a
            // tiny grace-wait if transcription somehow finishes before this resolves.
            FocusLockService.shared.setStopHoldDecisionPending(true)
            // VIPPDebug: STOP press key-down — recording is stopping NOW; arm the
            // stop-hold timer. modifierOnly flags whether we'll decide by live modifier
            // state (true) or by key-up timing (false).
            vippLog.info("shortcut: STOP press key-down → arming stop-hold timer (threshold=\(FocusLockService.longPressThreshold) modifierOnly=\(isModifierOnly) action=\(String(describing: action), privacy: .public))")
            longPressLockTask = Task { @MainActor [weak self] in
                let thresholdNanos = UInt64(FocusLockService.longPressThreshold * 1_000_000_000)
                try? await Task.sleep(nanoseconds: thresholdNanos)
                guard let self, !Task.isCancelled else {
                    // Cancelled before firing. For a KEY shortcut this means a real
                    // sub-threshold tap (key-up cancelled us) — nothing to do. For a
                    // modifier-only shortcut the key-up does NOT cancel us, so reaching
                    // here-cancelled would only happen on reset/teardown; also fine.
                    return
                }

                if isModifierOnly {
                    // MODIFIER-ONLY PATH: the synthetic ~0.1s key-up already cleared
                    // isShortcutPressed, so we CANNOT use it as a "still held" proxy.
                    // Ask the hardware directly: are the required modifiers (⇧⌃⌥) still
                    // physically down right now?
                    let stillHeld = FocusLockService.shared.requiredModifiersStillHeld(required: requiredModifiers)
                    // os_log: required mask + live raw flags + verdict. modifierFlags
                    // rawValue (UInt) is fine to interpolate directly.
                    let liveFlags = NSEvent.modifierFlags.rawValue
                    self.vippLog.info("focuslock: STOP threshold reached → modifiers still held=\(stillHeld) (required=\(requiredModifiers.rawValue), current=\(liveFlags)) → \(stillHeld ? "promoteToLock" : "tap") action=\(String(describing: action), privacy: .public)")
                    if stillHeld {
                        // Genuine long-hold → engage the focus lock so delivery restores
                        // focus to the field captured at the START press.
                        FocusLockService.shared.promoteToLock()
                    } else {
                        // Real quick tap (modifiers released before threshold) → no lock;
                        // discard the persisted candidate so delivery uses normal paste.
                        FocusLockService.shared.clearCandidate()
                    }
                    // Decision resolved either way — clear the pending flag so delivery's
                    // grace-wait (if any) proceeds immediately.
                    FocusLockService.shared.setStopHoldDecisionPending(false)
                    return
                }

                // KEY-SHORTCUT PATH (reliable key-up): if we got here the key-up never
                // cancelled us, i.e. the key is genuinely still held past the threshold.
                // Re-check the combo is still down for THIS action to guard a key-up
                // landing exactly as the timer fires.
                guard self.isShortcutPressed,
                      self.activeRecordingShortcutAction == action else {
                    // Released right at the boundary — let the key-up path resolve it.
                    return
                }
                // VIPPDebug: stop-hold timer SURVIVED to fire — key held past threshold
                // at STOP, so promote the persisted start-candidate to a lock.
                self.vippLog.info("focuslock: STOP long-hold ≥threshold → promoteToLock (paste into original field) action=\(String(describing: action), privacy: .public)")
                FocusLockService.shared.promoteToLock()
                FocusLockService.shared.setStopHoldDecisionPending(false)
            }
        }

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId, .primaryCurrentInput)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId, .primaryCurrentInput)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId, .primaryCurrentInput)
            }
        }
    }

    static func shouldApplyShortcutPressCooldown(
        action: ShortcutAction,
        mode: RecordingShortcutManager.Mode
    ) -> Bool {
        // Repeats from one held chord are still rejected by isShortcutPressed and
        // ShortcutMonitor's reducer. Only a released-and-pressed-again Primary
        // toggle bypasses the legacy cooldown so a recording-time second click can
        // select Won't paste and a third can Pause; while already paused, the
        // second click selects Won't paste without first resuming capture.
        !(action == .primaryRecording && mode == .toggle)
    }

    private func handlePrimaryToggleKeyDown(
        eventTime: TimeInterval,
        modeId: UUID?
    ) async {
        if recordingState() == .idle {
            if let suppressPrimaryIdlePressUntil {
                if eventTime <= suppressPrimaryIdlePressUntil {
                    vippLog.info("shortcut: ignored extra Primary press after consumed recording-time quadruple gesture")
                    return
                }
                self.suppressPrimaryIdlePressUntil = nil
            }
            await handlePrimaryIdleStartPress(
                eventTime: eventTime,
                modeId: modeId
            )
            return
        }

        // Once capture startup or a live recording owns the action, no idle timer
        // may survive and start another session later. This does not touch the
        // recording-time stop/clipboard/pause coordinator.
        cancelPendingPrimaryStartDecision()
        let decision = primaryPressCoordinator.registerPress(
            recordingState: recordingState(),
            eventTime: eventTime
        )

        switch decision {
        case .startOrCancelImmediately:
            primaryGestureDecisionTask?.cancel()
            primaryGestureDecisionTask = nil
            guard canHandleShortcutAction() else { return }
            await toggleRecorderPanel(modeId, .primaryCurrentInput)

        case .deferNormalStop(let generation):
            setActiveRecordingAutoSendDisposition(.configured)
            schedulePrimaryNormalStop(
                generation: generation,
                modeId: modeId
            )

        case .deferPausedResume(let generation):
            schedulePrimaryPausedResume(generation: generation)

        case .deferClipboardFinish(let generation):
            // Click two has already canceled the normal stop, so show the real
            // no-paste policy now rather than making Ethan wait through the click-three
            // window. A third click or alternate route clears it before continuing.
            setActiveRecordingCompletionDisposition(.clipboardOnly)
            setActiveRecordingAutoSendDisposition(.configured)
            schedulePrimaryClipboardFinish(
                generation: generation,
                modeId: modeId
            )

        case .finishPausedClipboardImmediately:
            primaryGestureDecisionTask?.cancel()
            primaryGestureDecisionTask = nil
            setActiveRecordingCompletionDisposition(.clipboardOnly)
            setActiveRecordingAutoSendDisposition(.configured)
            await finishPrimaryRecordingToClipboard(modeId: modeId)

        case .togglePause:
            primaryGestureDecisionTask?.cancel()
            primaryGestureDecisionTask = nil
            setActiveRecordingCompletionDisposition(.normalDelivery)
            setActiveRecordingAutoSendDisposition(.configured)
            guard canHandleShortcutAction() else { return }
            let pauseTask = Task { @MainActor [toggleRecordingPause] in
                await toggleRecordingPause()
            }
            primaryPauseTransitionTask = pauseTask
            let didPause = await pauseTask.value
            if primaryPauseTransitionTask != nil {
                primaryPauseTransitionTask = nil
            }
            vippLog.info("shortcut: genuine Primary triple-click pause success=\(didPause, privacy: .public) state=\(String(describing: self.recordingState()), privacy: .public)")

        case .finishWithoutAutoSend:
            primaryGestureDecisionTask?.cancel()
            primaryGestureDecisionTask = nil
            if let primaryPauseTransitionTask {
                _ = await primaryPauseTransitionTask.value
                self.primaryPauseTransitionTask = nil
            }
            setActiveRecordingCompletionDisposition(.normalDelivery)
            setActiveRecordingAutoSendDisposition(.suppressOnce)
            suppressPrimaryIdlePressUntil = eventTime +
                primaryPressCoordinator.triplePressContinuationInterval
            await finishPrimaryRecordingWithoutAutoSend(modeId: modeId)

        case .performOverduePausedResume:
            primaryGestureDecisionTask?.cancel()
            primaryGestureDecisionTask = nil
            guard recordingState() == .paused,
                  canHandleShortcutAction() else {
                return
            }
            let didResume = await toggleRecordingPause()
            vippLog.info("shortcut: overdue paused Primary single press committed as resume success=\(didResume, privacy: .public) state=\(String(describing: self.recordingState()), privacy: .public)")

        case .ignoreCompletedGesture:
            vippLog.info("shortcut: ignored extra Primary press inside completed multi-click gesture")

        case .performOverdueNormalStop:
            primaryGestureDecisionTask?.cancel()
            primaryGestureDecisionTask = nil
            guard recordingState().isRecordingOrPaused,
                  canHandleShortcutAction() else {
                return
            }
            vippLog.info("shortcut: overdue Primary single press committed as base-current-input stop")
            await toggleRecorderPanel(modeId, .primaryCurrentInput)

        case .performOverdueClipboardFinish:
            primaryGestureDecisionTask?.cancel()
            primaryGestureDecisionTask = nil
            await finishPrimaryRecordingToClipboard(modeId: modeId)
        }
    }

    private func handlePrimaryIdleStartPress(
        eventTime: TimeInterval,
        modeId: UUID?
    ) async {
        switch primaryIdleStartCoordinator.registerPress(eventTime: eventTime) {
        case .deferStart(let generation):
            pendingPrimaryCompletionTarget = pendingClipboardOnlySessionID().map {
                (generation: generation, sessionID: $0)
            } // Bind click two to the result present at click one, not an older card revealed if that result finishes meanwhile.
            if let target = pendingPrimaryCompletionTarget {
                _ = applyPendingPrimaryCompletionGesture(
                    target.sessionID,
                    .begin(
                        decisionInterval: primaryIdleStartCoordinator
                            .startDecisionInterval
                    )
                )
            }
            guard canHandleShortcutAction() else {
                endPendingPrimaryCompletionTarget()
                primaryIdleStartCoordinator.reset()
                return
            }
            guard let requestID = await reserveRecordingStart() else {
                endPendingPrimaryCompletionTarget()
                primaryIdleStartCoordinator.reset()
                return
            }
            // Launch cleanup can yield while the first press is reserving. If the
            // matching second press canceled this generation during that await, the
            // returned token must be released instead of resurrecting the start.
            guard primaryIdleStartCoordinator.isPendingStart(
                generation: generation
            ) else {
                cancelRecordingStartReservation(requestID)
                return
            }
            pendingPrimaryStartReservation = (
                generation: generation,
                requestID: requestID,
                modeId: modeId
            )
            schedulePrimaryStart(generation: generation)

        case .cancelPendingStart:
            primaryStartDecisionTask?.cancel()
            primaryStartDecisionTask = nil
            let target = pendingPrimaryCompletionTarget
            if let target {
                let selected = applyPendingPrimaryCompletionGesture(
                    target.sessionID,
                    .selectClipboardOnly(
                        continuationInterval: primaryIdleStartCoordinator
                            .multiPressContinuationInterval
                    )
                ) || selectPendingClipboardOnlyCompletion(target.sessionID)
                if selected {
                    _ = primaryIdleStartCoordinator
                        .armPendingCompletionContinuation()
                } else {
                    endPendingPrimaryCompletionTarget()
                }
                vippLog.info("shortcut: Primary transcription double-click clipboard-only selected=\(selected, privacy: .public) paste=false")
            }
            cancelPendingPrimaryStartReservation()
            vippLog.info("shortcut: Primary idle double-press canceled pending recording start")

        case .continuePendingCompletionGesture(let generation):
            guard let target = pendingPrimaryCompletionTarget,
                  target.generation == generation else {
                return
            }
            let continued = applyPendingPrimaryCompletionGesture(
                target.sessionID,
                .continueTowardNoAutoSend(
                    continuationInterval: primaryIdleStartCoordinator
                        .multiPressContinuationInterval
                )
            )
            if !continued {
                endPendingPrimaryCompletionTarget()
            }
            vippLog.info("shortcut: Primary pending-transcription click three continued toward no-auto-send selected=\(continued, privacy: .public)")

        case .finishPendingCompletionWithoutAutoSend(let generation):
            guard let target = pendingPrimaryCompletionTarget,
                  target.generation == generation else {
                return
            }
            let selected = applyPendingPrimaryCompletionGesture(
                target.sessionID,
                .deliverWithoutAutoSend
            )
            pendingPrimaryCompletionTarget = nil
            vippLog.info("shortcut: Primary pending-transcription quadruple-click selected=\(selected, privacy: .public) destination=sessionOwned paste=true autoSend=false")

        case .ignoreCompletedDoublePress:
            vippLog.info("shortcut: ignored extra Primary press inside canceled idle double-click gesture")

        case .ignoreCompletedQuadruplePress:
            vippLog.info("shortcut: ignored extra Primary press after consumed pending-transcription quadruple gesture")

        case .performOverdueStart:
            primaryStartDecisionTask?.cancel()
            primaryStartDecisionTask = nil
            guard let pendingPrimaryStartReservation else { return }
            self.pendingPrimaryStartReservation = nil
            vippLog.info("shortcut: overdue Primary idle single press committed as recording start")
            await commitPrimaryStart(pendingPrimaryStartReservation)
        }
    }

    private func schedulePrimaryStart(generation: Int) {
        primaryStartDecisionTask?.cancel()
        let delay = primaryIdleStartCoordinator.startDecisionInterval
        vippLog.info("shortcut: Primary idle press deferred for \(delay, privacy: .public)s awaiting accidental second click")
        primaryStartDecisionTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.primaryIdleStartCoordinator.consumeDeferredStart(
                      generation: generation
                  ),
                  let pending = self.pendingPrimaryStartReservation,
                  pending.generation == generation else {
                return
            }
            self.pendingPrimaryStartReservation = nil
            self.primaryStartDecisionTask = nil
            await self.commitPrimaryStart(pending)
        }
    }

    private func commitPrimaryStart(
        _ pending: (generation: Int, requestID: UUID, modeId: UUID?)
    ) async {
        if pendingPrimaryCompletionTarget?.generation == pending.generation {
            endPendingPrimaryCompletionTarget()
        }
        guard recordingState() == .idle,
              canHandleShortcutAction() else {
            cancelRecordingStartReservation(pending.requestID)
            return
        }

        vippLog.info("shortcut: Primary idle single-press window expired → recording start")
        if let startReservedRecording {
            await startReservedRecording(pending.requestID, pending.modeId)
        } else {
            // Tests and non-engine embeddings can retain the existing toggle hook;
            // production always supplies the reservation-aware start closure.
            await toggleRecorderPanel(pending.modeId, .primaryCurrentInput)
        }
    }

    private func cancelPendingPrimaryStartReservation() {
        guard let pendingPrimaryStartReservation else { return }
        self.pendingPrimaryStartReservation = nil
        cancelRecordingStartReservation(pendingPrimaryStartReservation.requestID)
    }

    private func cancelPendingPrimaryStartDecision() {
        endPendingPrimaryCompletionTarget()
        primaryStartDecisionTask?.cancel()
        primaryStartDecisionTask = nil
        primaryIdleStartCoordinator.reset()
        cancelPendingPrimaryStartReservation()
    }

    private func endPendingPrimaryCompletionTarget() {
        guard let target = pendingPrimaryCompletionTarget else { return }
        pendingPrimaryCompletionTarget = nil
        _ = applyPendingPrimaryCompletionGesture(
            target.sessionID,
            .endUnchanged
        )
    }

    private func schedulePrimaryNormalStop(
        generation: Int,
        modeId: UUID?
    ) {
        primaryGestureDecisionTask?.cancel()
        let delay = primaryPressCoordinator.normalStopDecisionInterval
        vippLog.info("shortcut: Primary first recording-time press deferred for \(delay, privacy: .public)s awaiting possible double-click")
        primaryGestureDecisionTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.primaryPressCoordinator.consumeDeferredStop(
                      generation: generation
                  ),
                  self.recordingState().isRecordingOrPaused,
                  self.isRecorderVisible(),
                  self.canHandleShortcutAction() else {
                return
            }

            self.primaryGestureDecisionTask = nil
            self.vippLog.info("shortcut: Primary single press window expired → base-current-input normal stop")
            await self.toggleRecorderPanel(modeId, .primaryCurrentInput)
        }
    }

    private func schedulePrimaryPausedResume(generation: Int) {
        primaryGestureDecisionTask?.cancel()
        let delay = primaryPressCoordinator.normalStopDecisionInterval
        vippLog.info("shortcut: paused Primary first press deferred for \(delay, privacy: .public)s awaiting possible Won't paste double-click")
        primaryGestureDecisionTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.primaryPressCoordinator.consumeDeferredPausedResume(
                      generation: generation
                  ),
                  self.recordingState() == .paused,
                  self.isRecorderVisible(),
                  self.canHandleShortcutAction() else {
                return
            }

            self.primaryGestureDecisionTask = nil
            let didResume = await self.toggleRecordingPause()
            self.vippLog.info("shortcut: paused Primary single-press window expired → resume success=\(didResume, privacy: .public) state=\(String(describing: self.recordingState()), privacy: .public)")
        }
    }

    private func schedulePrimaryClipboardFinish(
        generation: Int,
        modeId: UUID?
    ) {
        primaryGestureDecisionTask?.cancel()
        let delay = primaryPressCoordinator.triplePressContinuationInterval
        vippLog.info("shortcut: Primary double-click deferred for \(delay, privacy: .public)s awaiting possible pause triple-click")
        primaryGestureDecisionTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.primaryPressCoordinator.consumeDeferredClipboardFinish(
                      generation: generation
                  ) else {
                return
            }

            self.primaryGestureDecisionTask = nil
            await self.finishPrimaryRecordingToClipboard(modeId: modeId)
        }
    }

    private func finishPrimaryRecordingToClipboard(modeId: UUID?) async {
        guard recordingState().isRecordingOrPaused,
              canHandleShortcutAction() else {
            return
        }
        let didFinish = await finishRecordingToClipboard(modeId)
        vippLog.info("shortcut: Primary double-click clipboard-only finish success=\(didFinish, privacy: .public) paste=false autoSend=false playback=restoredIfOwned")
    }

    private func finishPrimaryRecordingWithoutAutoSend(modeId: UUID?) async {
        guard recordingState().isRecordingOrPaused,
              canHandleShortcutAction() else {
            return
        }
        let didFinish = await finishRecordingWithoutAutoSend(modeId)
        vippLog.info("shortcut: Primary quadruple-click finish success=\(didFinish, privacy: .public) destination=primaryCurrentInput paste=true autoSend=false playback=restoredIfOwned")
    }

    func cancelPendingPrimaryDecisions() {
        cancelPendingPrimaryStartDecision()
        primaryGestureDecisionTask?.cancel()
        primaryGestureDecisionTask = nil
        primaryPauseTransitionTask?.cancel()
        primaryPauseTransitionTask = nil
        primaryPressCoordinator.cancelPendingStop()
        setActiveRecordingCompletionDisposition(.normalDelivery)
        setActiveRecordingAutoSendDisposition(.configured)
        suppressPrimaryIdlePressUntil = nil
        // Next and monitor-reset boundaries end any pending Primary burst too;
        // a later Primary action must never inherit suppression across them.
        primaryDuplicateChordCoalescer.reset()
    }

    func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false

        if mode == .toggle {
            shortcutPressStartTime = nil
            isHandsFreeRecording = true
            return
        }

        // Feature A (new START→STOP model): the press has ended — but which press?
        //
        //   • START key-up: the start tap finished. Do NOTHING to the focus state —
        //     the captured candidate MUST persist for the whole recording so the later
        //     STOP press can decide whether to lock to it. (This is the key behaviour
        //     change: the old model cleared a short start-press here.) No timer to
        //     cancel either — the start press never arms one in the new model.
        //
        //   • STOP key-up: the stop press finished. Cancel the stop-hold timer (so it
        //     can't fire after release) and resolve long-hold vs short-tap:
        //       - short-tap (released before threshold) → clearCandidate(), no lock,
        //         normal paste at the live cursor.
        //       - long-hold (held ≥ threshold) → KEEP the candidate; the stop-hold
        //         timer already ran promoteToLock(), so delivery restores focus to the
        //         original field. We do NOT clear here.
        if currentPressStartedRecording {
            // START key-up — leave focus state untouched; candidate persists.
            // (No VIPPDebug noise here; the RECORD START line already logged capture.)
        } else if currentStopIsModifierOnly {
            // ── MODIFIER-ONLY STOP key-up (2026-06-21 fix) ─────────────────────────
            // This key-up is the SPURIOUS ~0.1s synthetic release that the OS emits for
            // a bare modifier combo regardless of how long Ethan physically holds the
            // keys. We must therefore IGNORE it entirely for the lock decision: do NOT
            // cancel the stop-hold timer, do NOT take any short-tap/long-hold branch.
            // The timer (armed at STOP key-down) will fire at longPressThreshold and
            // decide by LIVE NSEvent.modifierFlags whether the required modifiers (⇧⌃⌥)
            // are still physically held — that is the only reliable signal for this
            // shortcut kind. Leaving the timer alive here is the whole fix.
            vippLog.info("shortcut: STOP key-up (modifier-only) dur=\(self.shortcutPressStartTime.map { eventTime - $0 } ?? 0) → IGNORED for lock decision (live-modifier timer will decide)")
        } else {
            // STOP key-up (KEY shortcut, reliable key-up) — cancel the stop-hold timer,
            // then resolve the gesture by press duration.
            longPressLockTask?.cancel()
            longPressLockTask = nil
            if let pressStart = shortcutPressStartTime {
                let pressDuration = eventTime - pressStart
                if pressDuration < FocusLockService.longPressThreshold {
                    // SHORT TAP to stop → no lock; discard the persisted candidate so
                    // delivery uses the default frontmost/live-cursor paste (#785).
                    // VIPPDebug: stop short-tap — under threshold, candidate discarded.
                    vippLog.info("shortcut: STOP short-tap (dur=\(pressDuration)) → no lock, paste at cursor; clearCandidate")
                    FocusLockService.shared.clearCandidate()
                    // Decision resolved (no lock): clear the pending flag.
                    FocusLockService.shared.setStopHoldDecisionPending(false)
                } else {
                    // LONG HOLD to stop → the stop-hold timer should already have
                    // promoted the candidate to a lock; keep it (do NOT clear). This
                    // branch is mostly a fallback in case key-up fires slightly after
                    // the threshold without the timer having run yet — promote here too
                    // so a borderline-timed hold still locks.
                    if !FocusLockService.shared.isLockActive {
                        // Timer hasn't fired yet but we crossed the threshold by key-up:
                        // promote now so the hold still locks. Idempotent if it already did.
                        FocusLockService.shared.promoteToLock()
                    }
                    // Decision resolved (locked): clear the pending flag.
                    FocusLockService.shared.setStopHoldDecisionPending(false)
                    vippLog.info("shortcut: STOP long-hold key-up (dur=\(pressDuration)) ≥ threshold → lock kept (paste into original field)")
                }
            }
        }

        switch mode {
        case .toggle:
            isHandsFreeRecording = true

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId, .primaryCurrentInput)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId, .primaryCurrentInput)
            } else {
                isHandsFreeRecording = true
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
