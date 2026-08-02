import SwiftUI
import AppKit

enum RecorderDisplayReusePolicy {
    static func shouldReuse(
        existingDisplayIDs: [CGDirectDisplayID],
        currentDisplayIDs: [CGDirectDisplayID]
    ) -> Bool {
        !existingDisplayIDs.isEmpty && existingDisplayIDs == currentDisplayIDs
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}

@MainActor
class MiniWindowManager {
    private struct WindowEntry {
        let displayID: CGDirectDisplayID
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
        // onCancelTapped: red "X" → stop without paste, retain audio/HUD draft in
        // History, and resume paused media. Permanent deletion remains explicit.
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
        let screens = NSScreen.screens
        let currentDisplayIDs = screens.compactMap {
            RecorderDisplayReusePolicy.displayID(for: $0)
        }
        let existingDisplayIDs = windows.map(\.displayID)

        // Recorder panels are deliberately mirrored across every monitor, but the
        // SwiftUI trees are expensive: they observe the live waveform, streaming text,
        // and every active transcription. Rebuilding all of them on every recording
        // start regressed the upstream window-reuse optimization and made the HUD lag.
        // Rebuild only when the physical display set actually changes.
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

        // Mirror the recorder on every connected display. Each panel hosts its own
        // SwiftUI view hierarchy, but all of them observe the same engine/session
        // objects, so waveform, transcription state, and controls stay synchronized.
        for screen in screens {
            guard let displayID = RecorderDisplayReusePolicy.displayID(for: screen) else {
                continue
            }
            let metrics = MiniRecorderPanel.calculateWindowMetrics(for: screen)
            let panel = MiniRecorderPanel(contentRect: metrics)
            let hostingController = NSHostingController(rootView: makeView())
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
