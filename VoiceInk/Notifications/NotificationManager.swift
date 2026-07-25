import SwiftUI
import AppKit

@MainActor
protocol NotificationRecorderPlacementProviding: AnyObject {
    func notificationBottomReservedHeight(on screen: NSScreen) -> CGFloat?
}

class NotificationManager {
    static let shared = NotificationManager()

    private var notificationWindow: NSPanel?
    private var dismissTimer: Timer?
    private weak var recorderPlacementProvider: NotificationRecorderPlacementProviding?

    private init() {}

    @MainActor
    func setRecorderPlacementProvider(
        _ provider: NotificationRecorderPlacementProviding
    ) {
        recorderPlacementProvider = provider
    }

    @MainActor
    func showNotification(
        title: String,
        type: AppNotificationView.NotificationType,
        duration: TimeInterval = 3.0,
        playSound: Bool = true,
        onTap: (() -> Void)? = nil,
        actionButton: (label: String, action: () -> Void)? = nil
    ) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        if let existingWindow = notificationWindow {
            existingWindow.close()
            notificationWindow = nil
        }
        
        // Errors remain audible by default. Callers may suppress only the sound when
        // a warning is intentionally advisory while preserving the visible evidence.
        if type == .error && playSound {
            SoundManager.shared.playEscSound()
        }

        // Errors are diagnostic evidence, not momentary success feedback. Leave them
        // visible long enough to select and copy, and provide a one-click fallback for
        // nonactivating panels where the user's current app may still own Command-C.
        let effectiveDuration = type == .error ? max(duration, 12.0) : duration
        let effectiveActionButton: (label: String, action: () -> Void)?
        if let actionButton {
            effectiveActionButton = actionButton
        } else if type == .error {
            effectiveActionButton = (
                label: String(localized: "Copy"),
                action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(title, forType: .string)
                }
            )
        } else {
            effectiveActionButton = nil
        }
        
        let notificationView = AppNotificationView(
            title: title,
            type: type,
            duration: effectiveDuration,
            onClose: { [weak self] in
                Task { @MainActor in
                    self?.dismissNotification()
                }
            },
            onTap: onTap,
            actionButton: effectiveActionButton
        )
        let hostingController = NSHostingController(rootView: notificationView)
        let size = hostingController.view.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.contentView = hostingController.view
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level.mainMenu
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        
        positionWindow(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil as Any?)
        
        self.notificationWindow = panel
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        })
        
        // Schedule a new timer to dismiss the new notification.
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: effectiveDuration,
            repeats: false
        ) { [weak self] _ in
            self?.dismissNotification()
        }
    }

    @MainActor
    private func positionWindow(_ window: NSWindow) {
        let activeScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenRect = activeScreen.visibleFrame
        let notificationRect = window.frame

        // When the mini recorder is visible, clear its real rendered envelope—not
        // the old fixed 34pt estimate. Realtime text and stacked recordings make
        // that envelope taller. If no mini recorder owns the bottom edge, retain
        // the historical ordinary-notification position.
        let defaultBottomReservedHeight: CGFloat = 24 + 34
        let bottomReservedHeight =
            recorderPlacementProvider?.notificationBottomReservedHeight(on: activeScreen)
            ?? defaultBottomReservedHeight

        window.setFrameOrigin(
            Self.notificationOrigin(
                screenRect: screenRect,
                notificationSize: notificationRect.size,
                bottomReservedHeight: bottomReservedHeight
            )
        )
    }

    static func notificationOrigin(
        screenRect: NSRect,
        notificationSize: NSSize,
        bottomReservedHeight: CGFloat
    ) -> NSPoint {
        let spacing: CGFloat = 16
        let x = screenRect.midX - (notificationSize.width / 2)
        let proposedY = screenRect.minY + bottomReservedHeight + spacing
        let maximumY = screenRect.maxY - notificationSize.height - spacing
        let y = max(screenRect.minY + spacing, min(proposedY, maximumY))
        return NSPoint(x: x, y: y)
    }

    @MainActor
    func dismissNotification() {
        guard let window = notificationWindow else { return }
        
        notificationWindow = nil
        
        dismissTimer?.invalidate()
        dismissTimer = nil
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.close()

        })
    }
}
