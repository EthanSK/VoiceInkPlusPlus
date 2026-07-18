import Foundation
import AppKit
import ApplicationServices
import os

@MainActor
final class FocusLockService: ObservableObject {
    /// Terminal and iTerm reuse Accessibility editor wrappers across tabs and panes.
    /// Their native window plus TTY/session pair is therefore the only authority for
    /// later text delivery; window titles and whichever AX input is focused at delivery
    /// are intentionally not part of this identity.
    fileprivate enum TerminalAutomationTarget {
        case appleTerminal(windowID: Int, tty: String)
        case iTerm(windowID: Int, sessionID: String)
    }

    struct TerminalCaptureScriptResult: Equatable {
        let windowID: Int
        let sessionIdentity: String
        let windowSessionCount: Int
        let contents: String
    }

    struct TerminalNativeScriptResult: Equatable {
        let windowID: Int
        let sessionIdentity: String
        let previousContents: String
        let currentContents: String
    }

    enum TerminalTextDeliveryResult: Equatable {
        case issued(previousContents: String, currentContents: String)
        case unavailable
        case failed(String)
        case focusSafetyViolation
    }

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

    enum ApplicationFallbackScopeKind: Equatable {
        case selectedTask
        case floatingQuickComposer
        case windowMainComposer
    }

    fileprivate enum ApplicationFallbackValidationPhase: Equatable {
        case captureStrict
        case promotedStableSelection
    }

    /// A no-caret recording start must still identify the selected task or a genuinely
    /// separate floating panel at the decision moment. An already-focused, semantically
    /// proven main composer may additionally use a task-specific UUID-bearing window
    /// document together with its exact editor wrapper. A title, window identifier, or generic
    /// window wrapper is never enough: different tasks can share titles and Electron
    /// reuses one window while Codex/ChatGPT switches tasks. Retaining each scope gives
    /// the resolver a cheap capture-boundary check.
    fileprivate struct ApplicationFallbackScopeIdentity {
        let kind: ApplicationFallbackScopeKind
        /// The installed app artifact. This remains the authority for audited
        /// irreversible actions such as an unlabelled Send button.
        let surface: SemanticSendSurface
        /// The product semantics that own a selected task list. ChatGPT.app can host
        /// a Codex composer under a `Tasks` container, so selected-scope capture and
        /// every later rescan must not blindly reuse the host's chat/history tokens.
        let scopeSurface: SemanticSendSurface
        let element: AXUIElement
        let role: String?
        let subrole: String?
        let identifier: String?
        let domIdentifier: String?
        var stableTaskKey: String?
        let label: String?
        let containerDescriptor: String?
        let relativeFrame: CGRect?
        let ancestorPath: [String]
    }

    private struct SelectedTaskScopeScanResult {
        let scopes: [ApplicationFallbackScopeIdentity]
        let completed: Bool
        let visitedCount: Int
    }

    /// Cheap capture-time identity for the recordingStart application fallback. This
    /// is deliberately separate from `ExactInputIdentity`: when no caret exists there
    /// is no editor to fingerprint yet, but a real task/panel scope must stay selected
    /// while the post-microphone resolver freezes one exact composer.
    fileprivate struct ApplicationFallbackIdentity {
        let capturedAtUptime: TimeInterval
        let windowTitle: String?
        let windowDocument: String?
        let windowIdentifier: String?
        let scopes: [ApplicationFallbackScopeIdentity]
        let validationPhase: ApplicationFallbackValidationPhase
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
        fileprivate let applicationFallbackIdentity: ApplicationFallbackIdentity?
        fileprivate let app: NSRunningApplication
        fileprivate let pid: pid_t
        fileprivate let terminalAutomationTarget: TerminalAutomationTarget?
        fileprivate let captureID: UUID
        fileprivate let capturedAtUptime: TimeInterval
        fileprivate let captureFocusedElement: AXUIElement?
        let bundleIdentifier: String?
        let displayInfo: DisplayInfo
        var processIdentifier: pid_t { pid }
        /// The captured process object is part of the physical input decision. Mode
        /// resolution must use this exact launch instance rather than looking up the
        /// PID later: a terminated target must fail closed, and a recycled PID must
        /// never inherit the newly focused application's Mode.
        var runningApplication: NSRunningApplication { app }
        var applicationBundleName: String? { app.bundleURL?.lastPathComponent }
        /// A retained system-focused wrapper is a foreground-only capability. A large
        /// Electron history can exhaust the bounded identity scan even though macOS
        /// gave us the real editor. Keep that wrapper for the zero-focus-mutation path,
        /// but never re-resolve it or use it after keyboard focus moves.
        var hasForegroundInput: Bool {
            element != nil && window != nil
        }

        // Background delivery remains stricter: it needs both the retained editor and
        // a complete identity that can safely resolve the same input later.
        var hasExactInput: Bool {
            FocusLockService.exactInputCaptureIsUsable(
                hasElement: hasForegroundInput,
                hasIdentity: identity != nil
            )
        }
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
        let labelAttribute: String
        let usesVersionedUnlabelledOpenAIContract: Bool
        let score: CGFloat
        let ancestorIndex: Int
        let discoveredDepth: Int
        let surface: SemanticSendSurface
        let enabled: Bool?
    }

    private enum NearbySubmitButtonLookup {
        case ready(NearbySubmitButtonCandidate)
        case disabled(NearbySubmitButtonCandidate)
        case unavailable
        case ambiguous
    }

    enum SemanticSendReadinessObservation: Equatable {
        case unavailable
        case disabled
        case ready
        case ambiguous
        case cancelledOrBoundaryLost
    }

    enum SemanticSendReadinessDecision: Equatable {
        case wait
        case press
        case stop
    }

    static func semanticSendReadinessDecision(
        for observation: SemanticSendReadinessObservation,
        waitForUnavailable: Bool = true
    ) -> SemanticSendReadinessDecision {
        switch observation {
        case .unavailable:
            return waitForUnavailable ? .wait : .stop
        case .disabled:
            return .wait
        case .ready:
            return .press
        case .ambiguous, .cancelledOrBoundaryLost:
            return .stop
        }
    }

    private final class BoundedTraversalState {
        var remainingNodeBudget: Int
        var visitedNodeHashes = Set<CFHashCode>()

        init(nodeBudget: Int) {
            remainingNodeBudget = nodeBudget
        }
    }

    private enum BoundedTraversalCompletion: Equatable {
        case completed
        case exhausted
        case cancelled
        case boundaryChanged
        case stoppedByVisitor
    }

    private struct BoundedTraversalResult {
        let visitedCount: Int
        let completion: BoundedTraversalCompletion
    }

    private struct ContextFingerprintResult {
        let selection: ContextAnchorSelection
        let completion: BoundedTraversalCompletion

        var completed: Bool { completion == .completed }
    }

    enum SemanticSendSurface: String, Equatable {
        case openAIChatGPT
        case openAICodex
        case claudeDesktop
        case telegramForegroundOnly
    }

