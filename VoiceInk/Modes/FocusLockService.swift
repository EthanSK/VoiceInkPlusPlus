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

        fileprivate let element: AXUIElement?
        fileprivate let app: NSRunningApplication
        fileprivate let pid: pid_t
        let bundleIdentifier: String?
        let displayInfo: DisplayInfo
        var processIdentifier: pid_t { pid }
        var hasExactInput: Bool { element != nil }
    }

    enum NearbySubmitButtonResult: Equatable {
        case pressed
        case unavailable
        case failed(Int32)
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

    func captureFocusedInput(allowApplicationFallback: Bool = false) -> Target? {
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
        let isExactEditableInput = isEditableInput(role: role, subrole: subrole)
        let canUseApplicationFallback = allowApplicationFallback && isApplicationFallbackContainer(role: role)
        guard isExactEditableInput || canUseApplicationFallback else {
            logger.error("Focused input capture rejected non-editable element pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
            return nil
        }

        if isExactEditableInput {
            logger.info("Captured editable input pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
        } else {
            // Electron/Chromium frequently reports AXWebArea while a global shortcut's
            // modifiers are down. Preserve the owning app for the recording-start/Next
            // Track route; delivery can reactivate that app and use its retained focus even
            // when macOS did not expose the exact editor wrapper at capture time.
            logger.notice("Captured recording-start application fallback pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) rejectedRole=\(role ?? "nil", privacy: .public) rejectedSubrole=\(subrole ?? "nil", privacy: .public)")
        }

        // NSWorkspace activation notifications do not fire for non-activating
        // panels such as ChatGPT's floating input. The AX capture above knows the
        // true keyboard-focused owner, so feed it to the recorder's current-app
        // indicator without changing any per-session locked destination semantics.
        ActiveWindowService.shared.updateCurrentApplicationForDisplay(app)

        return Target(
            element: isExactEditableInput ? element : nil,
            app: app,
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: app.localizedName ?? app.bundleIdentifier ?? String(localized: "Unknown app"),
                inputName: isExactEditableInput ? inputDisplayName(for: element) : String(localized: "application focus"),
                applicationIcon: app.icon
            )
        )
    }

    func showRecordingStartInput(_ target: Target?) {
        guard target == nil else { return } // The persistent capsule icon already shows a valid Next Track destination; only interrupt the user when capture failed.
        NotificationManager.shared.showNotification(
            title: String(localized: "Recording start input unavailable — focus a text input before recording"),
            type: .warning,
            duration: 2.5
        )
    }

    func showPendingPasteInputUnavailable() {
        NotificationManager.shared.showNotification(
            title: String(localized: "Paste target unchanged — focus a text input and press Next Track again"),
            type: .warning,
            duration: 2.5
        )
    }

    func restoreFocus(to target: Target, allowApplicationFallback: Bool = false) async -> Bool {
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
        let targetRole = target.element.flatMap { self.stringAttribute(kAXRoleAttribute, from: $0) } ?? "app-fallback"
        let targetSubrole = target.element.flatMap { self.stringAttribute(kAXSubroleAttribute, from: $0) } ?? "nil"
        let targetElementHash = target.element.map { String(CFHash($0)) } ?? "nil"
        logger.info("Focused input restore BEGIN targetPid=\(target.pid, privacy: .public) targetBundle=\(target.bundleIdentifier ?? "nil", privacy: .public) targetRole=\(targetRole, privacy: .public) targetSubrole=\(targetSubrole, privacy: .public) targetElementHash=\(targetElementHash, privacy: .public) frontmostPid=\(frontmostPIDBeforeRestore, privacy: .public)")

        if frontmostPIDBeforeRestore != target.pid {
            guard await activateApplication(target.app) else {
                logger.error("Focused input restore failed waiting for target app to become frontmost targetPid=\(target.pid, privacy: .public) currentFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public) waitedMillis=\(Int((ProcessInfo.processInfo.systemUptime - restoreStarted) * 1_000), privacy: .public)")
                return false
            }
            logger.info("Focused input restore target app became frontmost targetPid=\(target.pid, privacy: .public) waitedMillis=\(Int((ProcessInfo.processInfo.systemUptime - restoreStarted) * 1_000), privacy: .public)")
        } else {
            logger.info("Focused input restore skipped app activation because target is already frontmost targetPid=\(target.pid, privacy: .public)")
        }

        guard let element = target.element else {
            guard allowApplicationFallback else {
                logger.error("Focused input restore rejected an app-only target outside the recording-start route")
                return false
            }
            logger.info("Restored recording-start application fallback targetPid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return true
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        let restoreResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            element
        )
        guard restoreResult == .success else {
            if allowApplicationFallback {
                logger.notice("Foreground recording-start input became stale; using the saved app's current focus pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) AXError=\(restoreResult.rawValue, privacy: .public)")
                return true
            }
            logger.error("Focused input restore failed with AX error \(restoreResult.rawValue) pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return false
        }

        guard await waitForFocusedElement(target, timeout: focusVerificationTimeout) else {
            let actualFocus = systemFocusedElement()
            if allowApplicationFallback, actualFocus?.pid == target.pid {
                logger.notice("Foreground recording-start input wrapper changed; using the saved app's current focus targetPid=\(target.pid, privacy: .public) targetElementHash=\(CFHash(element), privacy: .public) actualElementHash=\(actualFocus.map { String(CFHash($0.element)) } ?? "nil", privacy: .public)")
                return true
            }
            logger.error("Focused input restore was accepted by AX but verification failed targetPid=\(target.pid, privacy: .public) targetElementHash=\(CFHash(element), privacy: .public) actualPid=\(actualFocus?.pid ?? -1, privacy: .public) actualElementHash=\(actualFocus.map { String(CFHash($0.element)) } ?? "nil", privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return false
        }

        logger.info("Restored and verified focused input pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public) totalMillis=\(Int((ProcessInfo.processInfo.systemUptime - restoreStarted) * 1_000), privacy: .public)")
        return true
    }

    /// Read the live editor text for bounded delivery verification. This is not used
    /// to infer focus or choose a destination; it only lets the OpenAI composer path
    /// detect the otherwise invisible "Return was issued but ignored" failure after
    /// the transcript has already been pasted into the saved target.
    func focusedInputText(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) -> String? {
        guard let element = liveElement(for: target, allowApplicationFallback: allowApplicationFallback) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    /// Some Electron chat editors expose an adjacent accessibility button labelled
    /// "Send" even when their text area ignores synthetic Return. Restrict this to
    /// the caller-selected OpenAI composer path and to a small ancestor radius; never
    /// press generic/default buttons elsewhere in the target window.
    func pressNearbySubmitButton(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) -> NearbySubmitButtonResult {
        guard AXIsProcessTrusted() else {
            return .failed(AXError.apiDisabled.rawValue)
        }
        guard !target.app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              var ancestor = liveElement(
                for: target,
                allowApplicationFallback: allowApplicationFallback
              ) else {
            return .unavailable
        }

        for _ in 0..<4 {
            for child in elementArrayAttribute(kAXChildrenAttribute, from: ancestor) {
                guard stringAttribute(kAXRoleAttribute, from: child) == kAXButtonRole,
                      isNearbySubmitLabel(submitLabel(for: child)),
                      boolAttribute(kAXEnabledAttribute, from: child) != false else {
                    continue
                }

                let result = AXUIElementPerformAction(child, kAXPressAction as CFString)
                logger.info("Nearby submit-button press attempted pid=\(target.pid, privacy: .public) label=\(self.submitLabel(for: child) ?? "nil", privacy: .public) result=\(result.rawValue, privacy: .public)")
                return result == .success ? .pressed : .failed(result.rawValue)
            }

            guard let parent = elementAttribute(kAXParentAttribute, from: ancestor) else {
                break
            }
            ancestor = parent
        }

        logger.notice("Nearby submit button unavailable pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
        return .unavailable
    }

    /// Bring a known application to the foreground and verify that macOS actually
    /// made it frontmost. `NSRunningApplication.activate` returned `false` for Codex
    /// and VS Code during real cross-app delivery, so both destination activation and
    /// post-delivery workspace restoration share the `NSWorkspace` fallback here.
    func activateApplication(_ application: NSRunningApplication) async -> Bool {
        let pid = application.processIdentifier
        guard !application.isTerminated else {
            logger.error("Application activation failed because the app terminated pid=\(pid, privacy: .public)")
            return false
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return true
        }

        let directAccepted = application.activate(options: .activateAllWindows)
        logger.info("Application activation requested through NSRunningApplication pid=\(pid, privacy: .public) accepted=\(directAccepted, privacy: .public)")
        if directAccepted,
           await waitForFrontmostApplication(pid: pid, timeout: activationTimeout) {
            return true
        }

        guard let bundleURL = application.bundleURL else {
            logger.error("Application activation fallback unavailable because the app has no bundle URL pid=\(pid, privacy: .public)")
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let openedExpectedProcess = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { openedApplication, error in
                if let error {
                    self.logger.error("Application activation fallback failed pid=\(pid, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                }
                let matched = openedApplication?.processIdentifier == pid
                self.logger.info("Application activation fallback completed pid=\(pid, privacy: .public) openedPid=\(openedApplication?.processIdentifier ?? -1, privacy: .public) matched=\(matched, privacy: .public)")
                continuation.resume(returning: matched)
            }
        }
        guard openedExpectedProcess else { return false }

        let becameFrontmost = await waitForFrontmostApplication(pid: pid, timeout: activationTimeout)
        if !becameFrontmost {
            logger.error("Application activation fallback completed but app never became frontmost pid=\(pid, privacy: .public) actualPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        }
        return becameFrontmost
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
        guard let targetElement = target.element else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let focusedInput = systemFocusedElement(),
               focusedInput.pid == target.pid,
               CFEqual(focusedInput.element, targetElement) {
                return true
            }
            try? await Task.sleep(nanoseconds: focusPollInterval)
        }
        guard let focusedInput = systemFocusedElement() else { return false }
        return focusedInput.pid == target.pid && CFEqual(focusedInput.element, targetElement)
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

    private func liveElement(
        for target: Target,
        allowApplicationFallback: Bool
    ) -> AXUIElement? {
        if let element = target.element,
           stringAttribute(kAXRoleAttribute, from: element) != nil {
            return element
        }
        guard allowApplicationFallback,
              let focused = systemFocusedElement(),
              focused.pid == target.pid else {
            return nil
        }
        return focused.element
    }

    private func elementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let attributeElement = value as! AXUIElement
        return attributeElement
    }

    private func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func submitLabel(for element: AXUIElement) -> String? {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
            .lazy
            .compactMap { self.stringAttribute($0, from: element) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func isNearbySubmitLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "send", "send message", "send follow-up", "submit":
            return true
        default:
            return false
        }
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

    private func isApplicationFallbackContainer(role: String?) -> Bool {
        switch role {
        case "AXWebArea", kAXGroupRole:
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
