import Foundation
import AppKit
import ApplicationServices
import os

@MainActor
final class FocusLockService: ObservableObject {
    fileprivate enum TerminalAutomationTarget {
        case appleTerminal(windowID: Int, tty: String)
        case iTerm(windowID: Int, sessionID: String)
    }

    struct TerminalCaptureScriptResult: Equatable {
        let windowID: Int
        let sessionIdentity: String
        /// Every native session in the captured window, not just the selected tab.
        /// iTerm can have several one-pane tabs; counting only the current tab would
        /// incorrectly treat that window as an unambiguous single-session target.
        let windowSessionCount: Int
        let contents: String
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
        fileprivate let terminalAutomationTarget: TerminalAutomationTarget?
        fileprivate let retainedSubmitButton: AXUIElement?
        fileprivate let retainedSubmitButtonFrame: CGRect?
        fileprivate let captureID: UUID
        let bundleIdentifier: String?
        let displayInfo: DisplayInfo
        var processIdentifier: pid_t { pid }
        var hasExactInput: Bool { element != nil }
    }

    struct BackgroundDeliverySession {
        fileprivate enum Resolution: String {
            case strictFingerprint
            case retainedFocusedElement
            case applicationFocusedElement
        }

        fileprivate enum FocusMode: String {
            /// The target was fully backgrounded, so preparation opened one bounded
            /// process-targeted activation session and restored the target's internal
            /// window/editor without making it macOS-frontmost.
            case preparedTargetedInput
            /// The exact target already owned real system keyboard focus—either a
            /// non-activating panel (ChatGPT Option-Space) or a current terminal being
            /// routed through its exact native session API.
            case alreadyKeyboardFocused
            /// The target application was frontmost, but Ethan was working in a
            /// different input in that same app. Only direct AX mutation is allowed;
            /// changing app-internal focus would steal his typing.
            case directExactElement
        }

        fileprivate let target: Target
        fileprivate let element: AXUIElement
        fileprivate let window: AXUIElement
        fileprivate let app: NSRunningApplication
        fileprivate let frontmostPIDAtStart: pid_t
        fileprivate let keyboardFocusedPIDAtStart: pid_t
        fileprivate let keyboardFocusedElementAtStart: AXUIElement?
        fileprivate let previouslyFocusedWindow: AXUIElement?
        fileprivate let previouslyFocusedElement: AXUIElement?
        fileprivate let inputRole: String
        fileprivate let inputSubrole: String?
        fileprivate let inputFrame: CGRect?
        fileprivate let resolution: Resolution
        fileprivate let focusMode: FocusMode
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        var expectedFrontmostProcessIdentifier: pid_t { frontmostPIDAtStart }
        var expectedKeyboardFocusedProcessIdentifier: pid_t { keyboardFocusedPIDAtStart }
        var resolutionDescription: String { resolution.rawValue }
        var focusModeDescription: String { focusMode.rawValue }
        var allowsTargetedKeyboardEvents: Bool { focusMode != .directExactElement }
        var requiresDirectAccessibilityInsertion: Bool { focusMode == .directExactElement }
        var targetWasFrontmostAtStart: Bool { frontmostPIDAtStart == processIdentifier }
        var usesCurrentSystemKeyboardFocus: Bool { focusMode == .alreadyKeyboardFocused }
    }

    enum NearbySubmitButtonResult: Equatable {
        case pressed
        case unavailable
        case failed(Int32)
        case focusSafetyViolation
    }

    enum BackgroundTextInsertionResult: Equatable {
        case acceptedSelectedText
        case unavailable
        case failed(Int32)
        case focusSafetyViolation
    }

    enum BackgroundAutoSendResult: Equatable {
        case issued
        case unavailable
        case failed(String)
        case focusSafetyViolation
    }

    enum BackgroundTerminalTextDeliveryResult: Equatable {
        case issued(previousContents: String, currentContents: String)
        case unavailable
        case failed(String)
        case focusSafetyViolation
    }

    struct BackgroundInputSnapshot {
        let text: String
        let selectionLocation: Int?
        let selectionLength: Int?
    }

    private struct NearbySubmitButtonCandidate {
        let element: AXUIElement
        let label: String?
        let score: CGFloat
    }

    static let shared = FocusLockService()
    static let longPressThreshold: TimeInterval = 0.45

