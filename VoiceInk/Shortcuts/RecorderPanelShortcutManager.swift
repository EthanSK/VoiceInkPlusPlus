import Foundation
import AppKit
import Carbon.HIToolbox

@MainActor
final class RecorderPanelShortcutManager: ObservableObject {
    private var recorderUIManager: RecorderUIManager
    private var visibilityTask: Task<Void, Never>?
    private var shortcutChangeObserver: NSObjectProtocol?
    private let visibleRecorderMonitor = ShortcutMonitor()

    // NOTE (2026-07-11): the old two-stage "double-tap Escape" confirm machinery
    // (firstEscapePressTime / escapeDoublePressThreshold / escapeTimeoutTask +
    // resetEscapeState) was REMOVED here. See handleEscapeShortcut() for the full
    // why. Single Escape now cancels immediately, so there is no confirm window to
    // track and nothing to reset.

    init(recorderUIManager: RecorderUIManager) {
        self.recorderUIManager = recorderUIManager
        setupShortcutChangeObserver()
        setupVisibilityObserver()
    }

    private func setupShortcutChangeObserver() {
        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let action = notification.object as? ShortcutAction,
                action == .cancelRecorder
            else {
                return
            }

            Task { @MainActor in
                self?.refreshVisibleShortcuts()
            }
        }
    }

    private func setupVisibilityObserver() {
        visibilityTask = Task { @MainActor in
            for await isVisible in recorderUIManager.$isRecorderPanelVisible.values {
                if isVisible {
                    refreshVisibleShortcuts()
                } else {
                    visibleRecorderMonitor.stop()
                }
            }
        }
    }

    private var canUseModeShortcuts: Bool {
        !ModeManager.shared.enabledConfigurations.isEmpty
    }

    private func refreshVisibleShortcuts() {
        guard recorderUIManager.isRecorderPanelVisible else {
            visibleRecorderMonitor.stop()
            return
        }

        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.recorderPanelStoredActions)

        if ShortcutStore.shortcut(for: .cancelRecorder) == nil {
            shortcuts[.recorderPanelEscape] = .key(keyCode: UInt16(kVK_Escape), modifierFlags: [])
        }

        if canUseModeShortcuts {
            for (index, keyCode) in Self.digitKeyCodes.enumerated() {
                shortcuts[.recorderPanelMode(index)] = .key(
                    keyCode: keyCode,
                    modifierFlags: [.option]
                )
            }
        }

        visibleRecorderMonitor.start(
            shortcuts: shortcuts,
            onKeyDown: { [weak self] action, _ in
                Task { @MainActor in
                    await self?.handleRecorderPanelShortcut(action)
                }
            },
            onKeyUp: { _, _ in }
        )
    }

    private func handleRecorderPanelShortcut(_ action: ShortcutAction) async {
        guard recorderUIManager.isRecorderPanelVisible else { return }

        switch action {
        case .cancelRecorder:
            guard ShortcutStore.shortcut(for: .cancelRecorder) != nil else { return }
            await recorderUIManager.cancelRecording()
        case .recorderPanelEscape:
            await handleEscapeShortcut()
        case .recorderPanelMode(let index):
            handleModeSelectionShortcut(index: index)
        default:
            break
        }
    }

    // Single-press Escape cancels the active recording IMMEDIATELY.
    //
    // WHY THIS CHANGED (2026-07-11, Ethan): upstream shipped a two-stage
    // "double-tap Escape" confirm. The FIRST Escape only popped a
    // "Press Esc again to cancel" HUD — an AppNotificationView whose bottom edge
    // is a progress bar that shrinks from full width to zero over 1.5s (that
    // shrinking bar is the "slider/timer going down" Ethan reported). Only a
    // SECOND Escape within 1.5s actually cancelled. Two problems:
    //   1. It took a double-hit to cancel at all.
    //   2. WORSE — after the second Escape confirmed, cancelRecording() tore down
    //      the recorder panel but did NOT dismiss that confirm HUD. Its dismiss
    //      timer (NotificationManager.dismissTimer, also 1.5s) kept running, so
    //      the countdown "slider" lingered on screen for the remainder of its
    //      1.5s AFTER the cancel had already happened — i.e. "double-hit Escape
    //      works, but the slider/timer going down doesn't stop / doesn't
    //      disappear instantly".
    //
    // FIX: a single Escape now (1) cancels/stops the recording, (2) tears down the
    // recorder overlay, and (3) leaves NO lingering confirm HUD — because we no
    // longer show one. cancelRecording() → engine.cancelRecording() (discard, no
    // paste, resume paused media) → dismissRecorderPanel() (orderOut, instant).
    //
    // IDEMPOTENT: a second Escape is a harmless no-op. handleRecorderPanelShortcut
    // already guards on `recorderUIManager.isRecorderPanelVisible`, which is false
    // once the first Escape dismissed the panel, so the repeat press does nothing.
    //
    // The deliberate, low-accident-risk cancel affordance (the red X button in the
    // recorder panels) is unchanged; Escape is just the fast keyboard path.
    private func handleEscapeShortcut() async {
        // If the user has bound an explicit "cancel recorder" shortcut, that one
        // owns cancellation (handled in the .cancelRecorder case) and Escape here
        // is inert — preserve that upstream behaviour.
        guard ShortcutStore.shortcut(for: .cancelRecorder) == nil else { return }

        // Belt-and-braces: proactively dismiss any notification HUD that might be
        // on screen so nothing keeps counting down after we cancel. During an
        // active recording the only HUD in play is recorder-related, so this is
        // safe and guarantees "no lingering slider" even across build upgrades.
        NotificationManager.shared.dismissNotification()

        await recorderUIManager.cancelRecording()
    }

    private func handleModeSelectionShortcut(index: Int) {
        guard canUseModeShortcuts else { return }

        let modeManager = ModeManager.shared
        let availableConfigurations = modeManager.enabledConfigurations

        guard index < availableConfigurations.count else { return }

        let selectedConfig = availableConfigurations[index]
        modeManager.setActiveConfiguration(selectedConfig)
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        visibilityTask?.cancel()
        MainActor.assumeIsolated {
            visibleRecorderMonitor.stop()
        }
    }

    private static let digitKeyCodes: [UInt16] = [
        UInt16(kVK_ANSI_1),
        UInt16(kVK_ANSI_2),
        UInt16(kVK_ANSI_3),
        UInt16(kVK_ANSI_4),
        UInt16(kVK_ANSI_5),
        UInt16(kVK_ANSI_6),
        UInt16(kVK_ANSI_7),
        UInt16(kVK_ANSI_8),
        UInt16(kVK_ANSI_9),
        UInt16(kVK_ANSI_0)
    ]
}
