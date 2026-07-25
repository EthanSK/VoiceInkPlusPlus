import SwiftUI
import AppKit

/// Shared geometry for the bottom-anchored mini recorder and notifications that
/// must clear it. Keep these values as the single source of truth: a hard-coded
/// notification offset previously assumed a 34pt bar and overlapped the 97pt
/// real-time transcript HUD.
enum MiniRecorderLayoutMetrics {
    static let bottomPadding: CGFloat = 24
    static let controlBarHeight: CGFloat = 40
    static let liveTranscriptHeight: CGFloat = 56
    static let separatorHeight: CGFloat = 1
    static let assistantPanelHeight: CGFloat = 320
    static let stackedCardSpacing: CGFloat = 46

    static func notificationBottomReservedHeight(
        showsAssistant: Bool,
        showsRealtimeTranscript: Bool,
        sessionCount: Int
    ) -> CGFloat {
        let baseHeight: CGFloat
        if showsAssistant {
            baseHeight = assistantPanelHeight + separatorHeight + controlBarHeight
        } else if showsRealtimeTranscript {
            baseHeight = liveTranscriptHeight + separatorHeight + controlBarHeight
        } else {
            baseHeight = controlBarHeight
        }

        let stackedHeight = CGFloat(max(0, sessionCount - 1)) * stackedCardSpacing
        return bottomPadding + baseHeight + stackedHeight
    }
}

class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }
    
    private func configurePanel() {
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }
    
    static func calculateWindowMetrics(for screen: NSScreen? = NSScreen.main) -> NSRect {
        let width: CGFloat = 540
        let height: CGFloat = 430

        guard let screen else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }

        // Host stays large enough for assistant output; SwiftUI controls the visible mini width.
        let visibleFrame = screen.visibleFrame
        let centerX = visibleFrame.midX
        let xPosition = centerX - (width / 2)
        let yPosition = visibleFrame.minY + MiniRecorderLayoutMetrics.bottomPadding

        return NSRect(
            x: xPosition,
            y: yPosition,
            width: width,
            height: height
        )
    }

    func show(on screen: NSScreen) {
        let metrics = MiniRecorderPanel.calculateWindowMetrics(for: screen)
        setFrame(metrics, display: true)
        orderFrontRegardless()
    }
    
} 
