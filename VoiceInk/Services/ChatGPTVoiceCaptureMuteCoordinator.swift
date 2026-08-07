import AppKit
import Carbon.HIToolbox
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import os

struct ChatGPTVoiceInputSnapshot: Equatable, Sendable {
    let applicationPID: pid_t
    let isInputRunning: Bool
}

protocol ChatGPTVoiceMuteTransport: Sendable {
    func snapshot() async -> ChatGPTVoiceInputSnapshot?
    func postMicrophoneToggle(to applicationPID: pid_t) async -> Bool
    func waitForInputState(
        _ isInputRunning: Bool,
        applicationPID: pid_t
    ) async -> Bool
}

/// Owns one narrowly scoped lease over ChatGPT Voice's supported microphone-toggle shortcut.
///
/// This is intentionally driven by `Recorder`'s real hardware-capture boundaries rather than by
/// transcription jobs or `RecordingActivityNotifier`: a finished recording may keep transcribing
/// after the microphone belongs to a newer session, while the notifier is reserved for the proven
/// YouTube playback bridge. The coordinator never uses Accessibility, changes global input state,
/// activates ChatGPT, or moves the pointer.
///
/// A mute is owned only after Core Audio proves that ChatGPT changed from an active input stream to
/// an inactive one following our one targeted shortcut. Restoration is therefore safe and bounded:
/// it occurs only for the same running ChatGPT process, only while input is still inactive, and only
/// after the matching capture stop/pause. If input becomes active independently, the user or
/// ChatGPT has overridden us and ownership is relinquished without sending another toggle.
actor ChatGPTVoiceCaptureMuteCoordinator {
    static let shared = ChatGPTVoiceCaptureMuteCoordinator(
        transport: SystemChatGPTVoiceMuteTransport()
    )

    private let transport: any ChatGPTVoiceMuteTransport
    private let ownershipPollNanoseconds: UInt64
    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "ChatGPTVoiceCaptureMute"
    )

    private var lastRequestedCaptureState = false
    private var appliedCaptureState = false
    private var ownedMutedApplicationPID: pid_t?
    private var ownershipMonitorTask: Task<Void, Never>?
    private var transitionTail: Task<Void, Never> = Task {}

    init(
        transport: any ChatGPTVoiceMuteTransport,
        ownershipPollNanoseconds: UInt64 = 100_000_000
    ) {
        self.transport = transport
        self.ownershipPollNanoseconds = ownershipPollNanoseconds
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
        guard ownedMutedApplicationPID == nil else {
            startOwnershipMonitorIfNeeded()
            return
        }
        guard let before = await transport.snapshot() else {
            logger.debug("Capture began without one resolvable ChatGPT application; listener suppression is a no-op")
            return
        }
        guard before.isInputRunning else {
            // Core Audio cannot distinguish an absent Voice session from one Ethan already muted.
            // Both must remain untouched: toggling either would risk starting or unmuting listening.
            logger.debug("Capture began while ChatGPT had no active input stream; microphone toggle was not posted pid=\(before.applicationPID, privacy: .public)")
            return
        }
        guard await transport.postMicrophoneToggle(to: before.applicationPID) else {
            logger.error("Could not post the configured ChatGPT Voice microphone shortcut pid=\(before.applicationPID, privacy: .public)")
            return
        }
        guard await transport.waitForInputState(
            false,
            applicationPID: before.applicationPID
        ) else {
            // Event creation/posting is not success. Without Core Audio confirmation we do not
            // claim ownership and therefore will not risk a later inverse toggle.
            logger.error("ChatGPT Voice microphone shortcut was not verified as muted pid=\(before.applicationPID, privacy: .public)")
            return
        }

        ownedMutedApplicationPID = before.applicationPID
        logger.notice("VoiceInk++ verified and owns ChatGPT Voice microphone suppression pid=\(before.applicationPID, privacy: .public)")
        startOwnershipMonitorIfNeeded()
    }

    private func restoreChatGPTVoiceIfOwned() async {
        stopOwnershipMonitor()
        guard let ownedPID = ownedMutedApplicationPID else { return }
        guard let current = await transport.snapshot(),
              current.applicationPID == ownedPID else {
            ownedMutedApplicationPID = nil
            logger.notice("ChatGPT process changed or exited; stale microphone-suppression ownership was discarded pid=\(ownedPID, privacy: .public)")
            return
        }
        guard !current.isInputRunning else {
            ownedMutedApplicationPID = nil
            logger.notice("ChatGPT input became active outside VoiceInk++; restoration ownership was relinquished pid=\(ownedPID, privacy: .public)")
            return
        }
        guard await transport.postMicrophoneToggle(to: ownedPID) else {
            // Keep the lease rather than lying that we restored it. A later real capture cycle can
            // still observe a user unmute and relinquish this stale ownership safely.
            logger.error("Could not post owned ChatGPT Voice microphone restoration pid=\(ownedPID, privacy: .public)")
            return
        }

        let restored = await transport.waitForInputState(true, applicationPID: ownedPID)
        ownedMutedApplicationPID = nil
        if restored {
            logger.notice("VoiceInk++ verified ChatGPT Voice microphone restoration pid=\(ownedPID, privacy: .public)")
        } else {
            // The Voice session may have ended while muted. One targeted toggle was already sent;
            // never retry an unverified toggle because a late first action could invert the state.
            logger.notice("Owned ChatGPT Voice restoration was not observable; ownership ended without retry pid=\(ownedPID, privacy: .public)")
        }
    }

    private func startOwnershipMonitorIfNeeded() {
        guard ownershipMonitorTask == nil,
              let ownedPID = ownedMutedApplicationPID,
              appliedCaptureState else { return }

        let transport = self.transport
        let interval = ownershipPollNanoseconds
        ownershipMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let current = await transport.snapshot()
                await self?.handleOwnershipObservation(current, expectedPID: ownedPID)
                guard await self?.stillOwnsSuppression(for: ownedPID) == true else { return }
            }
        }
    }

    private func handleOwnershipObservation(
        _ current: ChatGPTVoiceInputSnapshot?,
        expectedPID: pid_t
    ) {
        guard appliedCaptureState,
              ownedMutedApplicationPID == expectedPID else { return }
        guard let current,
              current.applicationPID == expectedPID else {
            ownedMutedApplicationPID = nil
            ownershipMonitorTask = nil
            logger.notice("ChatGPT process changed or exited during capture; microphone-suppression ownership was discarded pid=\(expectedPID, privacy: .public)")
            return
        }
        guard !current.isInputRunning else {
            ownedMutedApplicationPID = nil
            ownershipMonitorTask = nil
            logger.notice("ChatGPT input was re-enabled externally during capture; VoiceInk++ will not override or restore that user state pid=\(expectedPID, privacy: .public)")
            return
        }
    }

    private func stillOwnsSuppression(for applicationPID: pid_t) -> Bool {
        appliedCaptureState && ownedMutedApplicationPID == applicationPID
    }

    private func stopOwnershipMonitor() {
        ownershipMonitorTask?.cancel()
        ownershipMonitorTask = nil
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

    func waitForInputState(
        _ isInputRunning: Bool,
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
            if current.isInputRunning == isInputRunning {
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
            isInputRunning: inputIsRunning
        )
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
