import SwiftUI
import AppKit

@MainActor
class MiniWindowManager {
    private struct WindowEntry {
        let panel: MiniRecorderPanel
        let windowController: NSWindowController
    }

    private var windows: [WindowEntry] = []

    private let makeView: () -> AnyView

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
        self.makeView = {
            AnyView(
                // Host the STACK container (one card per engine.sessions entry) rather than
                // a single MiniRecorderView. The stack renders the active/base card with full
                // controls and older transcribing cards piled upward.
                MiniRecorderStackView(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
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

        // Mirror the recorder on every connected display. Each panel hosts its own
        // SwiftUI view hierarchy, but all of them observe the same engine/session
        // objects, so waveform, transcription state, and controls stay synchronized.
        for screen in NSScreen.screens {
            let metrics = MiniRecorderPanel.calculateWindowMetrics(for: screen)
            let panel = MiniRecorderPanel(contentRect: metrics)
            let hostingController = NSHostingController(rootView: makeView())
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
