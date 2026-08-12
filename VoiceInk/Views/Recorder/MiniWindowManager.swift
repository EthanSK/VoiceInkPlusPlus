import SwiftUI
import AppKit

enum RecorderDisplayReusePolicy {
    enum WindowSetPlan: Equatable {
        case keepExisting
        case reuse
        case rebuild
    }

    struct ScreenIdentity: Hashable {
        let value: String
    }

    static func shouldReuse(
        existingDisplayIDs: [ScreenIdentity],
        currentDisplayIDs: [ScreenIdentity]
    ) -> Bool {
        !existingDisplayIDs.isEmpty && existingDisplayIDs == currentDisplayIDs
    }

    static func windowSetPlan(
        existingDisplayIDs: [ScreenIdentity],
        currentDisplayIDs: [ScreenIdentity]
    ) -> WindowSetPlan {
        guard !currentDisplayIDs.isEmpty else { return .keepExisting }
        return shouldReuse(
            existingDisplayIDs: existingDisplayIDs,
            currentDisplayIDs: currentDisplayIDs
        ) ? .reuse : .rebuild
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    static func screenIdentity(
        displayID: CGDirectDisplayID?,
        fallbackIndex: Int,
        frame: NSRect,
        backingScaleFactor: CGFloat
    ) -> ScreenIdentity {
        if let displayID {
            return ScreenIdentity(value: "display:\(displayID)")
        }

        // NSScreenNumber is normally present, but display wake/reconfiguration can
        // transiently omit it. Skipping that screen created a truthful-looking app
        // icon and recording sound with no HUD on the affected monitor. Geometry plus
        // ordinal is a conservative reuse key: if it changes, rebuilding is cheaper
        // and safer than silently dropping one mirrored panel.
        return ScreenIdentity(
            value: [
                "fallback",
                String(fallbackIndex),
                String(describing: frame.origin.x),
                String(describing: frame.origin.y),
                String(describing: frame.size.width),
                String(describing: frame.size.height),
                String(describing: backingScaleFactor)
            ].joined(separator: ":")
        )
    }

    static func screenIdentity(for screen: NSScreen, index: Int) -> ScreenIdentity {
        screenIdentity(
            displayID: displayID(for: screen),
            fallbackIndex: index,
            frame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }
}

struct RecorderPanelPresentationReport: Equatable {
    let expectedScreenCount: Int
    let materializedPanelCount: Int
    let visibleOnScreenPanelCount: Int

    var isComplete: Bool {
        RecorderPanelPresentationPolicy.isComplete(
            expectedScreenCount: expectedScreenCount,
            materializedPanelCount: materializedPanelCount,
            visibleOnScreenPanelCount: visibleOnScreenPanelCount
        )
    }

    var hasVisiblePanel: Bool {
        visibleOnScreenPanelCount > 0
    }
}

enum RecorderPanelPresentationPolicy {
    static func isComplete(
        expectedScreenCount: Int,
        materializedPanelCount: Int,
        visibleOnScreenPanelCount: Int
    ) -> Bool {
        expectedScreenCount > 0
            && materializedPanelCount == expectedScreenCount
            && visibleOnScreenPanelCount == expectedScreenCount
    }

    static func shouldRemirror(isLogicallyVisible: Bool) -> Bool {
        isLogicallyVisible
    }
}

@MainActor
class MiniWindowManager {
    private struct WindowEntry {
        let screenIdentity: RecorderDisplayReusePolicy.ScreenIdentity
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

    @discardableResult
    func show() -> RecorderPanelPresentationReport {
        let screens = NSScreen.screens
        let currentDisplayIDs = screens.enumerated().map { index, screen in
            RecorderDisplayReusePolicy.screenIdentity(for: screen, index: index)
        }
        let existingDisplayIDs = windows.map(\.screenIdentity)

        // Never destroy a previously materialized HUD because AppKit briefly reports
        // no screens during wake/reconfiguration. The caller treats this report as a
        // failed initial presentation (so recording cannot start invisibly), while an
        // already-active lifecycle keeps its old panels until a screen event retries.
        switch RecorderDisplayReusePolicy.windowSetPlan(
            existingDisplayIDs: existingDisplayIDs,
            currentDisplayIDs: currentDisplayIDs
        ) {
        case .keepExisting:
            return RecorderPanelPresentationReport(
                expectedScreenCount: 0,
                materializedPanelCount: windows.count,
                visibleOnScreenPanelCount: 0
            )
        case .rebuild:
            // Recorder panels are deliberately mirrored across every monitor, but the
            // SwiftUI trees are expensive: rebuild only when the physical display set
            // changes, never on every recording start.
            initializeWindows(screens: screens)
            return presentationReport(for: screens)
        case .reuse:
            for (entry, screen) in zip(windows, screens) {
                entry.panel.show(on: screen)
            }
            return presentationReport(for: screens)
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
        for (index, screen) in screens.enumerated() {
            let metrics = MiniRecorderPanel.calculateWindowMetrics(for: screen)
            let panel = MiniRecorderPanel(contentRect: metrics)
            let hostingController = NSHostingController(rootView: makeView())
            panel.contentView = hostingController.view
            let windowController = NSWindowController(window: panel)
            windows.append(WindowEntry(
                screenIdentity: RecorderDisplayReusePolicy.screenIdentity(
                    for: screen,
                    index: index
                ),
                panel: panel,
                windowController: windowController
            ))
            panel.show(on: screen)
        }
    }

    private func presentationReport(for screens: [NSScreen]) -> RecorderPanelPresentationReport {
        let screensByIdentity = Dictionary(
            screens.enumerated().map { index, screen in
                (RecorderDisplayReusePolicy.screenIdentity(for: screen, index: index), screen)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let currentEntries = windows.filter { screensByIdentity[$0.screenIdentity] != nil }
        let visibleOnScreenCount = currentEntries.reduce(into: 0) { count, entry in
            guard let screen = screensByIdentity[entry.screenIdentity] else { return }
            if entry.panel.isVisible && entry.panel.frame.intersects(screen.frame) {
                count += 1
            }
        }

        return RecorderPanelPresentationReport(
            expectedScreenCount: screens.count,
            materializedPanelCount: currentEntries.count,
            visibleOnScreenPanelCount: visibleOnScreenCount
        )
    }

    private func deinitializeWindows() {
        windows.forEach {
            $0.panel.orderOut(nil)
            $0.windowController.close()
        }
        windows.removeAll()
    }
}
