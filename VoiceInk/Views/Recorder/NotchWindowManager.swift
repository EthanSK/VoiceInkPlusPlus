import SwiftUI
import AppKit

@MainActor
class NotchWindowManager {
    private struct WindowEntry {
        let displayID: CGDirectDisplayID
        let panel: NotchRecorderPanel
        let windowController: NSWindowController
    }

    private var windows: [WindowEntry] = []

    private let makeView: (_ notchWidth: CGFloat, _ notchHeight: CGFloat) -> AnyView

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        // onCancelTapped: fired by the red "X" → discard the recording/transcription
        // (no paste) and resume paused media. Routed to RecorderUIManager.cancelRecording().
        onCancelTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void,
        // onCancelSession: per-card cancel for a SPECIFIC background transcribing session
        // (record-while-transcribing stack). Routed to engine.cancelSession(id:).
        onCancelSession: @escaping (UUID) -> Void
    ) {
        self.makeView = { notchWidth, notchHeight in
            AnyView(
                // Host the STACK container: the active session is the notch pill, background
                // transcribing sessions render as chips stacked beneath it.
                NotchRecorderStackView(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    notchWidth: notchWidth,
                    notchHeight: notchHeight,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onCancelTapped: onCancelTapped,
                    onAssistantFollowUp: onAssistantFollowUp,
                    onCancelSession: onCancelSession
                )
            )
        }
    }

    func show() {
        let screens = NSScreen.screens
        let currentDisplayIDs = screens.compactMap {
            RecorderDisplayReusePolicy.displayID(for: $0)
        }
        let existingDisplayIDs = windows.map(\.displayID)

        // Match MiniWindowManager's reuse boundary. Each notch panel owns a full
        // SwiftUI recorder hierarchy, so recreating one per display on every start
        // multiplies startup and animation work for no visible benefit.
        guard currentDisplayIDs.count == screens.count,
              RecorderDisplayReusePolicy.shouldReuse(
                existingDisplayIDs: existingDisplayIDs,
                currentDisplayIDs: currentDisplayIDs
              ) else {
            initializeWindows(screens: screens)
            return
        }

        for (entry, screen) in zip(windows, screens) {
            entry.panel.show(on: screen)
        }
    }

    func hide() {
        windows.forEach { $0.panel.orderOut(nil) }
    }

    func destroyWindow() {
        deinitializeWindows()
    }

    private func initializeWindows(screens: [NSScreen] = NSScreen.screens) {
        deinitializeWindows()

        for screen in screens {
            guard let displayID = RecorderDisplayReusePolicy.displayID(for: screen) else {
                continue
            }
            let metrics = NotchRecorderPanel.calculateWindowMetrics(for: screen)
            let panel = NotchRecorderPanel(contentRect: metrics.frame)
            let view = makeView(metrics.notchWidth, metrics.notchHeight)
            let hostingController = NotchRecorderHostingController(rootView: view)
            panel.contentView = hostingController.view
            let windowController = NSWindowController(window: panel)
            windows.append(WindowEntry(
                displayID: displayID,
                panel: panel,
                windowController: windowController
            ))
            panel.show(on: screen)
        }
    }

    private func deinitializeWindows() {
        windows.forEach {
            $0.panel.orderOut(nil)
            $0.windowController.close()
        }
        windows.removeAll()
    }

}
