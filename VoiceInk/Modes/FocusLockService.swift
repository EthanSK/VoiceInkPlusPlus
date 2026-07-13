import Foundation
import AppKit
import ApplicationServices
import os

@MainActor
final class FocusLockService: ObservableObject {
    struct Target {
        struct DisplayInfo {
            let applicationName: String
            let inputName: String
            let applicationIcon: NSImage?
        }

        fileprivate let element: AXUIElement
        fileprivate let app: NSRunningApplication
        fileprivate let pid: pid_t
        let bundleIdentifier: String?
        let displayInfo: DisplayInfo
        var processIdentifier: pid_t { pid }
    }

    static let shared = FocusLockService()
    static let longPressThreshold: TimeInterval = 0.45

    @Published private(set) var isLockActive = false
    private(set) var stopHoldDecisionPending = false

    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "FocusLock")
    private let activationTimeout: TimeInterval = 1
    private let focusVerificationTimeout: TimeInterval = 0.25
    private let focusPollInterval: UInt64 = 20_000_000

    private init() {}

    func captureFocusedInput() -> Target? {
        guard AXIsProcessTrusted() else {
            logger.error("Focused input capture failed because Accessibility is not trusted")
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            logger.error("Focused input capture failed with AX error \(focusedResult.rawValue)")
            return nil
        }

        let element = focusedValue as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            logger.error("Focused input capture could not resolve a live owning application")
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        guard isEditableInput(role: role, subrole: subrole) else {
            logger.error("Focused input capture rejected non-editable element pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
            return nil
        }

        logger.info("Captured editable input pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
        return Target(
            element: element,
            app: app,
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: app.localizedName ?? app.bundleIdentifier ?? String(localized: "Unknown app"),
                inputName: inputDisplayName(for: element),
                applicationIcon: app.icon
            )
        )
    }

    func showRecordingStartInput(_ target: Target?) {
        guard let target else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Recording start input unavailable — focus a text input before recording"),
                type: .warning,
                duration: 2.5
            )
            return
        }

        NotificationManager.shared.showNotification(
            title: "Recording start input: \(target.displayInfo.applicationName) — \(target.displayInfo.inputName)",
            type: .info,
            duration: 1.5
        )
    }

    func showPendingPasteInput(_ target: Target?) {
        guard let target else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Paste target unchanged — focus a text input and press Next Track again"),
                type: .warning,
                duration: 2.5
            )
            return
        }

        NotificationManager.shared.showNotification(
            title: "Pending transcription target: \(target.displayInfo.applicationName) — \(target.displayInfo.inputName)",
            type: .info,
            duration: 2
        )
    }

    func prepareBackgroundFocus(to target: Target) -> Bool {
        guard AXIsProcessTrusted() else {
            logger.error("Background focused input preparation failed because Accessibility is not trusted")
            return false
        }
        guard !target.app.isTerminated else {
            logger.error("Background focused input preparation failed because the target application terminated")
            return false
        }

        if isFocused(target.element) || applicationFocusedElement(pid: target.pid).map({ CFEqual($0, target.element) }) == true {
            logger.info("Background focused input already matches target pid=\(target.pid, privacy: .public) elementHash=\(CFHash(target.element), privacy: .public)")
            return true
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        let restoreResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            target.element
        )
        guard restoreResult == .success else {
            logger.error("Background focused input preparation failed with AX error \(restoreResult.rawValue) pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return false
        }
        let applicationFocusedElement = applicationFocusedElement(pid: target.pid)
        guard isFocused(target.element) || applicationFocusedElement.map({ CFEqual($0, target.element) }) == true else {
            logger.error("Background focused input preparation was accepted by AX but direct target focus verification failed pid=\(target.pid, privacy: .public) targetElementHash=\(CFHash(target.element), privacy: .public) appFocusedElementHash=\(applicationFocusedElement.map { String(CFHash($0)) } ?? "nil", privacy: .public)")
            return false
        }

        logger.info("Prepared and verified background focused input pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) elementHash=\(CFHash(target.element), privacy: .public)")
        return true
    }

    func restoreFocus(to target: Target) async -> Bool {
        guard AXIsProcessTrusted() else {
            logger.error("Focused input restore failed because Accessibility is not trusted")
            return false
        }
        guard !target.app.isTerminated else {
            logger.error("Focused input restore failed because the target application terminated")
            return false
        }

        let restoreStarted = ProcessInfo.processInfo.systemUptime
        let frontmostPIDBeforeRestore = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        logger.info("Focused input restore BEGIN targetPid=\(target.pid, privacy: .public) targetBundle=\(target.bundleIdentifier ?? "nil", privacy: .public) targetRole=\(self.stringAttribute(kAXRoleAttribute, from: target.element) ?? "nil", privacy: .public) targetSubrole=\(self.stringAttribute(kAXSubroleAttribute, from: target.element) ?? "nil", privacy: .public) targetElementHash=\(CFHash(target.element), privacy: .public) frontmostPid=\(frontmostPIDBeforeRestore, privacy: .public)")

        if frontmostPIDBeforeRestore != target.pid {
            let activationAccepted = await activate(target)
            logger.info("Focused input restore requested app activation accepted=\(activationAccepted, privacy: .public) targetPid=\(target.pid, privacy: .public)")
            guard await waitForFrontmostApplication(pid: target.pid, timeout: activationTimeout) else {
                logger.error("Focused input restore failed waiting for target app to become frontmost targetPid=\(target.pid, privacy: .public) currentFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public) waitedMillis=\(Int((ProcessInfo.processInfo.systemUptime - restoreStarted) * 1_000), privacy: .public)")
                return false
            }
            logger.info("Focused input restore target app became frontmost targetPid=\(target.pid, privacy: .public) waitedMillis=\(Int((ProcessInfo.processInfo.systemUptime - restoreStarted) * 1_000), privacy: .public)")
        } else {
            logger.info("Focused input restore skipped app activation because target is already frontmost targetPid=\(target.pid, privacy: .public)")
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        let restoreResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            target.element
        )
        guard restoreResult == .success else {
            logger.error("Focused input restore failed with AX error \(restoreResult.rawValue) pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return false
        }

        guard await waitForFocusedElement(target, timeout: focusVerificationTimeout) else {
            let actualFocus = systemFocusedElement()
            logger.error("Focused input restore was accepted by AX but verification failed targetPid=\(target.pid, privacy: .public) targetElementHash=\(CFHash(target.element), privacy: .public) actualPid=\(actualFocus?.pid ?? -1, privacy: .public) actualElementHash=\(actualFocus.map { String(CFHash($0.element)) } ?? "nil", privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return false
        }

        logger.info("Restored and verified focused input pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) elementHash=\(CFHash(target.element), privacy: .public) totalMillis=\(Int((ProcessInfo.processInfo.systemUptime - restoreStarted) * 1_000), privacy: .public)")
        return true
    }

    private func activate(_ target: Target) async -> Bool {
        if target.app.activate(options: .activateAllWindows) { // No-argument activation returned false for Codex during a real recording-start restore, so cross-app delivery deliberately requests all target windows before using the workspace fallback.
            logger.info("Focused input restore activation succeeded through NSRunningApplication targetPid=\(target.pid, privacy: .public)")
            return true
        }

        guard let bundleURL = target.app.bundleURL else {
            logger.error("Focused input restore activation fallback unavailable because the target app has no bundle URL targetPid=\(target.pid, privacy: .public)")
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { application, error in
                if let error {
                    self.logger.error("Focused input restore activation fallback failed targetPid=\(target.pid, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
                let activatedExpectedProcess = application?.processIdentifier == target.pid
                self.logger.info("Focused input restore activation fallback completed targetPid=\(target.pid, privacy: .public) activatedPid=\(application?.processIdentifier ?? -1, privacy: .public) matched=\(activatedExpectedProcess, privacy: .public)")
                continuation.resume(returning: activatedExpectedProcess)
            }
        }
    }

    private func waitForFrontmostApplication(pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            try? await Task.sleep(nanoseconds: focusPollInterval)
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func waitForFocusedElement(_ target: Target, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let focusedInput = systemFocusedElement(),
               focusedInput.pid == target.pid,
               CFEqual(focusedInput.element, target.element) {
                return true
            }
            try? await Task.sleep(nanoseconds: focusPollInterval)
        }
        guard let focusedInput = systemFocusedElement() else { return false }
        return focusedInput.pid == target.pid && CFEqual(focusedInput.element, target.element)
    }

    private func systemFocusedElement() -> (element: AXUIElement, pid: pid_t)? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = focusedValue as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return (element, pid)
    }

    private func applicationFocusedElement(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = focusedValue as! AXUIElement
        return element
    }

    private func isFocused(_ element: AXUIElement) -> Bool {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            &focusedValue
        ) == .success else {
            return false
        }
        return focusedValue as? Bool == true // Electron can return a different app-scoped AX wrapper for the same editor, so the saved element's own AXFocused state is the authoritative background verification.
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func inputDisplayName(for element: AXUIElement) -> String {
        let attributes = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
        if let label = attributes.lazy.compactMap({ self.stringAttribute($0, from: element) }).first(where: { !$0.isEmpty }) {
            return label
        }

        if stringAttribute(kAXSubroleAttribute, from: element) == kAXSearchFieldSubrole {
            return String(localized: "search field")
        }

        switch stringAttribute(kAXRoleAttribute, from: element) {
        case kAXTextAreaRole:
            return String(localized: "text area")
        case kAXTextFieldRole:
            return String(localized: "text field")
        case .some(let role):
            return role.replacingOccurrences(of: "AX", with: "")
        case .none:
            return String(localized: "focused input")
        }
    }

    private func isEditableInput(role: String?, subrole: String?) -> Bool {
        if subrole == kAXSearchFieldSubrole {
            return true
        }

        switch role {
        case kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole:
            return true
        case .some(_), .none:
            return false
        }
    }

    func setStartInputIndicatorVisible(_ visible: Bool) {
        isLockActive = visible
    }

    func setStopHoldDecisionPending(_ pending: Bool) {
        stopHoldDecisionPending = pending
    }

    func captureCandidate() {}

    func promoteToLock() {
        isLockActive = true
    }

    func clearCandidate() {}

    func requiredModifiersStillHeld(required: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
        let wanted = required.intersection(relevant)
        guard !wanted.isEmpty else { return false }
        return NSEvent.modifierFlags.intersection(relevant).isSuperset(of: wanted)
    }

    func clearLock() {
        isLockActive = false
        stopHoldDecisionPending = false
    }
}
