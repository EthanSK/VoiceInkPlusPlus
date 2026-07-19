import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    weak var voiceInkEngine: VoiceInkEngine?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let menuBarManager = menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.showMainWindow() != nil {
                return false
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    static func shouldBlockTermination(hasInFlightSessions: Bool) -> Bool {
        hasInFlightSessions
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasInFlightSessions = voiceInkEngine?.sessions.isEmpty == false
        guard Self.shouldBlockTermination(
            hasInFlightSessions: hasInFlightSessions
        ) else {
            return .terminateNow
        }

        // A normal quit/release swap must never discard live microphone audio or an
        // in-flight transcription. Returning terminateCancel also makes the external
        // installer abort before it renames the bundle. Force-kill/crash recovery is a
        // separate boundary; this guard protects every cooperative app replacement.
        NotificationManager.shared.showNotification(
            title: String(localized: "VoiceInk++ is still recording or transcribing — finish or cancel it before quitting"),
            type: .error,
            duration: 12
        )
        return .terminateCancel
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI’s WindowGroup-created ContentView and let it process this later.
            pendingOpenFileURL = url
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            menuBarManager?.focusMainWindow()
            NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }
}
