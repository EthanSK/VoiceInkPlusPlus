import SwiftUI
import AppKit

@MainActor
class NotchWindowManager {
    private struct WindowEntry {
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
        initializeWindows()
    }

    func hide() {
        windows.forEach { $0.panel.orderOut(nil) }
    }

    func destroyWindow() {
        deinitializeWindows()
    }

    private func initializeWindows() {
        deinitializeWindows()

        for screen in NSScreen.screens {
            let metrics = NotchRecorderPanel.calculateWindowMetrics(for: screen)
            let panel = NotchRecorderPanel(contentRect: metrics.frame)
            let view = makeView(metrics.notchWidth, metrics.notchHeight)
            let hostingController = NotchRecorderHostingController(rootView: view)
            panel.contentView = hostingController.view
            let windowController = NSWindowController(window: panel)
            windows.append(WindowEntry(panel: panel, windowController: windowController))
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
