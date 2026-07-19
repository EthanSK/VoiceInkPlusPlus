import Foundation
import AppKit
import ApplicationServices
import os

@MainActor
final class FocusLockService: ObservableObject {
    fileprivate struct ExactInputIdentity {
        let role: String
        let subrole: String?
        let identifier: String?
        let domIdentifier: String?
        let title: String?
        let description: String?
        let placeholder: String?
        let relativeFrame: CGRect?
        let ancestorPath: [String]
        let contextRegion: CGRect?
        let contextAnchors: [String]
    }

    struct Target {
        struct DisplayInfo {
            let applicationName: String
            let inputName: String
            let applicationIcon: NSImage?
        }

        fileprivate let element: AXUIElement?
        fileprivate let window: AXUIElement?
        fileprivate let identity: ExactInputIdentity?
        fileprivate let app: NSRunningApplication
        fileprivate let pid: pid_t
        let bundleIdentifier: String?
        let displayInfo: DisplayInfo
        var processIdentifier: pid_t { pid }
        var hasExactInput: Bool { element != nil }
    }

    struct BackgroundDeliverySession {
        fileprivate let element: AXUIElement
        fileprivate let window: AXUIElement
        fileprivate let app: NSRunningApplication
        fileprivate let frontmostPIDAtStart: pid_t
        fileprivate let previouslyFocusedWindow: AXUIElement?
        fileprivate let previouslyFocusedElement: AXUIElement?
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        var expectedFrontmostProcessIdentifier: pid_t { frontmostPIDAtStart }
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

        let owningWindow = isExactEditableInput ? owningWindow(for: element) : nil
        let identity = owningWindow.flatMap { exactInputIdentity(for: element, in: $0) }

