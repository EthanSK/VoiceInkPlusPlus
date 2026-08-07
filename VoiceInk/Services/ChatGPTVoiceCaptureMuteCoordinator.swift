import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import os

enum ChatGPTVoiceMicrophoneState: Equatable, Hashable, Sendable {
    case listening
    case muted
}

struct ChatGPTVoiceInputSnapshot: Equatable, Sendable {
    let applicationPID: pid_t
    let isInputRunning: Bool
    let microphoneState: ChatGPTVoiceMicrophoneState?
}

protocol ChatGPTVoiceMuteTransport: Sendable {
    func snapshot() async -> ChatGPTVoiceInputSnapshot?
    func postMicrophoneToggle(to applicationPID: pid_t) async -> Bool
    func waitForMicrophoneState(
        _ microphoneState: ChatGPTVoiceMicrophoneState,
        applicationPID: pid_t
    ) async -> Bool
}

/// Owns one narrowly scoped lease over ChatGPT Voice's supported microphone-toggle shortcut.
///
/// This is intentionally driven by `Recorder`'s real hardware-capture boundaries rather than by
/// transcription jobs or `RecordingActivityNotifier`: a finished recording may keep transcribing
/// after the microphone belongs to a newer session, while the notifier is reserved for the proven
/// YouTube playback bridge. The coordinator never mutates Accessibility, changes global input
/// state, activates ChatGPT, or moves the pointer.
///
/// Core Audio proves that an actual ChatGPT Voice session exists, but ChatGPT deliberately keeps
/// that process input stream running while its Voice microphone is muted. Mute ownership therefore
/// uses a separate read-only Accessibility state check against the exact `Mute microphone` /
/// `Unmute microphone` control. Accessibility is never used to activate ChatGPT, set focus, press
/// the control, or move the pointer; the only mutation remains the user-configured keyboard command.
/// VoiceInk++ deliberately does not poll that tree while recording—the rejected polling experiment
/// caused lag. Restoration performs one bounded check and occurs only for the same process while the
/// control still proves the muted state we own; a user-visible unmute therefore relinquishes the
/// lease without an inverse toggle.
actor ChatGPTVoiceCaptureMuteCoordinator {
    static let shared = ChatGPTVoiceCaptureMuteCoordinator(
        transport: SystemChatGPTVoiceMuteTransport()
    )

    private let transport: any ChatGPTVoiceMuteTransport
    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "ChatGPTVoiceCaptureMute"
    )

    private var lastRequestedCaptureState = false
    private var appliedCaptureState = false
    private var ownedMutedApplicationPID: pid_t?
    private var transitionTail: Task<Void, Never> = Task {}

    init(transport: any ChatGPTVoiceMuteTransport) {
        self.transport = transport
    }

    /// Queue the actual microphone-capture state. Transitions are FIFO so an older stop can never
    /// run after and unmute a newer recording; the final queued state always wins.
    func setCaptureActive(_ isActive: Bool) {
        guard lastRequestedCaptureState != isActive else { return }
        lastRequestedCaptureState = isActive

        let previous = transitionTail
        transitionTail = Task { [weak self] in
            await previous.value
            guard !Task.isCancelled else { return }
            await self?.applyCaptureState(isActive)
        }
    }

    func waitForPendingTransitionsForTesting() async {
        let tail = transitionTail
        await tail.value
    }

    func stateForTesting() -> (captureActive: Bool, ownedMutedApplicationPID: pid_t?) {
        (appliedCaptureState, ownedMutedApplicationPID)
    }

    private func applyCaptureState(_ isActive: Bool) async {
        guard appliedCaptureState != isActive else { return }
        appliedCaptureState = isActive

        if isActive {
            await suppressChatGPTVoiceIfNeeded()
        } else {
            await restoreChatGPTVoiceIfOwned()
        }
    }

    private func suppressChatGPTVoiceIfNeeded() async {
        guard ownedMutedApplicationPID == nil else { return }
        guard let before = await transport.snapshot() else {
            logger.debug("Capture began without one resolvable ChatGPT application; listener suppression is a no-op")
            return
        }
        guard before.isInputRunning else {
            // An absent Voice session must remain untouched: a blind toggle could affect a later
            // session or another app state that VoiceInk++ does not own.
            logger.debug("Capture began while ChatGPT had no active input stream; microphone toggle was not posted pid=\(before.applicationPID, privacy: .public)")
            return
        }
        guard before.microphoneState == .listening else {
            // Already-muted and unreadable controls are both fail-closed. VoiceInk++ must not
            // unmute a user-owned state merely because hardware capture began.
            logger.debug("Capture began without one verified listening ChatGPT Voice control; microphone toggle was not posted pid=\(before.applicationPID, privacy: .public)")
            return
        }
        guard await transport.postMicrophoneToggle(to: before.applicationPID) else {
            logger.error("Could not post the configured ChatGPT Voice microphone shortcut pid=\(before.applicationPID, privacy: .public)")
            return
        }
        guard await transport.waitForMicrophoneState(
            .muted,
            applicationPID: before.applicationPID
        ) else {
            // Event creation/posting is not success. Without the read-only control-state proof we do not
            // claim ownership and therefore will not risk a later inverse toggle.
            logger.error("ChatGPT Voice microphone shortcut was not verified as muted pid=\(before.applicationPID, privacy: .public)")
            return
        }

        ownedMutedApplicationPID = before.applicationPID
        logger.notice("VoiceInk++ verified and owns ChatGPT Voice microphone suppression pid=\(before.applicationPID, privacy: .public)")
    }

    private func restoreChatGPTVoiceIfOwned() async {
        guard let ownedPID = ownedMutedApplicationPID else { return }
        guard let current = await transport.snapshot(),
              current.applicationPID == ownedPID else {
            ownedMutedApplicationPID = nil
            logger.notice("ChatGPT process changed or exited; stale microphone-suppression ownership was discarded pid=\(ownedPID, privacy: .public)")
            return
        }
        guard current.microphoneState == .muted else {
            ownedMutedApplicationPID = nil
            logger.notice("ChatGPT Voice microphone was no longer provably muted by VoiceInk++; restoration ownership was relinquished pid=\(ownedPID, privacy: .public)")
            return
        }
        guard await transport.postMicrophoneToggle(to: ownedPID) else {
            // Keep the lease rather than lying that we restored it. A later real capture cycle can
            // still observe a user unmute and relinquish this stale ownership safely.
            logger.error("Could not post owned ChatGPT Voice microphone restoration pid=\(ownedPID, privacy: .public)")
            return
        }

        let restored = await transport.waitForMicrophoneState(.listening, applicationPID: ownedPID)
        ownedMutedApplicationPID = nil
        if restored {
            logger.notice("VoiceInk++ verified ChatGPT Voice microphone restoration pid=\(ownedPID, privacy: .public)")
        } else {
            // The Voice session may have ended while muted. One targeted toggle was already sent;
            // never retry an unverified toggle because a late first action could invert the state.
            logger.notice("Owned ChatGPT Voice restoration was not observable; ownership ended without retry pid=\(ownedPID, privacy: .public)")
        }
    }

}