    /// The installed host artifact and the composer product are separate facts.
    /// ChatGPT.app now embeds both ChatGPT and Codex task surfaces, even though the
    /// process still reports the shared `com.openai.codex` bundle identifier. Keep
    /// this product evidence separate from `SemanticSendSurface`, whose host identity
    /// remains the authority for version-audited irreversible Send actions.
    enum OpenAIComposerProduct: String, Equatable {
        case chatGPT
        case codex
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
    private static let backgroundSemanticSendBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "com.anthropic.claudefordesktop"
    ]
    private static let recordingStartMainComposerBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat",
        "com.anthropic.claudefordesktop"
    ]
    private static let nativeTerminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]
    private static let openAIChatGPTApplicationName = "ChatGPT.app"
    private static let openAICodexApplicationName = "Codex.app"
    private static let telegramGenericContextLabels: Set<String> = [
        "attach", "cancel", "close", "edit", "emoji", "message", "more",
        "mute", "online", "search", "send", "telegram", "unmute",
        "write a message"
    ]
    private static let telegramVolatileContextPrefixes = [
        "last seen", "typing", "write a message"
    ]

    private init() {}

    /// Capture the exact editable input at one destination decision. Application
    /// fallback is allowed only for recordingStart (Next while recording), where an
    /// Electron/Chromium shortcut can temporarily hide its editor. That fallback is
    /// promoted once, immediately after microphone start, against capture-time
    /// app/window/task identity; delivery never rediscovers a later composer. Primary
    /// normal stop and second chance must keep the default exact-input-only behavior.
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
            if allowApplicationFallback,
               let app = recordingStartApplicationWithoutFocusedInput() {
                logger.notice("Captured recording-start main-composer application fallback without a focused AX element pid=\(app.processIdentifier, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) focusedAXError=\(focusedResult.rawValue, privacy: .public)")
                return applicationFallbackTarget(
                    for: app,
                    sourceElement: nil
                )
            }
            logger.error("Focused input capture failed with AX error \(focusedResult.rawValue)")
            return nil
        }

        let decisionFocusedElement = focusedValue as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(decisionFocusedElement, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated else {
            if allowApplicationFallback,
               let fallbackApp = recordingStartApplicationWithoutFocusedInput() {
                logger.notice("Captured recording-start main-composer application fallback after the focused AX wrapper could not identify a usable external app pid=\(fallbackApp.processIdentifier, privacy: .public) bundle=\(fallbackApp.bundleIdentifier ?? "nil", privacy: .public)")
                return applicationFallbackTarget(
                    for: fallbackApp,
                    sourceElement: nil
                )
            }
            logger.error("Focused input capture could not resolve a live owning application")
            return nil
        }

        var element = decisionFocusedElement
        var role = stringAttribute(kAXRoleAttribute, from: element)
        var subrole = stringAttribute(kAXSubroleAttribute, from: element)
        var isExactEditableInput = isEditableInput(role: role, subrole: subrole)
        var inferredGenericFocusVerified: Bool?
        // There is no universal Accessibility "main input" property. For apps without
        // an audited task/composer contract, make one conservative foreground-only
        // attempt: if the unchanged active window exposes exactly one visible, enabled,
        // focusable AXTextArea and the original non-editable control still owns focus,
        // focus that field in place. Ambiguous or incomplete scans do nothing. Known
        // OpenAI/Claude surfaces continue through their stronger task-scoped async path.
        if allowApplicationFallback,
           !isExactEditableInput,
           !Self.supportsRecordingStartMainComposer(
                bundleIdentifier: app.bundleIdentifier
           ),
           let promoted = identifyAndFocusUniqueGenericMainInputIfSafe(
                from: decisionFocusedElement,
                in: app
           ) {
            element = promoted.element
            inferredGenericFocusVerified = promoted.focusVerified
            role = stringAttribute(kAXRoleAttribute, from: promoted.element)
            subrole = stringAttribute(kAXSubroleAttribute, from: promoted.element)
            isExactEditableInput = isEditableInput(
                role: role,
                subrole: subrole
            )
            logger.info("Identified the unique generic main input inside the unchanged active app pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) elementHash=\(CFHash(promoted.element), privacy: .public) focusVerified=\(promoted.focusVerified, privacy: .public)")
        }
        let canUseApplicationFallback = allowApplicationFallback
            && (isApplicationFallbackContainer(role: role)
                || Self.supportsRecordingStartMainComposer(
                    bundleIdentifier: app.bundleIdentifier
                ))
        guard isExactEditableInput || canUseApplicationFallback else {
            logger.error("Focused input capture rejected non-editable element pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
            return nil
        }

        if isExactEditableInput {
            logger.info("Captured editable input pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) role=\(role ?? "nil", privacy: .public) subrole=\(subrole ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public)")
        } else {
            // Electron/Chromium can report AXWebArea, a toolbar button, or no focused
            // editor while the global shortcut is down. For recordingStart only, save
            // the proven app/window so the one capture-bound promotion immediately
            // after microphone start can freeze its main composer. Delivery never
            // rediscovers it; primary normal stop and second chance never use fallback.
            logger.notice("Captured recording-start application fallback pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public) rejectedRole=\(role ?? "nil", privacy: .public) rejectedSubrole=\(subrole ?? "nil", privacy: .public)")
        }

        // NSWorkspace activation notifications do not fire for non-activating
        // panels such as ChatGPT's floating input. The AX capture above knows the
        // true keyboard-focused owner, so feed it to the recorder's current-app
        // indicator without changing any per-session locked destination semantics.
        ActiveWindowService.shared.updateCurrentApplicationForDisplay(app)

        // Telegram can expose the exact focused AXTextArea while omitting its AXWindow
        // attribute. Use the owning app's verified focused window at the same capture
        // instant so readable chat/header context is preserved. Do not accept the live
        // wrapper alone: Telegram reuses it across chats. This exception must remain
        // inside `owningWindow`'s explicit Telegram allowlist; applying the same fallback
        // generically can associate an orphaned editor with an unrelated focused window.
        let owningWindow = owningWindow(
            for: element,
            allowFocusedApplicationFallback: Self.isTelegram(
                bundleIdentifier: app.bundleIdentifier
            )
        )
        // Streaming/history updates beside an OpenAI or Claude composer may invalidate
        // ordinary context anchors while the same exact editor still owns focus. Only
        // a semantically proven main composer may capture the bounded selected-task or
        // Option-Space panel scope that tolerates that drift. Search/rename/feedback
        // fields keep the stricter ordinary identity path, and Telegram never uses it.
        let exactApplicationScope = isExactEditableInput
            ? exactMainComposerApplicationScope(
                for: element,
                in: owningWindow,
                app: app
              )
            : nil
        let identity = isExactEditableInput ? owningWindow.flatMap {
            exactInputIdentity(
                for: element,
                in: $0,
                bundleIdentifier: app.bundleIdentifier,
                hasHardenedApplicationScope: exactApplicationScope != nil
            )
        } : nil
        // Non-editable recording-start fallbacks deliberately stay cheap here: they
        // save only the proven app/window scope and promote one exact composer after
        // microphone start. Exact inputs retain that scope only as the narrow focused-
        // wrapper drift guard described above.
        let fallbackIdentity = isExactEditableInput
            ? exactApplicationScope
            : applicationFallbackIdentity(
                for: owningWindow,
                sourceElement: element,
                bundleIdentifier: app.bundleIdentifier,
                applicationBundleName: app.bundleURL?.lastPathComponent
            )
        if !isExactEditableInput,
           !recordingStartNonFrontmostFallbackIsAllowed(
                app: app,
                window: owningWindow
           ) {
            logger.notice("Recording-start no-caret fallback rejected because the AX-focused app was not frontmost and no proven ChatGPT floating panel owned the decision pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        let inferredGenericRetainedTierIsUsable = inferredGenericFocusVerified.map {
            Self.inferredGenericMainInputCaptureIsUsable(
                hasExactIdentity: identity != nil,
                focusVerified: $0
            )
        } ?? true
        guard !isExactEditableInput
                || identity != nil
                || (Self.allowsRetainedForegroundOnlyInput(
                    bundleIdentifier: app.bundleIdentifier
                )
                    && owningWindow != nil
                    && inferredGenericRetainedTierIsUsable) else {
            // Telegram reuses a retained editor wrapper across chats, so wrapper focus
            // alone cannot identify the stop-time chat. Other apps may keep the exact
            // system-focused wrapper as a foreground-only capability when the bounded
            // context scan is incomplete.
            logger.notice("Exact-input capture rejected because neither a complete identity nor a safe retained-foreground tier was available pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard isExactEditableInput || fallbackIdentity != nil else {
            logger.notice("Recording-start application fallback rejected because no capture-time selected task or distinct panel could be proven pid=\(pid, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }

        return Target(
            element: isExactEditableInput ? element : nil,
            window: owningWindow,
            identity: identity,
            applicationFallbackIdentity: fallbackIdentity,
            app: app,
            pid: pid,
            terminalAutomationTarget: nil,
            captureID: UUID(),
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            captureFocusedElement: decisionFocusedElement,
            bundleIdentifier: app.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: app.localizedName ?? app.bundleIdentifier ?? String(localized: "Unknown app"),
                inputName: isExactEditableInput ? inputDisplayName(for: element) : String(localized: "application focus"),
                applicationIcon: app.icon
            )
        )
    }

    static func genericMainInputPromotionIsAllowed(
        traversalCompleted: Bool,
        candidateCount: Int,
        appIsStillFrontmost: Bool,
        sourceFocusStillMatches: Bool,
        focusedWindowStillMatches: Bool
    ) -> Bool {
        traversalCompleted
            && candidateCount == 1
            && appIsStillFrontmost
            && sourceFocusStillMatches
            && focusedWindowStillMatches
    }

    static func inferredGenericMainInputCaptureIsUsable(
        hasExactIdentity: Bool,
        focusVerified: Bool
    ) -> Bool {
        // Unlike the original AX-focused element, a discovered generic candidate is
        // only a real capability if it can be replayed exactly or the one focus setter
        // was verified. Otherwise it was never the user's input and cannot be latched.
        hasExactIdentity || focusVerified
    }

    /// Best-effort fallback for the user's broader "active app, no caret" workflow.
    /// It is intentionally narrower than app-specific composer discovery: only one
    /// large visible AXTextArea in the unchanged active window can win, the bounded
    /// scan must finish, and focus is set only inside the already-frontmost app.
    private func identifyAndFocusUniqueGenericMainInputIfSafe(
        from sourceElement: AXUIElement,
        in app: NSRunningApplication
    ) -> (element: AXUIElement, focusVerified: Bool)? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == app.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        ),
              owningWindow(
                for: sourceElement,
                allowFocusedApplicationFallback: false
              ).map({ CFEqual($0, window) }) == true,
              let windowFrame = frame(of: window),
              let focusedBefore = systemFocusedElement(),
              focusedBefore.pid == app.processIdentifier,
              CFEqual(focusedBefore.element, sourceElement) else {
            return nil
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 0.020
        let nodeBudget = 300
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0
        var visited = Set<CFHashCode>()
        var candidates: [AXUIElement] = []
        var traversalCompleted = true
        while cursor < queue.count {
            guard visited.count < nodeBudget,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                traversalCompleted = false
                break
            }
            let (candidate, depth) = queue[cursor]
            cursor += 1
            guard visited.insert(CFHash(candidate)).inserted else { continue }

            if !CFEqual(candidate, sourceElement),
               stringAttribute(kAXRoleAttribute, from: candidate)
                    == kAXTextAreaRole,
               boolAttribute(kAXEnabledAttribute, from: candidate) != false,
               boolAttribute("AXVisible", from: candidate) != false,
               let candidateFrame = frame(of: candidate),
               candidateFrame.width >= 160,
               candidateFrame.height >= 24,
               candidateFrame.intersects(windowFrame),
               owningWindow(for: candidate).map({ CFEqual($0, window) }) == true {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(
                    candidate,
                    kAXFocusedAttribute as CFString,
                    &settable
                ) == .success,
                   settable.boolValue,
                   !candidates.contains(where: { CFEqual($0, candidate) }) {
                    candidates.append(candidate)
                    if candidates.count > 1 { break }
                }
            }
            guard depth < 24 else { continue }
            for child in elementArrayAttribute(
                kAXChildrenAttribute,
                from: candidate
            ) {
                queue.append((child, depth + 1))
            }
        }
        if cursor < queue.count { traversalCompleted = false }

        let focusStillMatches = systemFocusedElement().map {
            $0.pid == app.processIdentifier
                && CFEqual($0.element, sourceElement)
        } == true
        let windowStillMatches = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        ).map({ CFEqual($0, window) }) == true
        guard Self.genericMainInputPromotionIsAllowed(
            traversalCompleted: traversalCompleted,
            candidateCount: candidates.count,
            appIsStillFrontmost:
                NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == app.processIdentifier,
            sourceFocusStillMatches: focusStillMatches,
            focusedWindowStillMatches: windowStillMatches
        ), let candidate = candidates.first else {
            return nil
        }

        // AX reads can run app code. Put the source-focus read last, immediately before
        // the one setter, and never make a compensating focus mutation: a rollback
        // cannot distinguish our caret from a newer user click onto the same composer.
        guard elementAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
              ).map({ CFEqual($0, window) }) == true,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == app.processIdentifier,
              systemFocusedElement().map({
                $0.pid == app.processIdentifier
                    && CFEqual($0.element, sourceElement)
              }) == true else {
            return nil
        }
        guard AXUIElementSetAttributeValue(
            candidate,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success else {
            // Candidate discovery is independent of this optional convenience focus.
            // The caller will retain it only if exact replay-safe identity succeeds.
            return (candidate, false)
        }
        let promotionVerified =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == app.processIdentifier
            && systemFocusedElement().map({
                $0.pid == app.processIdentifier
                    && CFEqual($0.element, candidate)
            }) == true
        return (candidate, promotionVerified)
    }

    func requiresNativeTerminalSessionBinding(for target: Target) -> Bool {
        target.bundleIdentifier.map(
            Self.nativeTerminalBundleIdentifiers.contains
        ) == true
    }

    func hasNativeTerminalAutomationTarget(for target: Target) -> Bool {
        target.terminalAutomationTarget != nil
    }

    func representsSameCaptureDecision(_ lhs: Target, _ rhs: Target) -> Bool {
        lhs.captureID == rhs.captureID
    }

    /// Deterministic, non-mutating seam for session-ordering tests. The fake wrapper is
    /// never resolved or used for delivery; it only lets tests distinguish two enriched
    /// values that belong to the same capture decision without touching a live input.
    /// Keep this internal seam available in Release test builds: the shared Xcode scheme
    /// deliberately runs unit tests with its Release configuration, where `DEBUG` is not
    /// defined even though `@testable import` is enabled for the test action.
    static func makeTestingTarget(
        captureID: UUID,
        inputName: String
    ) -> Target? {
        guard let app = NSWorkspace.shared.frontmostApplication
                ?? NSWorkspace.shared.runningApplications.first(where: {
                    !$0.isTerminated && $0.processIdentifier > 0
                }) else {
            return nil
        }
        let placeholder = AXUIElementCreateApplication(app.processIdentifier)
        return Target(
            element: placeholder,
            window: placeholder,
            identity: nil,
            applicationFallbackIdentity: nil,
            app: app,
            pid: app.processIdentifier,
            terminalAutomationTarget: nil,
            captureID: captureID,
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            captureFocusedElement: placeholder,
            bundleIdentifier: app.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: app.localizedName ?? "Test application",
                inputName: inputName,
                applicationIcon: app.icon
            )
        )
    }

    /// Enrich one already-frozen AX decision with the host-native window and
    /// TTY/session identity. This never recaptures current focus. The async Apple Event
    /// is adopted only if the selected tab/pane plus readable AX/native fingerprint
    /// still prove the same decision after the await; otherwise the unchanged target is
    /// returned and native delivery later fails closed before mutation.
    func completingTerminalAutomationTarget(for target: Target) async -> Target {
        guard target.terminalAutomationTarget == nil,
              let element = target.element,
              let window = target.window,
              requiresNativeTerminalSessionBinding(for: target),
              !Task.isCancelled else {
            return target
        }
        let automationTarget = await captureTerminalAutomationTarget(
            bundleIdentifier: target.bundleIdentifier,
            pid: target.pid,
            element: element,
            window: window
        )
        guard let automationTarget, !Task.isCancelled else { return target }
        return Target(
            element: target.element,
            window: target.window,
            identity: target.identity,
            applicationFallbackIdentity: target.applicationFallbackIdentity,
            app: target.app,
            pid: target.pid,
            terminalAutomationTarget: automationTarget,
            captureID: target.captureID,
            capturedAtUptime: target.capturedAtUptime,
            captureFocusedElement: target.captureFocusedElement,
            bundleIdentifier: target.bundleIdentifier,
            displayInfo: target.displayInfo
        )
    }

    private func captureTerminalAutomationTarget(
        bundleIdentifier: String?,
        pid: pid_t,
        element: AXUIElement,
        window: AXUIElement
    ) async -> TerminalAutomationTarget? {
        guard let bundleIdentifier,
              Self.nativeTerminalBundleIdentifiers.contains(bundleIdentifier),
              terminalDecisionBoundaryMatches(
                pid: pid,
                element: element,
                window: window
              ),
              let windowID = cgWindowIdentifier(pid: pid, window: window),
              let decisionContents = stringAttribute(
                kAXValueAttribute,
                from: element
              ) else {
            return nil
        }

        // Freeze every non-Apple-Event input before yielding. A script that merely
        // reports whichever session is selected later would bind the wrong tab if Ethan
        // moved immediately after the button press.
        let selectedScan = terminalSelectedControls(in: window)
        guard selectedScan.completed else { return nil }
        let decisionSelectedControls = selectedScan.elements
        let decisionContentAnchors = Self.terminalContentAnchors(
            decisionContents
        )
        let source: String
        switch bundleIdentifier {
        case "com.apple.Terminal":
            source = Self.terminalScriptHelpers + """

            tell application "Terminal"
                set windowMatchCount to 0
                set targetWindow to missing value
                repeat with candidateWindow in windows
                    if (id of candidateWindow as integer) is \(windowID) then
                        set windowMatchCount to windowMatchCount + 1
                        set targetWindow to contents of candidateWindow
                    end if
                end repeat
                if windowMatchCount is not 1 then error "Terminal window ID was not unique"
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
                set windowMatchCount to 0
                set targetWindow to missing value
                repeat with candidateWindow in windows
                    if (id of candidateWindow as integer) is \(windowID) then
                        set windowMatchCount to windowMatchCount + 1
                        set targetWindow to contents of candidateWindow
                    end if
                end repeat
                if windowMatchCount is not 1 then error "iTerm window ID was not unique"
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
            let output = try await BoundedAppleScriptRunner.run(
                source: source,
                timeout: 1.5
            ).stdout
            guard !Task.isCancelled,
                  let value = Self.terminalCaptureScriptResult(output) else {
                return nil
            }
            parsed = value
        } catch {
            logger.error("Terminal native identity capture failed without exposing host output category=\(String(describing: type(of: error)), privacy: .public)")
            return nil
        }

        let currentSelectedScan = terminalSelectedControls(in: window)
        let currentSelectedControls = currentSelectedScan.elements
        let selectionControlsMatch = currentSelectedScan.completed
            && decisionSelectedControls.count == currentSelectedControls.count
            && zip(decisionSelectedControls, currentSelectedControls).allSatisfy {
                CFEqual($0.0, $0.1)
            }
        guard !Task.isCancelled,
              parsed.windowID == windowID,
              Self.terminalSelectionMultiplicityIsSafe(
                selectedControlCount: decisionSelectedControls.count,
                windowSessionCount: parsed.windowSessionCount
              ),
              selectionControlsMatch,
              Self.terminalDecisionFingerprintMatches(
                captured: decisionContentAnchors,
                native: Self.terminalContentAnchors(parsed.contents),
                windowSessionCount: parsed.windowSessionCount
              ),
              terminalCapturedScopeStillMatches(
                pid: pid,
                element: element,
                window: window
              ) else {
            logger.error("Terminal native identity did not match the frozen decision boundary pid=\(pid, privacy: .public) windowID=\(windowID, privacy: .public) selectedControls=\(decisionSelectedControls.count, privacy: .public) windowSessions=\(parsed.windowSessionCount, privacy: .public)")
            return nil
        }

        switch bundleIdentifier {
        case "com.apple.Terminal":
            logger.info("Captured Terminal native destination windowID=\(windowID, privacy: .public) tty=\(parsed.sessionIdentity, privacy: .private(mask: .hash))")
            return .appleTerminal(
                windowID: windowID,
                tty: parsed.sessionIdentity
            )
        case "com.googlecode.iterm2":
            logger.info("Captured iTerm native destination windowID=\(windowID, privacy: .public) session=\(parsed.sessionIdentity, privacy: .private(mask: .hash))")
            return .iTerm(
                windowID: windowID,
                sessionID: parsed.sessionIdentity
            )
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

    static func terminalContentAnchors(_ contents: String) -> [String] {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return Array(normalized
            .split(separator: "\n")
            .map {
                $0.split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
            }
            .filter { $0.count >= 20 }
            .suffix(20))
    }

    static func terminalDecisionFingerprintMatches(
        captured: [String],
        native: [String],
        windowSessionCount: Int
    ) -> Bool {
        if windowSessionCount == 1, captured.isEmpty { return true }
        return contextFingerprintMatches(captured: captured, current: native)
    }

    static func terminalSelectionMultiplicityIsSafe(
        selectedControlCount: Int,
        windowSessionCount: Int
    ) -> Bool {
        windowSessionCount == 1 || selectedControlCount == 1
    }

    static func terminalTextIsSafeForSingleNativeOperation(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.newlines.contains(scalar)
        }
    }

    static func terminalDeliveryFocusStayedSafe(
        targetPID: pid_t,
        targetWasFrontmost: Bool,
        targetOwnedKeyboardFocus: Bool,
        currentFrontmostPID: pid_t?,
        currentKeyboardFocusPID: pid_t?
    ) -> Bool {
        (targetWasFrontmost || currentFrontmostPID != targetPID)
            && (targetOwnedKeyboardFocus || currentKeyboardFocusPID != targetPID)
    }

    /// Perform exactly one host-native mutation against the frozen session pair. The
    /// script locates that pair without selecting or activating it, writes text and the
    /// configured newline atomically, then performs bounded read-only polling. It never
    /// falls back to PID/AX insertion or retries Return.
    func performTerminalTextDelivery(
        _ text: String,
        autoSendKey: AutoSendKey,
        to target: Target
    ) async -> TerminalTextDeliveryResult {
        guard Self.terminalTextIsSafeForSingleNativeOperation(text),
              requiresNativeTerminalSessionBinding(for: target),
              let destination = target.terminalAutomationTarget,
              !target.app.isTerminated,
              let focusBefore = systemFocusedElement() else {
            return target.terminalAutomationTarget == nil
                ? .unavailable
                : .failed("terminal transcript or focus boundary was unsafe")
        }
        let frontmostPIDBefore = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        let targetWasFrontmost = frontmostPIDBefore == target.pid
        let targetOwnedKeyboardFocus = focusBefore.pid == target.pid

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
                if tabMatchCount is not 1 then error "Terminal TTY was not unique"
                set beforeContents to my voiceInkTail((contents of targetTab as text), 4096)
                do script (\(textLiteral)) in targetTab
                set afterContents to beforeContents
                repeat with pollIndex from 1 to 16
                    delay 0.05
                    set afterContents to my voiceInkTail((contents of targetTab as text), 4096)
                end repeat
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
                if sessionMatchCount is not 1 then error "iTerm session was not unique"
                set beforeContents to my voiceInkTail((contents of targetSession as text), 4096)
                write targetSession text (\(textLiteral)) newline \(newline)
                set afterContents to beforeContents
                repeat with pollIndex from 1 to 16
                    delay 0.05
                    set afterContents to my voiceInkTail((contents of targetSession as text), 4096)
                end repeat
                return my voiceInkFramedResult({(id of targetWindow as text), (id of targetSession as text)}, {beforeContents, afterContents})
            end tell
            """
        }

        let parsed: TerminalNativeScriptResult
        do {
            let output = try await BoundedAppleScriptRunner.run(
                source: source,
                timeout: 2.5
            ).stdout
            guard !Task.isCancelled,
                  let value = Self.terminalNativeScriptResult(output),
                  value.windowID == expectedWindowID,
                  value.sessionIdentity == expectedSessionIdentity else {
                return .failed("terminal host returned malformed or mismatched native identity")
            }
            parsed = value
        } catch {
            return .failed(error.localizedDescription)
        }

        let currentKeyboardPID = systemFocusedElement()?.pid
        guard Self.terminalDeliveryFocusStayedSafe(
            targetPID: target.pid,
            targetWasFrontmost: targetWasFrontmost,
            targetOwnedKeyboardFocus: targetOwnedKeyboardFocus,
            currentFrontmostPID: NSWorkspace.shared.frontmostApplication?
                .processIdentifier,
            currentKeyboardFocusPID: currentKeyboardPID
        ) else {
            return .focusSafetyViolation
        }
        return .issued(
            previousContents: parsed.previousContents,
            currentContents: parsed.currentContents
        )
    }

    private static let terminalScriptHelpers = """
    on voiceInkTail(valueText, maximumLength)
        set valueText to valueText as text
        if (count characters of valueText) is greater than maximumLength then
            set startIndex to ((count characters of valueText) - maximumLength + 1)
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

    private func terminalDecisionBoundaryMatches(
        pid: pid_t,
        element: AXUIElement,
        window: AXUIElement
    ) -> Bool {
        guard let focused = systemFocusedElement(),
              focused.pid == pid,
              CFEqual(focused.element, element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        else { return false }
        return terminalCapturedScopeStillMatches(
            pid: pid,
            element: element,
            window: window
        )
    }

    private func terminalCapturedScopeStillMatches(
        pid: pid_t,
        element: AXUIElement,
        window: AXUIElement
    ) -> Bool {
        var elementPID: pid_t = 0
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              AXUIElementGetPid(window, &windowPID) == .success,
              elementPID == pid,
              windowPID == pid,
              owningWindow(
                for: element,
                allowFocusedApplicationFallback: false
              ).map({ CFEqual($0, window) }) == true else {
            return false
        }
        return true
    }

    private func terminalSelectedControls(
        in window: AXUIElement
    ) -> (elements: [AXUIElement], completed: Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var cursor = 0
        var visited = 0
        var seen = Set<CFHashCode>()
        var selected: [AXUIElement] = []
        var truncated = false
        while cursor < queue.count,
              visited < 500,
              ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            visited += 1
            if stringAttribute(kAXRoleAttribute, from: element)
                    == kAXRadioButtonRole,
               numberAttribute(kAXValueAttribute, from: element)?.intValue == 1 {
                selected.append(element)
            }
            let descendants = traversalChildren(of: element)
            guard depth < 14 else {
                if !descendants.isEmpty { truncated = true }
                continue
            }
            let remaining = max(
                0,
                500 - visited - (queue.count - cursor)
            )
            if descendants.count > remaining { truncated = true }
            queue.append(contentsOf: descendants.prefix(remaining).map {
                ($0, depth + 1)
            })
        }
        return (
            selected,
            cursor >= queue.count && !truncated
                && ProcessInfo.processInfo.systemUptime < deadline
        )
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
        let expectedTitle = nonEmptyStringAttribute(
            kAXTitleAttribute,
            from: window
        )
        let candidates: [(id: Int, title: String?)] = windowInfo.compactMap {
            info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?
                    .int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String]
                    as? NSDictionary else {
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
                number.intValue,
                info[kCGWindowName as String] as? String
            )
        }
        if candidates.count == 1 { return candidates[0].id }
        guard let expectedTitle else { return nil }
        let titleMatches = candidates.filter { $0.title == expectedTitle }
        return titleMatches.count == 1 ? titleMatches[0].id : nil
    }

    private func recordingStartApplicationWithoutFocusedInput() -> NSRunningApplication? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApplicationValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplicationValue
        )
        var accessibilityApplication: NSRunningApplication?
        if result == .success,
           let focusedApplicationValue,
           CFGetTypeID(focusedApplicationValue) == AXUIElementGetTypeID() {
            var focusedPID: pid_t = 0
            if AXUIElementGetPid(
                focusedApplicationValue as! AXUIElement,
                &focusedPID
            ) == .success {
                accessibilityApplication = NSRunningApplication(
                    processIdentifier: focusedPID
                )
            }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = [
            accessibilityApplication,
            NSWorkspace.shared.frontmostApplication
        ].compactMap { $0 }.reduce(into: [NSRunningApplication]()) {
            result, candidate in
            if !result.contains(where: { existing in
                existing.processIdentifier == candidate.processIdentifier
            }) {
                result.append(candidate)
            }
        }
        return candidates.first { candidate in
            guard candidate.processIdentifier != ownPID,
                  !candidate.isTerminated,
                  Self.supportsRecordingStartMainComposer(
                    bundleIdentifier: candidate.bundleIdentifier
                  ) else {
                return false
            }
            let appElement = AXUIElementCreateApplication(
                candidate.processIdentifier
            )
            let window = elementAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
            )
            // A stale AX-focused OpenAI app must not prevent the real frontmost app
            // from being considered. Only a proven ChatGPT floating panel may win a
            // deliberate AX/frontmost disagreement.
            return recordingStartNonFrontmostFallbackIsAllowed(
                app: candidate,
                window: window
            )
        }
    }

    private func recordingStartNonFrontmostFallbackIsAllowed(
        app: NSRunningApplication,
        window: AXUIElement?
    ) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier
            == app.processIdentifier {
            return true
        }
        guard let window,
              let surface = Self.semanticSendSurface(
                bundleIdentifier: app.bundleIdentifier,
                applicationBundleName: app.bundleURL?.lastPathComponent
              ) else {
            return false
        }
        return Self.recordingStartFloatingPanelEvidenceMatches(
            surface: surface,
            subrole: nonEmptyStringAttribute(kAXSubroleAttribute, from: window),
            isModal: boolAttribute(kAXModalAttribute, from: window) == true
        )
    }

    private static func allowsRetainedForegroundOnlyInput(
        bundleIdentifier: String?
    ) -> Bool {
        // Telegram can reuse one AXTextArea wrapper for a different selected chat.
        // Without complete readable chat identity, even CFEqual + keyboard focus does
        // not prove that this is the chat selected at the stop decision.
        !isTelegram(bundleIdentifier: bundleIdentifier)
    }

    private func applicationFallbackTarget(
        for app: NSRunningApplication,
        sourceElement: AXUIElement?
    ) -> Target? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let window = sourceElement.flatMap {
            owningWindow(for: $0, allowFocusedApplicationFallback: false)
        }
            ?? elementAttribute(kAXFocusedWindowAttribute, from: appElement)
        guard recordingStartNonFrontmostFallbackIsAllowed(
            app: app,
            window: window
        ) else {
            logger.notice("Recording-start no-focus fallback rejected because a nonfrontmost app did not expose the proven ChatGPT floating panel pid=\(app.processIdentifier, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard let identity = applicationFallbackIdentity(
            for: window,
            sourceElement: sourceElement,
            bundleIdentifier: app.bundleIdentifier,
            applicationBundleName: app.bundleURL?.lastPathComponent
        ) else {
            logger.notice("Recording-start no-focus fallback rejected because no capture-time selected task or distinct panel could be proven pid=\(app.processIdentifier, privacy: .public) bundle=\(app.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        ActiveWindowService.shared.updateCurrentApplicationForDisplay(app)
        return Target(
            element: nil,
            window: window,
            identity: nil,
            applicationFallbackIdentity: identity,
            app: app,
            pid: app.processIdentifier,
            terminalAutomationTarget: nil,
            captureID: UUID(),
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            captureFocusedElement: sourceElement,
            bundleIdentifier: app.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: app.localizedName
                    ?? app.bundleIdentifier
                    ?? String(localized: "Unknown app"),
                inputName: String(localized: "main composer"),
                applicationIcon: app.icon
            )
        )
    }

    /// Only a proven primary chat composer may borrow the selected-task/floating-panel
    /// scope as its context-drift boundary. Merely being an editable field inside an
    /// OpenAI/Claude process is insufficient: search, feedback, rename, settings, and
    /// modal textareas must keep their ordinary exact context proof. Submission still
    /// independently requires an explicit semantic Send control at action time.
    private func exactMainComposerApplicationScope(
        for element: AXUIElement,
        in window: AXUIElement?,
        app: NSRunningApplication
    ) -> ApplicationFallbackIdentity? {
        guard let window,
              let surface = Self.semanticSendSurface(
                bundleIdentifier: app.bundleIdentifier,
                applicationBundleName: app.bundleURL?.lastPathComponent
              ),
              surface != .telegramForegroundOnly else {
            return nil
        }
        let windowIsModal = boolAttribute(kAXModalAttribute, from: window) == true
        let hasDisallowedSecondaryAncestor =
            hasDisallowedSecondaryComposerAncestor(element, stoppingAt: window)
        let composerDescription = nonEmptyStringAttribute(
            kAXDescriptionAttribute,
            from: element
        )
        let composerPlaceholder = nonEmptyStringAttribute(
            kAXPlaceholderValueAttribute,
            from: element
        )
        guard Self.exactMainComposerCaptureEvidenceMatches(
            surface: surface,
            description: composerDescription,
            placeholder: composerPlaceholder,
            windowIsModal: windowIsModal,
            hasDisallowedSecondaryAncestor: hasDisallowedSecondaryAncestor
        ) else {
            return nil
        }
        let openAIComposerProduct = Self.openAIComposerProduct(
            description: composerDescription,
            placeholder: composerPlaceholder
        )
        let composerProduct = openAIComposerProduct?.rawValue ?? "nonOpenAI"
        let composerScopeSurfaces = Self.selectedTaskScopeSurfaces(
            hostSurface: surface,
            composerProduct: openAIComposerProduct
        )
        guard composerScopeSurfaces.count == 1,
              let composerScopeSurface = composerScopeSurfaces.first else {
            return nil
        }
        logger.info("Exact main-composer semantics accepted hostSurface=\(surface.rawValue, privacy: .public) composerProduct=\(composerProduct, privacy: .public)")

        // A focused main composer already supplies the semantic input proof that a
        // no-caret fallback lacks. Prefer a strict UUID-bearing task/window identity
        // when the app exposes one: this avoids synchronously walking a long React
        // history before the recorder HUD can appear. Titles—even specific-looking
        // ones—are not unique and never qualify on their own; without a task key this
        // falls back to the selected-task scan or a foreground-only wrapper.
        if let windowIdentity = exactMainComposerWindowIdentity(
            for: window,
            surface: surface,
            scopeSurface: composerScopeSurface
        ) {
            return windowIdentity
        }

        guard let identity = applicationFallbackIdentity(
            for: window,
            sourceElement: element,
            bundleIdentifier: app.bundleIdentifier,
            applicationBundleName: app.bundleURL?.lastPathComponent,
            selectedTaskScopeSurfaces: composerScopeSurfaces,
            // One complete selected-task scope is the only safe way to let a retained
            // renderer composer survive later focus changes. Give this targeted start-
            // decision scan the same bounded budget as the no-caret path; when it wins,
            // exact-input capture skips the separate history fingerprint, so recorder
            // latency stays bounded while the common Codex enrichment path remains usable.
            scanDeadlineInterval: 0.060,
            scanNodeBudget: 900
        ), identity.scopes.count == 1,
           identity.scopes.allSatisfy({
               Self.recordingStartComposerScopeEvidenceMatches(
                   scopeKind: $0.kind,
                   hostSurface: surface,
                   scopeSurface: $0.scopeSurface,
                   description: composerDescription,
                   placeholder: composerPlaceholder
               )
           }),
           let scope = identity.scopes.first,
           Self.recordingStartComposerContainmentAllowed(
            scopeKind: scope.kind,
            windowIsModal: windowIsModal,
            hasDisallowedSecondaryAncestor: hasDisallowedSecondaryAncestor
           ) else {
            return nil
        }
        // The composer itself has already supplied the semantic promotion proof. Convert
        // selected-task captures to the stable-key phase so a streaming response or an
        // automatic task-title update cannot invalidate a still-selected task. A real
        // task/tab switch still fails because the retained selected control/key changes.
        return identityAfterSuccessfulComposerPromotion(identity)
    }

    private func exactMainComposerWindowIdentity(
        for window: AXUIElement,
        surface: SemanticSendSurface,
        scopeSurface: SemanticSendSurface
    ) -> ApplicationFallbackIdentity? {
        let title = nonEmptyStringAttribute(kAXTitleAttribute, from: window)
        let document = nonEmptyStringAttribute(kAXDocumentAttribute, from: window)
        let identifier = nonEmptyStringAttribute(kAXIdentifierAttribute, from: window)
        guard Self.exactMainComposerWindowIdentityIsUsable(
            windowTitle: title,
            windowDocument: document,
            windowIdentifier: identifier
        ), let scope = applicationFallbackScopeIdentity(
            kind: .windowMainComposer,
            surface: surface,
            scopeSurface: scopeSurface,
            element: window,
            in: window,
            containerDescriptor: title ?? document ?? identifier
        ) else {
            return nil
        }
        return ApplicationFallbackIdentity(
            capturedAtUptime: ProcessInfo.processInfo.systemUptime,
            windowTitle: title,
            windowDocument: document,
            windowIdentifier: identifier,
            scopes: [scope],
            validationPhase: .captureStrict
        )
    }

    static func exactMainComposerWindowIdentityIsUsable(
        windowTitle: String?,
        windowDocument: String?,
        windowIdentifier: String?
    ) -> Bool {
        // Electron commonly exposes stable-but-generic window identifiers—including
        // UUID-shaped renderer/window instance IDs—while the selected task changes
        // inside that same window. A UUID shape therefore proves only uniqueness of a
        // string, not task ownership. The fast path is valid only when AXDocument is a
        // task/conversation/thread URL that carries instance evidence; otherwise use
        // the bounded selected-task scan. Window title and AXIdentifier remain drift
        // checks after that document proof, never identity authorities by themselves.
        _ = windowTitle // Titles are retained for drift detection, never uniqueness.
        _ = windowIdentifier
        return windowDocument.map(stableTaskDocumentHasInstanceEvidence) == true
    }

    static func stableTaskDocumentHasInstanceEvidence(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard stableTaskIdentifierHasInstanceEvidence(normalized) else {
            return false
        }
        return ["thread", "task", "conversation", "chat"].contains {
            normalized.contains($0)
        }
    }

    static func exactMainComposerWindowIdentityMatches(
        capturedTitle: String?,
        capturedDocument: String?,
        capturedIdentifier: String?,
        currentTitle: String?,
        currentDocument: String?,
        currentIdentifier: String?
    ) -> Bool {
        guard exactMainComposerWindowIdentityIsUsable(
            windowTitle: capturedTitle,
            windowDocument: capturedDocument,
            windowIdentifier: capturedIdentifier
        ) else {
            return false
        }
        return (capturedTitle == nil || capturedTitle == currentTitle)
            && (capturedDocument == nil || capturedDocument == currentDocument)
            && (capturedIdentifier == nil || capturedIdentifier == currentIdentifier)
    }

    static func exactMainComposerCaptureEvidenceMatches(
        surface: SemanticSendSurface,
        description: String?,
        placeholder: String?,
        windowIsModal: Bool,
        hasDisallowedSecondaryAncestor: Bool
    ) -> Bool {
        !windowIsModal
            && !hasDisallowedSecondaryAncestor
            && recordingStartComposerEvidenceMatches(
                surface: surface,
                description: description,
                placeholder: placeholder
            )
    }

    private func applicationFallbackIdentity(
        for window: AXUIElement?,
        sourceElement: AXUIElement?,
        bundleIdentifier: String?,
        applicationBundleName: String?,
        selectedTaskScopeSurfaces explicitScopeSurfaces: [SemanticSendSurface]? = nil,
        scanDeadlineInterval: TimeInterval = 0.060,
        scanNodeBudget: Int = 900
    ) -> ApplicationFallbackIdentity? {
        guard let window,
              let surface = Self.semanticSendSurface(
                bundleIdentifier: bundleIdentifier,
                applicationBundleName: applicationBundleName
              ) else { return nil }
        let captureStarted = ProcessInfo.processInfo.systemUptime
        let scopes: [ApplicationFallbackScopeIdentity]
        if let floatingComposer = floatingComposerScopeIdentity(
            for: window,
            surface: surface
        ) {
            scopes = [floatingComposer]
        } else {
            let scopeSurfaces = explicitScopeSurfaces
                ?? Self.selectedTaskScopeSurfaces(
                    hostSurface: surface,
                    composerProduct: nil
                )
            guard !scopeSurfaces.isEmpty else { return nil }
            let scan = selectedTaskScopeIdentities(
                in: window,
                sourceElement: sourceElement,
                hostSurface: surface,
                scopeSurfaces: scopeSurfaces,
                deadline: captureStarted + scanDeadlineInterval,
                nodeBudget: scanNodeBudget
            )
            guard Self.recordingStartScopeScanIsAcceptable(
                completed: scan.completed,
                matchingScopeCount: scan.scopes.count
            ) else {
                logger.notice("Recording-start selected-task scope rejected incomplete or ambiguous scan bundle=\(bundleIdentifier ?? "nil", privacy: .public) surface=\(surface.rawValue, privacy: .public) completed=\(scan.completed, privacy: .public) matchingScopes=\(scan.scopes.count, privacy: .public) nodesVisited=\(scan.visitedCount, privacy: .public)")
                return nil
            }
            scopes = scan.scopes
        }
        guard scopes.count == 1 else { return nil }
        logger.info("Captured recording-start application scope bundle=\(bundleIdentifier ?? "nil", privacy: .public) hostSurface=\(scopes[0].surface.rawValue, privacy: .public) scopeSurface=\(scopes[0].scopeSurface.rawValue, privacy: .public) kind=\(String(describing: scopes[0].kind), privacy: .public) scopeCount=\(scopes.count, privacy: .public) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - captureStarted) * 1_000), privacy: .public)")
        return ApplicationFallbackIdentity(
            capturedAtUptime: captureStarted,
            windowTitle: nonEmptyStringAttribute(kAXTitleAttribute, from: window),
            windowDocument: nonEmptyStringAttribute(kAXDocumentAttribute, from: window),
            windowIdentifier: nonEmptyStringAttribute(kAXIdentifierAttribute, from: window),
            scopes: scopes,
            // A completed selected-task scan has already proven one uniquely keyed
            // selected control. Use that proof immediately: Electron may rename the
            // task/window while microphone startup is in flight. Floating panels have
            // no task key and therefore retain strict title/document validation.
            validationPhase: scopes.contains(where: {
                $0.kind == .selectedTask
            }) ? .promotedStableSelection : .captureStrict
        )
    }

    private func applicationFallbackWindowMatches(
        _ target: Target,
        window: AXUIElement,
        requireFreshCapture: Bool,
        requireUniqueSelectedTaskRescan: Bool = false
    ) -> Bool {
        guard let captured = target.applicationFallbackIdentity,
              target.window.map({ CFEqual($0, window) }) == true else {
            return false
        }
        if requireFreshCapture,
           ProcessInfo.processInfo.systemUptime - captured.capturedAtUptime > 2.5 {
            return false
        }
        if captured.scopes.contains(where: { $0.kind == .windowMainComposer }),
           !Self.exactMainComposerWindowIdentityMatches(
            capturedTitle: captured.windowTitle,
            capturedDocument: captured.windowDocument,
            capturedIdentifier: captured.windowIdentifier,
            currentTitle: nonEmptyStringAttribute(kAXTitleAttribute, from: window),
            currentDocument: nonEmptyStringAttribute(
                kAXDocumentAttribute,
                from: window
            ),
            currentIdentifier: nonEmptyStringAttribute(
                kAXIdentifierAttribute,
                from: window
            )
           ) {
            return false
        }
        let checks: [(String?, String)] = switch captured.validationPhase {
        case .captureStrict:
            [
                (captured.windowTitle, kAXTitleAttribute),
                (captured.windowDocument, kAXDocumentAttribute),
                (captured.windowIdentifier, kAXIdentifierAttribute)
            ]
        case .promotedStableSelection:
            // Task names and window titles can change automatically while the same
            // task remains selected. Stable document/window identifiers remain hard
            // boundaries; the selected task key below proves task ownership.
            [
                (captured.windowDocument, kAXDocumentAttribute),
                (captured.windowIdentifier, kAXIdentifierAttribute)
            ]
        }
        guard checks.allSatisfy({ expected, attribute in
            expected == nil
                || nonEmptyStringAttribute(attribute, from: window) == expected
        }) else {
            return false
        }
        guard captured.scopes.allSatisfy({
            applicationFallbackScopeMatches(
                $0,
                in: window,
                validationPhase: captured.validationPhase
            )
        }) else {
            return false
        }
        guard requireUniqueSelectedTaskRescan else { return true }
        return captured.scopes.allSatisfy {
            $0.kind != .selectedTask
                || selectedTaskScopeStillUniquelyMatches($0, in: window)
        }
    }

    /// Retained Electron rows can be virtualized and reused for another task. Cheap
    /// wrapper/key checks are suitable between traversal yields, but every promotion
    /// and every later delivery boundary must re-scan the current selected-task tree
    /// and prove the captured task key remains the sole selected match.
    private func selectedTaskScopeStillUniquelyMatches(
        _ captured: ApplicationFallbackScopeIdentity,
        in window: AXUIElement
    ) -> Bool {
        guard captured.kind == .selectedTask,
              let capturedKey = captured.stableTaskKey else {
            return false
        }
        let started = ProcessInfo.processInfo.systemUptime
        let scan = selectedTaskScopeIdentities(
            in: window,
            sourceElement: nil,
            hostSurface: captured.surface,
            scopeSurfaces: [captured.scopeSurface],
            deadline: started + 0.060,
            nodeBudget: 900
        )
        guard scan.completed,
              scan.scopes.count == 1,
              let current = scan.scopes.first,
              current.stableTaskKey == capturedKey,
              CFEqual(current.element, captured.element) else {
            return false
        }
        return true
    }

    private func identityAfterSuccessfulComposerPromotion(
        _ captured: ApplicationFallbackIdentity
    ) -> ApplicationFallbackIdentity? {
        let hasSelectedTask = captured.scopes.contains {
            $0.kind == .selectedTask
        }
        if hasSelectedTask,
           captured.scopes.contains(where: {
               $0.kind == .selectedTask && $0.stableTaskKey == nil
           }) {
            return nil
        }
        return ApplicationFallbackIdentity(
            capturedAtUptime: captured.capturedAtUptime,
            windowTitle: captured.windowTitle,
            windowDocument: captured.windowDocument,
            windowIdentifier: captured.windowIdentifier,
            scopes: captured.scopes,
            validationPhase: hasSelectedTask
                ? .promotedStableSelection
                : .captureStrict
        )
    }

    private func floatingComposerScopeIdentity(
        for window: AXUIElement,
        surface: SemanticSendSurface
    ) -> ApplicationFallbackScopeIdentity? {
        // Construction repeats the product boundary instead of relying only on the
        // evidence helper below. A future widening of that helper must never allow a
        // Codex task (or another host) to inherit ChatGPT's Option-Space wrapper.
        guard surface == .openAIChatGPT else { return nil }
        let subrole = nonEmptyStringAttribute(kAXSubroleAttribute, from: window)
        let isModal = boolAttribute(kAXModalAttribute, from: window) == true
        guard Self.recordingStartFloatingPanelEvidenceMatches(
            surface: surface,
            subrole: subrole,
            isModal: isModal
        ) else { return nil }
        return applicationFallbackScopeIdentity(
            kind: .floatingQuickComposer,
            surface: surface,
            // Option-Space is a ChatGPT product surface even though ChatGPT.app can
            // also host Codex tasks. Pin it explicitly so a later wrapper replacement
            // cannot borrow this window scope for an embedded Codex composer.
            scopeSurface: .openAIChatGPT,
            element: window,
            in: window,
            containerDescriptor: applicationFallbackScopeLabel(for: window)
        )
    }

    static func recordingStartFloatingPanelEvidenceMatches(
        surface: SemanticSendSurface,
        subrole: String?,
        isModal: Bool
    ) -> Bool {
        // The only accepted no-task-list panel is ChatGPT's Option-Space quick composer.
        // A generic dialog/modal is a secondary surface and may contain its own textarea
        // plus Send button, so window-wrapper identity alone must never promote it.
        surface == .openAIChatGPT
            && subrole == "AXFloatingWindow"
            && !isModal
    }

    static func recordingStartScopeScanIsAcceptable(
        completed: Bool,
        matchingScopeCount: Int
    ) -> Bool {
        completed && matchingScopeCount == 1
    }

    /// Capture only actual selected task/tab controls. A generic focused group or the
    /// ambient message text is deliberately insufficient because both can survive a
    /// task switch inside one Electron window. The scan is small and deadline-bounded
    /// so recorder appearance cannot regress behind an unbounded AX tree walk.
    private func selectedTaskScopeIdentities(
        in window: AXUIElement,
        sourceElement: AXUIElement?,
        hostSurface: SemanticSendSurface,
        scopeSurfaces: [SemanticSendSurface],
        deadline: TimeInterval,
        nodeBudget: Int
    ) -> SelectedTaskScopeScanResult {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        if let sourceElement, !CFEqual(sourceElement, window) {
            queue.insert((sourceElement, 0), at: 0)
        }
        var cursor = 0
        var visited = 0
        var seen = Set<CFHashCode>()
        var matches: [ApplicationFallbackScopeIdentity] = []
        var identifierCounts: [String: Int] = [:]
        var domIdentifierCounts: [String: Int] = [:]
        var truncated = false
        let candidateRoles = Set(
            scopeSurfaces.flatMap { Self.selectedTaskRoles(for: $0) }
        )
        while cursor < queue.count,
              visited < nodeBudget,
              ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            visited += 1

            let role = stringAttribute(kAXRoleAttribute, from: element)
            if let role, candidateRoles.contains(role) {
                // Cross-process AX reads dominate this capture-time deadline. Only a
                // task-like row/cell/tab can contribute task identity, so do not read
                // selection, labels, or an 18-level ancestor chain for every generic
                // group in ChatGPT's renderer. Count UUID evidence across every task
                // control—not merely the selected one—so the uniqueness boundary is
                // unchanged while recorder startup remains bounded.
                let selected = boolAttribute(kAXSelectedAttribute, from: element)
                let identifier = nonEmptyStringAttribute(
                    kAXIdentifierAttribute,
                    from: element
                )
                let domIdentifier = nonEmptyStringAttribute(
                    "AXDOMIdentifier",
                    from: element
                )
                if let identifier {
                    identifierCounts[identifier, default: 0] += 1
                }
                if let domIdentifier {
                    domIdentifierCounts[domIdentifier, default: 0] += 1
                }
                if selected == true {
                    let label = applicationFallbackScopeLabel(for: element)
                    let containerDescriptor = taskSelectionContainerDescriptor(
                        for: element,
                        stoppingAt: window
                    )
                    let matchingScopeSurfaces = scopeSurfaces.filter {
                        Self.selectedTaskScopeEvidenceMatches(
                            surface: $0,
                            role: role,
                            selected: selected,
                            identifier: identifier,
                            domIdentifier: domIdentifier,
                            label: label,
                            containerDescriptor: containerDescriptor
                        )
                    }
                    // Avoid a cross-process ancestor traversal unless this selected
                    // control already has product-specific task-scope evidence.
                    if !matchingScopeSurfaces.isEmpty,
                       owningWindow(
                        for: element,
                        allowFocusedApplicationFallback: false
                    ).map({ CFEqual($0, window) }) == true {
                        for scopeSurface in matchingScopeSurfaces
                        where !matches.contains(where: {
                            CFEqual($0.element, element)
                                && $0.scopeSurface == scopeSurface
                        }) {
                            if let identity = applicationFallbackScopeIdentity(
                                kind: .selectedTask,
                                surface: hostSurface,
                                scopeSurface: scopeSurface,
                                element: element,
                                in: window,
                                containerDescriptor: containerDescriptor
                            ) {
                                matches.append(identity)
                            }
                            // Two selected controls—or one generic container that
                            // ambiguously matches two products—cannot identify one task.
                            if matches.count > 1 {
                                return SelectedTaskScopeScanResult(
                                    scopes: matches,
                                    completed: true,
                                    visitedCount: visited
                                )
                            }
                        }
                    }
                }
            }

            let descendants = traversalChildren(of: element)
            guard depth < 14 else {
                if !descendants.isEmpty { truncated = true }
                continue
            }
            let remaining = max(0, nodeBudget - visited - (queue.count - cursor))
            if descendants.count > remaining { truncated = true }
            queue.append(contentsOf: descendants.prefix(remaining).map {
                ($0, depth + 1)
            })
        }
        let completed = cursor >= queue.count && !truncated
        let uniquelyIdentifiedMatches = completed ? matches.compactMap {
            scope -> ApplicationFallbackScopeIdentity? in
            guard let stableTaskKey = Self.uniqueStableTaskKey(
                identifier: scope.identifier,
                domIdentifier: scope.domIdentifier,
                identifierOccurrences: scope.identifier.map {
                    identifierCounts[$0, default: 0]
                } ?? 0,
                domIdentifierOccurrences: scope.domIdentifier.map {
                    domIdentifierCounts[$0, default: 0]
                } ?? 0
            ) else {
                return nil
            }
            var scope = scope
            scope.stableTaskKey = stableTaskKey
            return scope
        } : matches
        return SelectedTaskScopeScanResult(
            scopes: uniquelyIdentifiedMatches,
            completed: completed,
            visitedCount: visited
        )
    }

    static func uniqueStableTaskKey(
        identifier: String?,
        domIdentifier: String?,
        identifierOccurrences: Int,
        domIdentifierOccurrences: Int
    ) -> String? {
        if let domIdentifier,
           domIdentifierOccurrences == 1,
           stableTaskIdentifierHasInstanceEvidence(domIdentifier) {
            return "dom:\(domIdentifier)"
        }
        if let identifier,
           identifierOccurrences == 1,
           stableTaskIdentifierHasInstanceEvidence(identifier) {
            return "ax:\(identifier)"
        }
        return nil
    }

    /// Uniqueness in one virtualized AX snapshot is not enough: a generic retained
    /// row id can stay unique while Electron swaps the task represented by that row.
    /// Require a canonical UUID before an identifier can outlive task-title drift.
    /// Short or long opaque row ids can belong to a virtualized wrapper rather than
    /// the task it currently renders, so they fail closed even when unique once.
    static func stableTaskIdentifierHasInstanceEvidence(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 20 else { return false }
        return normalized.range(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
            options: .regularExpression
        ) != nil
    }

    /// A DOM/AX id such as `prompt-textarea` can be perfectly stable while a renderer
    /// reuses it for every task or browser tab. It may help match structure only when
    /// readable context or a separately revalidated task scope already proves the
    /// document. Renderer bundles still require a revalidated task/document scope even
    /// when the id contains a UUID; this helper is only the stricter fallback for native
    /// inputs whose app does not reuse one renderer wrapper across documents.
    static func exactInputIdentifierHasInstanceEvidence(
        identifier: String?,
        domIdentifier: String?
    ) -> Bool {
        identifier.map(stableTaskIdentifierHasInstanceEvidence) == true
            || domIdentifier.map(stableTaskIdentifierHasInstanceEvidence) == true
    }

    static func selectedTaskScopeEvidenceMatches(
        surface: SemanticSendSurface,
        role: String?,
        selected: Bool?,
        identifier: String?,
        domIdentifier: String?,
        label: String?,
        containerDescriptor: String?
    ) -> Bool {
        guard selected == true,
              let role,
              selectedTaskRoles(for: surface).contains(role),
              identifier != nil || domIdentifier != nil,
              let containerDescriptor else {
            return false
        }
        let normalizedLabel = label?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let labelIsSpecific = normalizedLabel.map {
            !$0.isEmpty
                && !["selected", "tab", "task", "conversation"].contains($0)
        } == true
        let containerTokens = normalizedEvidenceTokens(containerDescriptor)
        return labelIsSpecific
            && !containerTokens.isDisjoint(with: selectedTaskContainerTokens(for: surface))
    }

    private static func selectedTaskRoles(
        for surface: SemanticSendSurface
    ) -> Set<String> {
        switch surface {
        case .openAIChatGPT, .openAICodex:
            return ["AXRow", "AXCell", "AXTab"]
        case .claudeDesktop:
            return ["AXRow", "AXCell"]
        case .telegramForegroundOnly:
            return []
        }
    }

    private static func selectedTaskContainerTokens(
        for surface: SemanticSendSurface
    ) -> Set<String> {
        switch surface {
        case .openAIChatGPT:
            return ["chat", "chats", "conversation", "conversations", "history", "thread", "threads"]
        case .openAICodex:
            return ["conversation", "conversations", "session", "sessions", "task", "tasks", "thread", "threads"]
        case .claudeDesktop:
            return ["chat", "chats", "conversation", "conversations", "history", "recent", "recents"]
        case .telegramForegroundOnly:
            return []
        }
    }

    private static func normalizedEvidenceTokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    private func taskSelectionContainerDescriptor(
        for element: AXUIElement,
        stoppingAt window: AXUIElement
    ) -> String? {
        var current = elementAttribute(kAXParentAttribute, from: element)
        for _ in 0..<18 {
            guard let candidate = current,
                  !CFEqual(candidate, window) else { return nil }
            switch stringAttribute(kAXRoleAttribute, from: candidate) {
            case "AXList", "AXOutline", "AXTabGroup", "AXTable":
                let descriptor = [
                    nonEmptyStringAttribute(kAXIdentifierAttribute, from: candidate),
                    nonEmptyStringAttribute("AXDOMIdentifier", from: candidate),
                    nonEmptyStringAttribute(kAXTitleAttribute, from: candidate),
                    nonEmptyStringAttribute(kAXDescriptionAttribute, from: candidate),
                    nonEmptyStringAttribute(kAXHelpAttribute, from: candidate)
                ].compactMap { $0 }.joined(separator: " ")
                if !descriptor.isEmpty {
                    return String(descriptor.prefix(240))
                }
                current = elementAttribute(kAXParentAttribute, from: candidate)
            default:
                current = elementAttribute(kAXParentAttribute, from: candidate)
            }
        }
        return nil
    }

    private func applicationFallbackScopeIdentity(
        kind: ApplicationFallbackScopeKind,
        surface: SemanticSendSurface,
        scopeSurface: SemanticSendSurface? = nil,
        element: AXUIElement,
        in window: AXUIElement,
        containerDescriptor: String?
    ) -> ApplicationFallbackScopeIdentity? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return ApplicationFallbackScopeIdentity(
            kind: kind,
            surface: surface,
            scopeSurface: scopeSurface ?? surface,
            element: element,
            role: stringAttribute(kAXRoleAttribute, from: element),
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            identifier: nonEmptyStringAttribute(kAXIdentifierAttribute, from: element),
            domIdentifier: nonEmptyStringAttribute("AXDOMIdentifier", from: element),
            stableTaskKey: nil,
            label: applicationFallbackScopeLabel(for: element),
            containerDescriptor: containerDescriptor,
            relativeFrame: relativeFrame(of: element, in: window),
            ancestorPath: ancestorPath(from: element, through: window)
        )
    }

    private func applicationFallbackScopeLabel(
        for element: AXUIElement
    ) -> String? {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute
        ].lazy.compactMap {
            self.nonEmptyStringAttribute($0, from: element)
        }.first.map { String($0.prefix(180)) }
    }

    private func applicationFallbackScopeMatches(
        _ scope: ApplicationFallbackScopeIdentity,
        in window: AXUIElement,
        validationPhase: ApplicationFallbackValidationPhase
    ) -> Bool {
        if validationPhase == .promotedStableSelection,
           scope.kind == .selectedTask {
            let sameWindow = owningWindow(
                for: scope.element,
                allowFocusedApplicationFallback: false
            ).map({ CFEqual($0, window) }) == true
            let roleMatches =
                stringAttribute(kAXRoleAttribute, from: scope.element)
                    == scope.role
                && stringAttribute(kAXSubroleAttribute, from: scope.element)
                    == scope.subrole
            let stableKeyMatches = scope.stableTaskKey.map {
                currentStableTaskKey(
                    for: scope.element,
                    capturedKey: $0
                ) == $0
            } == true
            guard Self.promotedStableSelectionMatches(
                sameWindow: sameWindow,
                sameRetainedWrapper: true,
                selected: boolAttribute(
                    kAXSelectedAttribute,
                    from: scope.element
                ) == true,
                roleMatches: roleMatches,
                stableTaskKeyMatches: stableKeyMatches
            ) else {
                return false
            }
            return true
        }

        switch scope.kind {
        case .floatingQuickComposer:
            guard CFEqual(scope.element, window),
                  scope.scopeSurface == .openAIChatGPT,
                  Self.recordingStartFloatingPanelEvidenceMatches(
                    surface: scope.surface,
                    subrole: nonEmptyStringAttribute(
                        kAXSubroleAttribute,
                        from: window
                    ),
                    isModal: boolAttribute(kAXModalAttribute, from: window) == true
                  ) else { return false }
        case .windowMainComposer:
            guard CFEqual(scope.element, window),
                  Self.exactMainComposerWindowIdentityIsUsable(
                    windowTitle: nonEmptyStringAttribute(
                        kAXTitleAttribute,
                        from: window
                    ),
                    windowDocument: nonEmptyStringAttribute(
                        kAXDocumentAttribute,
                        from: window
                    ),
                    windowIdentifier: nonEmptyStringAttribute(
                        kAXIdentifierAttribute,
                        from: window
                    )
                  ) else {
                return false
            }
        case .selectedTask:
            let currentContainerDescriptor = taskSelectionContainerDescriptor(
                for: scope.element,
                stoppingAt: window
            )
            guard Self.selectedTaskScopeEvidenceMatches(
                    surface: scope.scopeSurface,
                    role: stringAttribute(kAXRoleAttribute, from: scope.element),
                    selected: boolAttribute(kAXSelectedAttribute, from: scope.element),
                    identifier: nonEmptyStringAttribute(
                        kAXIdentifierAttribute,
                        from: scope.element
                    ),
                    domIdentifier: nonEmptyStringAttribute(
                        "AXDOMIdentifier",
                        from: scope.element
                    ),
                    label: applicationFallbackScopeLabel(for: scope.element),
                    containerDescriptor: currentContainerDescriptor
                  ),
                  currentContainerDescriptor == scope.containerDescriptor,
                  owningWindow(
                    for: scope.element,
                    allowFocusedApplicationFallback: false
                  ).map({ CFEqual($0, window) }) == true else {
                return false
            }
        }
        var pid: pid_t = 0
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(scope.element, &pid) == .success,
              AXUIElementGetPid(window, &windowPID) == .success,
              pid == windowPID,
              stringAttribute(kAXRoleAttribute, from: scope.element) == scope.role,
              stringAttribute(kAXSubroleAttribute, from: scope.element) == scope.subrole,
              scope.identifier.map({
                nonEmptyStringAttribute(kAXIdentifierAttribute, from: scope.element) == $0
              }) ?? true,
              scope.domIdentifier.map({
                nonEmptyStringAttribute("AXDOMIdentifier", from: scope.element) == $0
              }) ?? true,
              scope.label.map({
                applicationFallbackScopeLabel(for: scope.element) == $0
              }) ?? true,
              ancestorPath(from: scope.element, through: window) == scope.ancestorPath else {
            return false
        }
        return Self.elementGeometryMatches(
            isSameRetainedWrapper: true,
            expectedFrame: scope.relativeFrame,
            currentFrame: relativeFrame(of: scope.element, in: window)
        )
    }

    private func currentStableTaskKey(
        for element: AXUIElement,
        capturedKey: String
    ) -> String? {
        if capturedKey.hasPrefix("dom:"),
           let value = nonEmptyStringAttribute(
            "AXDOMIdentifier",
            from: element
           ) {
            return "dom:\(value)"
        }
        if capturedKey.hasPrefix("ax:"),
           let value = nonEmptyStringAttribute(
            kAXIdentifierAttribute,
            from: element
           ) {
            return "ax:\(value)"
        }
        return nil
    }

    static func promotedStableSelectionMatches(
        sameWindow: Bool,
        sameRetainedWrapper: Bool,
        selected: Bool,
        roleMatches: Bool,
        stableTaskKeyMatches: Bool
    ) -> Bool {
        sameWindow
            && sameRetainedWrapper
            && selected
            && roleMatches
            && stableTaskKeyMatches
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

    /// Foreground-only legacy/workspace helper. It may activate the target app and
    /// rewrite its focused element, so background exact delivery and same-app/
    /// different-input delivery must never call it; those routes are non-activating
    /// and fail closed when the saved input cannot be addressed directly.
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
            let currentContextResult = contextFingerprint(
                in: window,
                region: identity.contextRegion,
                excluding: element,
                bundleIdentifier: target.bundleIdentifier
            )
            let currentContext = currentContextResult.selection
            logger.notice("Telegram retained-input preparation rejected hidden, changed, internally unfocused, or incompletely scanned chat pid=\(target.pid, privacy: .public) capturedPrimary=\(identity.primaryContextAnchors.count, privacy: .public) capturedSecondary=\(identity.contextAnchors.count, privacy: .public) currentPrimary=\(currentContext.primary.count, privacy: .public) currentSecondary=\(currentContext.secondary.count, privacy: .public) contextComplete=\(currentContextResult.completed, privacy: .public)")
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
        if !target.hasExactInput {
            return retainedInputOwnsSystemKeyboardFocus(target)
        }
        guard let focused = systemFocusedElement(),
              focused.pid == target.pid,
              let element = resolvedExactElement(for: target) else {
            return false
        }
        // Electron may replace the composer AX wrapper while preserving the same
        // verified task/input. Compare system focus with the safely re-resolved live
        // element, never only the stale capture-time wrapper. Resolution still fails
        // closed when context/task identity cannot prove a replacement.
        return CFEqual(focused.element, element)
    }

    /// Process-only foreground boundary for the explicit base-VoiceInk compatibility
    /// mode. This intentionally exposes no AX wrapper or saved-input identity: legacy
    /// delivery must follow the real current cursor, not quietly rebuild the exact
    /// destination engine. The PID is still enough to cancel Cmd-V/Return if Ethan
    /// switches apps (including leaving a non-activating ChatGPT panel) mid-sequence.
    func systemKeyboardFocusedProcessIdentifier() -> pid_t? {
        systemFocusedElement()?.pid
    }

    /// Cheap irreversible-boundary guard used after one full route decision. It never
    /// discovers a replacement wrapper and therefore cannot authorize background
    /// delivery. The exact capture-time editor must still own system keyboard focus,
    /// remain editable, and still belong to the capture-time window.
    func retainedInputOwnsSystemKeyboardFocus(_ target: Target) -> Bool {
        guard !target.app.isTerminated,
              let element = target.element,
              let window = target.window,
              let focused = systemFocusedElement(),
              focused.pid == target.pid,
              CFEqual(focused.element, element),
              isEditableInput(
                role: stringAttribute(kAXRoleAttribute, from: element),
                subrole: stringAttribute(kAXSubroleAttribute, from: element)
              ),
              owningWindow(
                for: element,
                allowFocusedApplicationFallback: Self.isTelegram(
                    bundleIdentifier: target.bundleIdentifier
                )
              ).map({ CFEqual($0, window) }) == true else {
            return false
        }
        let hardenedScopeMatches = target.applicationFallbackIdentity != nil
            && applicationFallbackWindowMatches(
                target,
                window: window,
                requireFreshCapture: false,
                requireUniqueSelectedTaskRescan: true
            )
        let rendererRequiresIdentityOrContext = target.bundleIdentifier.map(
            Self.exactWrapperRequiresIdentityOrContextBundleIdentifiers.contains
        ) == true
        guard Self.retainedForegroundInputBoundaryAllowed(
            rendererRequiresIdentityOrContext:
                rendererRequiresIdentityOrContext,
            hasExactIdentity: target.identity != nil,
            hasHardenedApplicationScope: hardenedScopeMatches
        ) else {
            return false
        }
        return true
    }

    static func retainedForegroundInputBoundaryAllowed(
        rendererRequiresIdentityOrContext: Bool,
        hasExactIdentity: Bool,
        hasHardenedApplicationScope: Bool
    ) -> Bool {
        !rendererRequiresIdentityOrContext
            || hasExactIdentity
            || hasHardenedApplicationScope
    }

    /// Cheap foreground paste-settlement read. This never authorizes delivery: callers
    /// must still run the full saved document/chat resolver immediately before Send.
    /// It only avoids repeatedly walking an Electron/Telegram AX tree while waiting for
    /// a just-issued foreground paste to appear in the exact still-focused wrapper.
    func focusedExactInputTextFast(_ target: Target) -> String? {
        guard retainedInputOwnsSystemKeyboardFocus(target),
              let element = target.element else {
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

    /// A session prepared through the exact-input path can still be the user's current
    /// foreground or Option-Space composer. Only that pre-decided
    /// `alreadyKeyboardFocused` mode may use one ordinary global HID Return when an
    /// explicit semantic Send control is unavailable. Re-run the complete saved
    /// document/task boundary here; process identity or frontmost status alone is never
    /// sufficient and no focus mutation is permitted.
    func backgroundInputOwnsSystemKeyboardFocus(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        session.focusMode == .alreadyKeyboardFocused
            && backgroundDeliveryBoundaryMatches(session)
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

    static func supportsBackgroundSemanticSend(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return backgroundSemanticSendBundleIdentifiers.contains(bundleIdentifier)
    }

    static func supportsRecordingStartMainComposer(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return recordingStartMainComposerBundleIdentifiers.contains(bundleIdentifier)
    }

    /// `com.openai.codex` is shared by the separately installed ChatGPT and Codex
    /// applications. Preserve their bundle URL identity instead of pretending the
    /// bundle identifier alone proves which real surface was inspected. Telegram is
    /// deliberately foreground-only: its visible Send slot is a private custom view,
    /// not a labelled AXButton that can be pressed safely in a saved background chat.
    static func semanticSendSurface(
        bundleIdentifier: String?,
        applicationBundleName: String?
    ) -> SemanticSendSurface? {
        switch bundleIdentifier {
        case "com.openai.codex", "com.openai.chat":
            switch applicationBundleName {
            case openAIChatGPTApplicationName:
                return .openAIChatGPT
            case openAICodexApplicationName:
                return .openAICodex
            default:
                return nil
            }
        case "com.anthropic.claudefordesktop":
            return .claudeDesktop
        case "ru.keepcoder.Telegram":
            return .telegramForegroundOnly
        default:
            return nil
        }
    }

    /// The exact audited ChatGPT and Codex builds render their idle composer action as
    /// an enabled HTML button with no aria-label; React supplies only the visual tooltip
    /// "Send". The same slot acquires an explicit "Stop" aria-label while a turn runs.
    /// That means the old explicit-label-only rule can never submit either audited app,
    /// while accepting an arbitrary unlabelled square across versions could press a
    /// future Stop control. Permit the unlabelled idle shape only for an exact inspected
    /// bundle tuple. Any app update or changed Chromium base fails closed until audited.
    static func versionedUnlabelledOpenAISendIsAllowed(
        surface: SemanticSendSurface,
        applicationBundleName: String?,
        marketingVersion: String?,
        buildNumber: String?,
        chromiumBaseVersion: String?
    ) -> Bool {
        switch surface {
        case .openAIChatGPT:
            return applicationBundleName == openAIChatGPTApplicationName
                && [
                    ("26.715.21425", "5488", "150.0.7871.124"),
                    ("26.715.31925", "5551", "150.0.7871.124")
                ].contains {
                    $0.0 == marketingVersion
                        && $0.1 == buildNumber
                        && $0.2 == chromiumBaseVersion
                }
        case .openAICodex:
            return applicationBundleName == openAICodexApplicationName
                && [
                    ("26.707.31428", "5059", "150.0.7871.101"),
                    ("26.707.72221", "5307", "150.0.7871.115")
                ].contains {
                    $0.0 == marketingVersion
                        && $0.1 == buildNumber
                        && $0.2 == chromiumBaseVersion
                }
        case .claudeDesktop, .telegramForegroundOnly:
            return false
        }
    }

    private func versionedUnlabelledOpenAISendIsAllowed(
        pid: pid_t,
        surface: SemanticSendSurface
    ) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid),
              let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL) else {
            return false
        }
        return Self.versionedUnlabelledOpenAISendIsAllowed(
            surface: surface,
            applicationBundleName: bundleURL.lastPathComponent,
            marketingVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            chromiumBaseVersion: bundle.object(
                forInfoDictionaryKey: "ChromiumBaseVersion"
            ) as? String
        )
    }

    /// Resolve only stable, app-owned OpenAI composer descriptions. ChatGPT.app is a
    /// host for both product surfaces, so its Codex task composer must be recognized
    /// without weakening the host/version tuple used later for semantic Send. Search,
    /// feedback, rename, and arbitrary textareas do not match this product evidence.
    static func openAIComposerProduct(
        description: String?,
        placeholder: String?
    ) -> OpenAIComposerProduct? {
        guard let normalizedDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedDescription.isEmpty else {
            return nil
        }
        let normalizedPlaceholder = placeholder?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedPlaceholder == nil
                || normalizedDescription == normalizedPlaceholder else {
            return nil
        }

        if normalizedDescription == "message chatgpt"
            || normalizedDescription == "ask chatgpt"
            || normalizedDescription.hasPrefix("message chatgpt ")
            || normalizedDescription.hasPrefix("ask chatgpt anything") {
            return .chatGPT
        }
        if [
            "ask for follow-up changes",
            "do anything",
            "ask codex",
            "message codex"
        ].contains(normalizedDescription)
            || normalizedDescription.hasPrefix("ask codex to do anything") {
            return .codex
        }
        return nil
    }

    /// Map a composer to the selected-scope vocabulary it actually owns. The host and
    /// product deliberately diverge for Codex tasks embedded in ChatGPT.app: the host
    /// still gates audited Send actions, while the selected control must live under a
    /// Codex `task`/`tasks`/`session` scope. With no composer evidence (the no-caret
    /// recording-start path), scan both product vocabularies and require exactly one
    /// unique match before any later promotion.
    static func selectedTaskScopeSurfaces(
        hostSurface: SemanticSendSurface,
        composerProduct: OpenAIComposerProduct?
    ) -> [SemanticSendSurface] {
        switch (hostSurface, composerProduct) {
        case (.openAIChatGPT, .some(.chatGPT)):
            return [.openAIChatGPT]
        case (.openAIChatGPT, .some(.codex)):
            return [.openAICodex]
        case (.openAIChatGPT, .none):
            return [.openAIChatGPT, .openAICodex]
        case (.openAICodex, .some(.codex)), (.openAICodex, .none):
            return [.openAICodex]
        case (.openAICodex, .some(.chatGPT)):
            return []
        case (.claudeDesktop, .none):
            return [.claudeDesktop]
        case (.claudeDesktop, .some(_)), (.telegramForegroundOnly, _):
            return []
        }
    }

    /// Promotion must compose all three facts atomically: installed host, captured
    /// selected-scope vocabulary, and the candidate composer product. This prevents a
    /// ChatGPT textarea from borrowing a Codex `Tasks` identity (or vice versa) merely
    /// because both products happen to share one Electron host and bundle identifier.
    static func recordingStartComposerScopeEvidenceMatches(
        scopeKind: ApplicationFallbackScopeKind,
        hostSurface: SemanticSendSurface,
        scopeSurface: SemanticSendSurface,
        description: String?,
        placeholder: String?
    ) -> Bool {
        guard recordingStartComposerEvidenceMatches(
            surface: hostSurface,
            description: description,
            placeholder: placeholder
        ) else {
            return false
        }
        let composerProduct = openAIComposerProduct(
            description: description,
            placeholder: placeholder
        )
        switch scopeKind {
        case .floatingQuickComposer:
            // ChatGPT's Option-Space panel is the sole accepted floating scope. It
            // cannot authorize an embedded Codex composer even inside ChatGPT.app.
            return hostSurface == .openAIChatGPT
                && scopeSurface == .openAIChatGPT
                && composerProduct == .chatGPT
        case .selectedTask, .windowMainComposer:
            return selectedTaskScopeSurfaces(
                hostSurface: hostSurface,
                composerProduct: composerProduct
            ) == [scopeSurface]
        }
    }

    /// Main-composer capture must not depend on whether the adjacent action currently
    /// says Send or Stop: Ethan often starts dictating while an agent is still running.
    /// These are known per-surface composer semantics, not the old permissive rule that
    /// accepted any textarea whose description happened to equal its placeholder. The
    /// caller must additionally prove one selected-task/floating-panel scope, unique
    /// composer geometry, and no secondary/modal ancestor. A labelled Send/Stop adds
    /// evidence when available but is not required for capture: current OpenAI builds
    /// can expose that action as an unlabelled custom control while an agent runs.
    static func recordingStartComposerEvidenceMatches(
        surface: SemanticSendSurface,
        description: String?,
        placeholder: String?
    ) -> Bool {
        let normalizedPlaceholder = placeholder?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch surface {
        case .openAIChatGPT:
            // ChatGPT.app now hosts both ChatGPT conversations and Codex tasks. The
            // product evidence may therefore be either one, while app filename plus
            // exact version/build/Chromium remain independently mandatory for the
            // unlabelled Send exception.
            return openAIComposerProduct(
                description: description,
                placeholder: placeholder
            ) != nil
        case .openAICodex:
            return openAIComposerProduct(
                description: description,
                placeholder: placeholder
            ) == .codex
        case .claudeDesktop:
            let normalizedDescription = description?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalizedDescription == "prompt"
                && (normalizedPlaceholder == nil
                    || normalizedPlaceholder == "reply to claude"
                    || normalizedPlaceholder == "message claude")
        case .telegramForegroundOnly:
            return false
        }
    }

    static func recordingStartComposerContainmentAllowed(
        scopeKind: ApplicationFallbackScopeKind,
        windowIsModal: Bool,
        hasDisallowedSecondaryAncestor: Bool
    ) -> Bool {
        guard !windowIsModal, !hasDisallowedSecondaryAncestor else { return false }
        switch scopeKind {
        case .selectedTask, .floatingQuickComposer, .windowMainComposer:
            return true
        }
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
                in: session.window,
                bundleIdentifier: session.bundleIdentifier
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
        let currentContextResult = contextFingerprint(
            in: session.window,
            region: identity.contextRegion,
            excluding: session.element,
            bundleIdentifier: session.bundleIdentifier
        )
        guard currentContextResult.completed else { return false }
        let currentContext = currentContextResult.selection
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
              owningWindow(
                for: session.element,
                allowFocusedApplicationFallback: true
              ).map({
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

    /// The recordingStart/Next route may intentionally begin from ChatGPT, Codex, or
    /// Claude while its main composer has no caret. Capture stores the proven app and
    /// focused window, then the already-visible recorder start path promotes that
    /// app-level fallback to exactly one visible main AXTextArea without activating the
    /// app. If the capture-time control still owns focus, it also makes one bounded
    /// in-place focus attempt; failure cannot invalidate the frozen exact target and no
    /// compensating focus rewrite is attempted. Delivery never retries
    /// discovery. Primary normal stop and second chance never call this resolver.
    /// Ambiguity fails closed.
    func resolveRecordingStartMainComposer(
        for target: Target
    ) async -> Target? {
        if target.hasForegroundInput, !target.hasExactInput {
            return await enrichRecordingStartRetainedInput(for: target)
        }
        guard !target.hasExactInput,
              Self.supportsRecordingStartMainComposer(
                bundleIdentifier: target.bundleIdentifier
              ),
              let surface = Self.semanticSendSurface(
                bundleIdentifier: target.bundleIdentifier,
                applicationBundleName: target.app.bundleURL?.lastPathComponent
              ),
              surface != .telegramForegroundOnly,
              let fallbackIdentity = target.applicationFallbackIdentity,
              fallbackIdentity.scopes.count == 1,
              let applicationScope = fallbackIdentity.scopes.first,
              applicationScope.surface == surface,
              !target.app.isTerminated else {
            return nil
        }

        // Never choose a delivery-time/current window. This resolver is valid only for
        // the cheap application fallback captured immediately before this recording;
        // if it cannot be promoted now, recordingStart fails visibly instead of later
        // discovering a different task after Ethan has switched tabs or inputs.
        guard let window = target.window,
              applicationFallbackWindowMatches(
                target,
                window: window,
                requireFreshCapture: true,
                requireUniqueSelectedTaskRescan: true
              ),
              let windowFrame = frame(of: window) else {
            logger.notice("Recording-start main-composer promotion has no saved/focused window pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success,
              windowPID == target.pid else {
            return nil
        }

        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 0.35
        let traversalState = BoundedTraversalState(nodeBudget: 1_600)
        let captureScopeStillMatches = {
            self.applicationFallbackWindowMatches(
                target,
                window: window,
                requireFreshCapture: true
            )
        }
        let composerRegion = CGRect(
            x: windowFrame.minX,
            y: windowFrame.midY - 100,
            width: windowFrame.width,
            height: windowFrame.height / 2 + 100
        )
        let windowIsModal = boolAttribute(kAXModalAttribute, from: window) == true
        var contextElements: [AXUIElement] = []
        var candidates: [AXUIElement] = []
        let traversal = await visitBoundedDescendants(
            of: window,
            maximumDepth: 24,
            state: traversalState,
            deadline: deadline,
            boundary: captureScopeStillMatches,
            shouldDescend: { element, depth in
                guard depth > 0,
                      let elementFrame = self.frame(of: element) else {
                    return true
                }
                return elementFrame.intersects(composerRegion)
            },
            visitor: { element, _ in
                contextElements.append(element)
                guard self.stringAttribute(kAXRoleAttribute, from: element)
                        == kAXTextAreaRole else {
                    return true
                }
                var candidatePID: pid_t = 0
                guard AXUIElementGetPid(element, &candidatePID) == .success,
                      candidatePID == target.pid,
                      self.boolAttribute(kAXEnabledAttribute, from: element) != false,
                      self.boolAttribute("AXVisible", from: element) != false,
                      let candidateFrame = self.frame(of: element),
                      candidateFrame.width >= 160,
                      candidateFrame.height >= 24,
                      candidateFrame.intersects(composerRegion),
                      self.owningWindow(for: element).map({
                        CFEqual($0, window)
                      }) == true,
                      Self.recordingStartComposerContainmentAllowed(
                        scopeKind: applicationScope.kind,
                        windowIsModal: windowIsModal,
                        hasDisallowedSecondaryAncestor:
                            self.hasDisallowedSecondaryComposerAncestor(
                                element,
                                stoppingAt: window
                            )
                      ),
                      Self.recordingStartComposerScopeEvidenceMatches(
                        scopeKind: applicationScope.kind,
                        hostSurface: surface,
                        scopeSurface: applicationScope.scopeSurface,
                        description: self.nonEmptyStringAttribute(
                            kAXDescriptionAttribute,
                            from: element
                        ),
                        placeholder: self.nonEmptyStringAttribute(
                            kAXPlaceholderValueAttribute,
                            from: element
                        )
                      ) else {
                    return true
                }
                if !candidates.contains(where: { CFEqual($0, element) }) {
                    candidates.append(element)
                }
                return candidates.count < 2
            }
        )
        guard traversal.completion == BoundedTraversalCompletion.completed,
              candidates.count == 1,
              let element = candidates.first,
              captureScopeStillMatches() else {
            logger.notice("Recording-start main-composer promotion was not semantically unique or its bounded scan did not complete pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) composerCandidates=\(candidates.count, privacy: .public) nodesVisited=\(traversal.visitedCount, privacy: .public) traversal=\(String(describing: traversal.completion), privacy: .public) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1_000), privacy: .public)")
            return nil
        }
        let promotedComposerProduct = Self.openAIComposerProduct(
            description: nonEmptyStringAttribute(
                kAXDescriptionAttribute,
                from: element
            ),
            placeholder: nonEmptyStringAttribute(
                kAXPlaceholderValueAttribute,
                from: element
            )
        )?.rawValue ?? "nonOpenAI"
        logger.info("Recording-start composer promotion semantics accepted hostSurface=\(surface.rawValue, privacy: .public) scopeSurface=\(applicationScope.scopeSurface.rawValue, privacy: .public) composerProduct=\(promotedComposerProduct, privacy: .public)")

        // A feedback/modal textarea can have plausible placeholder text, so ambiguity
        // in the app-specific action topology still fails closed. Current OpenAI builds
        // can expose their real Send/Stop square as an unlabelled custom control while
        // an agent is running. Missing topology is therefore not a capture failure once
        // the unique composer, selected task/floating panel, geometry, semantic
        // description, and disallowed-ancestor checks above all agree. Submission is a
        // separate decision: it normally requires an explicit Send label. The sole
        // exception is the exact audited ChatGPT build whose idle unlabelled button is
        // revalidated as still unlabelled at the irreversible AXPress boundary.
        switch await nearbySubmitButtonLookup(
            element: element,
            pid: target.pid,
            surface: surface,
            allowStopForComposerTopology: true,
            boundary: captureScopeStillMatches
        ) {
        case .ready, .disabled:
            break
        case .unavailable:
            logger.notice("Recording-start main-composer promotion continuing without labelled action topology after unique semantic composer proof pid=\(target.pid, privacy: .public) surface=\(surface.rawValue, privacy: .public)")
        case .ambiguous:
            logger.notice("Recording-start main-composer promotion rejected ambiguous composer action topology pid=\(target.pid, privacy: .public) surface=\(surface.rawValue, privacy: .public)")
            return nil
        }
        guard captureScopeStillMatches() else { return nil }

        guard let identity = await exactInputIdentityBounded(
            for: element,
            in: window,
            bundleIdentifier: target.bundleIdentifier,
            contextElements: contextElements,
            deadline: ProcessInfo.processInfo.systemUptime + 0.12,
            hasHardenedApplicationScope: true,
            boundary: captureScopeStillMatches
        ), !Task.isCancelled,
              captureScopeStillMatches(),
              applicationFallbackWindowMatches(
                target,
                window: window,
                requireFreshCapture: true,
                requireUniqueSelectedTaskRescan: true
              ) else {
            logger.notice("Recording-start main-composer promotion could not freeze its exact composer inside the capture-time task scope pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard let promotedFallbackIdentity =
                identityAfterSuccessfulComposerPromotion(fallbackIdentity) else {
            logger.notice("Recording-start main-composer promotion lacked one scan-proven stable selected-task key pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        let focusedPromotedComposer = await focusRecordingStartComposerIfSafe(
            element,
            for: target,
            in: window,
            boundary: captureScopeStillMatches
        )
        logger.info("Promoted recording-start application fallback to one frozen main composer without activation pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) elementHash=\(CFHash(element), privacy: .public) focusedWithinActiveSurface=\(focusedPromotedComposer, privacy: .public) nodesVisited=\(traversal.visitedCount, privacy: .public) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1_000), privacy: .public)")
        return Target(
            element: element,
            window: window,
            identity: identity,
            applicationFallbackIdentity: promotedFallbackIdentity,
            app: target.app,
            pid: target.pid,
            terminalAutomationTarget: target.terminalAutomationTarget,
            captureID: target.captureID,
            capturedAtUptime: target.capturedAtUptime,
            captureFocusedElement: target.captureFocusedElement,
            bundleIdentifier: target.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: target.displayInfo.applicationName,
                inputName: inputDisplayName(for: element),
                applicationIcon: target.displayInfo.applicationIcon
            )
        )
    }

    /// Ethan may start recording from the active Codex/ChatGPT/Claude page while its
    /// main composer has no caret. Once the capture-time task scope has yielded exactly
    /// one composer, try to focus that editor in place. This never activates an app: the
    /// original non-editable control must still own system focus, the same window/task
    /// boundary must still match, and the macOS frontmost app must remain unchanged.
    /// If Ethan clicks elsewhere while the bounded scan runs, no focus mutation occurs.
    /// There is no compensating focus rewrite after the attempt: a rollback cannot prove
    /// whether a later focus on the composer belongs to VoiceInk++ or to Ethan.
    private func focusRecordingStartComposerIfSafe(
        _ composer: AXUIElement,
        for target: Target,
        in window: AXUIElement,
        boundary: () -> Bool
    ) async -> Bool {
        guard let captureFocusedElement = target.captureFocusedElement,
              let focusedBefore = systemFocusedElement(),
              focusedBefore.pid == target.pid,
              CFEqual(focusedBefore.element, captureFocusedElement),
              owningWindow(
                for: captureFocusedElement,
                allowFocusedApplicationFallback: false
              ).map({ CFEqual($0, window) }) == true,
              boundary() else {
            return false
        }
        let frontmostPIDBefore = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            composer,
            kAXFocusedAttribute as CFString,
            &settable
        ) == .success,
              settable.boolValue,
              boundary(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == frontmostPIDBefore,
              let immediateFocus = systemFocusedElement(),
              immediateFocus.pid == target.pid,
              CFEqual(immediateFocus.element, captureFocusedElement) else {
            return false
        }
        guard AXUIElementSetAttributeValue(
            composer,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success else {
            return false
        }
        for _ in 0..<6 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                    != frontmostPIDBefore {
                break
            }
            if let focused = systemFocusedElement(),
               focused.pid == target.pid,
               CFEqual(focused.element, composer),
               boundary() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// A focused editor can be the exact recording-start decision even when its first
    /// bounded history scan cannot build a replay-safe identity. Enrich that retained
    /// wrapper once, while it still owns system focus and the capture-time app/window/
    /// task boundary remains true. This is deliberately the same session-owned task as
    /// no-caret main-composer promotion: if Ethan switches before it completes, the
    /// target fails closed instead of following a reused renderer wrapper into another
    /// task or tab.
    private func enrichRecordingStartRetainedInput(
        for target: Target
    ) async -> Target? {
        guard let element = target.element,
              let window = target.window,
              !target.app.isTerminated else {
            return nil
        }
        let rendererRequiresIdentityOrContext = target.bundleIdentifier.map(
            Self.exactWrapperRequiresIdentityOrContextBundleIdentifiers.contains
        ) == true
        let hasHardenedApplicationScope = target.applicationFallbackIdentity != nil
        let captureBoundaryMatches = {
            guard !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime - target.capturedAtUptime <= 2.5,
                  !target.app.isTerminated,
                  self.recordingStartNonFrontmostFallbackIsAllowed(
                    app: target.app,
                    window: window
                  ),
                  let focused = self.systemFocusedElement(),
                  focused.pid == target.pid,
                  CFEqual(focused.element, element),
                  self.owningWindow(
                    for: element,
                    allowFocusedApplicationFallback: Self.isTelegram(
                        bundleIdentifier: target.bundleIdentifier
                    )
                  ).map({ CFEqual($0, window) }) == true else {
                return false
            }
            if hasHardenedApplicationScope {
                return self.applicationFallbackWindowMatches(
                    target,
                    window: window,
                    requireFreshCapture: true,
                    requireUniqueSelectedTaskRescan: true
                )
            }
            // Renderer wrappers are known to survive task/tab changes. Without a
            // capture-time selected-task scope, a later async walk cannot prove that
            // the same wrapper still represents the original decision.
            return !rendererRequiresIdentityOrContext
        }
        guard captureBoundaryMatches() else { return nil }

        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 0.35
        let traversalState = BoundedTraversalState(nodeBudget: 1_600)
        var contextElements: [AXUIElement] = []
        let traversal = await visitBoundedDescendants(
            of: window,
            maximumDepth: 24,
            state: traversalState,
            deadline: deadline,
            boundary: captureBoundaryMatches,
            visitor: { candidate, _ in
                contextElements.append(candidate)
                return true
            }
        )
        guard traversal.completion == .completed,
              captureBoundaryMatches(),
              let identity = await exactInputIdentityBounded(
                for: element,
                in: window,
                bundleIdentifier: target.bundleIdentifier,
                contextElements: contextElements,
                deadline: ProcessInfo.processInfo.systemUptime + 0.12,
                hasHardenedApplicationScope: hasHardenedApplicationScope,
                boundary: captureBoundaryMatches
              ),
              captureBoundaryMatches() else {
            logger.notice("Recording-start retained input enrichment failed closed pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) traversal=\(String(describing: traversal.completion), privacy: .public) nodesVisited=\(traversal.visitedCount, privacy: .public)")
            return nil
        }
        logger.info("Enriched recording-start retained input with replay-safe identity pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) nodesVisited=\(traversal.visitedCount, privacy: .public) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1_000), privacy: .public)")
        return Target(
            element: element,
            window: window,
            identity: identity,
            applicationFallbackIdentity: target.applicationFallbackIdentity,
            app: target.app,
            pid: target.pid,
            terminalAutomationTarget: target.terminalAutomationTarget,
            captureID: target.captureID,
            capturedAtUptime: target.capturedAtUptime,
            captureFocusedElement: target.captureFocusedElement,
            bundleIdentifier: target.bundleIdentifier,
            displayInfo: target.displayInfo
        )
    }

    func pressNearbySubmitButton(
        for session: BackgroundDeliverySession
    ) async -> NearbySubmitButtonResult {
        guard AXIsProcessTrusted(),
              Self.supportsBackgroundSemanticSend(
                bundleIdentifier: session.bundleIdentifier
              ),
              let surface = Self.semanticSendSurface(
                bundleIdentifier: session.bundleIdentifier,
                applicationBundleName: session.app.bundleURL?.lastPathComponent
              ),
              !session.app.isTerminated,
              backgroundDeliveryBoundaryMatches(session) else {
            return .unavailable
        }

        let result = await pressNearbySubmitButton(
            element: session.element,
            pid: session.processIdentifier,
            surface: surface,
            preserveSystemFocusAcrossAction:
                session.focusMode == .directExactElement,
            // A truly backgrounded composer has no safe key fallback, so briefly wait
            // for React to expose its semantic Send control. Option-Space/current-input
            // sessions can use one exact-focus HID Return and should not pay the full
            // unavailable-button deadline first; an observed disabled button still waits.
            waitForUnavailableCandidate:
                session.focusMode != .alreadyKeyboardFocused,
            preflight: {
                self.backgroundDeliveryBoundaryMatches(session)
            }
        )
        if !backgroundFocusBoundaryIsSafe(
            session,
            allowReplacementAfterSubmission: true
        ) {
            logger.error("Semantic Send violated the exact user-focus boundary pid=\(session.processIdentifier, privacy: .public)")
            return .failed(AXError.cannotComplete.rawValue)
        }
        return result
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
    /// when their text area ignores synthetic Return. Discovery is intentionally
    /// surface-specific: Claude exposes a direct sibling; current OpenAI builds place
    /// FooterActions in a sibling branch several wrappers away; Telegram's visual slot
    /// is not an Accessibility button and therefore remains foreground-Return-only.
    /// Never treat an arbitrary unlabelled square as Send: OpenAI reuses that slot as
    /// Stop. One exact audited ChatGPT build may use its idle unlabelled button only
    /// after version, uniqueness, geometry, state, and action-time label revalidation.
    func pressNearbySubmitButton(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) async -> NearbySubmitButtonResult {
        guard AXIsProcessTrusted() else {
            return .failed(AXError.apiDisabled.rawValue)
        }
        guard !target.app.isTerminated,
              Self.supportsSemanticSend(bundleIdentifier: target.bundleIdentifier),
              let surface = Self.semanticSendSurface(
                bundleIdentifier: target.bundleIdentifier,
                applicationBundleName: target.app.bundleURL?.lastPathComponent
              ),
              target.hasForegroundInput,
              targetOwnsSystemKeyboardFocus(target),
              let element = liveElement(
                for: target,
                allowApplicationFallback: allowApplicationFallback
              ) else {
            return .unavailable
        }

        return await pressNearbySubmitButton(
            element: element,
            pid: target.pid,
            surface: surface,
            preserveSystemFocusAcrossAction: false,
            // The exact target already owns system keyboard focus. If no labelled Send
            // exists, return promptly to the one-shot normal-HID fallback; only an
            // observed disabled Send warrants readiness polling.
            waitForUnavailableCandidate: false,
            preflight: {
                self.targetOwnsSystemKeyboardFocus(target)
            }
        )
    }

    private func pressNearbySubmitButton(
        element: AXUIElement,
        pid: pid_t,
        surface: SemanticSendSurface,
        preserveSystemFocusAcrossAction: Bool,
        waitForUnavailableCandidate: Bool,
        preflight: () -> Bool
    ) async -> NearbySubmitButtonResult {
        guard surface != .telegramForegroundOnly else {
            // Telegram 12.9 renders the microphone/Send slot as a custom TGUIKit view
            // with no AXButton/AXPress surface. A coordinate click cannot identify the
            // frozen chat while backgrounded. Foreground delivery may instead issue one
            // exact-focus-gated normal Return; background delivery fails closed.
            return .unavailable
        }

        // React may add the Send button after insertion, flip a disabled wrapper, or
        // replace wrapper A with ready wrapper B. Poll the complete surface-specific
        // relationship—not one retained disabled AX object—through the bounded
        // readiness window. Ambiguity, cancellation, or a lost exact-input boundary
        // stops immediately and no action is issued.
        let readinessDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        var readyCandidate: NearbySubmitButtonCandidate?
        var loggedReadinessWait = false
        repeat {
            guard preflight(), !Task.isCancelled else { return .unavailable }
            let lookup = await nearbySubmitButtonLookup(
                element: element,
                pid: pid,
                surface: surface,
                boundary: preflight
            )
            let observation: SemanticSendReadinessObservation = switch lookup {
            case .ready: .ready
            case .disabled: .disabled
            case .unavailable: .unavailable
            case .ambiguous: .ambiguous
            }
            switch Self.semanticSendReadinessDecision(
                for: observation,
                waitForUnavailable: waitForUnavailableCandidate
            ) {
            case .press:
                guard case .ready(let candidate) = lookup else {
                    return .unavailable
                }
                readyCandidate = candidate
            case .wait:
                if !loggedReadinessWait,
                   case .disabled(let candidate) = lookup {
                    logger.info("Waiting for verified semantic Send readiness pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public) label=\(candidate.label, privacy: .public) labelAttribute=\(candidate.labelAttribute, privacy: .public)")
                    loggedReadinessWait = true
                } else if !loggedReadinessWait {
                    logger.info("Waiting for transiently unavailable semantic Send pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public)")
                    loggedReadinessWait = true
                }
            case .stop:
                if observation == .unavailable,
                   !waitForUnavailableCandidate {
                    logger.info("Semantic Send unavailable for exact-focus target; returning immediately to one-shot HID fallback pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public)")
                } else {
                    logger.notice("Semantic Send lookup was ambiguous or its exact boundary was lost; no action issued pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public)")
                }
                return .unavailable
            }
            if readyCandidate != nil { break }
            guard ProcessInfo.processInfo.systemUptime < readinessDeadline else {
                logger.notice("Semantic Send remained unavailable or disabled through readiness deadline pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public)")
                return .unavailable
            }
            try? await Task.sleep(nanoseconds: focusPollInterval)
        } while true

        // React may replace or reparent a control while its enabled state settles.
        // Re-resolve the surface-specific relationship immediately before AXPress and
        // require one currently ready candidate; never hard-code stale ambiguity=true.
        guard readyCandidate != nil,
              preflight(),
              !Task.isCancelled else { return .unavailable }
        let finalCandidate: NearbySubmitButtonCandidate
        switch await nearbySubmitButtonLookup(
            element: element,
            pid: pid,
            surface: surface,
            boundary: preflight
        ) {
        case .ready(let readyCandidate):
            finalCandidate = readyCandidate
        case .disabled, .unavailable, .ambiguous:
            return .unavailable
        }
        return pressVerifiedSubmitButton(
            finalCandidate,
            editor: element,
            pid: pid,
            preserveSystemFocusAcrossAction: preserveSystemFocusAcrossAction,
            preflight: preflight
        )
    }

    private func pressVerifiedSubmitButton(
        _ candidate: NearbySubmitButtonCandidate,
        editor: AXUIElement,
        pid: pid_t,
        preserveSystemFocusAcrossAction: Bool,
        preflight: () -> Bool
    ) -> NearbySubmitButtonResult {
        guard let editorWindow = owningWindow(for: editor),
              let editorFrame = frame(of: editor),
              let candidateFrame = frame(of: candidate.element) else {
            return .unavailable
        }
        let currentLabelEvidence = submitLabelEvidence(for: candidate.element)
        // Re-evaluate the exact app build and absence of every accepted label at the
        // irreversible boundary. If React changed the unlabelled idle Send into its
        // labelled Stop control after discovery, this becomes false and AXPress is
        // never attempted.
        let currentVersionedUnlabelledOpenAIContract =
            candidate.usesVersionedUnlabelledOpenAIContract
            && currentLabelEvidence == nil
            && versionedUnlabelledOpenAISendIsAllowed(
                pid: pid,
                surface: candidate.surface
            )
        var candidatePID: pid_t = 0
        var focusStayedUnchanged = true
        let result = Self.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: AXUIElementGetPid(candidate.element, &candidatePID) == .success
                && candidatePID == pid,
            windowMatches: owningWindow(for: candidate.element).map({
                CFEqual($0, editorWindow)
            }) == true,
            geometryMatches: Self.semanticSendGeometryMatches(
                surface: candidate.surface,
                editorFrame: editorFrame,
                candidateFrame: candidateFrame
            ),
            roleMatches: stringAttribute(kAXRoleAttribute, from: candidate.element)
                == kAXButtonRole,
            enabled: boolAttribute(kAXEnabledAttribute, from: candidate.element)
                == true,
            label: currentLabelEvidence?.label,
            labelAttribute: currentLabelEvidence?.attribute,
            allowsVersionedUnlabelledOpenAISend:
                currentVersionedUnlabelledOpenAIContract,
            hasPressAction: actionNames(from: candidate.element)
                .contains(kAXPressAction),
            boundaryMatches: !Task.isCancelled && preflight()
        ) {
            guard !Task.isCancelled, preflight() else {
                return AXError.cannotComplete.rawValue
            }
            let focusBeforeAction = preserveSystemFocusAcrossAction
                ? systemFocusedElement()
                : nil
            guard !preserveSystemFocusAcrossAction
                    || focusBeforeAction != nil else {
                return AXError.cannotComplete.rawValue
            }
            let actionResult = AXUIElementPerformAction(
                candidate.element,
                kAXPressAction as CFString
            )
            if let focusBeforeAction {
                let focusAfterAction = systemFocusedElement()
                focusStayedUnchanged = focusAfterAction?.pid
                    == focusBeforeAction.pid
                    && focusAfterAction.map {
                        CFEqual($0.element, focusBeforeAction.element)
                    } == true
            }
            let deltaX = Int(candidateFrame.midX - editorFrame.maxX)
            let deltaY = Int(candidateFrame.midY - editorFrame.maxY)
            logger.info("Verified semantic Send press attempted pid=\(pid, privacy: .public) surface=\(candidate.surface.rawValue, privacy: .public) label=\(candidate.label, privacy: .public) labelAttribute=\(candidate.labelAttribute, privacy: .public) ancestorIndex=\(candidate.ancestorIndex, privacy: .public) discoveredDepth=\(candidate.discoveredDepth, privacy: .public) deltaX=\(deltaX, privacy: .public) deltaY=\(deltaY, privacy: .public) result=\(actionResult.rawValue, privacy: .public)")
            return actionResult.rawValue
        }
        guard focusStayedUnchanged else {
            logger.error("Semantic Send changed Ethan's current system-focused input during direct exact delivery pid=\(pid, privacy: .public) surface=\(candidate.surface.rawValue, privacy: .public)")
            return .failed(AXError.cannotComplete.rawValue)
        }
        if result == .unavailable {
            logger.notice("Semantic Send changed identity, label, enabled state, geometry, or exact-input boundary immediately before press pid=\(pid, privacy: .public) surface=\(candidate.surface.rawValue, privacy: .public)")
        }
        return result
    }

    private func nearbySubmitButtonLookup(
        element: AXUIElement,
        pid: pid_t,
        surface: SemanticSendSurface,
        allowStopForComposerTopology: Bool = false,
        boundary: () -> Bool = { true }
    ) async -> NearbySubmitButtonLookup {
        guard boundary() else { return .unavailable }
        switch surface {
        case .claudeDesktop:
            return claudeSubmitButtonLookup(
                element: element,
                pid: pid,
                allowStopForComposerTopology: allowStopForComposerTopology,
                boundary: boundary
            )
        case .openAIChatGPT, .openAICodex:
            return await openAISubmitButtonLookup(
                element: element,
                pid: pid,
                surface: surface,
                allowStopForComposerTopology: allowStopForComposerTopology,
                boundary: boundary
            )
        case .telegramForegroundOnly:
            return .unavailable
        }
    }

    /// Claude Desktop 1.21459.3 exposes the exact Prompt AXTextArea and a single Send
    /// AXButton as direct siblings in one 44-point composer group. Its React can-send
    /// state can lag the AXValue mutation briefly, so lookup returns the disabled
    /// candidate for bounded readiness polling instead of broad-scanning the window.
    private func claudeSubmitButtonLookup(
        element: AXUIElement,
        pid: pid_t,
        allowStopForComposerTopology: Bool,
        boundary: () -> Bool
    ) -> NearbySubmitButtonLookup {
        guard boundary(),
              let parent = elementAttribute(kAXParentAttribute, from: element),
              let editorWindow = owningWindow(for: element),
              let editorFrame = frame(of: element) else {
            return .unavailable
        }
        let candidates = elementArrayAttribute(kAXChildrenAttribute, from: parent)
            .compactMap {
                semanticSendCandidate(
                    $0,
                    editor: element,
                    editorWindow: editorWindow,
                    editorFrame: editorFrame,
                    pid: pid,
                    surface: .claudeDesktop,
                    ancestorIndex: 0,
                    discoveredDepth: 1,
                    allowStopForComposerTopology: allowStopForComposerTopology
                )
            }
        return boundary() ? semanticSendLookup(from: candidates) : .unavailable
    }

    /// ChatGPT and Codex place FooterActions in a sibling branch of the editor's
    /// ancestor chain. The v2.0.211 framed-container/editor±100 search visited only 24
    /// nodes and never reached that real branch. Walk only sibling subtrees as the exact
    /// editor ascends—never its chat-history subtree or the whole AXWindow—and stop at
    /// the nearest ancestor containing exactly one explicit Send AXButton. Delivery can
    /// overlap a newer recording, so the bounded walk yields cooperatively below rather
    /// than monopolizing MainActor and delaying recorder/shortcut updates.
    private func openAISubmitButtonLookup(
        element: AXUIElement,
        pid: pid_t,
        surface: SemanticSendSurface,
        allowStopForComposerTopology: Bool,
        boundary: () -> Bool
    ) async -> NearbySubmitButtonLookup {
        guard boundary(),
              let editorFrame = frame(of: element),
              let editorWindow = owningWindow(for: element) else {
            return .unavailable
        }

        let searchStarted = ProcessInfo.processInfo.systemUptime
        let deadline = searchStarted + 0.35
        let traversalState = BoundedTraversalState(nodeBudget: 1_600)
        let allowsVersionedUnlabelledOpenAISend =
            versionedUnlabelledOpenAISendIsAllowed(
                pid: pid,
                surface: surface
            )
        var visitedNodeCount = 0
        var editorBranch = element
        var ancestor = elementAttribute(kAXParentAttribute, from: element)
        for ancestorIndex in 0..<16 {
            guard traversalState.remainingNodeBudget > 0,
                  ProcessInfo.processInfo.systemUptime < deadline,
                  boundary() else {
                break
            }
            guard let container = ancestor,
                  !CFEqual(container, editorWindow) else { break }
            ancestor = elementAttribute(kAXParentAttribute, from: container)

            var candidates: [NearbySubmitButtonCandidate] = []
            let siblingBranches = traversalChildren(of: container)
                .filter { !CFEqual($0, editorBranch) }
            var traversalCompleted = true
            for sibling in siblingBranches {
                let traversal = await visitBoundedDescendants(
                    of: sibling,
                    maximumDepth: 10,
                    state: traversalState,
                    deadline: deadline,
                    boundary: boundary,
                    visitor: { candidateElement, discoveredDepth in
                        if let candidate = self.semanticSendCandidate(
                            candidateElement,
                            editor: element,
                            editorWindow: editorWindow,
                            editorFrame: editorFrame,
                            pid: pid,
                            surface: surface,
                            ancestorIndex: ancestorIndex,
                            discoveredDepth: discoveredDepth,
                            allowStopForComposerTopology:
                                allowStopForComposerTopology,
                            allowsVersionedUnlabelledOpenAISend:
                                allowsVersionedUnlabelledOpenAISend
                        ) {
                            candidates.append(candidate)
                        }
                        // Two distinct explicit Send controls in the same nearest
                        // composer ancestor are ambiguous; stop before walking more.
                        return self.semanticSendUniqueCount(candidates) < 2
                    }
                )
                visitedNodeCount += traversal.visitedCount
                switch traversal.completion {
                case .completed:
                    break
                case .stoppedByVisitor:
                    return .ambiguous
                case .exhausted, .cancelled, .boundaryChanged:
                    traversalCompleted = false
                }
                guard traversalCompleted else { break }
            }

            guard traversalCompleted else { break }

            let lookup = semanticSendLookup(from: candidates)
            switch lookup {
            case .ready(let candidate), .disabled(let candidate):
                let elapsedMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
                )
                logger.info("Resolved OpenAI FooterActions Send sibling pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public) label=\(candidate.label, privacy: .public) labelAttribute=\(candidate.labelAttribute, privacy: .public) ancestorIndex=\(ancestorIndex, privacy: .public) discoveredDepth=\(candidate.discoveredDepth, privacy: .public) nodesVisited=\(visitedNodeCount, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return lookup
            case .ambiguous:
                let elapsedMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
                )
                logger.notice("OpenAI shared composer ancestor had ambiguous Send buttons pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public) ancestorIndex=\(ancestorIndex, privacy: .public) nodesVisited=\(visitedNodeCount, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return .ambiguous
            case .unavailable:
                break
            }
            editorBranch = container
        }

        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
        )
        logger.notice("Bounded OpenAI FooterActions sibling search found no candidate pid=\(pid, privacy: .public) surface=\(surface.rawValue, privacy: .public) nodesVisited=\(visitedNodeCount, privacy: .public) remainingNodeBudget=\(traversalState.remainingNodeBudget, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
        return .unavailable
    }

    private func semanticSendCandidate(
        _ candidateElement: AXUIElement,
        editor: AXUIElement,
        editorWindow: AXUIElement,
        editorFrame: CGRect,
        pid: pid_t,
        surface: SemanticSendSurface,
        ancestorIndex: Int,
        discoveredDepth: Int,
        allowStopForComposerTopology: Bool,
        allowsVersionedUnlabelledOpenAISend: Bool = false
    ) -> NearbySubmitButtonCandidate? {
        var candidatePID: pid_t = 0
        let labelEvidence = submitLabelEvidence(for: candidateElement)
        // The exact audited ChatGPT build omits an aria-label only for idle Send and
        // adds an explicit Stop label when the same slot changes state. Treat absence
        // of all accepted label attributes as versioned evidence, never as a generic
        // button rule. Final action re-reads both the app build and label so a live
        // Send-to-Stop transition cannot cross this boundary.
        let usesVersionedUnlabelledOpenAIContract =
            labelEvidence == nil
            && allowsVersionedUnlabelledOpenAISend
            && !allowStopForComposerTopology
        guard !CFEqual(candidateElement, editor),
              AXUIElementGetPid(candidateElement, &candidatePID) == .success,
              candidatePID == pid,
              stringAttribute(kAXRoleAttribute, from: candidateElement)
                == kAXButtonRole,
              ((labelEvidence.map {
                    Self.isExplicitSemanticSendEvidence(
                        label: $0.label,
                        attribute: $0.attribute
                    )
                 } == true)
                || (allowStopForComposerTopology
                    && labelEvidence.map {
                        Self.isExplicitSemanticStopEvidence(
                            label: $0.label,
                            attribute: $0.attribute
                        )
                    } == true)
                || usesVersionedUnlabelledOpenAIContract),
              actionNames(from: candidateElement).contains(kAXPressAction),
              owningWindow(for: candidateElement).map({
                CFEqual($0, editorWindow)
              }) == true,
              let candidateFrame = frame(of: candidateElement),
              Self.semanticSendGeometryMatches(
                surface: surface,
                editorFrame: editorFrame,
                candidateFrame: candidateFrame
              ) else {
            return nil
        }
        let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)
        return NearbySubmitButtonCandidate(
            element: candidateElement,
            label: labelEvidence?.label ?? "versioned-unlabelled-send",
            labelAttribute: labelEvidence?.attribute ?? "OpenAIBundleContract",
            usesVersionedUnlabelledOpenAIContract:
                usesVersionedUnlabelledOpenAIContract,
            score: abs(center.x - editorFrame.maxX)
                + abs(center.y - editorFrame.maxY),
            ancestorIndex: ancestorIndex,
            discoveredDepth: discoveredDepth,
            surface: surface,
            enabled: boolAttribute(kAXEnabledAttribute, from: candidateElement)
        )
    }

    private func semanticSendLookup(
        from candidates: [NearbySubmitButtonCandidate]
    ) -> NearbySubmitButtonLookup {
        var unique: [NearbySubmitButtonCandidate] = []
        for candidate in candidates.sorted(by: { $0.score < $1.score }) {
            guard !unique.contains(where: {
                CFEqual($0.element, candidate.element)
            }) else { continue }
            unique.append(candidate)
        }
        guard unique.count == 1, let candidate = unique.first else {
            return unique.isEmpty ? .unavailable : .ambiguous
        }
        switch candidate.enabled {
        case true:
            return .ready(candidate)
        case false:
            return .disabled(candidate)
        case nil:
            return .unavailable
        }
    }

    private func semanticSendUniqueCount(
        _ candidates: [NearbySubmitButtonCandidate]
    ) -> Int {
        var unique: [AXUIElement] = []
        for candidate in candidates where !unique.contains(where: {
            CFEqual($0, candidate.element)
        }) {
            unique.append(candidate.element)
            if unique.count == 2 { break }
        }
        return unique.count
    }

    static func semanticSendGeometryMatches(
        surface: SemanticSendSurface,
        editorFrame: CGRect,
        candidateFrame: CGRect
    ) -> Bool {
        guard candidateFrame.width >= 14,
              candidateFrame.width <= 96,
              candidateFrame.height >= 14,
              candidateFrame.height <= 96 else {
            return false
        }
        let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)
        switch surface {
        case .claudeDesktop:
            return editorFrame.insetBy(dx: -100, dy: -100).contains(center)
        case .openAIChatGPT, .openAICodex:
            return editorFrame.insetBy(dx: -360, dy: -320).contains(center)
        case .telegramForegroundOnly:
            return false
        }
    }

    /// Bring a known application to the foreground and verify that macOS actually
    /// made it frontmost. This is restricted to explicit foreground/legacy fallbacks
    /// and post-delivery workspace restoration. Saved background targets and same-app/
    /// different-input delivery must never call it. `NSRunningApplication.activate`
    /// returned `false` for Codex and VS Code, so the permitted foreground callers and
    /// workspace restoration share the `NSWorkspace` fallback here.
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
              owningWindow(
                for: element,
                allowFocusedApplicationFallback: Self.isTelegram(
                    bundleIdentifier: session.bundleIdentifier
                )
              ).map({
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
        if retainedInputOwnsSystemKeyboardFocus(target) {
            return target.element
        }
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
        let hardenedApplicationScopeMatches: Bool
        if target.applicationFallbackIdentity != nil {
            guard let savedWindow,
                  applicationFallbackWindowMatches(
                    target,
                    window: savedWindow,
                    requireFreshCapture: false,
                    requireUniqueSelectedTaskRescan: true
                  ) else {
                // A no-caret recordingStart capture is promoted only inside the exact
                // saved task/window. A later tab/task change invalidates that promoted
                // composer even if Electron reused the same editor geometry or wrapper.
                return nil
            }
            hardenedApplicationScopeMatches = true
        } else {
            hardenedApplicationScopeMatches = false
        }
        // A revalidated task/panel scope plus the retained wrapper's exact structure
        // is already the stronger document boundary. Skip the extra 45 ms history
        // fingerprint in that case so foreground paste and recorder stop stay snappy.
        // Targets without that scope still require their ordinary context proof.
        let scopedRetainedWrapperMayIgnoreContextDrift =
            Self.scopedRetainedWrapperMayIgnoreContextDrift(
                hasHardenedApplicationScope:
                    target.applicationFallbackIdentity != nil,
                captureScopeStillMatches: hardenedApplicationScopeMatches
            )
        let directContextMatches: Bool
        if scopedRetainedWrapperMayIgnoreContextDrift {
            directContextMatches = true
        } else {
            directContextMatches = target.identity.map { identity in
                guard let savedWindow else { return false }
                let currentContextResult = contextFingerprint(
                    in: savedWindow,
                    region: identity.contextRegion,
                    excluding: Self.isTelegram(
                        bundleIdentifier: target.bundleIdentifier
                    ) ? target.element : nil,
                    bundleIdentifier: target.bundleIdentifier
                )
                let hasInstanceSpecificIdentifier = Self
                    .exactInputIdentifierHasInstanceEvidence(
                        identifier: identity.identifier,
                        domIdentifier: identity.domIdentifier
                    )
                if !currentContextResult.completed {
                    return !Self.isTelegram(
                        bundleIdentifier: target.bundleIdentifier
                    )
                        && identity.primaryContextAnchors.isEmpty
                        && identity.contextAnchors.isEmpty
                        && hasInstanceSpecificIdentifier
                }
                let currentContext = currentContextResult.selection
                return Self.directCapturedElementContextAllowed(
                    bundleIdentifier: target.bundleIdentifier,
                    hasInstanceSpecificIdentifier:
                        hasInstanceSpecificIdentifier,
                    capturedPrimaryContextAnchors: identity.primaryContextAnchors,
                    capturedContextAnchors: identity.contextAnchors,
                    currentPrimaryContextAnchors: currentContext.primary,
                    currentContextAnchors: currentContext.secondary
                )
            } ?? true
        }
        // Context beside an OpenAI/Claude composer can legitimately change while a
        // response streams. Ignore that drift only for the exact retained AX wrapper
        // and only after the capture-time selected-task/floating-panel scope above was
        // revalidated. This remains safe while backgrounded: the selected task proves
        // document ownership, exactStructureMatches below proves the same composer,
        // and the delivery boundary separately forbids app activation/focus theft.
        // A replaced wrapper still requires its normal context/identity proof.
        if let element = target.element,
           let identity = target.identity,
           let savedWindow,
           directContextMatches,
           exactStructureMatches(
            element,
            identity: identity,
            in: savedWindow,
            bundleIdentifier: target.bundleIdentifier,
            requireAncestorPathMatch: !Self
                .retainedFocusedAncestorDriftAllowed(
                    isTelegram: Self.isTelegram(
                        bundleIdentifier: target.bundleIdentifier
                    ),
                    retainedInputOwnsSystemKeyboardFocus:
                        retainedInputOwnsSystemKeyboardFocus(target),
                    directContextMatches: directContextMatches,
                    hasHardenedApplicationScope:
                        hardenedApplicationScopeMatches
                )
           ) {
            return element
        }

        // Electron can replace the AXTextArea wrapper when a paste updates a focused
        // composer. A freshly revalidated selected-task/floating/window scope plus the
        // app's one internally focused semantic main composer is sufficient to adopt
        // that replacement without a descendant search or any focus mutation. This is
        // deliberately unavailable to generic editors, Telegram, modal/search/rename
        // fields, and any task/window whose capture-bound identity drifted.
        if hardenedApplicationScopeMatches,
           let identity = target.identity,
           let savedWindow,
           let replacement = scopedMainComposerReplacement(
            for: target,
            identity: identity,
            in: savedWindow
           ) {
            return replacement
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

    private func scopedMainComposerReplacement(
        for target: Target,
        identity: ExactInputIdentity,
        in window: AXUIElement
    ) -> AXUIElement? {
        guard !Self.isTelegram(bundleIdentifier: target.bundleIdentifier),
              let surface = Self.semanticSendSurface(
                bundleIdentifier: target.bundleIdentifier,
                applicationBundleName: target.applicationBundleName
              ),
              surface != .telegramForegroundOnly else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(target.pid)
        guard let focusedWindow = elementAttribute(
            kAXFocusedWindowAttribute,
            from: appElement
        ), CFEqual(focusedWindow, window),
              let candidate = elementAttribute(
                kAXFocusedUIElementAttribute,
                from: appElement
              ),
              target.element.map({ !CFEqual($0, candidate) }) == true,
              exactStructureMatches(
                candidate,
                identity: identity,
                in: window,
                bundleIdentifier: target.bundleIdentifier,
                requireAncestorPathMatch: false
              ),
              Self.elementGeometryMatches(
                isSameRetainedWrapper: false,
                expectedFrame: identity.relativeFrame,
                currentFrame: relativeFrame(of: candidate, in: window)
              ),
              Self.exactMainComposerCaptureEvidenceMatches(
                surface: surface,
                description: nonEmptyStringAttribute(
                    kAXDescriptionAttribute,
                    from: candidate
                ),
                placeholder: nonEmptyStringAttribute(
                    kAXPlaceholderValueAttribute,
                    from: candidate
                ),
                windowIsModal: boolAttribute(
                    kAXModalAttribute,
                    from: window
                ) == true,
                hasDisallowedSecondaryAncestor:
                    hasDisallowedSecondaryComposerAncestor(
                        candidate,
                        stoppingAt: window
                    )
              ), target.applicationFallbackIdentity?.scopes.allSatisfy({ scope in
                  // Every scope kind owns product identity. Restricting this check to
                  // selected-task rows let a stable task-document window adopt a
                  // ChatGPT wrapper after capturing Codex (or vice versa).
                  Self.recordingStartComposerScopeEvidenceMatches(
                      scopeKind: scope.kind,
                      hostSurface: surface,
                      scopeSurface: scope.scopeSurface,
                      description: nonEmptyStringAttribute(
                          kAXDescriptionAttribute,
                          from: candidate
                      ),
                      placeholder: nonEmptyStringAttribute(
                          kAXPlaceholderValueAttribute,
                          from: candidate
                      )
                  )
              }) != false else {
            return nil
        }
        return candidate
    }

    /// Failure telemetry intentionally reports only booleans, counts, roles, and AX
    /// hashes—never chat titles or message text. This distinguishes an empty/mismatched
    /// Telegram context from a stale window, replaced wrapper, or ambiguous editor tree
    /// without leaking the user's conversation into unified logs.
    private func exactInputResolutionDiagnostics(for target: Target) -> String {
        let savedWindow = liveWindow(for: target, resolvedElement: nil)
        let identity = target.identity
        let currentContextResult: ContextFingerprintResult? = if let savedWindow, let identity {
            contextFingerprint(
                in: savedWindow,
                region: identity.contextRegion,
                excluding: Self.isTelegram(bundleIdentifier: target.bundleIdentifier)
                    ? target.element
                    : nil,
                bundleIdentifier: target.bundleIdentifier
            )
        } else {
            nil
        }
        let currentContext = currentContextResult?.selection
            ?? ContextAnchorSelection(primary: [], secondary: [])
        let directContextMatches = identity.map {
            currentContextResult?.completed == true
                && Self.directCapturedElementContextAllowed(
                bundleIdentifier: target.bundleIdentifier,
                hasInstanceSpecificIdentifier: Self
                    .exactInputIdentifierHasInstanceEvidence(
                        identifier: $0.identifier,
                        domIdentifier: $0.domIdentifier
                    ),
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
            exactStructureMatches(
                element,
                identity: identity,
                in: savedWindow,
                bundleIdentifier: target.bundleIdentifier
            )
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
        return "bundle=\(target.bundleIdentifier ?? "nil") savedWindow=\(savedWindow != nil) identity=\(identity != nil) contextComplete=\(currentContextResult?.completed == true) capturedPrimary=\(identity?.primaryContextAnchors.count ?? 0) currentPrimary=\(currentContext.primary.count) capturedSecondary=\(identity?.contextAnchors.count ?? 0) currentSecondary=\(currentContext.secondary.count) matchedSecondary=\(contextMatchCount) directContext=\(directContextMatches) directStructure=\(directStructureMatches) roleCandidates=\(matchingRoleCandidateCount) currentFocusPid=\(focused?.pid ?? -1) currentFocusMatchesSaved=\(currentFocusMatchesSaved)"
    }

    private func exactStructureMatches(
        _ element: AXUIElement,
        identity: ExactInputIdentity,
        in window: AXUIElement,
        bundleIdentifier: String?,
        requireAncestorPathMatch: Bool = true
    ) -> Bool {
        guard stringAttribute(kAXRoleAttribute, from: element) == identity.role,
              stringAttribute(kAXSubroleAttribute, from: element) == identity.subrole,
              owningWindow(
                for: element,
                allowFocusedApplicationFallback: Self.isTelegram(
                    bundleIdentifier: bundleIdentifier
                )
              ).map({ CFEqual($0, window) }) == true,
              (!requireAncestorPathMatch
                || ancestorPath(from: element, through: window)
                    == identity.ancestorPath),
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

    /// Electron may reparent the exact same, still-system-focused composer when the
    /// modifier macro arrives. Ancestor drift alone is harmless only for that retained
    /// wrapper after current context or a freshly revalidated task/panel scope proves
    /// ownership. A stable AX/DOM identifier is deliberately not required here: the
    /// retained-wrapper equality plus live system keyboard focus is the stronger
    /// foreground proof, and v2.0.211 showed that Codex may expose no such identifier
    /// while merely reparenting its real composer. Replacement wrappers and Telegram
    /// remain fully structural.
    static func retainedFocusedAncestorDriftAllowed(
        isTelegram: Bool,
        retainedInputOwnsSystemKeyboardFocus: Bool,
        directContextMatches: Bool,
        hasHardenedApplicationScope: Bool
    ) -> Bool {
        !isTelegram
            && retainedInputOwnsSystemKeyboardFocus
            && (directContextMatches || hasHardenedApplicationScope)
    }

    private func liveWindow(
        for target: Target,
        resolvedElement: AXUIElement?
    ) -> AXUIElement? {
        if let resolvedElement,
           let window = owningWindow(
            for: resolvedElement,
            allowFocusedApplicationFallback: Self.isTelegram(
                bundleIdentifier: target.bundleIdentifier
            )
           ) {
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
        bundleIdentifier: String?,
        hasHardenedApplicationScope: Bool = false
    ) -> ExactInputIdentity? {
        guard let role = stringAttribute(kAXRoleAttribute, from: element) else { return nil }
        let identifier = nonEmptyStringAttribute(
            kAXIdentifierAttribute,
            from: element
        )
        let domIdentifier = nonEmptyStringAttribute(
            "AXDOMIdentifier",
            from: element
        )
        let contextRegion = contentRegion(for: element, in: window)
        let context: ContextAnchorSelection
        if hasHardenedApplicationScope {
            // The selected task/panel is already a stronger boundary than volatile
            // nearby message text. Keep context empty so resolution can use this
            // identity only for the retained, still-system-focused wrapper; replacement
            // or background recovery remains fail-closed unless stable IDs exist.
            context = ContextAnchorSelection(primary: [], secondary: [])
        } else {
            let contextResult = contextFingerprint(
                in: window,
                region: contextRegion,
                excluding: element,
                bundleIdentifier: bundleIdentifier
            )
            if contextResult.completed {
                context = contextResult.selection
                if context.primary.isEmpty,
                   context.secondary.isEmpty,
                   bundleIdentifier.map(
                        Self.exactWrapperRequiresIdentityOrContextBundleIdentifiers
                            .contains
                   ) == true {
                    logger.notice("Exact-input capture rejected empty context without a hardened renderer task/document scope bundle=\(bundleIdentifier ?? "nil", privacy: .public)")
                    return nil
                }
            } else if !Self.isTelegram(bundleIdentifier: bundleIdentifier),
                      bundleIdentifier.map(
                        Self.exactWrapperRequiresIdentityOrContextBundleIdentifiers
                            .contains
                      ) != true,
                      Self.exactInputIdentifierHasInstanceEvidence(
                        identifier: identifier,
                        domIdentifier: domIdentifier
                      ) {
                // Only an instance-bearing AX/DOM ID can stand in for an exhausted
                // context scan. Generic ids such as `prompt-textarea` are reused across
                // tasks/tabs and therefore remain foreground-only. Telegram is always
                // excluded because readable chat identity is mandatory there.
                context = ContextAnchorSelection(primary: [], secondary: [])
                logger.notice("Exact-input capture retained instance-bearing identifier after bounded context exhaustion bundle=\(bundleIdentifier ?? "nil", privacy: .public)")
            } else {
                logger.notice("Exact-input capture rejected incomplete bounded context fingerprint bundle=\(bundleIdentifier ?? "nil", privacy: .public)")
                return nil
            }
        }
        return ExactInputIdentity(
            role: role,
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            identifier: identifier,
            domIdentifier: domIdentifier,
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

    private func exactInputIdentityBounded(
        for element: AXUIElement,
        in window: AXUIElement,
        bundleIdentifier: String?,
        contextElements: [AXUIElement],
        deadline: TimeInterval,
        hasHardenedApplicationScope: Bool = false,
        boundary: () -> Bool
    ) async -> ExactInputIdentity? {
        guard !Task.isCancelled,
              boundary(),
              ProcessInfo.processInfo.systemUptime < deadline,
              let role = stringAttribute(kAXRoleAttribute, from: element) else {
            return nil
        }
        let contextRegion = contentRegion(for: element, in: window)
        var candidates: [ContextAnchorCandidate] = []
        for (index, candidateElement) in contextElements.enumerated() {
            guard !Task.isCancelled,
                  boundary(),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                return nil
            }
            if index > 0, index.isMultiple(of: 24) {
                guard !Task.isCancelled, boundary() else { return nil }
                await Task.yield()
                guard !Task.isCancelled,
                      boundary(),
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    return nil
                }
            }
            if let candidate = contextAnchorCandidate(
                for: candidateElement,
                in: window,
                region: contextRegion,
                excluding: element,
                bundleIdentifier: bundleIdentifier
            ) {
                candidates.append(candidate)
            }
        }
        guard Self.boundedIdentityEvidenceIsComplete(
            traversalCompleted: true,
            withinDeadline: ProcessInfo.processInfo.systemUptime < deadline,
            boundaryMatches: boundary(),
            isCancelled: Task.isCancelled
        ) else { return nil }
        let context = Self.selectContextAnchors(candidates, limit: 16)
        let identifier = nonEmptyStringAttribute(
            kAXIdentifierAttribute,
            from: element
        )
        let domIdentifier = nonEmptyStringAttribute(
            "AXDOMIdentifier",
            from: element
        )
        if !hasHardenedApplicationScope,
           context.primary.isEmpty,
           context.secondary.isEmpty,
           bundleIdentifier.map(
                Self.exactWrapperRequiresIdentityOrContextBundleIdentifiers.contains
           ) == true {
            return nil
        }
        return ExactInputIdentity(
            role: role,
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            identifier: identifier,
            domIdentifier: domIdentifier,
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
            let currentResult = contextFingerprint(
                in: window,
                region: identity.contextRegion,
                excluding: nil,
                bundleIdentifier: bundleIdentifier
            )
            guard currentResult.completed else { return false }
            let current = currentResult.selection
            return Self.telegramContextFingerprintMatches(
                capturedPrimary: identity.primaryContextAnchors,
                capturedSecondary: identity.contextAnchors,
                currentPrimary: current.primary,
                currentSecondary: current.secondary
            )
        }
        if identity.contextAnchors.isEmpty {
            // Renderer inputs can reuse even UUID-bearing wrapper IDs across tasks and
            // tabs. Their empty context is valid only through the separately revalidated
            // task/document scope that bypasses this function. For simpler native apps,
            // an instance-bearing id may still identify one stable field.
            if bundleIdentifier.map(
                Self.exactWrapperRequiresIdentityOrContextBundleIdentifiers.contains
            ) == true {
                return false
            }
            return Self.exactInputIdentifierHasInstanceEvidence(
                identifier: identity.identifier,
                domIdentifier: identity.domIdentifier
            )
        }
        guard let currentContext = contextAnchors(
            in: window,
            region: identity.contextRegion,
            excluding: nil,
            bundleIdentifier: bundleIdentifier
        ) else { return false }
        return Self.contextFingerprintMatches(
            captured: identity.contextAnchors,
            current: currentContext
        )
    }

    static func directCapturedElementContextAllowed(
        bundleIdentifier: String?,
        hasInstanceSpecificIdentifier: Bool = false,
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
                // Even a UUID-bearing editor wrapper is not a task identity. A hardened
                // task/document scope is checked by the caller before reaching here.
                return false
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

    static func boundedIdentityEvidenceIsComplete(
        traversalCompleted: Bool,
        withinDeadline: Bool,
        boundaryMatches: Bool,
        isCancelled: Bool
    ) -> Bool {
        traversalCompleted
            && withinDeadline
            && boundaryMatches
            && !isCancelled
    }

    nonisolated static func exactInputCaptureIsUsable(
        hasElement: Bool,
        hasIdentity: Bool
    ) -> Bool {
        hasElement && hasIdentity
    }

    static func scopedRetainedWrapperMayIgnoreContextDrift(
        hasHardenedApplicationScope: Bool,
        captureScopeStillMatches: Bool
    ) -> Bool {
        hasHardenedApplicationScope && captureScopeStillMatches
    }

    private func contextAnchors(
        in window: AXUIElement,
        region: CGRect?,
        excluding excludedElement: AXUIElement?,
        bundleIdentifier: String?
    ) -> [String]? {
        let fingerprint = contextFingerprint(
            in: window,
            region: region,
            excluding: excludedElement,
            bundleIdentifier: bundleIdentifier
        )
        guard fingerprint.completed else { return nil }
        return fingerprint.selection.primary + fingerprint.selection.secondary
    }

    private func contextFingerprint(
        in window: AXUIElement,
        region: CGRect?,
        excluding excludedElement: AXUIElement?,
        bundleIdentifier: String?
    ) -> ContextFingerprintResult {
        // Capture and foreground verification run on MainActor. An unbounded walk of a
        // long Telegram/OpenAI history delayed recorder appearance and stop delivery by
        // hundreds of milliseconds. Visible breadth-first traversal keeps the selected
        // header/composer region early, then fails closed with the anchors gathered
        // inside a strict node/time budget instead of monopolizing the UI thread.
        let isTelegram = Self.isTelegram(bundleIdentifier: bundleIdentifier)
        let traversal = boundedVisibleDescendants(
            of: window,
            maximumDepth: 32,
            nodeBudget: isTelegram ? 900 : 650,
            deadline: ProcessInfo.processInfo.systemUptime
                + (isTelegram ? 0.060 : 0.045),
            region: isTelegram ? nil : region,
            relativeTo: window
        )
        let candidates = traversal.elements.compactMap {
            contextAnchorCandidate(
                for: $0,
                in: window,
                region: region,
                excluding: excludedElement,
                bundleIdentifier: bundleIdentifier
            )
        }
        return ContextFingerprintResult(
            selection: Self.selectContextAnchors(candidates, limit: 16),
            completion: traversal.completed ? .completed : .exhausted
        )
    }

    private func contextAnchorCandidate(
        for element: AXUIElement,
        in window: AXUIElement,
        region: CGRect?,
        excluding excludedElement: AXUIElement?,
        bundleIdentifier: String?
    ) -> ContextAnchorCandidate? {
        if let excludedElement, CFEqual(element, excludedElement) { return nil }
        let elementFrame = relativeFrame(of: element, in: window)
        if let region {
            guard let elementFrame, region.intersects(elementFrame) else {
                return nil
            }
        }
        let role = stringAttribute(kAXRoleAttribute, from: element)
        switch role {
        case kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole:
            break
        default:
            return nil
        }
        let rawValue = stringAttribute(kAXValueAttribute, from: element)
            ?? stringAttribute(kAXTitleAttribute, from: element)
        guard let rawValue else { return nil }
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
            return nil
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
        return ContextAnchorCandidate(
            value: anchor,
            isPrimary: isTelegramPrimary
        )
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

    /// A textarea in feedback, search, rename, comment, dialog, or popover chrome can
    /// expose the same placeholder and its own Send button. Those are secondary editors,
    /// not the task composer selected at recording start. The ChatGPT Option-Space panel
    /// is admitted separately by `recordingStartFloatingPanelEvidenceMatches` and is not
    /// a modal, so this rejection does not disable that intentional floating surface.
    private func hasDisallowedSecondaryComposerAncestor(
        _ element: AXUIElement,
        stoppingAt window: AXUIElement
    ) -> Bool {
        let disallowedRoles: Set<String> = [
            "AXDialog", "AXDrawer", "AXMenu", "AXPopover", "AXSheet", "AXSystemDialog"
        ]
        let disallowedTokens: Set<String> = [
            "comment", "comments", "dialog", "feedback", "modal", "popover",
            "preferences", "rename", "search", "settings", "sheet"
        ]
        var current = elementAttribute(kAXParentAttribute, from: element)
        for _ in 0..<30 {
            guard let candidate = current,
                  !CFEqual(candidate, window) else { return false }
            if boolAttribute(kAXModalAttribute, from: candidate) == true {
                return true
            }
            let role = stringAttribute(kAXRoleAttribute, from: candidate)
            let subrole = stringAttribute(kAXSubroleAttribute, from: candidate)
            if role.map(disallowedRoles.contains) == true
                || subrole.map(disallowedRoles.contains) == true {
                return true
            }
            let descriptor = [
                nonEmptyStringAttribute(kAXIdentifierAttribute, from: candidate),
                nonEmptyStringAttribute("AXDOMIdentifier", from: candidate),
                nonEmptyStringAttribute(kAXTitleAttribute, from: candidate),
                nonEmptyStringAttribute(kAXDescriptionAttribute, from: candidate),
                nonEmptyStringAttribute(kAXHelpAttribute, from: candidate)
            ].compactMap { $0 }.joined(separator: " ")
            if !Self.normalizedEvidenceTokens(descriptor).isDisjoint(
                with: disallowedTokens
            ) {
                return true
            }
            current = elementAttribute(kAXParentAttribute, from: candidate)
        }
        return true // An unbounded/invalid parent chain never proves main-composer containment.
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

    private func owningWindow(
        for element: AXUIElement,
        allowFocusedApplicationFallback: Bool = false
    ) -> AXUIElement? {
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

        // Telegram 12.9 can expose its real message AXTextArea without either an
        // AXWindow attribute or a parent chain that reaches AXWindow. Accept the app's
        // focused window only while that same app reports this exact wrapper as its own
        // internally focused element. This repairs foreground primary-stop paste and
        // also keeps every later Telegram chat-context boundary tied to the same editor;
        // a stale/background wrapper or a different input cannot borrow the fallback.
        // The caller must opt in from a Telegram-specific boundary. Applying this
        // focused-window shortcut generically would let any app borrow an unrelated
        // window when its true owning-window chain is missing.
        guard allowFocusedApplicationFallback else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        guard elementAttribute(kAXFocusedUIElementAttribute, from: appElement).map({
            CFEqual($0, element)
        }) == true,
              let focusedWindow = elementAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
              ),
              stringAttribute(kAXRoleAttribute, from: focusedWindow)
                == kAXWindowRole else {
            return nil
        }
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(focusedWindow, &windowPID) == .success,
              windowPID == pid else {
            return nil
        }
        return focusedWindow
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

    private func boundedVisibleDescendants(
        of root: AXUIElement,
        maximumDepth: Int,
        nodeBudget: Int,
        deadline: TimeInterval,
        region: CGRect? = nil,
        relativeTo regionWindow: AXUIElement? = nil
    ) -> (elements: [AXUIElement], completed: Bool) {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var seen = Set<CFHashCode>()
        var truncated = false
        while cursor < queue.count,
              result.count < nodeBudget,
              ProcessInfo.processInfo.systemUptime < deadline {
            let (element, depth) = queue[cursor]
            cursor += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            result.append(element)
            let allChildren = traversalChildren(of: element)
            // Context identity is local to the saved content pane. Pruning visibly
            // disjoint branches avoids rejecting a genuinely focused composer merely
            // because a long sidebar/history makes a whole-window walk exceed its
            // strict shortcut-time budget. Frameless containers remain traversable so
            // Accessibility grouping cannot hide an in-region descendant.
            let children = allChildren.filter { child in
                guard let region, let regionWindow,
                      let childFrame = relativeFrame(
                        of: child,
                        in: regionWindow
                      ) else {
                    return true
                }
                return childFrame.intersects(region)
            }
            guard depth < maximumDepth else {
                if !children.isEmpty { truncated = true }
                continue
            }
            let pendingCount = queue.count - cursor
            let availableSlots = max(
                0,
                nodeBudget - result.count - pendingCount
            )
            if children.count > availableSlots { truncated = true }
            queue.append(contentsOf: children.prefix(availableSlots).map {
                ($0, depth + 1)
            })
        }
        return (
            result,
            cursor >= queue.count
                && !truncated
                && ProcessInfo.processInfo.systemUptime < deadline
        )
    }

    /// Visit each new node inside one shared node/time budget. Candidate matching runs
    /// *during* traversal: collecting first and filtering afterward let the deadline
    /// expire with the real Send already collected but zero nodes ever evaluated. The
    /// cross-ancestor hash set avoids rewalking overlapping React sibling subtrees.
    private func visitBoundedDescendants(
        of root: AXUIElement,
        maximumDepth: Int,
        state: BoundedTraversalState,
        deadline: TimeInterval,
        boundary: () -> Bool = { true },
        shouldDescend: (AXUIElement, Int) -> Bool = { _, _ in true },
        visitor: (AXUIElement, Int) -> Bool
    ) async -> BoundedTraversalResult {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var visitedCount = 0
        var truncated = false
        while cursor < queue.count {
            guard boundary() else {
                return BoundedTraversalResult(
                    visitedCount: visitedCount,
                    completion: .boundaryChanged
                )
            }
            guard !Task.isCancelled else {
                return BoundedTraversalResult(
                    visitedCount: visitedCount,
                    completion: .cancelled
                )
            }
            guard state.remainingNodeBudget > 0,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                return BoundedTraversalResult(
                    visitedCount: visitedCount,
                    completion: .exhausted
                )
            }
            let (element, depth) = queue[cursor]
            cursor += 1
            let hash = CFHash(element)
            guard state.visitedNodeHashes.insert(hash).inserted else {
                // A prior, nearer ancestor already traversed this whole bounded subtree.
                continue
            }
            state.remainingNodeBudget -= 1
            visitedCount += 1
            guard visitor(element, depth) else {
                return BoundedTraversalResult(
                    visitedCount: visitedCount,
                    completion: .stoppedByVisitor
                )
            }
            // Delivery can overlap the start of a newer recording. Yield frequently
            // while reading a React AX sibling subtree so a slow renderer cannot stall
            // the recorder panels or shortcut handling on MainActor.
            if visitedCount.isMultiple(of: 24) {
                guard boundary() else {
                    return BoundedTraversalResult(
                        visitedCount: visitedCount,
                        completion: .boundaryChanged
                    )
                }
                guard !Task.isCancelled else {
                    return BoundedTraversalResult(
                        visitedCount: visitedCount,
                        completion: .cancelled
                    )
                }
                await Task.yield()
                guard boundary() else {
                    return BoundedTraversalResult(
                        visitedCount: visitedCount,
                        completion: .boundaryChanged
                    )
                }
                guard !Task.isCancelled else {
                    return BoundedTraversalResult(
                        visitedCount: visitedCount,
                        completion: .cancelled
                    )
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    return BoundedTraversalResult(
                        visitedCount: visitedCount,
                        completion: .exhausted
                    )
                }
            }
            guard shouldDescend(element, depth) else { continue }
            let children = traversalChildren(of: element)
            guard depth < maximumDepth else {
                if !children.isEmpty { truncated = true }
                continue
            }
            let pendingCount = queue.count - cursor
            let availableQueueSlots = max(
                0,
                state.remainingNodeBudget - pendingCount
            )
            if children.count > availableQueueSlots { truncated = true }
            guard availableQueueSlots > 0 else { continue }
            for child in children.prefix(availableQueueSlots) {
                queue.append((child, depth + 1))
            }
        }
        guard boundary() else {
            return BoundedTraversalResult(
                visitedCount: visitedCount,
                completion: .boundaryChanged
            )
        }
        guard !Task.isCancelled else {
            return BoundedTraversalResult(
                visitedCount: visitedCount,
                completion: .cancelled
            )
        }
        guard !truncated,
              ProcessInfo.processInfo.systemUptime < deadline else {
            return BoundedTraversalResult(
                visitedCount: visitedCount,
                completion: .exhausted
            )
        }
        return BoundedTraversalResult(
            visitedCount: visitedCount,
            completion: .completed
        )
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

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.origin.x - rhs.origin.x)
            + abs(lhs.origin.y - rhs.origin.y)
            + abs(lhs.size.width - rhs.size.width)
            + abs(lhs.size.height - rhs.size.height)
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

    /// Chromium can publish a real subtree exclusively through
    /// `AXChildrenInNavigationOrder`. Prefer the ordinary visible/children routes when
    /// either is populated, then use navigation order only as a last-resort equivalent
    /// child list. This keeps every existing bounded/depth/geometry guard intact while
    /// allowing Codex FooterActions and selected-task controls to remain discoverable.
    static func preferredTraversalChildren<Element>(
        visible: [Element],
        ordinary: @autoclosure () -> [Element],
        navigationOrder: @autoclosure () -> [Element]
    ) -> [Element] {
        guard visible.isEmpty else { return visible }
        let ordinary = ordinary()
        guard ordinary.isEmpty else { return ordinary }
        return navigationOrder()
    }

    private func traversalChildren(of element: AXUIElement) -> [AXUIElement] {
        Self.preferredTraversalChildren(
            visible: elementArrayAttribute(
                kAXVisibleChildrenAttribute,
                from: element
            ),
            ordinary: elementArrayAttribute(kAXChildrenAttribute, from: element),
            navigationOrder: elementArrayAttribute(
                "AXChildrenInNavigationOrder",
                from: element
            )
        )
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

    private func numberAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> NSNumber? {
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

    private func submitLabel(for element: AXUIElement) -> String? {
        submitLabelEvidence(for: element)?.label
    }

    private func submitLabelEvidence(
        for element: AXUIElement
    ) -> (label: String, attribute: String)? {
        [
            (kAXDescriptionAttribute, "AXDescription"),
            (kAXTitleAttribute, "AXTitle"),
            (kAXHelpAttribute, "AXHelp")
        ]
            .lazy
            .compactMap { attribute, name -> (String, String)? in
                guard let value = self.stringAttribute(attribute, from: element),
                      !value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                      ).isEmpty else {
                    return nil
                }
                return (value, name)
            }
            .first
            .map { (label: $0.0, attribute: $0.1) }
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

    static func isExplicitSemanticSendEvidence(
        label: String?,
        attribute: String?
    ) -> Bool {
        explicitSemanticLabelAttributes.contains(attribute ?? "")
            && isProvenSemanticSendLabel(label)
    }

    /// Stop is valid evidence that an inspected textarea is the real agent composer,
    /// but it never authorizes submission. This helper is used only by no-caret
    /// recording-start capture; every actual AXPress gate still requires Send.
    static func isProvenSemanticStopLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "stop", "stop generating", "stop response", "stop-button", "stopbutton":
            return true
        default:
            return false
        }
    }

    static func isExplicitSemanticStopEvidence(
        label: String?,
        attribute: String?
    ) -> Bool {
        explicitSemanticLabelAttributes.contains(attribute ?? "")
            && isProvenSemanticStopLabel(label)
    }

    private static let explicitSemanticLabelAttributes: Set<String> = [
        "AXDescription", "AXHelp", "AXTitle"
    ]

    /// The final semantic-Send gate owns the action closure, making it impossible for
    /// an ambiguous, stale, wrong-process, wrong-window, unaudited-unlabelled, or
    /// boundary-lost candidate to invoke AXPress. The one unlabelled exception is the
    /// exact versioned OpenAI contract re-proven by the caller at action time; a label
    /// appearing (especially Stop) invalidates it. Production supplies
    /// AXUIElementPerformAction; regression tests supply a counter and assert rejected
    /// candidates perform zero side effects.
    static func performProvenSemanticSend(
        isUnambiguous: Bool,
        pidMatches: Bool,
        windowMatches: Bool,
        geometryMatches: Bool,
        roleMatches: Bool,
        enabled: Bool,
        label: String?,
        labelAttribute: String?,
        allowsVersionedUnlabelledOpenAISend: Bool = false,
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
              (isExplicitSemanticSendEvidence(
                    label: label,
                    attribute: labelAttribute
               )
                || (allowsVersionedUnlabelledOpenAISend
                    && label == nil
                    && labelAttribute == nil)),
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