        return Target(
            element: isExactEditableInput ? element : nil,
            window: owningWindow,
            identity: identity,
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

        guard let element = resolvedExactElement(for: target) else {
            guard allowApplicationFallback else {
                logger.error("Focused input restore could not uniquely resolve the saved exact input")
                return false
            }
            logger.notice("Foreground recording-start exact input became unavailable; using the saved app's current focus targetPid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return true
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        if let window = liveWindow(for: target, resolvedElement: element) {
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            let windowResult = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                window
            )
            _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            guard windowResult == .success else {
                if allowApplicationFallback {
                    logger.notice("Foreground recording-start window became stale; using the saved app's current focus pid=\(target.pid, privacy: .public) AXError=\(windowResult.rawValue, privacy: .public)")
                    return true
                }
                logger.error("Focused input restore failed to select the saved window pid=\(target.pid, privacy: .public) AXError=\(windowResult.rawValue, privacy: .public)")
                return false
            }
        }
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

        guard await waitForFocusedElement(
            pid: target.pid,
            element: element,
            timeout: focusVerificationTimeout
        ) else {
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

    /// Prepare one exact saved editor for process-targeted background delivery without
    /// activating its application. Electron only acknowledges its background editor
    /// after the same inactive→active notification sequence used by a real app switch;
    /// every AX setter and the frontmost PID are verified before any text event is sent.
    func prepareBackgroundDelivery(to target: Target) async -> BackgroundDeliverySession? {
        guard AXIsProcessTrusted(),
              target.hasExactInput,
              !target.app.isTerminated,
              let element = resolvedExactElement(for: target),
              let window = liveWindow(for: target, resolvedElement: element) else {
            logger.error("Background exact-input preparation could not resolve a live saved element/window pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        let session = BackgroundDeliverySession(
            element: element,
            window: window,
            app: target.app,
            frontmostPIDAtStart: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            previouslyFocusedWindow: elementAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
            ),
            previouslyFocusedElement: elementAttribute(
                kAXFocusedUIElementAttribute,
                from: appElement
            ),
            processIdentifier: target.pid,
            bundleIdentifier: target.bundleIdentifier
        )
        guard await applyBackgroundFocus(session) else {
            CursorPaster.endTargetedInputSession(pid: target.pid)
            return nil
        }

        logger.info("Background exact input prepared pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) windowHash=\(CFHash(window), privacy: .public) elementHash=\(CFHash(element), privacy: .public) frontmostPid=\(session.frontmostPIDAtStart, privacy: .public)")
        return session
    }

    func refreshBackgroundFocus(_ session: BackgroundDeliverySession) async -> Bool {
        await applyBackgroundFocus(session)
    }

    func finishBackgroundDelivery(_ session: BackgroundDeliverySession) {
        defer { CursorPaster.endTargetedInputSession(pid: session.processIdentifier) }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == session.frontmostPIDAtStart,
              CursorPaster.beginTargetedInputSession(pid: session.processIdentifier) else {
            logger.notice("Background internal-focus restoration skipped because the frontmost app changed targetPid=\(session.processIdentifier, privacy: .public) expectedFrontmostPid=\(session.frontmostPIDAtStart, privacy: .public) actualFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return
        }

        // Electron processes the synthetic activation state asynchronously. The same
        // bounded 50 ms settlement used by preparation is required before and after
        // restoring its previous internal window/editor; immediate setters were
        // accepted but left Codex attached to the delivery window in the live probe.
        Thread.sleep(forTimeInterval: 0.05)
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        if let previousWindow = session.previouslyFocusedWindow,
           !CFEqual(previousWindow, session.window) {
            _ = AXUIElementSetAttributeValue(
                previousWindow,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                previousWindow
            )
            _ = AXUIElementSetAttributeValue(
                previousWindow,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        if let previousElement = session.previouslyFocusedElement,
           !CFEqual(previousElement, session.element) {
            _ = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                previousElement
            )
            _ = AXUIElementSetAttributeValue(
                previousElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }

        Thread.sleep(forTimeInterval: 0.05)
        let restoredWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement)
        let restoredElement = elementAttribute(kAXFocusedUIElementAttribute, from: appElement)
        let windowRestored = session.previouslyFocusedWindow.map { previousWindow in
            restoredWindow.map { CFEqual($0, previousWindow) } == true
        } ?? true
        let elementRestored = session.previouslyFocusedElement.map { previousElement in
            restoredElement.map { CFEqual($0, previousElement) } == true
        } ?? true
        logger.info("Background internal focus restored window=\(windowRestored, privacy: .public) element=\(elementRestored, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
    }

    func backgroundInputText(for session: BackgroundDeliverySession) -> String? {
        stringAttribute(kAXValueAttribute, from: session.element)
    }

    func backgroundWindowContains(
        _ text: String,
        for session: BackgroundDeliverySession,
        excludingSavedInput: Bool = false
    ) -> Bool {
        descendants(of: session.window).contains { element in
            if excludingSavedInput, CFEqual(element, session.element) {
                return false
            }
            return stringAttribute(kAXValueAttribute, from: element)?.contains(text) == true
        }
    }

    func pressNearbySubmitButton(
        for session: BackgroundDeliverySession
    ) -> NearbySubmitButtonResult {
        pressNearbySubmitButton(element: session.element, pid: session.processIdentifier)
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

    /// Read-only proof that the frozen exact input still owns system keyboard focus.
    /// Delivery uses this at the irreversible Cmd-V/Return boundaries so a later click
    /// routes through non-activating exact delivery instead of activating the saved app
    /// or rewriting focus from a newer input in the same app.
    func targetOwnsSystemKeyboardFocus(_ target: Target) -> Bool {
        guard target.hasExactInput,
              let targetElement = resolvedExactElement(for: target),
              let focusedInput = systemFocusedElement() else {
            return false
        }
        return focusedInput.pid == target.pid
            && CFEqual(focusedInput.element, targetElement)
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
              let element = liveElement(
                for: target,
                allowApplicationFallback: allowApplicationFallback
              ) else {
            return .unavailable
        }

        return pressNearbySubmitButton(element: element, pid: target.pid)
    }

    private func pressNearbySubmitButton(
        element: AXUIElement,
        pid: pid_t
    ) -> NearbySubmitButtonResult {
        var ancestor = element
        for _ in 0..<4 {
            for child in elementArrayAttribute(kAXChildrenAttribute, from: ancestor) {
                guard stringAttribute(kAXRoleAttribute, from: child) == kAXButtonRole,
                      isNearbySubmitLabel(submitLabel(for: child)),
                      boolAttribute(kAXEnabledAttribute, from: child) != false else {
                    continue
                }

                let result = AXUIElementPerformAction(child, kAXPressAction as CFString)
                logger.info("Nearby submit-button press attempted pid=\(pid, privacy: .public) label=\(self.submitLabel(for: child) ?? "nil", privacy: .public) result=\(result.rawValue, privacy: .public)")
                return result == .success ? .pressed : .failed(result.rawValue)
            }

            guard let parent = elementAttribute(kAXParentAttribute, from: ancestor) else {
                break
            }
            ancestor = parent
        }

        logger.notice("Nearby submit button unavailable pid=\(pid, privacy: .public)")
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

    private func waitForFocusedElement(
        pid: pid_t,
        element: AXUIElement,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let focusedInput = systemFocusedElement(),
               focusedInput.pid == pid,
               CFEqual(focusedInput.element, element) {
                return true
            }
            try? await Task.sleep(nanoseconds: focusPollInterval)
        }
        guard let focusedInput = systemFocusedElement() else { return false }
        return focusedInput.pid == pid && CFEqual(focusedInput.element, element)
    }

    private func applyBackgroundFocus(_ session: BackgroundDeliverySession) async -> Bool {
        guard !session.app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == session.frontmostPIDAtStart,
              CursorPaster.beginTargetedInputSession(pid: session.processIdentifier) else {
            logger.error("Background exact focus refused because the target/frontmost process changed targetPid=\(session.processIdentifier, privacy: .public) expectedFrontmostPid=\(session.frontmostPIDAtStart, privacy: .public) actualFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return false
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        let mainResult = AXUIElementSetAttributeValue(
            session.window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        let windowResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            session.window
        )
        let windowFocusedResult = AXUIElementSetAttributeValue(
            session.window,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        let raiseResult = AXUIElementPerformAction(
            session.window,
            kAXRaiseAction as CFString
        )
        let elementResult = AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            session.element
        )
        let elementFocusedResult = AXUIElementSetAttributeValue(
            session.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        let actualWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement)
        let actualElement = elementAttribute(kAXFocusedUIElementAttribute, from: appElement)
        let stayedInBackground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == session.frontmostPIDAtStart
        // Setter/action return codes are diagnostics, not proof. Electron has
        // returned success while ignoring events, and some apps report an unsupported
        // redundant setter after accepting the essential focus change. The verified
        // live internal window + element and unchanged macOS frontmost PID are the
        // load-bearing conditions.
        let verified = actualWindow.map { CFEqual($0, session.window) } == true
            && actualElement.map { CFEqual($0, session.element) } == true
            && stayedInBackground

        if !verified {
            logger.error("Background exact focus verification failed targetPid=\(session.processIdentifier, privacy: .public) expectedWindowHash=\(CFHash(session.window), privacy: .public) actualWindowHash=\(actualWindow.map { String(CFHash($0)) } ?? "nil", privacy: .public) expectedElementHash=\(CFHash(session.element), privacy: .public) actualElementHash=\(actualElement.map { String(CFHash($0)) } ?? "nil", privacy: .public) mainAX=\(mainResult.rawValue, privacy: .public) windowAX=\(windowResult.rawValue, privacy: .public) windowFocusedAX=\(windowFocusedResult.rawValue, privacy: .public) raiseAX=\(raiseResult.rawValue, privacy: .public) elementAX=\(elementResult.rawValue, privacy: .public) elementFocusedAX=\(elementFocusedResult.rawValue, privacy: .public) expectedFrontmostPid=\(session.frontmostPIDAtStart, privacy: .public) actualFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        }
        return verified
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
        if let element = resolvedExactElement(for: target) {
            return element
        }
        guard allowApplicationFallback,
              let focused = systemFocusedElement(),
              focused.pid == target.pid else {
            return nil
        }
        return focused.element
    }

    private func resolvedExactElement(for target: Target) -> AXUIElement? {
        let savedWindow = liveWindow(for: target, resolvedElement: nil)
        let directContextMatches = target.identity.map { identity in
            guard !identity.contextAnchors.isEmpty else { return true }
            guard let savedWindow else { return false }
            return Self.contextFingerprintMatches(
                captured: identity.contextAnchors,
                current: contextAnchors(
                    in: savedWindow,
                    region: identity.contextRegion,
                    excluding: nil
                )
            )
        } ?? true

        if let element = target.element,
           directContextMatches {
            let role = stringAttribute(kAXRoleAttribute, from: element)
            let subrole = stringAttribute(kAXSubroleAttribute, from: element)
            let elementWindow = owningWindow(for: element)
            let belongsToSavedWindow = savedWindow.map { savedWindow in
                elementWindow.map { CFEqual($0, savedWindow) } == true
            } ?? true
            if belongsToSavedWindow,
               isEditableInput(role: role, subrole: subrole) {
                return element
            }
        }

        guard let identity = target.identity,
              let window = savedWindow,
              exactInputContextMatches(identity, in: window) else {
            return nil
        }

        var candidates = descendants(of: window).filter { element in
            let role = stringAttribute(kAXRoleAttribute, from: element)
            let subrole = stringAttribute(kAXSubroleAttribute, from: element)
            return role == identity.role
                && subrole == identity.subrole
                && isEditableInput(role: role, subrole: subrole)
        }

        if let identifier = identity.identifier {
            candidates = candidates.filter {
                nonEmptyStringAttribute(kAXIdentifierAttribute, from: $0) == identifier
            }
        }
        if let domIdentifier = identity.domIdentifier {
            candidates = candidates.filter {
                nonEmptyStringAttribute("AXDOMIdentifier", from: $0) == domIdentifier
            }
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }

        let pathMatches = candidates.filter {
            ancestorPath(from: $0, through: window) == identity.ancestorPath
        }
        if pathMatches.count == 1 { return pathMatches[0] }
        if !pathMatches.isEmpty { candidates = pathMatches }

        if let expectedFrame = identity.relativeFrame {
            let ranked = candidates.compactMap { candidate -> (AXUIElement, CGFloat)? in
                guard let frame = relativeFrame(of: candidate, in: window) else { return nil }
                let distance = abs(frame.origin.x - expectedFrame.origin.x)
                    + abs(frame.origin.y - expectedFrame.origin.y)
                    + abs(frame.size.width - expectedFrame.size.width)
                    + abs(frame.size.height - expectedFrame.size.height)
                return (candidate, distance)
            }.sorted { $0.1 < $1.1 }
            if let best = ranked.first,
               best.1 <= 24,
               (ranked.count == 1 || ranked[1].1 - best.1 >= 8) {
                return best.0
            }
        }

        let labelMatches = candidates.filter { candidate in
            let checks: [(String?, String)] = [
                (identity.title, kAXTitleAttribute),
                (identity.description, kAXDescriptionAttribute),
                (identity.placeholder, kAXPlaceholderValueAttribute)
            ]
            return checks.allSatisfy { expected, attribute in
                expected == nil || nonEmptyStringAttribute(attribute, from: candidate) == expected
            }
        }
        return labelMatches.count == 1 ? labelMatches[0] : nil
    }

    private func liveWindow(
        for target: Target,
        resolvedElement: AXUIElement?
    ) -> AXUIElement? {
        if let resolvedElement,
           let window = owningWindow(for: resolvedElement) {
            return window
        }
        if let window = target.window,
           stringAttribute(kAXRoleAttribute, from: window) == kAXWindowRole {
            return window
        }
        return nil
    }

    private func exactInputIdentity(
        for element: AXUIElement,
        in window: AXUIElement
    ) -> ExactInputIdentity? {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else { return nil }
        let contextRegion = contentRegion(for: element, in: window)
        return ExactInputIdentity(
            role: role,
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            identifier: nonEmptyStringAttribute(kAXIdentifierAttribute, from: element),
            domIdentifier: nonEmptyStringAttribute("AXDOMIdentifier", from: element),
            title: nonEmptyStringAttribute(kAXTitleAttribute, from: element),
            description: nonEmptyStringAttribute(kAXDescriptionAttribute, from: element),
            placeholder: nonEmptyStringAttribute(kAXPlaceholderValueAttribute, from: element),
            relativeFrame: relativeFrame(of: element, in: window),
            ancestorPath: ancestorPath(from: element, through: window),
            contextRegion: contextRegion,
            contextAnchors: contextAnchors(
                in: window,
                region: contextRegion,
                excluding: element
            )
        )
    }

    private func exactInputContextMatches(
        _ identity: ExactInputIdentity,
        in window: AXUIElement
    ) -> Bool {
        if identity.contextAnchors.isEmpty {
            // Stable AX/DOM identifiers can safely re-resolve without document text.
            // With neither identifiers nor context, an existing exact AX wrapper is
            // still usable, but frame/path-only stale-wrapper recovery is unsafe: a
            // switched Codex/browser tab can expose a lookalike composer in the same
            // place.
            return identity.identifier != nil || identity.domIdentifier != nil
        }
        return Self.contextFingerprintMatches(
            captured: identity.contextAnchors,
            current: contextAnchors(
                in: window,
                region: identity.contextRegion,
                excluding: nil
            )
        )
    }

    static func contextFingerprintMatches(
        captured: [String],
        current: [String]
    ) -> Bool {
        guard !captured.isEmpty else { return false }
        let currentSet = Set(current)
        let matchCount = captured.reduce(into: 0) { count, anchor in
            if currentSet.contains(anchor) { count += 1 }
        }
        return matchCount >= min(2, captured.count)
    }

    private func contextAnchors(
        in window: AXUIElement,
        region: CGRect?,
        excluding excludedElement: AXUIElement?
    ) -> [String] {
        var anchors: [String] = []
        var seen = Set<String>()
        for element in descendants(of: window) {
            if let excludedElement, CFEqual(element, excludedElement) { continue }
            if let region,
               let elementFrame = relativeFrame(of: element, in: window),
               !region.intersects(elementFrame) {
                continue
            }
            switch stringAttribute(kAXRoleAttribute, from: element) {
            case kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole:
                break
            default:
                continue
            }
            let rawValue = stringAttribute(kAXValueAttribute, from: element)
                ?? stringAttribute(kAXTitleAttribute, from: element)
            guard let rawValue else { continue }
            let normalized = rawValue
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard normalized.count >= 20,
                  normalized != "Ask for follow-up changes",
                  normalized != "Do anything" else {
                continue
            }
            let anchor = String(normalized.prefix(180))
            if seen.insert(anchor).inserted {
                anchors.append(anchor)
            }
        }
        return Array(anchors.sorted { $0.count > $1.count }.prefix(16))
    }

    private func contentRegion(
        for element: AXUIElement,
        in window: AXUIElement
    ) -> CGRect? {
        guard let windowFrame = frame(of: window) else { return nil }
        var best: CGRect?
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let candidate = current,
                  !CFEqual(candidate, window) else {
                break
            }
            if let candidateFrame = relativeFrame(of: candidate, in: window),
               candidateFrame.width >= windowFrame.width * 0.45,
               candidateFrame.height >= windowFrame.height * 0.45,
               candidateFrame.width < windowFrame.width * 0.95 {
                best = candidateFrame
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return best
    }

    private func owningWindow(for element: AXUIElement) -> AXUIElement? {
        if let window = elementAttribute(kAXWindowAttribute, from: element) {
            return window
        }
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let candidate = current else { break }
            if stringAttribute(kAXRoleAttribute, from: candidate) == kAXWindowRole {
                return candidate
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return nil
    }

    private func descendants(of root: AXUIElement, maximumDepth: Int = 40) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var seen = Set<CFHashCode>()
        while cursor < queue.count {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            guard depth < maximumDepth else { continue }
            for child in elementArrayAttribute(kAXChildrenAttribute, from: element) {
                queue.append((child, depth + 1))
            }
        }
        return result
    }

    private func ancestorPath(
        from element: AXUIElement,
        through window: AXUIElement
    ) -> [String] {
        var path: [String] = []
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let candidate = current,
                  !CFEqual(candidate, window),
                  let parent = elementAttribute(kAXParentAttribute, from: candidate) else {
                break
            }
            let role = stringAttribute(kAXRoleAttribute, from: candidate) ?? "nil"
            let siblingIndex = elementArrayAttribute(kAXChildrenAttribute, from: parent)
                .firstIndex(where: { CFEqual($0, candidate) }) ?? -1
            path.append("\(role)#\(siblingIndex)")
            current = parent
        }
        return path
    }

    private func relativeFrame(
        of element: AXUIElement,
        in window: AXUIElement
    ) -> CGRect? {
        guard let elementFrame = frame(of: element),
              let windowFrame = frame(of: window) else {
            return nil
        }
        return CGRect(
            x: elementFrame.origin.x - windowFrame.origin.x,
            y: elementFrame.origin.y - windowFrame.origin.y,
            width: elementFrame.size.width,
            height: elementFrame.size.height
        )
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
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

    private func nonEmptyStringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        guard let value = stringAttribute(attribute, from: element) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
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