final class SystemChatGPTVoiceMuteTransport: ChatGPTVoiceMuteTransport, @unchecked Sendable {
    static let applicationPath = "/Applications/ChatGPT.app"
    static let shortcutCommand = "realtimeVoice.toggleMicrophoneMute"
    static let shortcutAccelerator = "Command+Control+Option+Shift+F20"

    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "ChatGPTVoiceMuteTransport"
    )

    func snapshot() async -> ChatGPTVoiceInputSnapshot? {
        await Task.detached(priority: .utility) {
            Self.readSnapshot()
        }.value
    }

    func postMicrophoneToggle(to applicationPID: pid_t) async -> Bool {
        await Task.detached(priority: .userInitiated) { [logger] in
            guard Self.hasExpectedShortcutBinding() else {
                logger.error("ChatGPT Voice microphone shortcut is missing or changed; refusing targeted input")
                return false
            }
            guard Self.isExpectedChatGPTApplicationPID(applicationPID) else {
                logger.error("Refusing ChatGPT Voice shortcut because the target is not /Applications/ChatGPT.app pid=\(applicationPID, privacy: .public)")
                return false
            }
            guard AXIsProcessTrusted(),
                  let source = CGEventSource(stateID: .privateState),
                  let keyDown = CGEvent(
                      keyboardEventSource: source,
                      virtualKey: CGKeyCode(kVK_F20),
                      keyDown: true
                  ),
                  let keyUp = CGEvent(
                      keyboardEventSource: source,
                      virtualKey: CGKeyCode(kVK_F20),
                      keyDown: false
                  ) else {
                logger.error("Could not create the targeted ChatGPT Voice shortcut sequence")
                return false
            }

            let flags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            keyDown.flags = flags
            keyUp.flags = flags
            keyDown.timestamp = mach_absolute_time()
            keyDown.postToPid(applicationPID)
            keyUp.timestamp = mach_absolute_time()
            keyUp.postToPid(applicationPID)
            logger.info("Posted one pointer-free ChatGPT Voice microphone shortcut pid=\(applicationPID, privacy: .public)")
            return true
        }.value
    }

    func waitForMicrophoneState(
        _ microphoneState: ChatGPTVoiceMicrophoneState,
        applicationPID: pid_t
    ) async -> Bool {
        for _ in 0..<8 {
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return false
            }
            guard let current = await snapshot(),
                  current.applicationPID == applicationPID else {
                return false
            }
            if current.microphoneState == microphoneState {
                return true
            }
        }
        return false
    }

    static func readSnapshot() -> ChatGPTVoiceInputSnapshot? {
        let matchingApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).filter { app in
            guard !app.isTerminated,
                  let bundleURL = app.bundleURL else { return false }
            return normalizedPath(bundleURL.path) == normalizedPath(applicationPath)
        }
        guard matchingApps.count == 1,
              let application = matchingApps.first,
              isExpectedChatGPTApplicationPID(application.processIdentifier) else {
            return nil
        }

        let processObjects = coreAudioProcessObjects()
        let inputIsRunning = processObjects.contains { processObject in
            guard let pid = processPID(for: processObject),
                  let executablePath = executablePath(for: pid),
                  belongsToChatGPTApplication(executablePath) else {
                return false
            }
            return uint32Property(
                kAudioProcessPropertyIsRunningInput,
                object: processObject
            ) == 1
        }
        return ChatGPTVoiceInputSnapshot(
            applicationPID: application.processIdentifier,
            isInputRunning: inputIsRunning,
            microphoneState: microphoneState(applicationPID: application.processIdentifier)
        )
    }

    /// Reads only the current accessible label of ChatGPT Voice's microphone button. The previous
    /// listener experiment failed because `AXPress` could report success without changing state and
    /// its pointer fallback stole Ethan's mouse. This bounded traversal performs no AX action or
    /// attribute write; it exists solely to make the proven keyboard-command lease reversible.
    static func microphoneState(applicationPID: pid_t) -> ChatGPTVoiceMicrophoneState? {
        guard AXIsProcessTrusted(),
              isExpectedChatGPTApplicationPID(applicationPID) else {
            return nil
        }

        let application = AXUIElementCreateApplication(applicationPID)
        let windows = elementArrayAttribute(kAXWindowsAttribute, from: application)
        var queue = (windows.isEmpty ? [application] : windows).map { ($0, 0) }
        var index = 0
        var visited: [AXUIElement] = []
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))

        while index < queue.count,
              visited.count < 700,
              ContinuousClock.now < deadline {
            let (element, depth) = queue[index]
            index += 1
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)

            if stringAttribute(kAXRoleAttribute, from: element) == kAXButtonRole,
               boolAttribute(kAXEnabledAttribute, from: element) != false {
                for attribute in [
                    kAXTitleAttribute,
                    kAXDescriptionAttribute,
                    kAXHelpAttribute,
                    kAXValueAttribute
                ] {
                    guard let label = stringAttribute(attribute, from: element),
                          let state = microphoneState(accessibilityLabel: label) else {
                        continue
                    }
                    return state
                }
            }

            guard depth < 14 else { continue }
            let children = mergedChildren(of: element)
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }

        return nil
    }

    static func microphoneState(
        accessibilityLabel: String
    ) -> ChatGPTVoiceMicrophoneState? {
        let normalized = accessibilityLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "mute microphone":
            return .listening
        case "unmute microphone":
            return .muted
        default:
            return nil
        }
    }

    private static func mergedChildren(of element: AXUIElement) -> [AXUIElement] {
        let attributes = [
            "AXChildrenInNavigationOrder",
            kAXVisibleChildrenAttribute,
            kAXChildrenAttribute
        ]
        var merged: [AXUIElement] = []
        for attribute in attributes {
            for candidate in elementArrayAttribute(attribute, from: element)
                where !merged.contains(where: { CFEqual($0, candidate) }) {
                merged.append(candidate)
            }
        }
        return merged
    }

    private static func elementArrayAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    static func belongsToChatGPTApplication(_ executablePath: String) -> Bool {
        let normalizedExecutable = normalizedPath(executablePath)
        let normalizedApplication = normalizedPath(applicationPath)
        return normalizedExecutable == normalizedApplication
            || normalizedExecutable.hasPrefix(normalizedApplication + "/Contents/")
    }

    static func hasExpectedShortcutBinding(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/keybindings.json")
    ) -> Bool {
        struct Binding: Decodable {
            let command: String
            let key: String?
        }

        guard let data = try? Data(contentsOf: url),
              let bindings = try? JSONDecoder().decode([Binding].self, from: data) else {
            return false
        }
        return bindings.contains {
            $0.command == shortcutCommand && $0.key == shortcutAccelerator
        }
    }

    private static func isExpectedChatGPTApplicationPID(_ pid: pid_t) -> Bool {
        guard let path = executablePath(for: pid) else { return false }
        return normalizedPath(path) == normalizedPath(
            applicationPath + "/Contents/MacOS/ChatGPT"
        )
    }

    private static func coreAudioProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size > 0 else {
            return []
        }

        var processObjects = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &processObjects
        ) == noErr else {
            return []
        }
        return processObjects
    }

    private static func processPID(for processObject: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObject,
            &address,
            0,
            nil,
            &size,
            &pid
        ) == noErr,
        pid > 0 else {
            return nil
        }
        return pid
    }

    private static func uint32Property(
        _ selector: AudioObjectPropertySelector,
        object: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