    @Published private(set) var isLockActive = false
    private(set) var stopHoldDecisionPending = false

    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "FocusLock")
    private let focusPollInterval: UInt64 = 20_000_000
    private static let nativeAccessibilityInsertionBundleIdentifiers: Set<String> = [
        "ru.keepcoder.Telegram"
    ]
    private static let retainedFocusedElementBundleIdentifiers: Set<String> = [
        "ru.keepcoder.Telegram"
    ]
    private static let exactWrapperRequiresReadableContextBundleIdentifiers: Set<String> = [
        "ru.keepcoder.Telegram"
    ]
    private static let exactWrapperRequiresIdentityOrContextBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "notion.id"
    ]
    private static let captureInternalFocusFallbackBundleIdentifiers: Set<String> = [
        "ru.keepcoder.Telegram",
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]
    private static let semanticSendBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "ru.keepcoder.Telegram"
    ]
    private static let retainedSemanticSendBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "ru.keepcoder.Telegram"
    ]
    private static let terminalHostBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable"
    ]
    private static let openAIComposerBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat"
    ]

    private init() {}

    func captureFocusedInput(allowApplicationFallback: Bool = false) async -> Target? {
        guard let target = captureFocusedInputSnapshot(
            allowApplicationFallback: allowApplicationFallback
        ) else {
            return nil
        }
        return await completingTerminalAutomationTarget(for: target)
    }

    /// Capture the exact decision-moment AX input synchronously. Next Track's event
    /// tap must return its consume/pass-through decision immediately, so its second-
    /// chance route snapshots here before Ethan can click elsewhere; only the native
    /// Terminal/iTerm identity enrichment is allowed to suspend afterward.
    func captureFocusedInputSnapshot(
        allowApplicationFallback: Bool = false
    ) -> Target? {
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

        var element = focusedValue as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            logger.error("Focused input capture could not resolve a live owning application")
            return nil
        }

        var role = stringAttribute(kAXRoleAttribute, from: element)
        var subrole = stringAttribute(kAXSubroleAttribute, from: element)
        var isExactEditableInput = isEditableInput(role: role, subrole: subrole)
        if !isExactEditableInput,
           Self.allowsInternalFocusedCaptureFallback(
               bundleIdentifier: app.bundleIdentifier
           ),
           let internalElement = elementAttribute(
               kAXFocusedUIElementAttribute,
               from: AXUIElementCreateApplication(pid)
           ) {
            var internalPID: pid_t = 0
            let internalRole = stringAttribute(kAXRoleAttribute, from: internalElement)
            let internalSubrole = stringAttribute(kAXSubroleAttribute, from: internalElement)
            let systemWindow = stringAttribute(kAXRoleAttribute, from: element) == kAXWindowRole
                ? element
                : owningWindow(for: element)
            let internalWindow = owningWindow(for: internalElement)
            if AXUIElementGetPid(internalElement, &internalPID) == .success,
               internalPID == pid,
               isEditableInput(role: internalRole, subrole: internalSubrole),
               boolAttribute(kAXFocusedAttribute, from: internalElement) != false,
               let systemWindow,
               let internalWindow,
               CFEqual(systemWindow, internalWindow) {
                logger.notice("Recovered exact internally focused editor after system focus exposed only a container pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) outerRole=\(role ?? "nil", privacy: .public) editorRole=\(internalRole ?? "nil", privacy: .public)")
                element = internalElement
                role = internalRole
                subrole = internalSubrole
                isExactEditableInput = true
            }
        }
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
            // Track route. Delivery may use one verifiable internally focused editor
            // in that saved app, but it never activates the app or guesses an input.
            logger.notice("Captured recording-start application fallback pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) rejectedRole=\(role ?? "nil", privacy: .public) rejectedSubrole=\(subrole ?? "nil", privacy: .public)")
        }

        // NSWorkspace activation notifications do not fire for non-activating
        // panels such as ChatGPT's floating input. The AX capture above knows the
        // true keyboard-focused owner, so feed it to the recorder's current-app
        // indicator without changing any per-session locked destination semantics.
        ActiveWindowService.shared.updateCurrentApplicationForDisplay(app)

        let owningWindow = isExactEditableInput ? owningWindow(for: element) : nil
        let identity = owningWindow.flatMap { exactInputIdentity(for: element, in: $0) }
        let retainedSubmitCandidate: NearbySubmitButtonCandidate?
        if isExactEditableInput,
           Self.allowsRetainedSemanticSend(
               bundleIdentifier: app.bundleIdentifier
           ) {
            retainedSubmitCandidate = nearbySubmitButtonCandidate(
                element: element,
                pid: pid,
                bundleIdentifier: app.bundleIdentifier,
                requireEnabled: false
            )
        } else {
            retainedSubmitCandidate = nil
        }

        return Target(
            element: isExactEditableInput ? element : nil,
            window: owningWindow,
            identity: identity,
            app: app,
            pid: pid,
            terminalAutomationTarget: nil,
            retainedSubmitButton: retainedSubmitCandidate?.element,
            retainedSubmitButtonFrame: retainedSubmitCandidate.flatMap {
                frame(of: $0.element)
            },
            captureID: UUID(),
            bundleIdentifier: app.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: app.localizedName ?? app.bundleIdentifier ?? String(localized: "Unknown app"),
                inputName: isExactEditableInput ? inputDisplayName(for: element) : String(localized: "application focus"),
                applicationIcon: app.icon
            )
        )
    }

    func completingTerminalAutomationTarget(for target: Target) async -> Target {
        guard let element = target.element,
              let window = target.window else {
            return target
        }
        let terminalAutomationTarget = await captureTerminalAutomationTarget(
            bundleIdentifier: target.bundleIdentifier,
            pid: target.pid,
            element: element,
            window: window
        )
        guard terminalAutomationTarget != nil else { return target }
        return Target(
            element: target.element,
            window: target.window,
            identity: target.identity,
            app: target.app,
            pid: target.pid,
            terminalAutomationTarget: terminalAutomationTarget,
            retainedSubmitButton: target.retainedSubmitButton,
            retainedSubmitButtonFrame: target.retainedSubmitButtonFrame,
            captureID: target.captureID,
            bundleIdentifier: target.bundleIdentifier,
            displayInfo: target.displayInfo
        )
    }

    func representsSameCaptureDecision(_ lhs: Target, _ rhs: Target) -> Bool {
        lhs.captureID == rhs.captureID
    }

    /// Terminal text areas expose no semantic AX action for Return. Capture the host's
    /// stable scripting window plus TTY/session identity while the exact input owns
    /// system focus. Window titles are mutable and commonly duplicated, so they are
    /// never used as the routing identity.
    private func captureTerminalAutomationTarget(
        bundleIdentifier: String?,
        pid: pid_t,
        element: AXUIElement,
        window: AXUIElement
    ) async -> TerminalAutomationTarget? {
        guard bundleIdentifier == "com.apple.Terminal"
                || bundleIdentifier == "com.googlecode.iterm2",
              terminalCaptureBoundaryMatches(
            pid: pid,
            element: element,
            window: window
        ), let windowID = cgWindowIdentifier(pid: pid, window: window),
           let decisionContents = stringAttribute(kAXValueAttribute, from: element) else {
            return nil
        }

        // Apple Events necessarily suspends. Terminal/iTerm can reuse one AX text-area
        // wrapper across tab or pane changes, so PID/window/wrapper equality after the
        // script is not enough to bind its returned TTY/session to the button-press
        // decision. Capture the selected tab control(s) and readable terminal-content
        // fingerprint before the first await, then require both independent boundaries
        // to still match the script-selected native session afterward.
        let decisionSelectedControls = terminalSelectedControls(in: window)
        let decisionContentAnchors = Self.terminalContentAnchors(decisionContents)

        let source: String
        switch bundleIdentifier {
        case "com.apple.Terminal":
            source = Self.terminalScriptHelpers + """

            tell application "Terminal"
                set frontWindows to every window whose frontmost is true
                if (count of frontWindows) is not 1 then error "Terminal front window was not unique"
                set targetWindow to item 1 of frontWindows
                set targetTab to selected tab of targetWindow
                set targetTTY to (tty of targetTab as text)
                if targetTTY is "" then error "Terminal selected tab had no TTY"
                set targetContents to my voiceInkTail((contents of targetTab as text), 4096)
                return my voiceInkFramedResult({(id of targetWindow as text), targetTTY, (count of tabs of targetWindow as text)}, {targetContents})
            end tell
            """

        case "com.googlecode.iterm2":
            source = Self.terminalScriptHelpers + """

            tell application "iTerm2"
                set targetWindow to current window
                if targetWindow is missing value then error "iTerm had no current window"
                set targetTab to current tab of targetWindow
                set targetSession to current session of targetWindow
                set targetSessionID to (id of targetSession as text)
                if targetSessionID is "" then error "iTerm current session had no ID"
                set windowSessionCount to 0
                repeat with candidateTab in tabs of targetWindow
                    set windowSessionCount to windowSessionCount + (count of sessions of candidateTab)
                end repeat
                set targetContents to my voiceInkTail((contents of targetSession as text), 4096)
                return my voiceInkFramedResult({(id of targetWindow as text), targetSessionID, (windowSessionCount as text)}, {targetContents})
            end tell
            """

        default:
            return nil
        }

        let parsed: TerminalCaptureScriptResult
        do {
            let value = try await BoundedAppleScriptRunner.run(
                source: source,
                timeout: 1.5
            ).stdout
            guard let result = Self.terminalCaptureScriptResult(value) else {
                logger.error("Terminal native identity capture returned malformed bounded metadata")
                return nil
            }
            parsed = result
        } catch {
            logger.error("AppleScript failed for capture exact terminal session category=\(String(describing: type(of: error)), privacy: .public)")
            return nil
        }

        let currentSelectedControls = terminalSelectedControls(in: window)
        let selectionControlsMatch = decisionSelectedControls.count
            == currentSelectedControls.count
            && zip(decisionSelectedControls, currentSelectedControls).allSatisfy {
                CFEqual($0.0, $0.1)
            }
        let nativeAnchors = Self.terminalContentAnchors(parsed.contents)
        guard parsed.windowID == windowID,
           Self.terminalSelectionMultiplicityIsSafe(
            selectedControlCount: decisionSelectedControls.count,
            windowSessionCount: parsed.windowSessionCount
           ),
           selectionControlsMatch,
           Self.terminalDecisionFingerprintMatches(
            captured: decisionContentAnchors,
            native: nativeAnchors,
            windowSessionCount: parsed.windowSessionCount
           ),
           terminalCaptureBoundaryMatches(
            pid: pid,
            element: element,
            window: window
           ) else {
            logger.error("Terminal scripting capture did not match the decision-moment AX/native session boundary pid=\(pid, privacy: .public) expectedWindowID=\(windowID, privacy: .public) selectedControls=\(decisionSelectedControls.count, privacy: .public) windowSessions=\(parsed.windowSessionCount, privacy: .public)")
            return nil
        }

        switch bundleIdentifier {
        case "com.apple.Terminal":
            logger.info("Captured Terminal scripting destination windowID=\(windowID, privacy: .public) tty=\(parsed.sessionIdentity, privacy: .private(mask: .hash))")
            return .appleTerminal(windowID: windowID, tty: parsed.sessionIdentity)
        case "com.googlecode.iterm2":
            logger.info("Captured iTerm scripting destination windowID=\(windowID, privacy: .public) session=\(parsed.sessionIdentity, privacy: .private(mask: .hash))")
            return .iTerm(windowID: windowID, sessionID: parsed.sessionIdentity)
        default:
            return nil
        }
    }

    static func terminalCaptureScriptResult(
        _ value: String
    ) -> TerminalCaptureScriptResult? {
        guard let framed = terminalFramedFields(
            value,
            metadataCount: 3,
            payloadCount: 1
        ), let windowID = Int(framed.metadata[0]),
              !framed.metadata[1].isEmpty,
              let windowSessionCount = Int(framed.metadata[2]),
              windowSessionCount > 0,
              let contents = framed.payloads.first else {
            return nil
        }
        return TerminalCaptureScriptResult(
            windowID: windowID,
            sessionIdentity: framed.metadata[1],
            windowSessionCount: windowSessionCount,
            contents: contents
        )
    }

    static func terminalContentAnchors(_ contents: String) -> [String] {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let anchors = normalized
            .split(separator: "\n")
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { $0.count >= 20 }
        return Array(anchors.suffix(20))
    }

    static func terminalDecisionFingerprintMatches(
        captured: [String],
        native: [String],
        windowSessionCount: Int
    ) -> Bool {
        // A genuinely single native session has no sibling to switch to, so a fresh
        // or cleared short prompt is still safe. With multiple tabs/panes, readable
        // decision-moment content is mandatory in addition to the selected-tab token;
        // this is what detects an iTerm pane switch inside the same selected tab.
        if windowSessionCount == 1, captured.isEmpty {
            return true
        }
        return contextFingerprintMatches(captured: captured, current: native)
    }

    static func terminalSelectionMultiplicityIsSafe(
        selectedControlCount: Int,
        windowSessionCount: Int
    ) -> Bool {
        windowSessionCount == 1 || selectedControlCount == 1
    }

    private static let terminalScriptHelpers = """
    on voiceInkTail(valueText, maximumLength)
        set valueText to valueText as text
        if (count characters of valueText) > maximumLength then
            set startIndex to (count characters of valueText) - maximumLength + 1
            return text startIndex thru -1 of valueText
        end if
        return valueText
    end voiceInkTail

    on voiceInkFramedResult(metadataValues, payloadValues)
        set outputText to ""
        repeat with metadataValue in metadataValues
            set outputText to outputText & ((contents of metadataValue) as text) & linefeed
        end repeat
        repeat with payloadValue in payloadValues
            set payloadText to (contents of payloadValue) as text
            set outputText to outputText & ((count characters of payloadText) as text) & linefeed
        end repeat
        repeat with payloadValue in payloadValues
            set outputText to outputText & ((contents of payloadValue) as text)
        end repeat
        return outputText
    end voiceInkFramedResult
    """

    static func terminalNativeScriptResult(
        _ value: String
    ) -> TerminalNativeScriptResult? {
        guard let framed = terminalFramedFields(
            value,
            metadataCount: 2,
            payloadCount: 2
        ), let windowID = Int(framed.metadata[0]),
              !framed.metadata[1].isEmpty else {
            return nil
        }
        return TerminalNativeScriptResult(
            windowID: windowID,
            sessionIdentity: framed.metadata[1],
            previousContents: framed.payloads[0],
            currentContents: framed.payloads[1]
        )
    }

    /// Return terminal contents directly through `osascript` stdout without ever
    /// interpolating them into `do shell script` (which exposes the shell command in
    /// argv). Metadata and payload lengths are line-delimited; payload bytes may then
    /// contain arbitrary newlines, Unicode, and delimiter-looking text. `osascript`
    /// appends one final newline to its printed return value, which is the only suffix
    /// accepted after the declared payload character counts.
    private static func terminalFramedFields(
        _ value: String,
        metadataCount: Int,
        payloadCount: Int
    ) -> (metadata: [String], payloads: [String])? {
        guard metadataCount > 0, payloadCount > 0 else { return nil }
        var cursor = value.startIndex

        func nextHeaderLine() -> String? {
            guard let newline = value[cursor...].firstIndex(of: "\n") else {
                return nil
            }
            var line = String(value[cursor..<newline])
            if line.last == "\r" { line.removeLast() }
            cursor = value.index(after: newline)
            return line
        }

        var metadata: [String] = []
        for _ in 0..<metadataCount {
            guard let field = nextHeaderLine() else { return nil }
            metadata.append(field)
        }

        var lengths: [Int] = []
        for _ in 0..<payloadCount {
            guard let field = nextHeaderLine(),
                  let length = Int(field),
                  (0...4096).contains(length) else {
                return nil
            }
            lengths.append(length)
        }

        var payloads: [String] = []
        for length in lengths {
            guard let end = value.index(
                cursor,
                offsetBy: length,
                limitedBy: value.endIndex
            ) else {
                return nil
            }
            payloads.append(String(value[cursor..<end]))
            cursor = end
        }

        let suffix = value[cursor...]
        guard suffix.isEmpty || suffix == "\n" else { return nil }
        return (metadata, payloads)
    }

    private func terminalCaptureBoundaryMatches(
        pid: pid_t,
        element: AXUIElement,
        window: AXUIElement
    ) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = systemFocusedElement(),
              focused.pid == pid,
              CFEqual(focused.element, element),
              let focusedWindow = elementAttribute(
                kAXFocusedWindowAttribute,
                from: AXUIElementCreateApplication(pid)
              ),
              CFEqual(focusedWindow, window),
              owningWindow(for: element).map({ CFEqual($0, window) }) == true else {
            return false
        }
        return true
    }

    private func terminalSelectedControls(in window: AXUIElement) -> [AXUIElement] {
        descendants(of: window).filter { element in
            guard stringAttribute(kAXRoleAttribute, from: element)
                    == kAXRadioButtonRole,
                  let value = numberAttribute(kAXValueAttribute, from: element) else {
                return false
            }
            return value.intValue == 1
        }
    }

    private func cgWindowIdentifier(
        pid: pid_t,
        window: AXUIElement
    ) -> Int? {
        guard let expectedFrame = frame(of: window),
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        let expectedTitle = nonEmptyStringAttribute(kAXTitleAttribute, from: window)
        let candidates: [(id: Int, title: String?)] = windowInfo.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary else {
                return nil
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(
                boundsDictionary as CFDictionary,
                &bounds
            ), frameDistance(bounds, expectedFrame) <= 4 else {
                return nil
            }
            return (
                id: number.intValue,
                title: info[kCGWindowName as String] as? String
            )
        }

        if candidates.count == 1 {
            return candidates[0].id
        }
        guard let expectedTitle else { return nil }
        let titleMatches = candidates.filter { $0.title == expectedTitle }
        return titleMatches.count == 1 ? titleMatches[0].id : nil
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

    /// Prepare one saved editor for non-activating delivery. The strict structural and
    /// content fingerprint remains the preferred route. Some native apps (Telegram is
    /// the proven case) hide every AX window child as soon as they become backgrounded,
    /// even though the captured text area is still live, readable, settable, and is
    /// still the app's own internally focused element. In that exact condition only,
    /// retain the captured wrapper instead of foregrounding the app. A non-empty but
    /// mismatched context still fails closed because it can indicate a changed chat,
    /// document, or browser tab.
    func prepareBackgroundDelivery(
        to target: Target,
        allowApplicationFallback: Bool = false
    ) async -> BackgroundDeliverySession? {
        guard AXIsProcessTrusted(),
              !target.app.isTerminated else {
            logger.error("Background input preparation unavailable pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }

        let resolved: (element: AXUIElement, resolution: BackgroundDeliverySession.Resolution)?
        if let element = resolvedExactElement(for: target) {
            resolved = (element, .strictFingerprint)
        } else if Self.allowsRetainedFocusedElementFallback(
            bundleIdentifier: target.bundleIdentifier
        ), let element = retainedInternallyFocusedElement(for: target) {
            resolved = (element, .retainedFocusedElement)
        } else if allowApplicationFallback,
                  !target.hasExactInput,
                  let element = applicationInternallyFocusedElement(for: target) {
            resolved = (element, .applicationFocusedElement)
        } else {
            resolved = nil
        }

        guard let resolved,
              let window = liveWindow(for: target, resolvedElement: resolved.element)
                ?? internallyFocusedWindow(for: target) else {
            logger.error("Background input preparation could not resolve a live saved element/window pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) exact=\(target.hasExactInput, privacy: .public) appFallback=\(allowApplicationFallback, privacy: .public)")
            return nil
        }

        let element = resolved.element
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        guard let role, isEditableInput(role: role, subrole: subrole) else {
            logger.error("Background input preparation rejected a non-editable resolved element pid=\(target.pid, privacy: .public) role=\(role ?? "nil", privacy: .public)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        let keyboardFocusAtStart = systemFocusedElement()
        guard let keyboardFocusAtStart else {
            logger.error("Background input preparation refused because system keyboard focus was unreadable targetPid=\(target.pid, privacy: .public)")
            return nil
        }
        let frontmostPIDAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let focusMode: BackgroundDeliverySession.FocusMode
        if frontmostPIDAtStart == target.pid,
           keyboardFocusAtStart.pid == target.pid,
           CFEqual(keyboardFocusAtStart.element, element) {
            // A current Terminal/iTerm target can still use the same exact native
            // session delivery as a background target. This mode performs no focus
            // mutation; it merely records that the saved editor already owns the
            // real keyboard input.
            focusMode = .alreadyKeyboardFocused
        } else if frontmostPIDAtStart == target.pid {
            guard target.hasExactInput else {
                logger.error("Background input preparation refused a frontmost app-only target targetPid=\(target.pid, privacy: .public)")
                return nil
            }
            focusMode = .directExactElement
        } else if keyboardFocusAtStart.pid == target.pid {
            focusMode = .alreadyKeyboardFocused
        } else {
            focusMode = .preparedTargetedInput
        }
        let session = BackgroundDeliverySession(
            target: target,
            element: element,
            window: window,
            app: target.app,
            frontmostPIDAtStart: frontmostPIDAtStart,
            keyboardFocusedPIDAtStart: keyboardFocusAtStart.pid,
            keyboardFocusedElementAtStart: keyboardFocusAtStart.element,
            previouslyFocusedWindow: elementAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
            ),
            previouslyFocusedElement: elementAttribute(
                kAXFocusedUIElementAttribute,
                from: appElement
            ),
            inputRole: role,
            inputSubrole: subrole,
            inputFrame: frame(of: element),
            resolution: resolved.resolution,
            focusMode: focusMode,
            processIdentifier: target.pid,
            bundleIdentifier: target.bundleIdentifier
        )
        guard await applyBackgroundFocus(session, prepareTargetedInputSession: true) else {
            return nil
        }

        logger.info("Background input prepared pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) resolution=\(resolved.resolution.rawValue, privacy: .public) focusMode=\(focusMode.rawValue, privacy: .public) windowHash=\(CFHash(window), privacy: .public) elementHash=\(CFHash(element), privacy: .public) frontmostPid=\(session.frontmostPIDAtStart, privacy: .public)")
        return session
    }

    func refreshBackgroundFocus(_ session: BackgroundDeliverySession) async -> Bool {
        await applyBackgroundFocus(session, prepareTargetedInputSession: false)
    }

    /// Verify the *current* keyboard/frontmost boundary. Do not infer safety from the
    /// session-start owner: Ethan can move away from an Option-Space panel while a
    /// transcript is being delivered. Every mutation checks this immediately before
    /// and after it, and unreadable system focus fails closed.
    func backgroundFocusSafetyVerified(
        for session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> Bool {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        if !session.targetWasFrontmostAtStart,
           frontmostPID == session.processIdentifier {
            return false
        }
        guard let focused = systemFocusedElement() else { return false }

        switch session.focusMode {
        case .preparedTargetedInput:
            return focused.pid != session.processIdentifier
        case .alreadyKeyboardFocused:
            if focused.pid != session.processIdentifier {
                // A successful submit can dismiss ChatGPT's non-activating quick
                // panel and naturally return keyboard focus to the still-frontmost
                // app. Accept that only after an issued submission and only while
                // the target itself stayed non-frontmost; pre-action checks remain
                // exact and strict.
                return allowReplacementAfterSubmission
                    && frontmostPID != session.processIdentifier
            }
            if CFEqual(focused.element, session.element) {
                return true
            }
            return allowReplacementAfterSubmission
                && postSubmissionReplacementMatches(
                    focused.element,
                    session: session
                )
        case .directExactElement:
            return focused.pid != session.processIdentifier
                || !backgroundElementMatchesSession(focused.element, session: session)
        }
    }

    func requiresTargetedInputSession(
        for session: BackgroundDeliverySession
    ) -> Bool {
        session.focusMode == .preparedTargetedInput
    }

    func backgroundInputIsTerminalHost(
        for session: BackgroundDeliverySession
    ) -> Bool {
        if let bundleIdentifier = session.bundleIdentifier,
           Self.terminalHostBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        let inputName = session.target.displayInfo.inputName.lowercased()
        return inputName.contains("terminal")
            || inputName.contains("shell")
            || inputName.contains("console")
    }

    /// A non-activating panel can own the exact system keyboard focus while another
    /// app remains NSWorkspace-frontmost. In that one mode, an ordinary HID Return
    /// is safer and more reliable than PID posting because macOS already routes the
    /// physical key to the saved composer. Exact AX focus is checked on both sides.
    func performKeyboardFocusedAutoSend(
        _ key: AutoSendKey,
        for session: BackgroundDeliverySession
    ) async -> BackgroundAutoSendResult {
        guard session.focusMode == .alreadyKeyboardFocused,
              backgroundFocusSafetyVerified(for: session),
              let focusBefore = systemFocusedElement(),
              focusBefore.pid == session.processIdentifier,
              CFEqual(focusBefore.element, session.element) else {
            return .unavailable
        }

        let result = await CursorPaster.performAutoSendToKeyboardFocusedProcess(
            key,
            expectedKeyboardFocusedPID: session.processIdentifier,
            expectedFocusedElement: session.element
        )
        guard result.didPostAutoSendCommand else {
            return .failed("keyboard-focused HID Return could not be posted")
        }
        guard let focusAfter = systemFocusedElement(),
              focusTransitionWasSafe(
                from: focusBefore,
                to: focusAfter,
                session: session,
                allowReplacementAfterSubmission: true
              ),
              backgroundFocusSafetyVerified(
                for: session,
                allowReplacementAfterSubmission: true
              ) else {
            return .focusSafetyViolation
        }
        return .issued
    }

    struct TerminalNativeScriptResult: Equatable {
        let windowID: Int
        let sessionIdentity: String
        let previousContents: String
        let currentContents: String
    }

    func hasNativeTerminalAutomationTarget(
        for session: BackgroundDeliverySession
    ) -> Bool {
        session.target.terminalAutomationTarget != nil
    }

    func requiresNativeTerminalSessionBinding(for target: Target) -> Bool {
        target.bundleIdentifier == "com.apple.Terminal"
            || target.bundleIdentifier == "com.googlecode.iterm2"
    }

    /// A Terminal/iTerm Apple Event is one native mutation and may optionally append
    /// one configured Return. Any embedded control or newline would be an additional
    /// terminal action hidden inside the transcript (for example a second command,
    /// tab-completion, or Escape sequence). Reject the whole native route before the
    /// host is touched; delivery then preserves the text in history/clipboard and
    /// reports the failure instead of partially executing it.
    static func terminalTextIsSafeForSingleNativeOperation(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
        }
    }

    /// Bind text and Return to one captured native PTY/session operation. Terminal
    /// apps can reuse a single AX text-area wrapper while tabs/panes change, so the
    /// former split route (PID-targeted text, then native newline) could type into B
    /// and execute A. Apple Terminal supports only atomic text+Return here; iTerm can
    /// also write exact-session text without Return. Unsupported variants fail before
    /// any mutation instead of falling back to a process-wide key event.
    func performTerminalTextDelivery(
        _ text: String,
        autoSendKey: AutoSendKey,
        for session: BackgroundDeliverySession
    ) async -> BackgroundTerminalTextDeliveryResult {
        guard Self.terminalTextIsSafeForSingleNativeOperation(text) else {
            return .failed(
                "transcript contains control characters that are unsafe for one native terminal operation"
            )
        }
        guard backgroundInputIsTerminalHost(for: session),
              backgroundFocusSafetyVerified(for: session),
              sessionTargetStillValid(session),
              liveBackgroundInput(for: session).map({
                CFEqual($0, session.element)
              }) == true,
              let destination = session.target.terminalAutomationTarget,
              let focusBefore = systemFocusedElement() else {
            return .unavailable
        }

        let expectedWindowID: Int
        let expectedSessionIdentity: String
        let source: String
        let textLiteral = Self.appleScriptLiteral(text)
        switch destination {
        case .appleTerminal(let windowID, let tty):
            guard autoSendKey == .enter else { return .unavailable }
            expectedWindowID = windowID
            expectedSessionIdentity = tty
            let ttyLiteral = Self.appleScriptLiteral(tty)
            source = Self.terminalScriptHelpers + """

            tell application "Terminal"
                set windowMatchCount to 0
                set tabMatchCount to 0
                set targetWindow to missing value
                set targetTab to missing value
                repeat with candidateWindow in windows
                    if (id of candidateWindow as integer) is \(windowID) then
                        set windowMatchCount to windowMatchCount + 1
                        set targetWindow to contents of candidateWindow
                    end if
                end repeat
                if windowMatchCount is not 1 then error "Terminal window ID was not unique"
                repeat with candidateTab in tabs of targetWindow
                    if (tty of candidateTab as text) is (\(ttyLiteral)) then
                        set tabMatchCount to tabMatchCount + 1
                        set targetTab to contents of candidateTab
                    end if
                end repeat
                if tabMatchCount is not 1 then error "Terminal TTY was not unique in the captured window"
                set beforeContents to my voiceInkTail((contents of targetTab as text), 4096)
                do script (\(textLiteral)) in targetTab
                delay 0.08
                set afterContents to my voiceInkTail((contents of targetTab as text), 4096)
                return my voiceInkFramedResult({(id of targetWindow as text), (tty of targetTab as text)}, {beforeContents, afterContents})
            end tell
            """

        case .iTerm(let windowID, let sessionID):
            guard autoSendKey == .none || autoSendKey == .enter else {
                return .unavailable
            }
            expectedWindowID = windowID
            expectedSessionIdentity = sessionID
            let sessionLiteral = Self.appleScriptLiteral(sessionID)
            let newline = autoSendKey == .enter ? "true" : "false"
            source = Self.terminalScriptHelpers + """

            tell application "iTerm2"
                set windowMatchCount to 0
                set sessionMatchCount to 0
                set targetWindow to missing value
                set targetSession to missing value
                repeat with candidateWindow in windows
                    if (id of candidateWindow as integer) is \(windowID) then
                        set windowMatchCount to windowMatchCount + 1
                        set targetWindow to contents of candidateWindow
                    end if
                end repeat
                if windowMatchCount is not 1 then error "iTerm window ID was not unique"
                repeat with candidateTab in tabs of targetWindow
                    repeat with candidateSession in sessions of candidateTab
                        if (id of candidateSession as text) is (\(sessionLiteral)) then
                            set sessionMatchCount to sessionMatchCount + 1
                            set targetSession to contents of candidateSession
                        end if
                    end repeat
                end repeat
                if sessionMatchCount is not 1 then error "iTerm session was not unique in the captured window"
                set beforeContents to my voiceInkTail((contents of targetSession as text), 4096)
                write targetSession text (\(textLiteral)) newline \(newline)
                delay 0.08
                set afterContents to my voiceInkTail((contents of targetSession as text), 4096)
                return my voiceInkFramedResult({(id of targetWindow as text), (id of targetSession as text)}, {beforeContents, afterContents})
            end tell
            """
        }

        let parsed: TerminalNativeScriptResult
        do {
            let output = try await BoundedAppleScriptRunner.run(
                source: source,
                timeout: 2
            ).stdout
            guard let value = Self.terminalNativeScriptResult(output),
                  value.windowID == expectedWindowID,
                  value.sessionIdentity == expectedSessionIdentity else {
                return .failed("terminal host returned a different native session identity")
            }
            parsed = value
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let focusAfter = systemFocusedElement(),
              focusTransitionWasSafe(
                from: focusBefore,
                to: focusAfter,
                session: session,
                allowReplacementAfterSubmission: autoSendKey == .enter
              ),
              backgroundFocusSafetyVerified(
                for: session,
                allowReplacementAfterSubmission: autoSendKey == .enter
              ) else {
            return .focusSafetyViolation
        }
        return .issued(
            previousContents: parsed.previousContents,
            currentContents: parsed.currentContents
        )
    }

    func finishBackgroundDelivery(_ session: BackgroundDeliverySession) {
        guard session.focusMode == .preparedTargetedInput else { return }
        // Ethan may legitimately move between other apps while delivery runs. The
        // invariant is that VoiceInk++ never activates the target, not that his
        // foreground PID remains frozen. If he brings the target forward himself,
        // leave its live internal focus alone instead of restoring stale state.
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = systemFocusedElement()
        guard frontmostPID != session.processIdentifier,
              focused?.pid != session.processIdentifier else {
            logger.notice("Background internal-focus restoration skipped because target is now frontmost/keyboard-focused targetPid=\(session.processIdentifier, privacy: .public) startFrontmostPid=\(session.frontmostPIDAtStart, privacy: .public) startKeyboardPid=\(session.keyboardFocusedPIDAtStart, privacy: .public) actualFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public) actualKeyboardPid=\(focused?.pid ?? -1, privacy: .public)")
            return
        }
        guard focused != nil else {
            // AX focus can become temporarily unreadable while Ethan switches apps.
            // The target is not frontmost, so close the synthetic activation session
            // but do not guess which stale internal editor should be restored.
            logger.notice("Background internal-focus restoration skipped because system focus is unreadable; closing targeted session only targetPid=\(session.processIdentifier, privacy: .public)")
            CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
            return
        }

        // Electron processes the synthetic activation state asynchronously. The same
        // bounded 50 ms settlement used by preparation is required before and after
        // restoring its previous internal window/editor; immediate setters were
        // accepted but left Codex attached to the delivery window in the live probe.
        Thread.sleep(forTimeInterval: 0.05)
        let frontmostPIDBeforeRestoration = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        let focusedBeforeRestoration = systemFocusedElement()
        guard frontmostPIDBeforeRestoration != session.processIdentifier,
              let verifiedFocusedBeforeRestoration = focusedBeforeRestoration,
              verifiedFocusedBeforeRestoration.pid != session.processIdentifier else {
            logger.notice("Background internal-focus restoration abandoned after settlement because target became active; leaving its live state untouched targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(frontmostPIDBeforeRestoration ?? -1, privacy: .public) keyboardPid=\(focusedBeforeRestoration?.pid ?? -1, privacy: .public)")
            // If focus merely became unreadable while the target stayed backgrounded,
            // close the synthetic session. Never send deactivation after Ethan actually
            // brought the target forward or focused its non-activating panel.
            if frontmostPIDBeforeRestoration != session.processIdentifier,
               focusedBeforeRestoration == nil {
                CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
            }
            return
        }
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        if let previousWindow = session.previouslyFocusedWindow,
           !CFEqual(previousWindow, session.window) {
            let windowRestoreFrontmostPID = NSWorkspace.shared.frontmostApplication?
                .processIdentifier
            let windowRestoreFocused = systemFocusedElement()
            guard windowRestoreFrontmostPID != session.processIdentifier,
                  let verifiedWindowRestoreFocused = windowRestoreFocused,
                  verifiedWindowRestoreFocused.pid != session.processIdentifier else {
                logger.notice("Background window restoration stopped because target became active or system focus became unreadable targetPid=\(session.processIdentifier, privacy: .public)")
                if windowRestoreFrontmostPID != session.processIdentifier,
                   windowRestoreFocused == nil {
                    CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
                }
                return
            }
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
            let elementRestoreFrontmostPID = NSWorkspace.shared.frontmostApplication?
                .processIdentifier
            let elementRestoreFocused = systemFocusedElement()
            guard elementRestoreFrontmostPID != session.processIdentifier,
                  let verifiedElementRestoreFocused = elementRestoreFocused,
                  verifiedElementRestoreFocused.pid != session.processIdentifier else {
                logger.notice("Background element restoration stopped because target became active or system focus became unreadable targetPid=\(session.processIdentifier, privacy: .public)")
                if elementRestoreFrontmostPID != session.processIdentifier,
                   elementRestoreFocused == nil {
                    CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
                }
                return
            }
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
        let finalFrontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        let finalFocusedPID = systemFocusedElement()?.pid
        guard finalFrontmostPID != session.processIdentifier,
              finalFocusedPID != session.processIdentifier else {
            logger.notice("Background targeted-session deactivation skipped because target became active during cleanup targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(finalFrontmostPID ?? -1, privacy: .public) keyboardPid=\(finalFocusedPID ?? -1, privacy: .public)")
            return
        }
        CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
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
        // AX reads are not atomic with tab/chat switching. Re-resolve after the read so
        // a value fetched from a wrapper that Ethan replaced mid-call is never accepted
        // as verification for the saved input.
        return text
    }

    func backgroundInputSnapshot(
        for session: BackgroundDeliverySession
    ) -> BackgroundInputSnapshot? {
        guard let element = liveBackgroundInput(for: session),
              let text = stringAttribute(kAXValueAttribute, from: element) else {
            return nil
        }
        let selection = selectedTextRange(from: element)
        guard liveBackgroundInput(for: session).map({
            CFEqual($0, element)
        }) == true else {
            return nil
        }
        // Text plus selection are one insertion precondition. If the saved tab/chat
        // changed between those AX reads, discard the whole snapshot rather than build
        // an edit against two different editor states.
        return BackgroundInputSnapshot(
            text: text,
            selectionLocation: selection.map { Int($0.location) },
            selectionLength: selection.map { Int($0.length) }
        )
    }

    func prefersAccessibilityTextInsertion(
        for session: BackgroundDeliverySession
    ) -> Bool {
        Self.prefersAccessibilityTextInsertion(
            bundleIdentifier: session.bundleIdentifier
        )
    }

    static func prefersAccessibilityTextInsertion(
        bundleIdentifier: String?
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return nativeAccessibilityInsertionBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Native text views can expose a genuinely background-safe paste primitive:
    /// setting AXSelectedText replaces the saved selection/caret without routing a
    /// global Command-V or activating the owning application. Telegram advertises
    /// this attribute as settable even while its background window hides all children.
    /// The delivery layer still verifies the exact resulting value before continuing.
    ///
    /// Do not fall back to reconstructing and setting the element's entire AXValue.
    /// Rich/contenteditable surfaces such as Notion can flatten formatting or replace
    /// block semantics even when AX reports the value as settable. Same-app/different-
    /// input delivery must therefore fail closed when AXSelectedText is unavailable.
    func insertTextUsingAccessibility(
        _ text: String,
        for session: BackgroundDeliverySession
    ) -> BackgroundTextInsertionResult {
        guard AXIsProcessTrusted(),
              !text.isEmpty,
              backgroundFocusSafetyVerified(for: session),
              let element = liveBackgroundInput(for: session) else {
            return .unavailable
        }

        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard let focusBefore = systemFocusedElement() else {
            logger.error("Background Accessibility insertion refused because system focus was unreadable pid=\(session.processIdentifier, privacy: .public)")
            return .unavailable
        }

        let result: AXError
        let acceptedResult: BackgroundTextInsertionResult
        let route: String
        if settableResult == .success, settable.boolValue {
            guard backgroundMutationBoundaryMatches(
                element,
                session: session
            ) else {
                return .focusSafetyViolation
            }
            result = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            acceptedResult = .acceptedSelectedText
            route = "AXSelectedText"
        } else {
            logger.notice("Background Accessibility insertion unavailable pid=\(session.processIdentifier, privacy: .public) selectedTextAX=\(settableResult.rawValue, privacy: .public) direct=\(session.requiresDirectAccessibilityInsertion, privacy: .public)")
            return .unavailable
        }

        let focusAfter = systemFocusedElement()
        let focusSafe = focusAfter.map {
            focusTransitionWasSafe(from: focusBefore, to: $0, session: session)
        } ?? false
        let targetSafe = backgroundMutationBoundaryMatches(
            element,
            session: session
        )
        logger.info("Background Accessibility insertion attempted pid=\(session.processIdentifier, privacy: .public) chars=\(text.count, privacy: .public) route=\(route, privacy: .public) result=\(result.rawValue, privacy: .public) focusSafe=\(focusSafe, privacy: .public) targetSafe=\(targetSafe, privacy: .public)")
        guard focusSafe, targetSafe else { return .focusSafetyViolation }
        return result == .success ? acceptedResult : .failed(result.rawValue)
    }

    /// This is the last gate immediately surrounding a direct AX mutation. Resolving
    /// the target once at function entry is insufficient: Telegram can reuse one editor
    /// wrapper after a chat switch, and same-app delivery can race a click into another
    /// input. Require both the exact per-session identity and the live system-focus
    /// boundary again on each side of the setter.
    private func backgroundMutationBoundaryMatches(
        _ element: AXUIElement,
        session: BackgroundDeliverySession
    ) -> Bool {
        backgroundFocusSafetyVerified(for: session)
            && sessionTargetStillValid(session)
            && liveBackgroundInput(for: session).map {
                CFEqual($0, element)
            } == true
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
        guard Self.supportsSemanticSend(bundleIdentifier: session.bundleIdentifier),
              backgroundFocusSafetyVerified(for: session),
              let liveElement = liveBackgroundInput(for: session),
              let focusBefore = systemFocusedElement() else {
            return .unavailable
        }
        var result = pressNearbySubmitButton(
            element: liveElement,
            pid: session.processIdentifier,
            bundleIdentifier: session.bundleIdentifier,
            preflight: {
                self.backgroundFocusSafetyVerified(for: session)
                    && self.liveBackgroundInput(for: session).map {
                        CFEqual($0, liveElement)
                    } == true
            }
        )
        if result == .unavailable,
           let retainedResult = pressRetainedSubmitButton(
               for: session,
               liveElement: liveElement
           ) {
            result = retainedResult
        }
        guard let focusAfter = systemFocusedElement(),
              focusTransitionWasSafe(
                from: focusBefore,
                to: focusAfter,
                session: session,
                allowReplacementAfterSubmission: true
              ) else {
            logger.error("Nearby submit-button action violated keyboard-focus safety pid=\(session.processIdentifier, privacy: .public)")
            return .focusSafetyViolation
        }
        return result
    }

    /// Telegram can hide every window descendant while backgrounded even though its
    /// captured native controls remain live. Reuse only the exact button wrapper
    /// captured beside this exact editor, then require the same saved window/slot,
    /// enabled state, press action, and an explicit Send label. An unlabelled OpenAI
    /// square can become Stop while an agent runs, so geometry is never semantic proof.
    private func pressRetainedSubmitButton(
        for session: BackgroundDeliverySession,
        liveElement: AXUIElement
    ) -> NearbySubmitButtonResult? {
        guard let button = validatedRetainedSubmitButton(
            for: session.target,
            liveElement: liveElement,
            window: session.window
        ), backgroundFocusSafetyVerified(for: session),
           liveBackgroundInput(for: session).map({
               CFEqual($0, liveElement)
           }) == true else {
            return nil
        }

        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        logger.info("Retained exact submit-button press attempted pid=\(session.processIdentifier, privacy: .public) bundle=\(session.bundleIdentifier ?? "nil", privacy: .public) result=\(result.rawValue, privacy: .public)")
        return result == .success ? .pressed : .failed(result.rawValue)
    }

    private func validatedRetainedSubmitButton(
        for target: Target,
        liveElement: AXUIElement,
        window: AXUIElement
    ) -> AXUIElement? {
        guard let bundleIdentifier = target.bundleIdentifier,
              Self.allowsRetainedSemanticSend(bundleIdentifier: bundleIdentifier),
              let button = target.retainedSubmitButton,
              let capturedFrame = target.retainedSubmitButtonFrame,
              stringAttribute(kAXRoleAttribute, from: button) == kAXButtonRole,
              boolAttribute(kAXEnabledAttribute, from: button) == true,
              let currentFrame = frame(of: button),
              frameDistance(currentFrame, capturedFrame) <= 24,
              let buttonWindow = owningWindow(for: button),
              CFEqual(buttonWindow, window),
              actionNames(of: button).contains(kAXPressAction) else {
            return nil
        }

        guard Self.isProvenSemanticSendLabel(submitLabel(for: button)) else {
            return nil
        }
        return button
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

    func focusedInputSnapshot(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) -> BackgroundInputSnapshot? {
        guard let element = liveElement(
            for: target,
            allowApplicationFallback: allowApplicationFallback
        ),
        let text = stringAttribute(kAXValueAttribute, from: element) else {
            return nil
        }
        let selection = selectedTextRange(from: element)
        return BackgroundInputSnapshot(
            text: text,
            selectionLocation: selection.map { Int($0.location) },
            selectionLength: selection.map { Int($0.length) }
        )
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
        guard Self.supportsSemanticSend(bundleIdentifier: target.bundleIdentifier),
              !target.app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              foregroundTargetStillOwnsKeyboardInput(
                target,
                allowApplicationFallback: allowApplicationFallback
              ),
              let element = liveElement(
                for: target,
                allowApplicationFallback: allowApplicationFallback
              ) else {
            return .unavailable
        }

        var result = pressNearbySubmitButton(
            element: element,
            pid: target.pid,
            bundleIdentifier: target.bundleIdentifier,
            preflight: {
                self.foregroundTargetStillOwnsKeyboardInput(
                    target,
                    allowApplicationFallback: allowApplicationFallback
                )
            }
        )
        if result == .unavailable,
           let window = owningWindow(for: element),
           let button = validatedRetainedSubmitButton(
               for: target,
               liveElement: element,
               window: window
           ) {
            guard foregroundTargetStillOwnsKeyboardInput(
                target,
                allowApplicationFallback: allowApplicationFallback
            ) else {
                return .focusSafetyViolation
            }
            let pressResult = AXUIElementPerformAction(
                button,
                kAXPressAction as CFString
            )
            result = pressResult == .success
                ? .pressed
                : .failed(pressResult.rawValue)
            logger.info("Foreground retained exact submit-button press attempted pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) result=\(pressResult.rawValue, privacy: .public)")
        }
        return result
    }

    private func pressNearbySubmitButton(
        element: AXUIElement,
        pid: pid_t,
        bundleIdentifier: String?,
        preflight: (() -> Bool)? = nil
    ) -> NearbySubmitButtonResult {
        guard let candidate = nearbySubmitButtonCandidate(
            element: element,
            pid: pid,
            bundleIdentifier: bundleIdentifier
        ) else {
            logger.notice("Nearby submit button unavailable pid=\(pid, privacy: .public)")
            return .unavailable
        }

        guard preflight?() != false else {
            logger.notice("Nearby submit button refused because its exact-input preflight changed pid=\(pid, privacy: .public)")
            return .focusSafetyViolation
        }
        let result = AXUIElementPerformAction(
            candidate.element,
            kAXPressAction as CFString
        )
        logger.info("Nearby submit-button press attempted pid=\(pid, privacy: .public) label=\(candidate.label ?? "nil", privacy: .public) result=\(result.rawValue, privacy: .public)")
        return result == .success ? .pressed : .failed(result.rawValue)
    }

    private func applyBackgroundFocus(
        _ session: BackgroundDeliverySession,
        prepareTargetedInputSession: Bool
    ) async -> Bool {
        let frontmostPIDBeforePreparation = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        guard !session.app.isTerminated,
              sessionTargetStillValid(session) else {
            logger.error("Background exact focus refused because target terminated or no longer resolves to the saved input targetPid=\(session.processIdentifier, privacy: .public) startFrontmostPid=\(session.frontmostPIDAtStart, privacy: .public) actualFrontmostPid=\(frontmostPIDBeforePreparation, privacy: .public)")
            return false
        }

        guard let systemFocusBeforePreparation = systemFocusedElement() else {
            logger.error("Background exact focus refused because system keyboard focus was unreadable targetPid=\(session.processIdentifier, privacy: .public)")
            return false
        }

        switch session.focusMode {
        case .directExactElement:
            // Same app, different editor: never rewrite the app's internal focus. The
            // delivery layer may use only AXSelectedText and a proven semantic action.
            return backgroundFocusSafetyVerified(for: session)

        case .alreadyKeyboardFocused:
            // ChatGPT's non-activating Option-Space panel and a current exact native
            // terminal can already be the keyboard owner. Do not synthesize
            // activation/deactivation or rewrite focus. If Ethan moves away after
            // preparation, a refresh fails instead of silently reacquiring it.
            guard systemFocusBeforePreparation.pid == session.processIdentifier,
                  CFEqual(systemFocusBeforePreparation.element, session.element),
                  sessionTargetStillValid(session) else {
                logger.error("Background exact focus refused because the non-activating target no longer owns the exact keyboard input targetPid=\(session.processIdentifier, privacy: .public)")
                return false
            }
            let appElement = AXUIElementCreateApplication(session.processIdentifier)
            let actualWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement)
            let actualElement = elementAttribute(kAXFocusedUIElementAttribute, from: appElement)
            return actualWindow.map { CFEqual($0, session.window) } == true
                && actualElement.map { CFEqual($0, session.element) } == true
                && backgroundFocusSafetyVerified(for: session)

        case .preparedTargetedInput:
            guard frontmostPIDBeforePreparation != session.processIdentifier,
                  systemFocusBeforePreparation.pid != session.processIdentifier else {
                logger.error("Background exact focus refused because the prepared target unexpectedly became frontmost or keyboard-focused targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(frontmostPIDBeforePreparation, privacy: .public) keyboardPid=\(systemFocusBeforePreparation.pid, privacy: .public)")
                return false
            }
        }

        var openedTargetedInputSession = false
        if prepareTargetedInputSession {
            guard CursorPaster.beginTargetedInputSession(pid: session.processIdentifier) else {
                logger.error("Background exact focus could not create targeted input session targetPid=\(session.processIdentifier, privacy: .public)")
                return false
            }
            openedTargetedInputSession = true
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        // The activation-state events settle asynchronously. Ethan can click or
        // activate the target during that window; re-sample immediately before the
        // first AX setter so we never rewrite a now-live foreground/keyboard target
        // and merely discover the theft afterward.
        let frontmostPIDBeforeSetters = NSWorkspace.shared.frontmostApplication?
            .processIdentifier ?? -1
        let systemFocusBeforeSetters = systemFocusedElement()
        guard let verifiedSystemFocusBeforeSetters = systemFocusBeforeSetters,
              frontmostPIDBeforeSetters != session.processIdentifier,
              verifiedSystemFocusBeforeSetters.pid != session.processIdentifier else {
            logger.notice("Background exact focus aborted because the target became frontmost or keyboard-focused during settlement targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(frontmostPIDBeforeSetters, privacy: .public) keyboardPid=\(systemFocusBeforeSetters?.pid ?? -1, privacy: .public)")
            if openedTargetedInputSession,
               frontmostPIDBeforeSetters != session.processIdentifier,
               systemFocusBeforeSetters?.pid != session.processIdentifier {
                CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
            }
            return false
        }
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
        let frontmostPIDAfterPreparation = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let systemFocusAfterPreparation = systemFocusedElement()
        let stayedInBackground = systemFocusAfterPreparation.map {
            focusTransitionWasSafe(
                from: systemFocusBeforePreparation,
                to: $0,
                session: session
            )
        } ?? false
        let currentBoundarySafe = backgroundFocusSafetyVerified(for: session)
        // Setter/action return codes are diagnostics, not proof. Electron has
        // returned success while ignoring events, and some apps report an unsupported
        // redundant setter after accepting the essential focus change. The verified
        // live internal window + element and unchanged macOS frontmost PID are the
        // load-bearing conditions.
        let verified = actualWindow.map { CFEqual($0, session.window) } == true
            && actualElement.map { CFEqual($0, session.element) } == true
            && stayedInBackground
            && currentBoundarySafe

        if !verified {
            logger.error("Background exact focus verification failed targetPid=\(session.processIdentifier, privacy: .public) resolution=\(session.resolution.rawValue, privacy: .public) expectedWindowHash=\(CFHash(session.window), privacy: .public) actualWindowHash=\(actualWindow.map { String(CFHash($0)) } ?? "nil", privacy: .public) expectedElementHash=\(CFHash(session.element), privacy: .public) actualElementHash=\(actualElement.map { String(CFHash($0)) } ?? "nil", privacy: .public) mainAX=\(mainResult.rawValue, privacy: .public) windowAX=\(windowResult.rawValue, privacy: .public) windowFocusedAX=\(windowFocusedResult.rawValue, privacy: .public) raiseAX=\(raiseResult.rawValue, privacy: .public) elementAX=\(elementResult.rawValue, privacy: .public) elementFocusedAX=\(elementFocusedResult.rawValue, privacy: .public) startFrontmostPid=\(session.frontmostPIDAtStart, privacy: .public) beforeFrontmostPid=\(frontmostPIDBeforePreparation, privacy: .public) actualFrontmostPid=\(frontmostPIDAfterPreparation, privacy: .public)")
            if openedTargetedInputSession {
                CursorPaster.endTargetedInputSession(pid: session.processIdentifier)
            }
        }
        return verified
    }

    private func sessionTargetStillValid(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        let current: AXUIElement?
        switch session.resolution {
        case .strictFingerprint:
            current = resolvedExactElement(for: session.target)
        case .retainedFocusedElement:
            guard Self.allowsRetainedFocusedElementFallback(
                bundleIdentifier: session.bundleIdentifier
            ) else { return false }
            current = retainedInternallyFocusedElement(for: session.target)
        case .applicationFocusedElement:
            guard !session.target.hasExactInput else { return false }
            current = applicationInternallyFocusedElement(for: session.target)
        }
        return current.map { CFEqual($0, session.element) } == true
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

    /// Route by exact editor identity, not only application PID. This prevents a
    /// latched input A from stealing focus when Ethan is already typing in input B of
    /// the same app at delivery time.
    func targetIsCurrentKeyboardInput(_ target: Target) -> Bool {
        guard target.hasExactInput,
              let resolved = resolvedExactElement(for: target),
              let focused = systemFocusedElement(),
              focused.pid == target.pid else {
            return false
        }
        return CFEqual(focused.element, resolved)
    }

    /// Recheck the foreground destination immediately before every global keyboard
    /// action. A PID-only check is insufficient when Ethan clicks another editor in
    /// the same app during the paste delay. Recording-start application fallbacks
    /// intentionally mean the app's current editable input, but exact targets must
    /// still resolve to the identical saved element.
    func foregroundTargetStillOwnsKeyboardInput(
        _ target: Target,
        allowApplicationFallback: Bool
    ) -> Bool {
        guard !target.app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let focused = systemFocusedElement(),
              focused.pid == target.pid else {
            return false
        }
        if target.hasExactInput {
            guard let resolved = resolvedExactElement(for: target) else { return false }
            return CFEqual(focused.element, resolved)
        }
        guard allowApplicationFallback else { return false }
        let role = stringAttribute(kAXRoleAttribute, from: focused.element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused.element)
        return isEditableInput(role: role, subrole: subrole)
    }

    /// PID-targeted Unicode is routed to the target process's internally focused
    /// editor. Verify that exact editor before each chunk so a concurrent tab/input
    /// change cannot redirect the remainder of a long transcript.
    func backgroundKeyboardEventTargetIsVerified(
        for session: BackgroundDeliverySession
    ) -> Bool {
        guard session.allowsTargetedKeyboardEvents,
              backgroundFocusSafetyVerified(for: session),
              sessionTargetStillValid(session) else {
            return false
        }
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        guard let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        ),
        let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ) else {
            return false
        }
        return CFEqual(focusedWindow, session.window)
            && CFEqual(focusedElement, session.element)
    }

    /// Cheap per-chunk boundary for long targeted-Unicode delivery. The full target
    /// resolver walks document context and remains mandatory before, periodically
    /// during, and after typing; doing that tree walk every 20 UTF-16 units can block
    /// MainActor for seconds. Between those checkpoints, prove only the live process,
    /// exact internal window/editor, and non-activation boundary so focus changes are
    /// still caught before the next chunk.
    func backgroundKeyboardEventFastBoundaryMatches(
        for session: BackgroundDeliverySession
    ) -> Bool {
        guard session.allowsTargetedKeyboardEvents,
              !session.app.isTerminated,
              backgroundFocusSafetyVerified(for: session) else {
            return false
        }
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        guard let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        ),
        let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ) else {
            return false
        }
        return CFEqual(focusedWindow, session.window)
            && CFEqual(focusedElement, session.element)
    }

    private func focusTransitionWasSafe(
        from before: (element: AXUIElement, pid: pid_t),
        to after: (element: AXUIElement, pid: pid_t),
        session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> Bool {
        switch session.focusMode {
        case .preparedTargetedInput:
            return before.pid != session.processIdentifier
                && after.pid != session.processIdentifier
        case .alreadyKeyboardFocused:
            guard before.pid == session.processIdentifier,
                  CFEqual(before.element, session.element) else {
                return false
            }
            if after.pid != session.processIdentifier {
                return allowReplacementAfterSubmission
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier
                        != session.processIdentifier
            }
            return CFEqual(after.element, session.element)
                || (allowReplacementAfterSubmission
                    && postSubmissionReplacementMatches(
                        after.element,
                        session: session
                    ))
        case .directExactElement:
            let beforeIsTarget = before.pid == session.processIdentifier
                && backgroundElementMatchesSession(before.element, session: session)
            let afterIsTarget = after.pid == session.processIdentifier
                && backgroundElementMatchesSession(after.element, session: session)
            guard !beforeIsTarget, !afterIsTarget else { return false }

            // When Ethan is in another editor of the same frontmost app, a semantic
            // action must leave that exact editor alone. Cross-app changes are allowed
            // because they can be Ethan's concurrent input and are not target focus.
            if before.pid == session.processIdentifier,
               after.pid == session.processIdentifier {
                return CFEqual(before.element, after.element)
            }
            return after.pid != session.processIdentifier
        }
    }

    static func allowsRetainedFocusedElementFallback(
        bundleIdentifier: String?
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return retainedFocusedElementBundleIdentifiers.contains(bundleIdentifier)
    }

    static func allowsInternalFocusedCaptureFallback(
        bundleIdentifier: String?
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        return captureInternalFocusFallbackBundleIdentifiers.contains(bundleIdentifier)
    }

    static func supportsSemanticSend(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return semanticSendBundleIdentifiers.contains(bundleIdentifier)
    }

    static func allowsRetainedSemanticSend(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return retainedSemanticSendBundleIdentifiers.contains(bundleIdentifier)
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

    /// Telegram can retain a live editor wrapper while hiding its window tree. A
    /// retained wrapper alone cannot identify the chat because Telegram may reuse it
    /// after a chat switch. Require independently readable matching context as well;
    /// if the context is hidden, fail closed rather than sending to a guessed chat.
    private func retainedInternallyFocusedElement(for target: Target) -> AXUIElement? {
        guard Self.allowsRetainedFocusedElementFallback(
                bundleIdentifier: target.bundleIdentifier
              ),
              let element = target.element,
              let window = target.window,
              let identity = target.identity else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(target.pid)
        let internalElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        )
        let internalWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        )
        let internalFocusMatches = internalElement.map { CFEqual($0, element) } == true
            && internalWindow.map { CFEqual($0, window) } == true
        let structureMatches = exactStructureMatches(
            element,
            identity: identity,
            in: window,
            isSameRetainedWrapper: true
        )
        let currentContext = contextAnchors(
            in: window,
            region: identity.contextRegion,
            excluding: nil
        )
        let allowed = Self.retainedFocusedElementFallbackAllowed(
            capturedContextAnchors: identity.contextAnchors,
            currentContextAnchors: currentContext,
            internalFocusMatches: internalFocusMatches,
            structureMatches: structureMatches
        )
        guard allowed else {
            logger.notice("Retained background element fallback rejected pid=\(target.pid, privacy: .public) capturedAnchors=\(identity.contextAnchors.count, privacy: .public) currentAnchors=\(currentContext.count, privacy: .public) internalFocusMatches=\(internalFocusMatches, privacy: .public) structureMatches=\(structureMatches, privacy: .public)")
            return nil
        }

        logger.notice("Using retained internally focused background element with matching readable context pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
        return element
    }

    static func retainedFocusedElementFallbackAllowed(
        capturedContextAnchors: [String],
        currentContextAnchors: [String],
        internalFocusMatches: Bool,
        structureMatches: Bool
    ) -> Bool {
        !capturedContextAnchors.isEmpty
            && !currentContextAnchors.isEmpty
            && contextFingerprintMatches(
                captured: capturedContextAnchors,
                current: currentContextAnchors
            )
            && internalFocusMatches
            && structureMatches
    }

    private func applicationInternallyFocusedElement(for target: Target) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(target.pid)
        guard let element = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ) else {
            return nil
        }
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        guard isEditableInput(role: role, subrole: subrole),
              internallyFocusedWindow(for: target) != nil else {
            return nil
        }
        logger.notice("Using saved application's internally focused editable element for non-activating recording-start fallback pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) role=\(role ?? "nil", privacy: .public)")
        return element
    }

    private func internallyFocusedWindow(for target: Target) -> AXUIElement? {
        elementAttribute(
            kAXFocusedWindowAttribute,
            from: AXUIElementCreateApplication(target.pid)
        )
    }

    private func liveBackgroundInput(
        for session: BackgroundDeliverySession,
        allowReplacementAfterSubmission: Bool = false
    ) -> AXUIElement? {
        if session.focusMode == .directExactElement {
            guard let exact = resolvedExactElement(for: session.target),
                  backgroundElementMatchesSession(exact, session: session) else {
                return nil
            }
            return exact
        }

        if session.focusMode == .alreadyKeyboardFocused {
            guard let focused = systemFocusedElement(),
                  focused.pid == session.processIdentifier else {
                return nil
            }
            if CFEqual(focused.element, session.element),
               sessionTargetStillValid(session) {
                return session.element
            }
            guard allowReplacementAfterSubmission,
                  postSubmissionReplacementMatches(
                    focused.element,
                    session: session
                  ) else {
                return nil
            }
            return focused.element
        }

        // Every pre-action read/mutation must re-resolve the exact saved target.
        // Telegram can reuse one editor wrapper after a chat switch, so matching only
        // the app's internally focused element/window is not enough.
        if !allowReplacementAfterSubmission,
           !sessionTargetStillValid(session) {
            return nil
        }

        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        guard let focusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ),
        let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        ),
        CFEqual(focusedWindow, session.window) else {
            return nil
        }

        if CFEqual(focusedElement, session.element),
           backgroundElementMatchesSession(session.element, session: session) {
            return session.element
        }

        // A successful send can replace an Electron/Chromium text-area wrapper. If
        // the app now exposes one internally focused replacement in the same exact
        // window, with the same role/subrole and near-identical frame, use it only for
        // value verification. Never search an unrelated window or arbitrary editor.
        guard allowReplacementAfterSubmission,
              backgroundElementMatchesSession(focusedElement, session: session) else {
            return nil
        }
        return focusedElement
    }

    private func backgroundElementMatchesSession(
        _ element: AXUIElement,
        session: BackgroundDeliverySession
    ) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == session.processIdentifier,
              stringAttribute(kAXRoleAttribute, from: element) == session.inputRole,
              stringAttribute(kAXSubroleAttribute, from: element) == session.inputSubrole else {
            return false
        }
        return Self.elementGeometryMatches(
            isSameRetainedWrapper: CFEqual(element, session.element),
            expectedFrame: session.inputFrame,
            currentFrame: frame(of: element)
        )
    }

    /// Electron can replace a composer wrapper only after submission. Accept the
    /// replacement for post-action verification when it is still the internally
    /// focused element in the same saved window and retains the saved role, subrole,
    /// and geometry. Routing before insertion or auto-send never uses this allowance.
    private func postSubmissionReplacementMatches(
        _ element: AXUIElement,
        session: BackgroundDeliverySession
    ) -> Bool {
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        guard let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        ),
        CFEqual(focusedWindow, session.window),
        let internallyFocusedElement = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ),
        CFEqual(internallyFocusedElement, element) else {
            return false
        }
        return backgroundElementMatchesSession(element, session: session)
    }

    private func exactStructureMatches(
        _ element: AXUIElement,
        identity: ExactInputIdentity,
        in window: AXUIElement,
        isSameRetainedWrapper: Bool
    ) -> Bool {
        guard stringAttribute(kAXRoleAttribute, from: element) == identity.role,
              stringAttribute(kAXSubroleAttribute, from: element) == identity.subrole else {
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
        if !Self.elementGeometryMatches(
            isSameRetainedWrapper: isSameRetainedWrapper,
            expectedFrame: identity.relativeFrame,
            currentFrame: relativeFrame(of: element, in: window)
        ) {
            return false
        }
        return isEditableInput(
            role: identity.role,
            subrole: identity.subrole
        )
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.origin.x - rhs.origin.x)
            + abs(lhs.origin.y - rhs.origin.y)
            + abs(lhs.size.width - rhs.size.width)
            + abs(lhs.size.height - rhs.size.height)
    }

    /// A retained AX wrapper is the captured object, not a geometry search result. Its
    /// role/window/identifier/context checks still have to pass, but a multiline
    /// composer may legitimately grow as text wraps. Replacement wrappers and stale-
    /// wrapper candidate recovery keep the strict 24-point geometry boundary.
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

    private func resolvedExactElement(for target: Target) -> AXUIElement? {
        let savedWindow = liveWindow(for: target, resolvedElement: nil)
        let directContextMatches = target.identity.map { identity in
            let currentContext = savedWindow.map {
                contextAnchors(
                    in: $0,
                    region: identity.contextRegion,
                    excluding: nil
                )
            } ?? []
            return Self.directCapturedElementContextAllowed(
                bundleIdentifier: target.bundleIdentifier,
                hasStableIdentifier: identity.identifier != nil
                    || identity.domIdentifier != nil,
                capturedContextAnchors: identity.contextAnchors,
                currentContextAnchors: currentContext
            )
        } ?? true

        if let element = target.element,
           let identity = target.identity,
           let savedWindow,
           directContextMatches,
           let elementWindow = owningWindow(for: element),
           CFEqual(elementWindow, savedWindow),
           exactStructureMatches(
            element,
            identity: identity,
            in: savedWindow,
            isSameRetainedWrapper: true
           ) {
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
        in window: AXUIElement,
        bundleIdentifier: String?
    ) -> Bool {
        if identity.contextAnchors.isEmpty {
            if let bundleIdentifier,
               Self.exactWrapperRequiresReadableContextBundleIdentifiers.contains(
                   bundleIdentifier
               ) {
                return false
            }
            if let bundleIdentifier,
               Self.exactWrapperRequiresIdentityOrContextBundleIdentifiers.contains(
                   bundleIdentifier
               ) {
                return identity.identifier != nil || identity.domIdentifier != nil
            }
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

    static func directCapturedElementContextAllowed(
        bundleIdentifier: String?,
        hasStableIdentifier: Bool = false,
        capturedContextAnchors: [String],
        currentContextAnchors: [String]
    ) -> Bool {
        if capturedContextAnchors.isEmpty {
            guard let bundleIdentifier else { return true }
            if exactWrapperRequiresReadableContextBundleIdentifiers.contains(
                bundleIdentifier
            ) {
                return false
            }
            if exactWrapperRequiresIdentityOrContextBundleIdentifiers.contains(
                bundleIdentifier
            ) {
                // Electron/Chromium and Notion can recycle the same direct AX
                // wrapper after a tab/task/card switch. With no readable document
                // fingerprint, only a stable AX/DOM identifier may retain it.
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
        // Two shared labels are not enough to identify a task, browser tab, Notion
        // card, or chat when a renderer reuses the same composer wrapper. Require the
        // whole fingerprint for small contexts and a strong majority for larger ones;
        // appended chat content remains compatible because captured anchors may be a
        // subset of the current context.
        let requiredMatches = captured.count <= 3
            ? captured.count
            : max(3, Int(ceil(Double(captured.count) * 0.75)))
        return matchCount >= requiredMatches
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

    private func numberAttribute(_ attribute: String, from element: AXUIElement) -> NSNumber? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? NSNumber
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else {
            return []
        }
        return names as? [String] ?? []
    }

    private func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    /// Resolve one explicitly labelled Send control from the *nearest* shared composer
    /// container. Never treat an unlabelled square as Send: in OpenAI surfaces the same
    /// geometry can become an enabled Stop control while an agent is running.
    private func nearbySubmitButtonCandidate(
        element: AXUIElement,
        pid: pid_t,
        bundleIdentifier: String?,
        requireEnabled: Bool = true
    ) -> NearbySubmitButtonCandidate? {
        guard let editorFrame = frame(of: element) else { return nil }

        var ancestor = elementAttribute(kAXParentAttribute, from: element)
        for _ in 0..<5 {
            guard let container = ancestor else { break }
            ancestor = elementAttribute(kAXParentAttribute, from: container)
            if let containerFrame = frame(of: container) {
                guard containerFrame.intersects(editorFrame),
                      containerFrame.width <= editorFrame.width + 240,
                      containerFrame.height <= editorFrame.height + 240 else {
                    continue
                }
            }

            var candidatesByHash: [CFHashCode: NearbySubmitButtonCandidate] = [:]
            for candidateElement in descendants(of: container, maximumDepth: 4) {
                let enabled = boolAttribute(kAXEnabledAttribute, from: candidateElement)
                guard !CFEqual(candidateElement, element),
                      stringAttribute(kAXRoleAttribute, from: candidateElement) == kAXButtonRole,
                      (!requireEnabled || enabled != false),
                      let candidateFrame = frame(of: candidateElement),
                      candidateFrame.width >= 14,
                      candidateFrame.width <= 96,
                      candidateFrame.height >= 14,
                      candidateFrame.height <= 96 else {
                    continue
                }

                let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)
                let expandedEditor = editorFrame.insetBy(dx: -100, dy: -100)
                guard expandedEditor.contains(center) else { continue }

                let label = submitLabel(for: candidateElement)
                let rightEdgeDistance = abs(center.x - editorFrame.maxX)
                let verticalDistance = abs(center.y - editorFrame.maxY)
                guard Self.isProvenSemanticSendLabel(label) else {
                    continue
                }

                let score = rightEdgeDistance + verticalDistance
                let candidate = NearbySubmitButtonCandidate(
                    element: candidateElement,
                    label: label,
                    score: score
                )
                let hash = CFHash(candidateElement)
                if candidate.score < (candidatesByHash[hash]?.score
                    ?? CGFloat.greatestFiniteMagnitude) {
                    candidatesByHash[hash] = candidate
                }
            }

            let ranked = candidatesByHash.values.sorted { $0.score < $1.score }
            if ranked.count == 1, let candidate = ranked.first {
                logger.info("Resolved explicitly labelled Send button in nearest composer container pid=\(pid, privacy: .public) label=\(candidate.label ?? "missing", privacy: .public)")
                return candidate
            }
            if ranked.count > 1 {
                logger.notice("Nearest composer container had ambiguous Send buttons pid=\(pid, privacy: .public) candidates=\(ranked.count, privacy: .public)")
                return nil
            }
        }

        return nil
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

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func appleScriptLiteral(_ value: String) -> String {
        var expression: [String] = []
        var segment = ""

        func flushSegment() {
            guard !segment.isEmpty else { return }
            let escaped = segment
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            expression.append("\"\(escaped)\"")
            segment = ""
        }

        // AppleScript does not reliably interpret Swift-style \n/\r escapes inside
        // string literals. Build an expression with explicit character values so a
        // multiline transcript cannot corrupt or inject into the native terminal
        // script; quotes and backslashes remain data inside quoted segments.
        for character in value {
            switch character {
            case "\n":
                flushSegment()
                expression.append("(ASCII character 10)")
            case "\r":
                flushSegment()
                expression.append("(ASCII character 13)")
            case "\t":
                flushSegment()
                expression.append("(ASCII character 9)")
            default:
                segment.append(character)
            }
        }
        flushSegment()
        return expression.isEmpty ? "\"\"" : expression.joined(separator: " & ")
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
