import Foundation
import AppKit
import ApplicationServices
import os

@MainActor
final class FocusLockService: ObservableObject {
    fileprivate enum BackgroundTargetResolution: String {
        case strictFingerprint
        case telegramRetainedFocusedElement
    }

    enum BackgroundFocusMode: String {
        /// A fully backgrounded target needs one bounded internal activation-state
        /// session. Preparation opens it once; delivery never re-posts that sequence.
        case preparedTargetedInput
        /// A non-activating surface such as ChatGPT Option-Space already owns the exact
        /// system keyboard focus, so no synthetic activation or focus setter is allowed.
        case alreadyKeyboardFocused
        /// Ethan is using another input (possibly in the same app). Only direct exact
        /// Accessibility mutation and a proven semantic action are permitted.
        case directExactElement
    }

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
        /// Telegram reuses one editor wrapper across chats. Header/title anchors are
        /// kept separately from message-history context so the selected chat identity
        /// cannot be evicted by long messages or satisfied by title text inside a chat.
        let primaryContextAnchors: [String]
        let contextAnchors: [String]
    }

    struct ContextAnchorCandidate: Equatable {
        let value: String
        let isPrimary: Bool
    }

    struct ContextAnchorSelection: Equatable {
        let primary: [String]
        let secondary: [String]
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
        fileprivate let retainedSubmitButton: AXUIElement?
        fileprivate let retainedSubmitButtonFrame: CGRect?
        fileprivate let app: NSRunningApplication
        fileprivate let pid: pid_t
        let bundleIdentifier: String?
        let displayInfo: DisplayInfo
        var processIdentifier: pid_t { pid }
        var hasExactInput: Bool { element != nil }
    }

    struct BackgroundDeliverySession {
        fileprivate let target: Target
        fileprivate let element: AXUIElement
        fileprivate let window: AXUIElement
        fileprivate let app: NSRunningApplication
        fileprivate let frontmostPIDAtStart: pid_t
        fileprivate let keyboardFocusedPIDAtStart: pid_t
        fileprivate let keyboardFocusedElementAtStart: AXUIElement
        fileprivate let previouslyFocusedWindow: AXUIElement?
        fileprivate let previouslyFocusedElement: AXUIElement?
        fileprivate let inputRole: String
        fileprivate let inputSubrole: String?
        fileprivate let inputFrame: CGRect?
        fileprivate let resolution: BackgroundTargetResolution
        fileprivate let focusMode: BackgroundFocusMode
        fileprivate let ownsTargetedInputSession: Bool
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        var frontmostProcessIdentifierAtStart: pid_t { frontmostPIDAtStart }
        var focusModeDescription: String { focusMode.rawValue }
        var requiresDirectAccessibilityInsertion: Bool {
            focusMode == .directExactElement
        }
    }

    enum BackgroundTextInsertionResult: Equatable {
        case acceptedSelectedText
        case unavailable
        case failed(Int32)
        case focusSafetyViolation
    }

    enum NearbySubmitButtonResult: Equatable {
        case pressed
        case unavailable
        case failed(Int32)
    }

    private struct NearbySubmitButtonCandidate {
        let element: AXUIElement
        let label: String
        let score: CGFloat
        let discoveredDepth: Int
    }

    static let shared = FocusLockService()
    static let longPressThreshold: TimeInterval = 0.45

    @Published private(set) var isLockActive = false
    private(set) var stopHoldDecisionPending = false

    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "FocusLock")
    private let activationTimeout: TimeInterval = 1
    private let focusVerificationTimeout: TimeInterval = 0.25
    private let focusPollInterval: UInt64 = 20_000_000
    private static let telegramBundleIdentifiers: Set<String> = [
        "ru.keepcoder.Telegram"
    ]
    private static let exactWrapperRequiresIdentityOrContextBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "notion.id"
    ]
    private static let semanticSendBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "ru.keepcoder.Telegram"
    ]
    private static let telegramGenericContextLabels: Set<String> = [
        "attach", "cancel", "close", "edit", "emoji", "message", "more",
        "mute", "online", "search", "send", "telegram", "unmute",
        "write a message"
    ]
    private static let telegramVolatileContextPrefixes = [
        "last seen", "typing", "write a message"
    ]

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
        let identity = owningWindow.flatMap {
            exactInputIdentity(
                for: element,
                in: $0,
                bundleIdentifier: app.bundleIdentifier
            )
        }
        // Only Telegram can hide its AX tree after capture and need the exact button
        // wrapper retained. OpenAI and Claude resolve Send at delivery time, keeping
        // their recording start/stop capture path free of a descendant search.
        let retainedSubmitCandidate = isExactEditableInput
            && Self.isTelegram(bundleIdentifier: app.bundleIdentifier)
            ? nearbySubmitButtonCandidate(
                element: element,
                pid: pid,
                requireEnabled: false
              )
            : nil

        return Target(
            element: isExactEditableInput ? element : nil,
            window: owningWindow,
            identity: identity,
            retainedSubmitButton: retainedSubmitCandidate?.element,
            retainedSubmitButtonFrame: retainedSubmitCandidate.flatMap {
                frame(of: $0.element)
            },
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
                let diagnostics = exactInputResolutionDiagnostics(for: target)
                logger.error("Focused input restore could not uniquely resolve the saved exact input \(diagnostics, privacy: .public)")
                return false
            }
            logger.notice("Foreground recording-start exact input became unavailable; using the saved app's current focus targetPid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return true
        }

        // A primary-button stop commonly arrives while the captured input still owns
        // real system keyboard focus. Re-selecting that same window/editor is needless
        // and can make native apps churn their Accessibility wrappers. Resolution above
        // still proves the saved document/chat identity (Telegram included); only then
        // may this be a no-op. The paste and normal HID Return remain foreground actions.
        if frontmostPIDBeforeRestore == target.pid,
           let focused = systemFocusedElement(),
           focused.pid == target.pid,
           CFEqual(focused.element, element) {
            logger.info("Focused input restore verified the already-focused exact input without rewriting focus targetPid=\(target.pid, privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
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

    /// Prepare one exact saved editor without making its application macOS-frontmost.
    ///
    /// Telegram hides every AX window child while backgrounded, so strict fingerprint
    /// resolution cannot run until its bounded internal activation-state session exists.
    /// For that allowlisted app only, open the session first and retain the original
    /// wrapper only when Telegram still reports that exact editor/window as internally
    /// focused and the captured chat context becomes readable and matches. Hidden or
    /// changed chat context fails closed; this fallback never rewrites Telegram's focus.
    func prepareBackgroundDelivery(to target: Target) async -> BackgroundDeliverySession? {
        guard AXIsProcessTrusted(),
              target.hasExactInput,
              !target.app.isTerminated else {
            logger.error("Background exact-input preparation unavailable pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }

        if let element = resolvedExactElement(for: target),
           let window = liveWindow(for: target, resolvedElement: element) {
            guard let session = makeBackgroundDeliverySession(
                target: target,
                element: element,
                window: window,
                resolution: .strictFingerprint
            ) else {
                return nil
            }
            guard await prepareBackgroundFocus(session) else {
                return nil
            }

            logger.info("Background exact input prepared pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) resolution=\(session.resolution.rawValue, privacy: .public) focusMode=\(session.focusMode.rawValue, privacy: .public) windowHash=\(CFHash(window), privacy: .public) elementHash=\(CFHash(element), privacy: .public) frontmostPid=\(session.frontmostPIDAtStart, privacy: .public)")
            return session
        }

        if let telegramSession = await prepareRetainedTelegramBackgroundDelivery(to: target) {
            return telegramSession
        }

        logger.error("Background exact-input preparation could not resolve a live saved element/window pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
        return nil
    }

    private func makeBackgroundDeliverySession(
        target: Target,
        element: AXUIElement,
        window: AXUIElement,
        resolution: BackgroundTargetResolution,
        frontmostPIDAtStart: pid_t? = nil,
        keyboardFocusAtStart: (element: AXUIElement, pid: pid_t)? = nil,
        previouslyFocusedWindow: AXUIElement? = nil,
        previouslyFocusedElement: AXUIElement? = nil
    ) -> BackgroundDeliverySession? {
        let appElement = AXUIElementCreateApplication(target.pid)
        guard let keyboardFocus = keyboardFocusAtStart ?? systemFocusedElement() else {
            logger.error("Background exact-input preparation refused because system keyboard focus was unreadable targetPid=\(target.pid, privacy: .public)")
            return nil
        }
        let frontmostPID = frontmostPIDAtStart
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            ?? -1
        let focusMode = Self.backgroundFocusMode(
            keyboardFocusMatchesTarget: keyboardFocus.pid == target.pid
                && CFEqual(keyboardFocus.element, element),
            keyboardFocusOwnedByTarget: keyboardFocus.pid == target.pid,
            targetIsFrontmost: frontmostPID == target.pid
        )
        return BackgroundDeliverySession(
            target: target,
            element: element,
            window: window,
            app: target.app,
            frontmostPIDAtStart: frontmostPID,
            keyboardFocusedPIDAtStart: keyboardFocus.pid,
            keyboardFocusedElementAtStart: keyboardFocus.element,
            previouslyFocusedWindow: previouslyFocusedWindow
                ?? elementAttribute(kAXFocusedWindowAttribute, from: appElement),
            previouslyFocusedElement: previouslyFocusedElement
                ?? elementAttribute(kAXFocusedUIElementAttribute, from: appElement),
            inputRole: stringAttribute(kAXRoleAttribute, from: element) ?? "",
            inputSubrole: stringAttribute(kAXSubroleAttribute, from: element),
            inputFrame: frame(of: element),
            resolution: resolution,
            focusMode: focusMode,
            ownsTargetedInputSession: focusMode == .preparedTargetedInput,
            processIdentifier: target.pid,
            bundleIdentifier: target.bundleIdentifier
        )
    }

    /// Decide the delivery mode before any target mutation. Keep this decision pure
    /// and unit-tested because the three routes have intentionally different safety
    /// permissions: one bounded internal session, no synthetic activation for an
    /// already-focused floating surface, or direct Accessibility-only insertion when
    /// Ethan is using another input.
    static func backgroundFocusMode(
        keyboardFocusMatchesTarget: Bool,
        keyboardFocusOwnedByTarget: Bool,
        targetIsFrontmost: Bool
    ) -> BackgroundFocusMode {
        if keyboardFocusMatchesTarget {
            return .alreadyKeyboardFocused
        }
        if keyboardFocusOwnedByTarget || targetIsFrontmost {
            return .directExactElement
        }
        return .preparedTargetedInput
    }

    private func prepareRetainedTelegramBackgroundDelivery(
        to target: Target
    ) async -> BackgroundDeliverySession? {
        guard Self.isTelegram(bundleIdentifier: target.bundleIdentifier),
              let element = target.element,
              let window = target.window,
              let identity = target.identity,
              !identity.primaryContextAnchors.isEmpty,
              let keyboardFocus = systemFocusedElement(),
              keyboardFocus.pid != target.pid,
              Self.backgroundTargetRemainsNonFrontmost(
                currentFrontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                targetPID: target.pid
              ) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        let previousWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement)
        let previousElement = elementAttribute(kAXFocusedUIElementAttribute, from: appElement)
        let frontmostPIDAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        guard let session = makeBackgroundDeliverySession(
            target: target,
            element: element,
            window: window,
            resolution: .telegramRetainedFocusedElement,
            frontmostPIDAtStart: frontmostPIDAtStart,
            keyboardFocusAtStart: keyboardFocus,
            previouslyFocusedWindow: previousWindow,
            previouslyFocusedElement: previousElement
        ), session.focusMode == .preparedTargetedInput,
              CursorPaster.beginTargetedInputSession(pid: target.pid) else {
            logger.error("Telegram retained-input preparation could not open its bounded activation-state session pid=\(target.pid, privacy: .public)")
            return nil
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard telegramDeliveryBoundaryMatches(session) else {
            let currentContext = contextFingerprint(
                in: window,
                region: identity.contextRegion,
                excluding: element,
                bundleIdentifier: target.bundleIdentifier
            )
            logger.notice("Telegram retained-input preparation rejected hidden, changed, or internally unfocused chat pid=\(target.pid, privacy: .public) capturedPrimary=\(identity.primaryContextAnchors.count, privacy: .public) capturedSecondary=\(identity.contextAnchors.count, privacy: .public) currentPrimary=\(currentContext.primary.count, privacy: .public) currentSecondary=\(currentContext.secondary.count, privacy: .public)")
            if preparedTargetFocusBoundaryIsSafe(session) {
                CursorPaster.endTargetedInputSession(pid: target.pid)
            }
            return nil
        }

        logger.notice("Telegram retained exact input prepared with readable matching chat context pid=\(target.pid, privacy: .public) windowHash=\(CFHash(window), privacy: .public) elementHash=\(CFHash(element), privacy: .public) frontmostPid=\(frontmostPIDAtStart, privacy: .public)")
        return session
    }

    func refreshBackgroundFocus(_ session: BackgroundDeliverySession) async -> Bool {
        backgroundDeliveryBoundaryMatches(session)
    }

    func finishBackgroundDelivery(_ session: BackgroundDeliverySession) {
        guard session.ownsTargetedInputSession else {
            return
        }

        // Never post another activation-state sequence during cleanup. The one session
        // opened in preparation remains active until this method. If Ethan has brought
        // the target forward or it has acquired real keyboard focus, do not inject a
        // synthetic deactivation or rewrite the input he is now using.
        guard preparedTargetFocusBoundaryIsSafe(session) else {
            logger.notice("Background internal-focus restoration/deactivation skipped because the target became active targetPid=\(session.processIdentifier, privacy: .public) actualFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public) actualKeyboardPid=\(self.systemFocusedElement()?.pid ?? -1, privacy: .public)")
            return
        }

        defer {
            if self.preparedTargetFocusBoundaryIsSafe(session) {
                CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
            } else {
                self.logger.notice("Skipped synthetic background deactivation because the target became active during cleanup targetPid=\(session.processIdentifier, privacy: .public)")
            }
        }
        if session.resolution == .telegramRetainedFocusedElement {
            // Telegram retained its own exact internal focus; nothing was rewritten.
            return
        }

        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        if let previousWindow = session.previouslyFocusedWindow,
           !CFEqual(previousWindow, session.window) {
            guard performPreparedCleanupMutation(session, mutation: {
                _ = AXUIElementSetAttributeValue(
                    previousWindow,
                    kAXMainAttribute as CFString,
                    kCFBooleanTrue
                )
            }), performPreparedCleanupMutation(session, mutation: {
                _ = AXUIElementSetAttributeValue(
                    appElement,
                    kAXFocusedWindowAttribute as CFString,
                    previousWindow
                )
            }), performPreparedCleanupMutation(session, mutation: {
                _ = AXUIElementSetAttributeValue(
                    previousWindow,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }) else {
                return
            }
        }
        if let previousElement = session.previouslyFocusedElement,
           !CFEqual(previousElement, session.element) {
            guard performPreparedCleanupMutation(session, mutation: {
                _ = AXUIElementSetAttributeValue(
                    appElement,
                    kAXFocusedUIElementAttribute as CFString,
                    previousElement
                )
            }), performPreparedCleanupMutation(session, mutation: {
                _ = AXUIElementSetAttributeValue(
                    previousElement,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
            }) else {
                return
            }
        }

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

    /// Accessibility setters may synchronously run target-app code. Recheck both
    /// immediately before and immediately after every cleanup mutation so a target
    /// Ethan foregrounds mid-cleanup cannot receive the remaining internal-focus
    /// writes. The operation is best-effort restoration; user focus always wins.
    private func performPreparedCleanupMutation(
        _ session: BackgroundDeliverySession,
        mutation: () -> Void
    ) -> Bool {
        guard preparedTargetFocusBoundaryIsSafe(session) else { return false }
        mutation()
        return preparedTargetFocusBoundaryIsSafe(session)
    }

    func backgroundInputText(
        for session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> String? {
        guard let element = liveBackgroundInput(
            for: session,
            allowReplacementAfterSubmission: allowReplacementAfterSubmission
        ), let text = stringAttribute(kAXValueAttribute, from: element),
              liveBackgroundInput(
                for: session,
                allowReplacementAfterSubmission: allowReplacementAfterSubmission
              ).map({ CFEqual($0, element) }) == true else {
            return nil
        }
        // Accessibility reads are not atomic with a renderer replacing its composer.
        // Resolve the exact same retained/replacement wrapper again after reading so a
        // value fetched from an element that changed mid-call is never accepted.
        return text
    }

    /// Cheap polling read used only while waiting for a mutation that was already
    /// surrounded by full exact-context checks. A matching candidate is never accepted
    /// until `backgroundInputText` repeats the full document/chat boundary. This keeps
    /// the main actor responsive without weakening the pre/post safety invariant.
    func backgroundInputTextFast(
        for session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> String? {
        guard let element = liveBackgroundInputFast(
            for: session,
            allowReplacementAfterSubmission: allowReplacementAfterSubmission
        ), let text = stringAttribute(kAXValueAttribute, from: element),
              liveBackgroundInputFast(
                for: session,
                allowReplacementAfterSubmission: allowReplacementAfterSubmission
              ).map({ CFEqual($0, element) }) == true else {
            return nil
        }
        return text
    }

    /// An unreadable post-submit composer is benign indeterminate telemetry only
    /// while Accessibility is still granted and the exact target app is alive.
    /// Permission loss or app termination is a real delivery infrastructure failure.
    func backgroundDeliveryEnvironmentIsAvailable(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        AXIsProcessTrusted() && !session.app.isTerminated
    }

    /// Ethan may safely switch from unrelated app A to unrelated app B while a
    /// background delivery runs. The invariant is that the saved target must never
    /// become macOS-frontmost; freezing A would turn normal computer use into a false
    /// delivery failure. A nil foreground is indeterminate and therefore fails closed.
    static func backgroundTargetRemainsNonFrontmost(
        currentFrontmostPID: pid_t?,
        targetPID: pid_t
    ) -> Bool {
        guard let currentFrontmostPID else { return false }
        return currentFrontmostPID != targetPID
    }

    func backgroundTargetRemainsNonFrontmost(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        Self.backgroundTargetRemainsNonFrontmost(
            currentFrontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            targetPID: session.processIdentifier
        )
    }

    func targetOwnsSystemKeyboardFocus(_ target: Target) -> Bool {
        guard let element = target.element,
              let focused = systemFocusedElement() else {
            return false
        }
        return focused.pid == target.pid && CFEqual(focused.element, element)
    }

    /// Cheap foreground paste-settlement read. This never authorizes delivery: callers
    /// must still run the full saved document/chat resolver immediately before Send.
    /// It only avoids repeatedly walking an Electron/Telegram AX tree while waiting for
    /// a just-issued foreground paste to appear in the exact still-focused wrapper.
    func focusedExactInputTextFast(_ target: Target) -> String? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let element = target.element,
              let focused = systemFocusedElement(),
              focused.pid == target.pid,
              CFEqual(focused.element, element) else {
            return nil
        }
        return stringAttribute(kAXValueAttribute, from: element)
    }

    private func preparedTargetFocusBoundaryIsSafe(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard !session.app.isTerminated,
              backgroundTargetRemainsNonFrontmost(session),
              let focused = systemFocusedElement() else {
            return false
        }
        // Internal app focus is expected to point at the saved editor, but system-wide
        // keyboard focus must remain with whatever unrelated surface Ethan is using.
        return focused.pid != session.processIdentifier
    }

    private func backgroundFocusBoundaryIsSafe(
        _ session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> Bool {
        guard !session.app.isTerminated,
              let focused = systemFocusedElement() else {
            return false
        }
        switch session.focusMode {
        case .preparedTargetedInput:
            return preparedTargetFocusBoundaryIsSafe(session)
        case .alreadyKeyboardFocused:
            if focused.pid == session.processIdentifier,
               CFEqual(focused.element, session.element) {
                return true
            }
            return allowReplacementAfterSubmission
                && focused.pid == session.processIdentifier
                && postSubmissionReplacementMatches(
                    focused.element,
                    session: session
                )
        case .directExactElement:
            // Ethan may move between unrelated apps/inputs while the direct exact
            // wrapper remains valid. If the saved input itself becomes system focus,
            // fail this pre-decided direct route rather than racing his live typing.
            return focused.pid != session.processIdentifier
                || !CFEqual(focused.element, session.element)
        }
    }

    func backgroundDeliveryFocusIsSafe(
        _ session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> Bool {
        backgroundFocusBoundaryIsSafe(
            session,
            allowReplacementAfterSubmission: allowReplacementAfterSubmission
        )
    }

    private func backgroundDeliveryBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard backgroundFocusBoundaryIsSafe(session) else { return false }
        if Self.isTelegram(bundleIdentifier: session.bundleIdentifier) {
            return telegramDeliveryBoundaryMatches(session)
        }
        return resolvedExactElement(for: session.target).map {
            CFEqual($0, session.element)
        } == true && fastExactElementBoundaryMatches(session)
    }

    static func isTelegram(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return telegramBundleIdentifiers.contains(bundleIdentifier)
    }

    static func supportsSemanticSend(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return semanticSendBundleIdentifiers.contains(bundleIdentifier)
    }

    static func prefersAccessibilityTextInsertion(bundleIdentifier: String?) -> Bool {
        isTelegram(bundleIdentifier: bundleIdentifier)
    }

    func prefersAccessibilityTextInsertion(
        for session: BackgroundDeliverySession
    ) -> Bool {
        session.requiresDirectAccessibilityInsertion
            || Self.prefersAccessibilityTextInsertion(
                bundleIdentifier: session.bundleIdentifier
            )
    }

    /// Cheap per-chunk boundary for targeted Unicode text. The full document/chat
    /// fingerprint is resolved before and after insertion; each 20-unit chunk only
    /// rechecks the exact live process, saved window/editor, and non-frontmost state so
    /// long dictations remain safe without repeating an expensive tree walk per key.
    func backgroundTextEventBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        if Self.isTelegram(bundleIdentifier: session.bundleIdentifier) {
            return telegramFastBoundaryMatches(session)
        }
        return backgroundFocusBoundaryIsSafe(session)
            && fastExactElementBoundaryMatches(session)
    }

    func backgroundTextMutationBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        backgroundDeliveryBoundaryMatches(session)
    }

    /// Telegram can reuse one editor wrapper after a chat switch. Wrapper identity,
    /// geometry, and internal focus therefore never identify the chat by themselves.
    /// Every Telegram mutation/action must cross this boundary immediately beforehand
    /// and afterward: exact retained editor/window, readable matching chat anchors,
    /// unchanged structure, and proof that Telegram stayed non-frontmost.
    private func telegramDeliveryBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard Self.isTelegram(bundleIdentifier: session.bundleIdentifier),
              !session.app.isTerminated,
              backgroundFocusBoundaryIsSafe(session),
              let identity = session.target.identity,
              exactStructureMatches(
                session.element,
                identity: identity,
                in: session.window
              ) else {
            return false
        }

        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        let internalElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        )
        let internalWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        )
        let internalFocusMatches = internalElement.map {
            CFEqual($0, session.element)
        } == true && internalWindow.map {
            CFEqual($0, session.window)
        } == true
        let currentContext = contextFingerprint(
            in: session.window,
            region: identity.contextRegion,
            excluding: session.element,
            bundleIdentifier: session.bundleIdentifier
        )
        return Self.telegramRetainedInputAllowed(
            capturedPrimaryContextAnchors: identity.primaryContextAnchors,
            capturedContextAnchors: identity.contextAnchors,
            currentPrimaryContextAnchors: currentContext.primary,
            currentContextAnchors: currentContext.secondary,
            internalFocusMatches: internalFocusMatches,
            structureMatches: true
        )
    }

    private func telegramFastBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard Self.isTelegram(bundleIdentifier: session.bundleIdentifier),
              !session.app.isTerminated,
              backgroundFocusBoundaryIsSafe(session),
              stringAttribute(kAXRoleAttribute, from: session.element)
                == session.inputRole,
              stringAttribute(kAXSubroleAttribute, from: session.element)
                == session.inputSubrole,
              owningWindow(for: session.element).map({
                CFEqual($0, session.window)
              }) == true else {
            return false
        }
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        return elementAttribute(kAXFocusedWindowAttribute, from: appElement).map {
            CFEqual($0, session.window)
        } == true && elementAttribute(kAXFocusedUIElementAttribute, from: appElement).map {
            CFEqual($0, session.element)
        } == true
    }

    private func fastExactElementBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard backgroundElementMatchesSession(
            session.element,
            session: session,
            isSameRetainedWrapper: true
        ) else {
            return false
        }
        switch session.focusMode {
        case .preparedTargetedInput:
            let appElement = AXUIElementCreateApplication(session.processIdentifier)
            return elementAttribute(kAXFocusedWindowAttribute, from: appElement).map {
                CFEqual($0, session.window)
            } == true && elementAttribute(kAXFocusedUIElementAttribute, from: appElement).map {
                CFEqual($0, session.element)
            } == true
        case .alreadyKeyboardFocused:
            guard let focused = systemFocusedElement() else { return false }
            return focused.pid == session.processIdentifier
                && CFEqual(focused.element, session.element)
        case .directExactElement:
            return true
        }
    }

    static func telegramRetainedInputAllowed(
        capturedPrimaryContextAnchors: [String],
        capturedContextAnchors: [String],
        currentPrimaryContextAnchors: [String],
        currentContextAnchors: [String],
        internalFocusMatches: Bool,
        structureMatches: Bool
    ) -> Bool {
        internalFocusMatches
            && structureMatches
            && telegramContextFingerprintMatches(
                capturedPrimary: capturedPrimaryContextAnchors,
                capturedSecondary: capturedContextAnchors,
                currentPrimary: currentPrimaryContextAnchors,
                currentSecondary: currentContextAnchors
            )
    }

    static func telegramContextFingerprintMatches(
        capturedPrimary: [String],
        capturedSecondary: [String],
        currentPrimary: [String],
        currentSecondary: [String]
    ) -> Bool {
        guard !capturedPrimary.isEmpty, !currentPrimary.isEmpty,
              Set(capturedPrimary) == Set(currentPrimary) else {
            return false
        }
        // The selected-chat title/header is the mandatory identity. Message-history
        // anchors are only corroboration: requiring every captured message made normal
        // incoming messages or scrolling break delivery, while ignoring them entirely
        // would make duplicate chat titles indistinguishable. When history existed at
        // capture, require at least one exact stable overlap and otherwise fail closed.
        guard !capturedSecondary.isEmpty else { return true }
        let currentSecondarySet = Set(currentSecondary)
        return capturedSecondary.contains { currentSecondarySet.contains($0) }
    }

    /// Pure guard used by the post-submit verifier and its regression tests. A new
    /// renderer wrapper is acceptable only for read-only verification after one Send:
    /// it must remain in the exact saved process/window, be that app's internally
    /// focused editor, preserve role/subrole and every stable identifier that existed,
    /// and occupy the same tight composer geometry. This never authorizes insertion,
    /// focus mutation, semantic-button lookup, or an auto-send retry.
    static func postSubmissionReplacementAllowed(
        sameProcess: Bool,
        sameWindow: Bool,
        internallyFocused: Bool,
        roleMatches: Bool,
        subroleMatches: Bool,
        stableIdentifierMatches: Bool,
        domIdentifierMatches: Bool,
        expectedFrame: CGRect?,
        currentFrame: CGRect?
    ) -> Bool {
        guard let expectedFrame, let currentFrame else { return false }
        return sameProcess
            && sameWindow
            && internallyFocused
            && roleMatches
            && subroleMatches
            && stableIdentifierMatches
            && domIdentifierMatches
            && elementGeometryMatches(
                isSameRetainedWrapper: false,
                expectedFrame: expectedFrame,
                currentFrame: currentFrame
            )
    }

    static func elementGeometryMatches(
        isSameRetainedWrapper: Bool,
        expectedFrame: CGRect?,
        currentFrame: CGRect?
    ) -> Bool {
        if isSameRetainedWrapper { return true }
        guard let expectedFrame else { return true }
        guard let currentFrame else { return false }
        return abs(currentFrame.origin.x - expectedFrame.origin.x)
            + abs(currentFrame.origin.y - expectedFrame.origin.y)
            + abs(currentFrame.size.width - expectedFrame.size.width)
            + abs(currentFrame.size.height - expectedFrame.size.height) <= 24
    }

    /// Telegram and same-app/different-input delivery use AXSelectedText on the exact
    /// saved wrapper. Telegram must additionally keep readable matching chat context.
    /// Never replace the entire AXValue: rich editors can flatten or corrupt content.
    func insertTextUsingAccessibility(
        _ text: String,
        for session: BackgroundDeliverySession
    ) -> BackgroundTextInsertionResult {
        guard AXIsProcessTrusted(),
              !text.isEmpty,
              prefersAccessibilityTextInsertion(for: session) else {
            return .unavailable
        }
        guard backgroundDeliveryBoundaryMatches(session) else {
            return .focusSafetyViolation
        }

        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            session.element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else {
            logger.notice("Exact-input AXSelectedText is unavailable pid=\(session.processIdentifier, privacy: .public) bundle=\(session.bundleIdentifier ?? "nil", privacy: .public) AXError=\(settableResult.rawValue, privacy: .public)")
            return .unavailable
        }
        // The settable query can run arbitrary app code. Re-run the complete exact
        // document/chat boundary immediately before the irreversible mutation; a fast
        // wrapper check is insufficient because Telegram can reuse it across chats.
        guard backgroundDeliveryBoundaryMatches(session) else {
            return .focusSafetyViolation
        }

        let result = AXUIElementSetAttributeValue(
            session.element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        let boundarySafe = backgroundDeliveryBoundaryMatches(session)
        logger.info("Exact-input Accessibility insertion attempted pid=\(session.processIdentifier, privacy: .public) bundle=\(session.bundleIdentifier ?? "nil", privacy: .public) chars=\(text.count, privacy: .public) route=AXSelectedText result=\(result.rawValue, privacy: .public) boundarySafe=\(boundarySafe, privacy: .public)")
        guard boundarySafe else { return .focusSafetyViolation }
        return result == .success
            ? .acceptedSelectedText
            : .failed(result.rawValue)
    }

    /// ChatGPT and Codex can expose the same bundle identifier. Keep the executable
    /// path in delivery telemetry so live acceptance can prove which app was tested.
    func backgroundTargetExecutablePath(
        for session: BackgroundDeliverySession
    ) -> String? {
        session.app.executableURL?.path ?? session.app.bundleURL?.path
    }

    func pressNearbySubmitButton(
        for session: BackgroundDeliverySession
    ) -> NearbySubmitButtonResult {
        guard AXIsProcessTrusted(),
              Self.supportsSemanticSend(bundleIdentifier: session.bundleIdentifier),
              !session.app.isTerminated,
              backgroundDeliveryBoundaryMatches(session) else {
            return .unavailable
        }
        var result = pressNearbySubmitButton(
            element: session.element,
            pid: session.processIdentifier,
            preflight: {
                self.backgroundDeliveryBoundaryMatches(session)
            }
        )
        if result == .unavailable {
            result = pressRetainedSubmitButton(for: session)
        }
        if !backgroundFocusBoundaryIsSafe(
            session,
            allowReplacementAfterSubmission: true
        ) {
            logger.error("Semantic Send violated the exact user-focus boundary pid=\(session.processIdentifier, privacy: .public)")
            return .failed(AXError.cannotComplete.rawValue)
        }
        if Self.isTelegram(bundleIdentifier: session.bundleIdentifier),
           !telegramDeliveryBoundaryMatches(session) {
            logger.error("Telegram semantic Send lost readable matching chat context after its one action pid=\(session.processIdentifier, privacy: .public)")
            return .failed(AXError.cannotComplete.rawValue)
        }
        return result
    }

    private func pressRetainedSubmitButton(
        for session: BackgroundDeliverySession
    ) -> NearbySubmitButtonResult {
        guard let button = session.target.retainedSubmitButton,
              let capturedFrame = session.target.retainedSubmitButtonFrame,
              let currentFrame = frame(of: button) else {
            return .unavailable
        }
        var pid: pid_t = 0
        let pidMatches = AXUIElementGetPid(button, &pid) == .success
            && pid == session.processIdentifier
        let geometryMatches = abs(currentFrame.origin.x - capturedFrame.origin.x)
            + abs(currentFrame.origin.y - capturedFrame.origin.y)
            + abs(currentFrame.size.width - capturedFrame.size.width)
            + abs(currentFrame.size.height - capturedFrame.size.height) <= 8
            && currentFrame.width >= 14
            && currentFrame.width <= 96
            && currentFrame.height >= 14
            && currentFrame.height <= 96
        return Self.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: pidMatches,
            windowMatches: owningWindow(for: button).map({
                CFEqual($0, session.window)
            }) == true,
            geometryMatches: geometryMatches,
            roleMatches: stringAttribute(kAXRoleAttribute, from: button)
                == kAXButtonRole,
            enabled: boolAttribute(kAXEnabledAttribute, from: button) != false,
            label: submitLabel(for: button),
            hasPressAction: actionNames(from: button).contains(kAXPressAction),
            boundaryMatches: backgroundDeliveryBoundaryMatches(session)
        ) {
            let retainedResult = AXUIElementPerformAction(
                button,
                kAXPressAction as CFString
            )
            logger.info("Retained exact submit-button press attempted pid=\(session.processIdentifier, privacy: .public) bundle=\(session.bundleIdentifier ?? "nil", privacy: .public) result=\(retainedResult.rawValue, privacy: .public)")
            return retainedResult.rawValue
        }
    }

    /// Read the live editor text for bounded delivery verification. This is not used
    /// to infer focus or choose a destination; it only lets an allowlisted chat path
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

    /// Some chat editors expose an Accessibility button explicitly labelled Send even
    /// when their text area ignores synthetic Return. Restrict discovery to proven chat
    /// bundles and the nearest small shared composer container. Never treat an unlabelled
    /// square as Send: the same OpenAI slot becomes Stop while an agent is running.
    func pressNearbySubmitButton(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) -> NearbySubmitButtonResult {
        guard AXIsProcessTrusted() else {
            return .failed(AXError.apiDisabled.rawValue)
        }
        guard !target.app.isTerminated,
              Self.supportsSemanticSend(bundleIdentifier: target.bundleIdentifier),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              (!target.hasExactInput || targetOwnsSystemKeyboardFocus(target)),
              let element = liveElement(
                for: target,
                allowApplicationFallback: allowApplicationFallback
              ) else {
            return .unavailable
        }

        return pressNearbySubmitButton(
            element: element,
            pid: target.pid,
            preflight: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
                    && (!target.hasExactInput
                        || self.targetOwnsSystemKeyboardFocus(target))
            }
        )
    }

    private func pressNearbySubmitButton(
        element: AXUIElement,
        pid: pid_t,
        preflight: () -> Bool
    ) -> NearbySubmitButtonResult {
        guard let candidate = nearbySubmitButtonCandidate(element: element, pid: pid),
              let editorWindow = owningWindow(for: element),
              let editorFrame = frame(of: element),
              let candidateFrame = frame(of: candidate.element) else {
            logger.notice("Nearby submit button unavailable or failed its final boundary pid=\(pid, privacy: .public)")
            return .unavailable
        }
        var candidatePID: pid_t = 0
        let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)
        let result = Self.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: AXUIElementGetPid(candidate.element, &candidatePID) == .success
                && candidatePID == pid,
            windowMatches: owningWindow(for: candidate.element).map({
                CFEqual($0, editorWindow)
            }) == true,
            geometryMatches: candidateFrame.width >= 14
                && candidateFrame.width <= 96
                && candidateFrame.height >= 14
                && candidateFrame.height <= 96
                && editorFrame.insetBy(dx: -100, dy: -100).contains(center),
            roleMatches: stringAttribute(kAXRoleAttribute, from: candidate.element)
                == kAXButtonRole,
            enabled: boolAttribute(kAXEnabledAttribute, from: candidate.element)
                != false,
            label: submitLabel(for: candidate.element),
            hasPressAction: actionNames(from: candidate.element)
                .contains(kAXPressAction),
            boundaryMatches: preflight()
        ) {
            let actionResult = AXUIElementPerformAction(
                candidate.element,
                kAXPressAction as CFString
            )
            logger.info("Nearby submit-button press attempted pid=\(pid, privacy: .public) label=\(candidate.label, privacy: .public) result=\(actionResult.rawValue, privacy: .public)")
            return actionResult.rawValue
        }
        if result == .unavailable {
            logger.notice("Nearby submit button changed identity, label, geometry, or exact-input boundary immediately before press pid=\(pid, privacy: .public)")
        }
        return result
    }

    /// Resolve exactly one explicitly labelled Send button from the nearest shared
    /// composer container. The bounded ancestor/depth/geometry search keeps unrelated
    /// window controls out, and ambiguity fails closed rather than guessing.
    private func nearbySubmitButtonCandidate(
        element: AXUIElement,
        pid: pid_t,
        requireEnabled: Bool = true
    ) -> NearbySubmitButtonCandidate? {
        guard let editorFrame = frame(of: element),
              let editorWindow = owningWindow(for: element) else {
            return nil
        }

        let searchStarted = ProcessInfo.processInfo.systemUptime
        let timeBudget: TimeInterval = requireEnabled ? 0.075 : 0.030
        let deadline = searchStarted + timeBudget
        var remainingNodeBudget = requireEnabled ? 600 : 240
        var visitedNodeHashes = Set<CFHashCode>()
        var visitedNodeCount = 0
        var ancestor = elementAttribute(kAXParentAttribute, from: element)
        // Codex's current React composer nests FooterAction/Send several wrapper
        // levels away from the AXTextArea. Keep this search inside the nearest
        // composer-sized ancestors so recording capture stays cheap, but allow enough
        // depth to reach the app's real explicitly labelled Send button. A whole-window
        // scan here would regress recorder start/stop latency on large chat histories.
        for ancestorIndex in 0..<10 {
            guard remainingNodeBudget > 0,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                break
            }
            guard let container = ancestor else { break }
            ancestor = elementAttribute(kAXParentAttribute, from: container)
            // Frameless Electron wrappers can represent huge virtual subtrees. Never
            // traverse one: doing so made a bounded ancestor count effectively become a
            // whole-window scan and delayed the recorder even when the button was Stop.
            guard let containerFrame = frame(of: container),
                  containerFrame.intersects(editorFrame),
                  containerFrame.width <= editorFrame.width + 240,
                  containerFrame.height <= editorFrame.height + 240 else {
                continue
            }

            var candidates: [NearbySubmitButtonCandidate] = []
            let descendants = boundedDescendants(
                of: container,
                maximumDepth: 8,
                remainingNodeBudget: &remainingNodeBudget,
                visitedNodeHashes: &visitedNodeHashes,
                deadline: deadline
            )
            visitedNodeCount += descendants.count
            for (candidateElement, discoveredDepth) in descendants {
                var candidatePID: pid_t = 0
                guard !CFEqual(candidateElement, element),
                      AXUIElementGetPid(candidateElement, &candidatePID) == .success,
                      candidatePID == pid,
                      owningWindow(for: candidateElement).map({
                        CFEqual($0, editorWindow)
                      }) == true,
                      stringAttribute(kAXRoleAttribute, from: candidateElement)
                        == kAXButtonRole,
                      (!requireEnabled
                        || boolAttribute(kAXEnabledAttribute, from: candidateElement) != false),
                      let candidateFrame = frame(of: candidateElement),
                      candidateFrame.width >= 14,
                      candidateFrame.width <= 96,
                      candidateFrame.height >= 14,
                      candidateFrame.height <= 96 else {
                    continue
                }

                let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)
                guard editorFrame.insetBy(dx: -100, dy: -100).contains(center),
                      let label = submitLabel(for: candidateElement),
                      Self.isProvenSemanticSendLabel(label) else {
                    continue
                }
                let candidate = NearbySubmitButtonCandidate(
                    element: candidateElement,
                    label: label,
                    score: abs(center.x - editorFrame.maxX)
                        + abs(center.y - editorFrame.maxY),
                    discoveredDepth: discoveredDepth
                )
                if let existingIndex = candidates.firstIndex(where: {
                    CFEqual($0.element, candidateElement)
                }) {
                    if candidate.score < candidates[existingIndex].score {
                        candidates[existingIndex] = candidate
                    }
                } else {
                    candidates.append(candidate)
                }
            }

            let ranked = candidates.sorted { $0.score < $1.score }
            if ranked.count == 1, let candidate = ranked.first {
                let elapsedMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
                )
                logger.info("Resolved explicitly labelled Send button in nearest composer container pid=\(pid, privacy: .public) label=\(candidate.label, privacy: .public) ancestorIndex=\(ancestorIndex, privacy: .public) discoveredDepth=\(candidate.discoveredDepth, privacy: .public) nodesVisited=\(visitedNodeCount, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return candidate
            }
            if ranked.count > 1 {
                let elapsedMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
                )
                logger.notice("Nearest composer container had ambiguous Send buttons pid=\(pid, privacy: .public) candidates=\(ranked.count, privacy: .public) ancestorIndex=\(ancestorIndex, privacy: .public) nodesVisited=\(visitedNodeCount, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return nil
            }
        }

        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
        )
        logger.notice("Bounded nearby Send search found no candidate pid=\(pid, privacy: .public) nodesVisited=\(visitedNodeCount, privacy: .public) remainingNodeBudget=\(remainingNodeBudget, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
        return nil
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

    private func prepareBackgroundFocus(
        _ session: BackgroundDeliverySession
    ) async -> Bool {
        switch session.focusMode {
        case .alreadyKeyboardFocused, .directExactElement:
            // These modes are deliberately non-mutating. The exact saved wrapper and
            // current system-focus boundary must already make direct delivery safe.
            return backgroundDeliveryBoundaryMatches(session)

        case .preparedTargetedInput:
            guard preparedTargetFocusBoundaryIsSafe(session) else {
                logger.error("Background exact focus refused before its one bounded activation-state session targetPid=\(session.processIdentifier, privacy: .public)")
                return false
            }
            guard CursorPaster.beginTargetedInputSession(
                pid: session.processIdentifier
            ) else {
                logger.error("Background exact focus could not create its one bounded activation-state session targetPid=\(session.processIdentifier, privacy: .public)")
                return false
            }
            var keepSessionOpen = false
            defer {
                if !keepSessionOpen,
                   preparedTargetFocusBoundaryIsSafe(session) {
                    CursorPaster.endTargetedInputSession(
                        pid: session.processIdentifier
                    )
                }
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
            guard preparedTargetFocusBoundaryIsSafe(session) else {
                logger.error("Background exact focus stopped because the target acquired user focus during activation settlement targetPid=\(session.processIdentifier, privacy: .public)")
                return false
            }

            let appElement = AXUIElementCreateApplication(session.processIdentifier)
            let mainResult = AXUIElementSetAttributeValue(
                session.window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            guard preparedTargetFocusBoundaryIsSafe(session) else { return false }
            let windowResult = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                session.window
            )
            guard preparedTargetFocusBoundaryIsSafe(session) else { return false }
            let windowFocusedResult = AXUIElementSetAttributeValue(
                session.window,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            guard preparedTargetFocusBoundaryIsSafe(session) else { return false }
            let elementResult = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                session.element
            )
            guard preparedTargetFocusBoundaryIsSafe(session) else { return false }
            let elementFocusedResult = AXUIElementSetAttributeValue(
                session.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            try? await Task.sleep(nanoseconds: 50_000_000)

            let verified = backgroundDeliveryBoundaryMatches(session)
            if !verified {
                let actualWindow = elementAttribute(
                    kAXFocusedWindowAttribute,
                    from: appElement
                )
                let actualElement = elementAttribute(
                    kAXFocusedUIElementAttribute,
                    from: appElement
                )
                logger.error("Background exact focus verification failed after one bounded session targetPid=\(session.processIdentifier, privacy: .public) expectedWindowHash=\(CFHash(session.window), privacy: .public) actualWindowHash=\(actualWindow.map { String(CFHash($0)) } ?? "nil", privacy: .public) expectedElementHash=\(CFHash(session.element), privacy: .public) actualElementHash=\(actualElement.map { String(CFHash($0)) } ?? "nil", privacy: .public) mainAX=\(mainResult.rawValue, privacy: .public) windowAX=\(windowResult.rawValue, privacy: .public) windowFocusedAX=\(windowFocusedResult.rawValue, privacy: .public) elementAX=\(elementResult.rawValue, privacy: .public) elementFocusedAX=\(elementFocusedResult.rawValue, privacy: .public)")
            }
            keepSessionOpen = verified
            return verified
        }
    }

    private func liveBackgroundInput(
        for session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> AXUIElement? {
        if Self.isTelegram(bundleIdentifier: session.bundleIdentifier) {
            // Telegram may reuse one native editor wrapper across chats. Even read-only
            // verification must keep requiring the retained wrapper plus readable,
            // matching chat context; a renderer-style replacement is never accepted.
            return telegramDeliveryBoundaryMatches(session) ? session.element : nil
        }

        guard !session.app.isTerminated,
              backgroundFocusBoundaryIsSafe(
                session,
                allowReplacementAfterSubmission: allowReplacementAfterSubmission
              ) else {
            return nil
        }

        let focusedElement: AXUIElement
        switch session.focusMode {
        case .directExactElement:
            guard resolvedExactElement(for: session.target).map({
                CFEqual($0, session.element)
            }) == true,
                  backgroundElementMatchesSession(
                    session.element,
                    session: session,
                    isSameRetainedWrapper: true
                  ) else {
                return nil
            }
            return session.element

        case .alreadyKeyboardFocused:
            guard let focused = systemFocusedElement(),
                  focused.pid == session.processIdentifier else {
                return nil
            }
            focusedElement = focused.element

        case .preparedTargetedInput:
            let appElement = AXUIElementCreateApplication(session.processIdentifier)
            guard let focusedWindow = elementAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
            ), CFEqual(focusedWindow, session.window),
                  let internalElement = elementAttribute(
                    kAXFocusedUIElementAttribute,
                    from: appElement
                  ) else {
                return nil
            }
            focusedElement = internalElement
        }

        if CFEqual(focusedElement, session.element),
           resolvedExactElement(for: session.target).map({
               CFEqual($0, session.element)
           }) == true,
           backgroundElementMatchesSession(
            session.element,
            session: session,
            isSameRetainedWrapper: true
           ) {
            return session.element
        }

        // Allowlisted renderer chat composers can replace their wrapper after Send.
        // Resolve the app's one internally focused element in the exact saved
        // window and use it solely for the read-only clear/reset verifier below.
        guard allowReplacementAfterSubmission,
              Self.supportsSemanticSend(bundleIdentifier: session.bundleIdentifier),
              !Self.isTelegram(bundleIdentifier: session.bundleIdentifier),
              postSubmissionReplacementMatches(
                focusedElement,
                session: session
              ) else {
            return nil
        }
        return focusedElement
    }

    private func liveBackgroundInputFast(
        for session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool
    ) -> AXUIElement? {
        if Self.isTelegram(bundleIdentifier: session.bundleIdentifier) {
            return telegramFastBoundaryMatches(session) ? session.element : nil
        }
        guard backgroundFocusBoundaryIsSafe(
            session,
            allowReplacementAfterSubmission: allowReplacementAfterSubmission
        ) else {
            return nil
        }

        switch session.focusMode {
        case .directExactElement:
            return backgroundElementMatchesSession(
                session.element,
                session: session,
                isSameRetainedWrapper: true
            ) ? session.element : nil

        case .alreadyKeyboardFocused:
            guard let focused = systemFocusedElement(),
                  focused.pid == session.processIdentifier else {
                return nil
            }
            if CFEqual(focused.element, session.element),
               backgroundElementMatchesSession(
                session.element,
                session: session,
                isSameRetainedWrapper: true
               ) {
                return session.element
            }
            return allowReplacementAfterSubmission
                && postSubmissionReplacementMatches(
                    focused.element,
                    session: session
                ) ? focused.element : nil

        case .preparedTargetedInput:
            let appElement = AXUIElementCreateApplication(session.processIdentifier)
            guard let focusedWindow = elementAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
            ), CFEqual(focusedWindow, session.window),
                  let focusedElement = elementAttribute(
                    kAXFocusedUIElementAttribute,
                    from: appElement
                  ) else {
                return nil
            }
            if CFEqual(focusedElement, session.element),
               backgroundElementMatchesSession(
                session.element,
                session: session,
                isSameRetainedWrapper: true
               ) {
                return session.element
            }
            return allowReplacementAfterSubmission
                && postSubmissionReplacementMatches(
                    focusedElement,
                    session: session
                ) ? focusedElement : nil
        }
    }

    private func backgroundElementMatchesSession(
        _ element: AXUIElement,
        session: BackgroundDeliverySession,
        isSameRetainedWrapper: Bool
    ) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == session.processIdentifier,
              stringAttribute(kAXRoleAttribute, from: element) == session.inputRole,
              stringAttribute(kAXSubroleAttribute, from: element) == session.inputSubrole,
              owningWindow(for: element).map({
                CFEqual($0, session.window)
              }) == true else {
            return false
        }

        let identity = session.target.identity
        let identifierMatches = identity?.identifier.map {
            nonEmptyStringAttribute(kAXIdentifierAttribute, from: element) == $0
        } ?? true
        let domIdentifierMatches = identity?.domIdentifier.map {
            nonEmptyStringAttribute("AXDOMIdentifier", from: element) == $0
        } ?? true
        return identifierMatches
            && domIdentifierMatches
            && Self.elementGeometryMatches(
                isSameRetainedWrapper: isSameRetainedWrapper,
                expectedFrame: session.inputFrame,
                currentFrame: frame(of: element)
            )
    }

    /// Electron/React can replace the composer wrapper after a successful Send. The
    /// replacement allowance is deliberately post-action and read-only: same process,
    /// exact saved window, internally focused element, role/subrole, stable IDs, and
    /// strict geometry. No descendant search or focus setter participates.
    private func postSubmissionReplacementMatches(
        _ element: AXUIElement,
        session: BackgroundDeliverySession
    ) -> Bool {
        var pid: pid_t = 0
        let pidMatches = AXUIElementGetPid(element, &pid) == .success
            && pid == session.processIdentifier
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        let focusedWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement)
        let internallyFocusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        )
        let identity = session.target.identity
        let identifierMatches = identity?.identifier.map {
            nonEmptyStringAttribute(kAXIdentifierAttribute, from: element) == $0
        } ?? true
        let domIdentifierMatches = identity?.domIdentifier.map {
            nonEmptyStringAttribute("AXDOMIdentifier", from: element) == $0
        } ?? true

        return Self.postSubmissionReplacementAllowed(
            sameProcess: pidMatches,
            sameWindow: focusedWindow.map({
                CFEqual($0, session.window)
            }) == true && owningWindow(for: element).map({
                CFEqual($0, session.window)
            }) == true,
            internallyFocused: internallyFocusedElement.map({
                CFEqual($0, element)
            }) == true,
            roleMatches: stringAttribute(kAXRoleAttribute, from: element)
                == session.inputRole,
            subroleMatches: stringAttribute(kAXSubroleAttribute, from: element)
                == session.inputSubrole,
            stableIdentifierMatches: identifierMatches,
            domIdentifierMatches: domIdentifierMatches,
            expectedFrame: session.inputFrame,
            currentFrame: frame(of: element)
        )
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
            let currentContext = savedWindow.map {
                contextFingerprint(
                    in: $0,
                    region: identity.contextRegion,
                    excluding: Self.isTelegram(bundleIdentifier: target.bundleIdentifier)
                        ? target.element
                        : nil,
                    bundleIdentifier: target.bundleIdentifier
                )
            } ?? ContextAnchorSelection(primary: [], secondary: [])
            return Self.directCapturedElementContextAllowed(
                bundleIdentifier: target.bundleIdentifier,
                hasStableIdentifier: identity.identifier != nil
                    || identity.domIdentifier != nil,
                capturedPrimaryContextAnchors: identity.primaryContextAnchors,
                capturedContextAnchors: identity.contextAnchors,
                currentPrimaryContextAnchors: currentContext.primary,
                currentContextAnchors: currentContext.secondary
            )
        } ?? true

        if let element = target.element,
           let identity = target.identity,
           let savedWindow,
           directContextMatches,
           exactStructureMatches(element, identity: identity, in: savedWindow) {
            return element
        }

        guard let identity = target.identity,
              let window = savedWindow,
              exactInputContextMatches(
                identity,
                in: window,
                bundleIdentifier: target.bundleIdentifier
              ) else {
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

    /// Failure telemetry intentionally reports only booleans, counts, roles, and AX
    /// hashes—never chat titles or message text. This distinguishes an empty/mismatched
    /// Telegram context from a stale window, replaced wrapper, or ambiguous editor tree
    /// without leaking the user's conversation into unified logs.
    private func exactInputResolutionDiagnostics(for target: Target) -> String {
        let savedWindow = liveWindow(for: target, resolvedElement: nil)
        let identity = target.identity
        let currentContext: ContextAnchorSelection = if let savedWindow, let identity {
            contextFingerprint(
                in: savedWindow,
                region: identity.contextRegion,
                excluding: Self.isTelegram(bundleIdentifier: target.bundleIdentifier)
                    ? target.element
                    : nil,
                bundleIdentifier: target.bundleIdentifier
            )
        } else {
            ContextAnchorSelection(primary: [], secondary: [])
        }
        let directContextMatches = identity.map {
            Self.directCapturedElementContextAllowed(
                bundleIdentifier: target.bundleIdentifier,
                hasStableIdentifier: $0.identifier != nil || $0.domIdentifier != nil,
                capturedPrimaryContextAnchors: $0.primaryContextAnchors,
                capturedContextAnchors: $0.contextAnchors,
                currentPrimaryContextAnchors: currentContext.primary,
                currentContextAnchors: currentContext.secondary
            )
        } ?? false
        let currentContextSet = Set(currentContext.secondary)
        let contextMatchCount = identity?.contextAnchors.reduce(into: 0) { count, anchor in
            if currentContextSet.contains(anchor) { count += 1 }
        } ?? 0
        let directStructureMatches = if let element = target.element,
                                        let identity,
                                        let savedWindow {
            exactStructureMatches(element, identity: identity, in: savedWindow)
        } else {
            false
        }
        let matchingRoleCandidateCount = if let identity, let savedWindow {
            descendants(of: savedWindow).filter { element in
                let role = stringAttribute(kAXRoleAttribute, from: element)
                let subrole = stringAttribute(kAXSubroleAttribute, from: element)
                return role == identity.role
                    && subrole == identity.subrole
                    && isEditableInput(role: role, subrole: subrole)
            }.count
        } else {
            0
        }
        let focused = systemFocusedElement()
        let currentFocusMatchesSaved = if let focused, let savedElement = target.element {
            focused.pid == target.pid && CFEqual(focused.element, savedElement)
        } else {
            false
        }
        return "bundle=\(target.bundleIdentifier ?? "nil") savedWindow=\(savedWindow != nil) identity=\(identity != nil) capturedPrimary=\(identity?.primaryContextAnchors.count ?? 0) currentPrimary=\(currentContext.primary.count) capturedSecondary=\(identity?.contextAnchors.count ?? 0) currentSecondary=\(currentContext.secondary.count) matchedSecondary=\(contextMatchCount) directContext=\(directContextMatches) directStructure=\(directStructureMatches) roleCandidates=\(matchingRoleCandidateCount) currentFocusPid=\(focused?.pid ?? -1) currentFocusMatchesSaved=\(currentFocusMatchesSaved)"
    }

    private func exactStructureMatches(
        _ element: AXUIElement,
        identity: ExactInputIdentity,
        in window: AXUIElement
    ) -> Bool {
        guard stringAttribute(kAXRoleAttribute, from: element) == identity.role,
              stringAttribute(kAXSubroleAttribute, from: element) == identity.subrole,
              owningWindow(for: element).map({ CFEqual($0, window) }) == true,
              ancestorPath(from: element, through: window) == identity.ancestorPath,
              isEditableInput(role: identity.role, subrole: identity.subrole) else {
            return false
        }
        if let identifier = identity.identifier,
           nonEmptyStringAttribute(kAXIdentifierAttribute, from: element) != identifier {
            return false
        }
        if let domIdentifier = identity.domIdentifier,
           nonEmptyStringAttribute("AXDOMIdentifier", from: element) != domIdentifier {
            return false
        }
        return true
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
        in window: AXUIElement,
        bundleIdentifier: String?
    ) -> ExactInputIdentity? {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else { return nil }
        let contextRegion = contentRegion(for: element, in: window)
        let context = contextFingerprint(
            in: window,
            region: contextRegion,
            excluding: element,
            bundleIdentifier: bundleIdentifier
        )
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
            primaryContextAnchors: context.primary,
            contextAnchors: context.secondary
        )
    }

    private func exactInputContextMatches(
        _ identity: ExactInputIdentity,
        in window: AXUIElement,
        bundleIdentifier: String?
    ) -> Bool {
        if Self.isTelegram(bundleIdentifier: bundleIdentifier) {
            guard !identity.primaryContextAnchors.isEmpty else { return false }
            let current = contextFingerprint(
                in: window,
                region: identity.contextRegion,
                excluding: nil,
                bundleIdentifier: bundleIdentifier
            )
            return Self.telegramContextFingerprintMatches(
                capturedPrimary: identity.primaryContextAnchors,
                capturedSecondary: identity.contextAnchors,
                currentPrimary: current.primary,
                currentSecondary: current.secondary
            )
        }
        if identity.contextAnchors.isEmpty {
            // Stable AX/DOM identifiers can safely re-resolve without document text.
            // With neither identifiers nor context, an existing exact AX wrapper is
            // still usable, but frame/path-only stale-wrapper recovery is unsafe: a
            // switched Codex/browser tab can expose a lookalike composer in the same
            // place.
            return identity.identifier != nil || identity.domIdentifier != nil
        }
        let currentContext = contextAnchors(
            in: window,
            region: identity.contextRegion,
            excluding: nil,
            bundleIdentifier: bundleIdentifier
        )
        return Self.contextFingerprintMatches(
            captured: identity.contextAnchors,
            current: currentContext
        )
    }

    static func directCapturedElementContextAllowed(
        bundleIdentifier: String?,
        hasStableIdentifier: Bool = false,
        capturedPrimaryContextAnchors: [String] = [],
        capturedContextAnchors: [String],
        currentPrimaryContextAnchors: [String] = [],
        currentContextAnchors: [String]
    ) -> Bool {
        if isTelegram(bundleIdentifier: bundleIdentifier) {
            return telegramContextFingerprintMatches(
                capturedPrimary: capturedPrimaryContextAnchors,
                capturedSecondary: capturedContextAnchors,
                currentPrimary: currentPrimaryContextAnchors,
                currentSecondary: currentContextAnchors
            )
        }
        if capturedContextAnchors.isEmpty {
            guard let bundleIdentifier else { return true }
            if exactWrapperRequiresIdentityOrContextBundleIdentifiers.contains(
                bundleIdentifier
            ) {
                return hasStableIdentifier
            }
            return true
        }
        return contextFingerprintMatches(
            captured: capturedContextAnchors,
            current: currentContextAnchors
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
        excluding excludedElement: AXUIElement?,
        bundleIdentifier: String?
    ) -> [String] {
        let fingerprint = contextFingerprint(
            in: window,
            region: region,
            excluding: excludedElement,
            bundleIdentifier: bundleIdentifier
        )
        return fingerprint.primary + fingerprint.secondary
    }

    private func contextFingerprint(
        in window: AXUIElement,
        region: CGRect?,
        excluding excludedElement: AXUIElement?,
        bundleIdentifier: String?
    ) -> ContextAnchorSelection {
        var candidates: [ContextAnchorCandidate] = []
        for element in descendants(of: window) {
            if let excludedElement, CFEqual(element, excludedElement) { continue }
            let elementFrame = relativeFrame(of: element, in: window)
            if let region {
                guard let elementFrame, region.intersects(elementFrame) else {
                    continue
                }
            }
            let role = stringAttribute(kAXRoleAttribute, from: element)
            switch role {
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
            guard Self.contextAnchorIsEligible(
                    normalized,
                    role: role,
                    bundleIdentifier: bundleIdentifier
                  ),
                  normalized != "Ask for follow-up changes",
                  normalized != "Do anything" else {
                continue
            }
            let anchor = String(normalized.prefix(180))
            let isTelegramPrimary = Self.isTelegram(
                bundleIdentifier: bundleIdentifier
            )
                && role == kAXStaticTextRole
                && elementFrame != nil
                && !hasAncestor(
                    element,
                    role: kAXScrollAreaRole,
                    stoppingAt: window
                )
            candidates.append(ContextAnchorCandidate(
                value: anchor,
                isPrimary: isTelegramPrimary
            ))
        }
        return Self.selectContextAnchors(candidates, limit: 16)
    }

    /// Reserve bounded slots for non-scroll Telegram header/title text before sorting
    /// secondary message anchors. This makes a short selected-chat title survive a
    /// populated history and keeps the same words inside message text from pretending
    /// to be the selected title. Generic apps simply receive secondary anchors.
    static func selectContextAnchors(
        _ candidates: [ContextAnchorCandidate],
        limit: Int
    ) -> ContextAnchorSelection {
        guard limit > 0 else {
            return ContextAnchorSelection(primary: [], secondary: [])
        }
        var primarySeen = Set<String>()
        let primary = Array(
            candidates
                .filter {
                    $0.isPrimary
                        && !$0.value.isEmpty
                        && primarySeen.insert($0.value).inserted
                }
                .prefix(min(4, limit))
                .map(\.value)
        )
        let primarySet = Set(primary)
        var secondarySeen = Set<String>()
        let secondary = Array(
            candidates
                .filter {
                    !$0.isPrimary
                        && !$0.value.isEmpty
                        && !primarySet.contains($0.value)
                        && secondarySeen.insert($0.value).inserted
                }
                .sorted { $0.value.count > $1.value.count }
                .prefix(max(0, limit - primary.count))
                .map(\.value)
        )
        return ContextAnchorSelection(primary: primary, secondary: secondary)
    }

    /// Telegram can expose an otherwise empty chat with only a short selected-chat
    /// title. Generic collection historically discarded every value under 20
    /// characters, so "Saved Messages" had no readable identity and every foreground
    /// primary stop failed closed. Admit short values only when they are static text and
    /// do not look like volatile status or generic app chrome. These short anchors are
    /// then mandatory in `telegramContextFingerprintMatches`, preserving wrong-chat
    /// rejection. Other apps retain the established 20-character threshold.
    static func contextAnchorIsEligible(
        _ normalized: String,
        role: String?,
        bundleIdentifier: String?
    ) -> Bool {
        guard isTelegram(bundleIdentifier: bundleIdentifier) else {
            return normalized.count >= 20
        }
        let lowercased = normalized.lowercased()
        guard !telegramGenericContextLabels.contains(lowercased),
              !telegramVolatileContextPrefixes.contains(where: {
                lowercased.hasPrefix($0)
              }),
              !telegramContextLooksVolatile(lowercased),
              lowercased.contains(where: { $0.isLetter }) else {
            return false
        }
        if normalized.count >= 20 { return true }
        return role == kAXStaticTextRole && normalized.count >= 4
    }

    private static func telegramContextLooksVolatile(_ lowercased: String) -> Bool {
        if lowercased.contains(" members")
            || lowercased.contains(" member")
            || lowercased.contains(" subscribers")
            || lowercased.contains(" subscriber")
            || lowercased.contains(" participants")
            || lowercased.contains(" participant")
            || lowercased.hasSuffix(" online") {
            return true
        }
        let dateOrTimeCharacters = CharacterSet.decimalDigits.union(
            CharacterSet(charactersIn: ":/.-")
        )
        let scalars = lowercased.unicodeScalars
        return !scalars.isEmpty
            && scalars.allSatisfy {
                dateOrTimeCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
            }
    }

    private func hasAncestor(
        _ element: AXUIElement,
        role: String,
        stoppingAt boundary: AXUIElement
    ) -> Bool {
        var current = elementAttribute(kAXParentAttribute, from: element)
        for _ in 0..<30 {
            guard let candidate = current,
                  !CFEqual(candidate, boundary) else {
                return false
            }
            if stringAttribute(kAXRoleAttribute, from: candidate) == role {
                return true
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return false
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

    /// Traverse only new nodes inside the semantic-Send search's shared node/time
    /// budget. Outer composer ancestors overlap inner ones heavily; the cross-ancestor
    /// hash set prevents repeatedly walking the same React subtree while still allowing
    /// a larger framed ancestor to contribute previously unseen sibling controls.
    private func boundedDescendants(
        of root: AXUIElement,
        maximumDepth: Int,
        remainingNodeBudget: inout Int,
        visitedNodeHashes: inout Set<CFHashCode>,
        deadline: TimeInterval
    ) -> [(AXUIElement, Int)] {
        var result: [(AXUIElement, Int)] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        while cursor < queue.count,
              remainingNodeBudget > 0,
              ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            let hash = CFHash(element)
            guard visitedNodeHashes.insert(hash).inserted else {
                // A prior, nearer ancestor already traversed this whole bounded subtree.
                continue
            }
            remainingNodeBudget -= 1
            result.append((element, depth))
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

    private func actionNames(from element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func submitLabel(for element: AXUIElement) -> String? {
        [
            kAXDescriptionAttribute,
            kAXTitleAttribute,
            kAXHelpAttribute,
            kAXIdentifierAttribute
        ]
            .lazy
            .compactMap { self.stringAttribute($0, from: element) }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func isProvenSemanticSendLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "send", "send message", "send follow-up", "submit", "send-button", "sendbutton":
            return true
        default:
            return false
        }
    }

    /// The final semantic-Send gate owns the action closure, making it impossible for
    /// an ambiguous, stale, wrong-process, wrong-window, unlabelled, or boundary-lost
    /// candidate to invoke AXPress. Production supplies AXUIElementPerformAction;
    /// regression tests supply a counter and assert rejected candidates perform zero
    /// side effects.
    static func performProvenSemanticSend(
        isUnambiguous: Bool,
        pidMatches: Bool,
        windowMatches: Bool,
        geometryMatches: Bool,
        roleMatches: Bool,
        enabled: Bool,
        label: String?,
        hasPressAction: Bool,
        boundaryMatches: Bool,
        action: () -> Int32
    ) -> NearbySubmitButtonResult {
        guard isUnambiguous,
              pidMatches,
              windowMatches,
              geometryMatches,
              roleMatches,
              enabled,
              isProvenSemanticSendLabel(label),
              hasPressAction,
              boundaryMatches else {
            return .unavailable
        }
        let result = action()
        return result == AXError.success.rawValue
            ? .pressed
            : .failed(result)
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
