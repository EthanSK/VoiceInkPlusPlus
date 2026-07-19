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

    struct FocusedInputTextSnapshot {
        let text: String
        let placeholder: String?
    }

    struct ApplicationIdentitySnapshot {
        let applicationBundleName: String
        let bundleIdentifier: String
        let shortVersion: String
        let build: String
        let chromium: String
    }

    enum BackgroundFocusBooleanSlot: CaseIterable, Hashable {
        case targetWindowMain
        case targetWindowFocused
        case targetElementFocused
        case previousWindowMain
        case previousWindowFocused
        case previousElementFocused
    }

    /// Exact readable values from before VoiceInk++ synthesizes internal focus.
    /// Missing values are deliberately omitted: writing a guessed `false` during
    /// teardown is less faithful than leaving an unsupported attribute alone.
    struct BackgroundFocusBooleanSnapshot {
        fileprivate let values: [BackgroundFocusBooleanSlot: Bool]

        init(read: (BackgroundFocusBooleanSlot) -> Bool?) {
            var captured: [BackgroundFocusBooleanSlot: Bool] = [:]
            for slot in BackgroundFocusBooleanSlot.allCases {
                if let value = read(slot) {
                    captured[slot] = value
                }
            }
            values = captured
        }

        @discardableResult
        func restore(
            write: (BackgroundFocusBooleanSlot, Bool) -> Bool
        ) -> Bool {
            var allWritesSucceeded = true
            for slot in BackgroundFocusBooleanSlot.allCases {
                guard let value = values[slot] else { continue }
                if !write(slot, value) {
                    // A stale or unsupported attribute must not prevent later saved
                    // values from being restored. Aggregate the result after making
                    // every safe best-effort write.
                    allWritesSucceeded = false
                }
            }
            return allWritesSucceeded
        }

        func containsAll(_ slots: [BackgroundFocusBooleanSlot]) -> Bool {
            slots.allSatisfy { values[$0] != nil }
        }

        func missing(from slots: [BackgroundFocusBooleanSlot]) -> [BackgroundFocusBooleanSlot] {
            slots.filter { values[$0] == nil }
        }

        func matches(read: (BackgroundFocusBooleanSlot) -> Bool?) -> Bool {
            values.allSatisfy { slot, expected in read(slot) == expected }
        }
    }

    struct BackgroundFocusSessionLifecycle {
        enum State: Equatable {
            case ready
            case activationSessionBegan
            case teardownRetryScheduled
            case teardownWaived
            case finished
        }

        private(set) var state: State = .ready
        var canBegin: Bool { state == .ready }
        var requiresTeardown: Bool {
            state == .activationSessionBegan || state == .teardownRetryScheduled
        }

        mutating func begin(open: () -> Bool) -> Bool {
            guard state == .ready else { return false }
            guard open() else { return false }
            state = .activationSessionBegan
            return true
        }

        /// Keep an unsafe/indeterminate teardown retryable rather than falsely marking
        /// the synthetic activation session finished before its paired end was posted.
        mutating func markTeardownRetryScheduled() -> Bool {
            guard state == .activationSessionBegan else { return false }
            state = .teardownRetryScheduled
            return true
        }

        mutating func waiveTeardown() -> Bool {
            guard requiresTeardown else { return false }
            state = .teardownWaived
            return true
        }

        /// Posts the paired end exactly once for any opened or deferred session.
        mutating func finish(postTeardown: () -> Void) -> Bool {
            guard requiresTeardown else { return false }
            postTeardown()
            state = .finished
            return true
        }
    }

    final class BackgroundDeliverySession {
        fileprivate enum Mode: Equatable {
            case preparedTargetedInput
            case directExactElement
        }

        fileprivate let target: Target
        fileprivate let element: AXUIElement
        fileprivate let window: AXUIElement
        fileprivate let app: NSRunningApplication
        fileprivate let mode: Mode
        fileprivate let frontmostPIDAtPreparation: pid_t
        fileprivate let previouslyFocusedWindow: AXUIElement?
        fileprivate let previouslyFocusedElement: AXUIElement?
        fileprivate let previouslyFocusedElementWasAbsent: Bool
        fileprivate let focusBooleanSnapshot: BackgroundFocusBooleanSnapshot
        fileprivate var lifecycle = BackgroundFocusSessionLifecycle()
        fileprivate var teardownRetryCount = 0
        let processIdentifier: pid_t
        let bundleIdentifier: String?

        fileprivate init(
            target: Target,
            element: AXUIElement,
            window: AXUIElement,
            app: NSRunningApplication,
            mode: Mode,
            frontmostPIDAtPreparation: pid_t,
            previouslyFocusedWindow: AXUIElement?,
            previouslyFocusedElement: AXUIElement?,
            previouslyFocusedElementWasAbsent: Bool,
            focusBooleanSnapshot: BackgroundFocusBooleanSnapshot,
            processIdentifier: pid_t,
            bundleIdentifier: String?
        ) {
            self.target = target
            self.element = element
            self.window = window
            self.app = app
            self.mode = mode
            self.frontmostPIDAtPreparation = frontmostPIDAtPreparation
            self.previouslyFocusedWindow = previouslyFocusedWindow
            self.previouslyFocusedElement = previouslyFocusedElement
            self.previouslyFocusedElementWasAbsent = previouslyFocusedElementWasAbsent
            self.focusBooleanSnapshot = focusBooleanSnapshot
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
        }

        var frontmostProcessIdentifierAtPreparation: pid_t {
            frontmostPIDAtPreparation
        }
        var usesPreparedTargetedInput: Bool {
            mode == .preparedTargetedInput
        }
        var diagnosticMode: String {
            switch mode {
            case .preparedTargetedInput: "preparedTargetedInput"
            case .directExactElement: "directExactElement"
            }
        }
        @MainActor
        var diagnosticApplicationIdentity: ApplicationIdentitySnapshot {
            FocusLockService.applicationIdentitySnapshot(for: app)
        }
    }

    enum NearbySubmitButtonResult: Equatable {
        case pressed
        case targetedClick
        case unavailable
        case focusLostBeforeAction
        case refusedAfterCandidate
        case failed(Int32)
    }

    enum BackgroundTextInsertionResult: Equatable {
        case acceptedSelectedText
        case unavailable
        case failed(Int32)
        case focusSafetyViolation
    }

    private struct NearbySubmitButtonCandidate {
        let element: AXUIElement
        let usesAuditedUnlabelledContract: Bool
        let score: CGFloat
    }

    private enum NearbySubmitButtonLookup {
        case ready(NearbySubmitButtonCandidate)
        case unavailable
        case ambiguous
        case boundaryChanged
    }

    /// `nil` is not proof that an OpenAI button is genuinely unlabelled: AX can also
    /// return no string when the renderer is busy or the wrapper has gone stale. Keep
    /// those states distinct so a failed label read can never inherit the audited
    /// unlabelled-Send exception and accidentally press Stop.
    private enum SubmitLabelState {
        case labelled(String)
        case unlabelled
        case unreadable
    }

    enum ElementReferenceAvailability: Equatable {
        case value
        case absent
        case failed
    }

    /// Pointer-valued AX reads must distinguish a genuinely absent value from a
    /// transport/read failure. Electron commonly exposes a focused window but no
    /// focused UI element while inactive. That explicit absence is valid state: the
    /// bounded session restores the target's prior `AXFocused=false` and accepts only
    /// absence or that same inactive retained pointer. A failed read remains unsafe.
    private enum ElementReferenceRead {
        case value(AXUIElement)
        case absent
        case failed(Int32)

        var availability: ElementReferenceAvailability {
            switch self {
            case .value: return .value
            case .absent: return .absent
            case .failed: return .failed
            }
        }

        var diagnostic: String {
            switch self {
            case .value:
                return "value"
            case .absent:
                return "absent"
            case .failed(let error):
                return "failed(\(error))"
            }
        }
    }

    enum BackgroundTeardownBoundaryStatus: Equatable {
        case safe
        case targetOwnsSystemFocus
        case targetTerminated
        case frontmostUnavailable
        case systemFocusUnavailable
    }

    enum BackgroundTeardownDecision: Equatable {
        case restoreNow
        case retryFullRestoration
        case finishPartialAndEnd
        case waiveWithoutMutation
    }

    static func priorFocusedElementReadIsRestorable(
        _ availability: ElementReferenceAvailability
    ) -> Bool {
        availability != .failed
    }

    /// Public AX cannot write a nil focused-element pointer back into Electron. When
    /// the exact pre-session state was explicitly absent, restoration is nevertheless
    /// safe if Electron either reports absence again or retains only the same target
    /// pointer with its readable focused boolean restored to the exact prior `false`.
    /// A different retained element, an unreadable state, or a focused target fails.
    static func absentPriorFocusedElementRestorationMatches(
        restoredAvailability: ElementReferenceAvailability,
        restoredElementMatchesTarget: Bool,
        restoredTargetFocused: Bool?,
        expectedTargetFocused: Bool?
    ) -> Bool {
        if restoredAvailability == .absent { return true }
        return restoredAvailability == .value
            && restoredElementMatchesTarget
            && expectedTargetFocused == false
            && restoredTargetFocused == expectedTargetFocused
    }

    private final class BoundedTraversalState {
        var remainingNodeBudget: Int
        var visitedNodeHashes = Set<CFHashCode>()
        var navigationChildEdges = 0
        var visibleChildEdges = 0
        var ordinaryChildEdges = 0
        var mergedChildEdges = 0
        var buttonNodes = 0
        var labelledSendButtons = 0
        var labelledOtherButtons = 0
        var unlabelledButtons = 0
        var unreadableLabelButtons = 0
        var auditedUnlabelledButtons = 0
        var enabledButtons = 0
        var disabledButtons = 0
        var unreadableEnabledButtons = 0
        var pressableButtons = 0
        var unpressableButtons = 0
        var matchingWindowButtons = 0
        var mismatchedWindowButtons = 0
        var readableFrameButtons = 0
        var unreadableFrameButtons = 0
        var matchingGeometryButtons = 0
        var mismatchedGeometryButtons = 0

        init(nodeBudget: Int) {
            remainingNodeBudget = nodeBudget
        }
    }

    private enum BoundedTraversalCompletion {
        case completed
        case exhausted
        case cancelled
        case boundaryChanged
        case stoppedByVisitor
    }

    private struct BoundedTraversalResult {
        let completion: BoundedTraversalCompletion
    }

    static let shared = FocusLockService()
    static let longPressThreshold: TimeInterval = 0.45

    @Published private(set) var isLockActive = false
    private(set) var stopHoldDecisionPending = false

    private let logger = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "FocusLock")
    private static let semanticSendNodeBudget = 1_600
    private static let semanticSendSearchSeconds = 0.35
    // The separately installed Codex and ChatGPT apps share `com.openai.codex` but
    // have different bundle paths and release trains. Offline inspection of each
    // exact app.asar proves its idle Send control is the sole enabled unlabelled
    // composer button, while the same control gains an explicit Stop label once a
    // turn runs. Pin both the real .app name and full build tuple: a product update
    // must fail closed until its renderer is audited again.
    private static let auditedCodexSubmitBuild = (
        applicationBundleName: "Codex.app",
        shortVersion: "26.707.72221",
        build: "5307",
        chromium: "150.0.7871.115"
    )
    private static let auditedChatGPTSubmitBuild = (
        applicationBundleName: "ChatGPT.app",
        shortVersion: "26.715.31925",
        build: "5551",
        chromium: "150.0.7871.124"
    )

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
            // modifiers are down. Preserve the owning app only for recording-start/Next.
            // Delivery may promote this to the already-frontmost app's one exact focused
            // editor; it must never activate a background fallback or guess from retained
            // application focus.
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

    /// Prepare one exact saved editor for non-activating delivery. A background
    /// Electron target gets exactly one bounded internal activation-state session.
    /// When the saved app is frontmost but another input owns the keyboard, no internal
    /// focus is rewritten; that route may use only direct AXSelectedText insertion.
    func prepareBackgroundDelivery(to target: Target) async -> BackgroundDeliverySession? {
        guard AXIsProcessTrusted() else {
            logger.error("Background exact-input preparation requires Accessibility permission pid=\(target.pid, privacy: .public)")
            return nil
        }
        guard target.hasExactInput else {
            logger.error("Background exact-input preparation received no saved exact element pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard !target.app.isTerminated else {
            logger.error("Background exact-input preparation target app is terminated pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard let keyboardFocus = await systemFocusedElementWithBoundedRetry() else {
            logger.error("Background exact-input preparation could not read current system keyboard focus after bounded retry pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier else {
            logger.error("Background exact-input preparation could not read the frontmost application pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard let element = resolvedExactElement(for: target) else {
            logger.error("Background exact-input preparation could not resolve the saved element pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }
        guard let window = liveWindow(for: target, resolvedElement: element) else {
            logger.error("Background exact-input preparation could not resolve the saved window pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public)")
            return nil
        }

        let exactInputOwnsKeyboardFocus = keyboardFocus.pid == target.pid
            && CFEqual(keyboardFocus.element, element)
        guard !exactInputOwnsKeyboardFocus else {
            logger.error("Non-activating delivery preparation refused because the exact target already owns system keyboard focus pid=\(target.pid, privacy: .public)")
            return nil
        }
        let mode: BackgroundDeliverySession.Mode =
            frontmostPID == target.pid || keyboardFocus.pid == target.pid
                ? .directExactElement
                : .preparedTargetedInput

        let appElement = AXUIElementCreateApplication(target.pid)
        let previouslyFocusedWindow: AXUIElement?
        let previouslyFocusedElement: AXUIElement?
        let previouslyFocusedElementWasAbsent: Bool
        switch mode {
        case .directExactElement:
            previouslyFocusedWindow = nil
            previouslyFocusedElement = nil
            previouslyFocusedElementWasAbsent = false
        case .preparedTargetedInput:
            let windowRead = elementReferenceAttribute(
                kAXFocusedWindowAttribute,
                from: appElement
            )
            let elementRead = elementReferenceAttribute(
                kAXFocusedUIElementAttribute,
                from: appElement
            )
            guard case .value(let previousWindow) = windowRead,
                  Self.priorFocusedElementReadIsRestorable(
                    elementRead.availability
                  ) else {
                // The previous window must remain exact. For the editor pointer,
                // `.absent` is a real inactive Electron state; only a transport/read
                // failure is rejected before mutation.
                logger.error("Background exact focus refused without restorable prior pointer state targetPid=\(target.pid, privacy: .public) windowRead=\(windowRead.diagnostic, privacy: .public) elementRead=\(elementRead.diagnostic, privacy: .public)")
                return nil
            }
            previouslyFocusedWindow = previousWindow
            switch elementRead {
            case .value(let previousElement):
                previouslyFocusedElement = previousElement
                previouslyFocusedElementWasAbsent = false
            case .absent:
                previouslyFocusedElement = nil
                previouslyFocusedElementWasAbsent = true
            case .failed:
                // Guarded above; retain a defensive fail-closed branch if the enum
                // gains another restorable availability without a concrete mapping.
                return nil
            }
        }
        // Adapt the useful part of Cua/Trope's MIT-licensed synthetic-focus
        // pattern to VoiceInk++'s stricter exact-input contract: snapshot every
        // readable boolean we may overwrite, including literal `false` values.
        // The saved app/window/editor references remain VoiceInk++-specific because
        // delayed delivery must restore the exact prior internal destination.
        let focusBooleanSnapshot = BackgroundFocusBooleanSnapshot { slot in
            guard mode == .preparedTargetedInput else { return nil }
            return self.backgroundFocusBoolean(
                slot,
                targetWindow: window,
                targetElement: element,
                previousWindow: previouslyFocusedWindow,
                previousElement: previouslyFocusedElement
            )
        }
        let requiredBooleanSlots = requiredBackgroundFocusBooleanSlots(
            targetWindow: window,
            targetElement: element,
            previousWindow: previouslyFocusedWindow,
            previousElement: previouslyFocusedElement,
            mode: mode
        )
        let missingBooleanSlots = focusBooleanSnapshot.missing(
            from: requiredBooleanSlots
        )
        guard missingBooleanSlots.isEmpty else {
            // Never overwrite a focus boolean whose exact previous value could not be
            // read. Omitting it from verification would otherwise permit teardown to
            // claim success while leaving stale synthetic focus behind.
            logger.error("Background exact focus refused without complete restorable boolean state targetPid=\(target.pid, privacy: .public) missing=\(String(describing: missingBooleanSlots), privacy: .public)")
            return nil
        }
        let session = BackgroundDeliverySession(
            target: target,
            element: element,
            window: window,
            app: target.app,
            mode: mode,
            frontmostPIDAtPreparation: frontmostPID,
            previouslyFocusedWindow: previouslyFocusedWindow,
            previouslyFocusedElement: previouslyFocusedElement,
            previouslyFocusedElementWasAbsent: previouslyFocusedElementWasAbsent,
            focusBooleanSnapshot: focusBooleanSnapshot,
            processIdentifier: target.pid,
            bundleIdentifier: target.bundleIdentifier
        )

        switch mode {
        case .directExactElement:
            guard backgroundSessionRemainsPrepared(session) else { return nil }
        case .preparedTargetedInput:
            guard await Self.runBackgroundPreparationWithOwnedFailureCleanup(
                prepare: { await self.applyBackgroundFocus(session) },
                cleanup: { self.finishBackgroundDelivery(session) }
            ) else { return nil }
        }

        logger.info("Non-activating exact input prepared pid=\(target.pid, privacy: .public) bundle=\(target.bundleIdentifier ?? "nil", privacy: .public) mode=\(String(describing: mode), privacy: .public) windowHash=\(CFHash(window), privacy: .public) elementHash=\(CFHash(element), privacy: .public) preparationFrontmostPid=\(session.frontmostPIDAtPreparation, privacy: .public) currentFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        return session
    }

    static func runBackgroundPreparationWithOwnedFailureCleanup(
        prepare: () async -> Bool,
        cleanup: () -> Void
    ) async -> Bool {
        guard await prepare() else {
            // Preparation can fail after only some AX setters succeeded. The
            // session owner—not a caller that never receives it—must pair the
            // activation-state begin and restore every captured mutation.
            cleanup()
            return false
        }
        return true
    }

    static func backgroundTeardownDecision(
        boundary: BackgroundTeardownBoundaryStatus,
        restorationIncomplete: Bool,
        retryCount: Int
    ) -> BackgroundTeardownDecision {
        switch boundary {
        case .safe:
            guard restorationIncomplete else { return .restoreNow }
            return retryCount == 0 ? .retryFullRestoration : .finishPartialAndEnd
        case .targetOwnsSystemFocus, .targetTerminated:
            return .waiveWithoutMutation
        case .frontmostUnavailable, .systemFocusUnavailable:
            // One bounded retry may recover a transient AX/Workspace read. After that,
            // the least disruptive terminal choice is to waive teardown rather than
            // post a deactivation that might fight a real but unreadable user focus.
            return retryCount == 0 ? .retryFullRestoration : .waiveWithoutMutation
        }
    }

    static func preservedBackgroundTeardownBoundary(
        current: BackgroundTeardownBoundaryStatus,
        observed: BackgroundTeardownBoundaryStatus
    ) -> BackgroundTeardownBoundaryStatus {
        guard current == .safe, observed != .safe else { return current }
        return observed
    }

    func finishBackgroundDelivery(_ session: BackgroundDeliverySession) {
        guard session.mode == .preparedTargetedInput,
              session.lifecycle.requiresTeardown else {
            return
        }
        // The synthetic active state belongs only to the one bounded background
        // session. If Ethan has really brought Codex forward, explicitly waive the
        // synthetic deactivation; if focus state is merely unreadable, retain a
        // retryable lifecycle state instead of falsely declaring teardown complete.
        let entryBoundary = preparedTargetFocusBoundaryStatus(session)
        guard entryBoundary == .safe else {
            resolveBackgroundTeardown(
                session,
                boundary: entryBoundary,
                restorationIncomplete: false
            )
            return
        }
        var teardownCompleted = false
        var restorationBoundary: BackgroundTeardownBoundaryStatus = .safe
        func restorationBoundaryIsSafe() -> Bool {
            let observed = preparedTargetFocusBoundaryStatus(session)
            if observed != .safe {
                // Preserve the first unsafe observation for the terminal decision. A
                // second AX/Workspace read must never erase a real user focus takeover
                // and then permit VoiceInk++ to resume internal-focus mutation.
                restorationBoundary = Self.preservedBackgroundTeardownBoundary(
                    current: restorationBoundary,
                    observed: observed
                )
                return false
            }
            return restorationBoundary == .safe
        }
        defer {
            if !teardownCompleted {
                resolveBackgroundTeardown(
                    session,
                    boundary: restorationBoundary,
                    restorationIncomplete: true
                )
            }
        }

        // Electron settles its private activation state asynchronously. Keep the
        // session open and re-check the target-not-system-focused boundary before every
        // internal mutation; never begin a nested/repeated activation session.
        Thread.sleep(forTimeInterval: 0.05)
        guard restorationBoundaryIsSafe() else { return }
        let appElement = AXUIElementCreateApplication(session.processIdentifier)

        // First return every concrete pointer to its exact former value. Electron may
        // legitimately have had no focused UI element while inactive. Public AX cannot
        // write nil into the app pointer, so that case restores the target's exact
        // focused boolean below and accepts only absence or the same inactive pointer.
        guard let previousWindow = session.previouslyFocusedWindow else {
            logger.error("Background internal-focus restoration lost its required prior window pointer targetPid=\(session.processIdentifier, privacy: .public)")
            return
        }
        if !CFEqual(previousWindow, session.window) {
            guard restorationBoundaryIsSafe() else { return }
            _ = AXUIElementSetAttributeValue(
                previousWindow,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            guard restorationBoundaryIsSafe() else { return }
            _ = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                previousWindow
            )
            guard restorationBoundaryIsSafe() else { return }
            _ = AXUIElementSetAttributeValue(
                previousWindow,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        if let previousElement = session.previouslyFocusedElement,
           !CFEqual(previousElement, session.element) {
            guard restorationBoundaryIsSafe() else { return }
            _ = AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedUIElementAttribute as CFString,
                previousElement
            )
            guard restorationBoundaryIsSafe() else { return }
            _ = AXUIElementSetAttributeValue(
                previousElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }

        let booleansRestored = session.focusBooleanSnapshot.restore { slot, value in
            guard restorationBoundaryIsSafe(),
                  let (element, attribute) = self.backgroundFocusBooleanTarget(
                    for: slot,
                    session: session
                  ) else {
                return false
            }
            return AXUIElementSetAttributeValue(
                element,
                attribute as CFString,
                value ? kCFBooleanTrue : kCFBooleanFalse
            ) == .success
        }

        Thread.sleep(forTimeInterval: 0.05)
        guard restorationBoundaryIsSafe() else { return }
        let restoredWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement)
        let restoredElementRead = elementReferenceAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        )
        let windowRestored = restoredWindow.map { CFEqual($0, previousWindow) } == true
        let elementRestored: Bool
        if let previousElement = session.previouslyFocusedElement {
            if case .value(let restoredElement) = restoredElementRead {
                elementRestored = CFEqual(restoredElement, previousElement)
            } else {
                elementRestored = false
            }
        } else if session.previouslyFocusedElementWasAbsent {
            let restoredElementMatchesTarget: Bool
            if case .value(let restoredElement) = restoredElementRead {
                restoredElementMatchesTarget = CFEqual(
                    restoredElement,
                    session.element
                )
            } else {
                restoredElementMatchesTarget = false
            }
            elementRestored = Self.absentPriorFocusedElementRestorationMatches(
                restoredAvailability: restoredElementRead.availability,
                restoredElementMatchesTarget: restoredElementMatchesTarget,
                restoredTargetFocused: boolAttribute(
                    kAXFocusedAttribute,
                    from: session.element
                ),
                expectedTargetFocused: session.focusBooleanSnapshot.values[
                    .targetElementFocused
                ]
            )
        } else {
            elementRestored = false
        }
        let booleansVerified = session.focusBooleanSnapshot.matches { slot in
            guard let (element, attribute) = self.backgroundFocusBooleanTarget(
                for: slot,
                session: session
            ) else {
                return nil
            }
            return self.boolAttribute(attribute, from: element)
        }
        guard restorationBoundaryIsSafe() else { return }
        let restorationComplete = windowRestored
            && elementRestored
            && booleansRestored
            && booleansVerified
        if restorationComplete {
            let targetPID = session.processIdentifier
            teardownCompleted = session.lifecycle.finish {
                CursorPaster.endTargetedInputSession(pid: targetPID)
            }
        } else {
            // Do not pair the synthetic deactivation merely because the restoration
            // setters returned. Retry the complete pointer + boolean restoration once;
            // only the terminal policy may then end a still-partial session.
            logger.error("Background internal-focus restoration incomplete; scheduling bounded resolution window=\(windowRestored, privacy: .public) element=\(elementRestored, privacy: .public) booleansWritten=\(booleansRestored, privacy: .public) booleansVerified=\(booleansVerified, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
        }
        logger.info("Background internal focus restoration checked complete=\(restorationComplete, privacy: .public) window=\(windowRestored, privacy: .public) element=\(elementRestored, privacy: .public) booleansWritten=\(booleansRestored, privacy: .public) booleansVerified=\(booleansVerified, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
    }

    private func resolveBackgroundTeardown(
        _ session: BackgroundDeliverySession,
        boundary: BackgroundTeardownBoundaryStatus,
        restorationIncomplete: Bool
    ) {
        let decision = Self.backgroundTeardownDecision(
            boundary: boundary,
            restorationIncomplete: restorationIncomplete,
            retryCount: session.teardownRetryCount
        )
        switch decision {
        case .restoreNow:
            // This resolver is entered only after an unsafe boundary or an incomplete
            // restoration. A safe complete state is handled inline by the caller. Fail
            // closed if a future caller violates that invariant; never recurse on a
            // freshly re-read boundary or leave an ownerless synthetic session.
            _ = session.lifecycle.waiveTeardown()
            logger.error("Background internal-focus teardown received an invalid restore-now resolution; teardown waived targetPid=\(session.processIdentifier, privacy: .public)")
        case .retryFullRestoration:
            guard session.lifecycle.markTeardownRetryScheduled(),
                  session.teardownRetryCount == 0 else {
                _ = session.lifecycle.waiveTeardown()
                logger.error("Background internal-focus teardown retry could not be owned; teardown waived targetPid=\(session.processIdentifier, privacy: .public)")
                return
            }
            session.teardownRetryCount += 1
            // Resolve the only retry before returning to the serialized pipeline. A
            // detached retry could otherwise race a newer session for the same PID and
            // restore stale pointers or post that newer session's synthetic end.
            Thread.sleep(forTimeInterval: 0.05)
            finishBackgroundDelivery(session)
        case .finishPartialAndEnd:
            // The complete restoration path was retried once while the non-activating
            // boundary was safe. Pair the activation session exactly once, keep the
            // unresolved AX restoration in telemetry, and never spin indefinitely.
            let targetPID = session.processIdentifier
            _ = session.lifecycle.finish {
                CursorPaster.endTargetedInputSession(pid: targetPID)
            }
            logger.error("Background internal-focus restoration remained partial after one full retry; activation session ended targetPid=\(targetPID, privacy: .public)")
        case .waiveWithoutMutation:
            // Target takeover, termination, or persistent unreadable focus makes any
            // further AX write/deactivation less safe than stopping. This is an explicit
            // terminal waiver, not a silently orphaned activation-session owner.
            _ = session.lifecycle.waiveTeardown()
            logger.notice("Background internal-focus teardown waived without another mutation targetPid=\(session.processIdentifier, privacy: .public) boundary=\(String(describing: boundary), privacy: .public)")
        }
    }

    func backgroundInputText(for session: BackgroundDeliverySession) -> String? {
        backgroundInputTextSnapshot(for: session)?.text
    }

    func backgroundInputTextSnapshot(
        for session: BackgroundDeliverySession
    ) -> FocusedInputTextSnapshot? {
        guard backgroundDeliveryFastBoundaryMatches(session),
              let text = stringAttribute(
                kAXValueAttribute,
                from: session.element
              ) else {
            return nil
        }
        return FocusedInputTextSnapshot(
            text: text,
            placeholder: stringAttribute(
                kAXPlaceholderValueAttribute,
                from: session.element
            )
        )
    }

    /// After a successful chat Send, Electron may replace the composer wrapper.
    /// Re-resolve only inside the same frozen target/window/context and require the
    /// new exact editor to own the target app's internal focus. This read is used for
    /// clear/reset verification and diagnostics only; it never retargets the session,
    /// mutates focus, or authorizes a retry.
    func backgroundPostActionInputTextSnapshot(
        for session: BackgroundDeliverySession
    ) -> FocusedInputTextSnapshot? {
        if let retained = backgroundInputTextSnapshot(for: session) {
            return retained
        }
        guard backgroundFocusBoundaryIsSafeAfterSubmission(session),
              let resolved = resolvedExactElement(for: session.target),
              owningWindow(for: resolved).map({
                CFEqual($0, session.window)
              }) == true,
              let internallyFocused = elementAttribute(
                kAXFocusedUIElementAttribute,
                from: AXUIElementCreateApplication(
                    session.processIdentifier
                )
              ),
              CFEqual(internallyFocused, resolved),
              let text = stringAttribute(kAXValueAttribute, from: resolved) else {
            return nil
        }
        return FocusedInputTextSnapshot(
            text: text,
            placeholder: stringAttribute(
                kAXPlaceholderValueAttribute,
                from: resolved
            )
        )
    }

    /// Privacy-safe rolling telemetry for one background Send attempt. This logs only
    /// executable/build identity, focus/boundary booleans, timings, and aggregate text
    /// counts. It never logs transcript, composer, placeholder, chat, URL, or clipboard
    /// content. The repository trace runner retains allowlisted lines for seven days.
    func logBackgroundAutoSendDiagnostic(
        stage: String,
        route: String,
        verification: String,
        beforeText: String,
        afterSnapshot: FocusedInputTextSnapshot?,
        session: BackgroundDeliverySession,
        elapsedMilliseconds: Int,
        sampleCount: Int
    ) {
        let identity = session.diagnosticApplicationIdentity
        let currentFrontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier ?? -1
        let systemFocusPID = systemFocusedElement()?.pid ?? -1
        let retainedBoundary = backgroundDeliveryFastBoundaryMatches(session)
        let fullBoundary = backgroundSessionRemainsPrepared(session)
        let beforeCharacterCount = beforeText.count
        let beforeNewlineCount = beforeText.reduce(into: 0) { count, scalar in
            if scalar.isNewline { count += 1 }
        }
        let afterText = afterSnapshot?.text
        let afterCharacterCount = afterText?.count ?? -1
        let afterNewlineCount = afterText?.reduce(into: 0) { count, scalar in
            if scalar.isNewline { count += 1 }
        } ?? -1
        let afterMatchesPlaceholder = afterSnapshot.flatMap { snapshot in
            snapshot.placeholder.map { $0 == snapshot.text }
        }
        let afterTrimmedEmpty = afterText.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let endsWithNewline = afterText?.last.map {
            $0 == "\n" || $0 == "\r"
        }
        let afterReadable = afterText != nil
        let composerElementReplaced = afterReadable && !retainedBoundary
        let targetBecameFrontmost = currentFrontmostPID
            == session.processIdentifier
        let auditedTupleMatched = Self.matchesAuditedOpenAISubmitBuild(
            session.app
        )
        let characterDelta = afterText.map {
            $0.count - beforeCharacterCount
        } ?? Int.min
        let newlineDelta = afterText.map { text in
            text.reduce(into: 0) { count, scalar in
                if scalar.isNewline { count += 1 }
            } - beforeNewlineCount
        } ?? Int.min
        let placeholderReadable = afterSnapshot?.placeholder != nil
        let matchesPlaceholderDescription = afterMatchesPlaceholder.map {
            String(describing: $0)
        } ?? "unknown"
        let trimmedEmptyDescription = afterTrimmedEmpty.map {
            String(describing: $0)
        } ?? "unknown"
        let endsWithNewlineDescription = endsWithNewline.map {
            String(describing: $0)
        } ?? "unknown"
        let windowID = SkyLightTargetedMouseEventPost.windowID(
            for: session.window
        ) ?? 0
        logger.info("Background auto-send diagnostic stage=\(stage, privacy: .public) route=\(route, privacy: .public) verification=\(verification, privacy: .public) app=\(identity.applicationBundleName, privacy: .public) bundle=\(identity.bundleIdentifier, privacy: .public) version=\(identity.shortVersion, privacy: .public) build=\(identity.build, privacy: .public) chromium=\(identity.chromium, privacy: .public) auditedTuple=\(auditedTupleMatched, privacy: .public) sessionMode=\(session.diagnosticMode, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) windowId=\(windowID, privacy: .public) windowHash=\(CFHash(session.window), privacy: .public) elementHash=\(CFHash(session.element), privacy: .public) targetActive=\(session.app.isActive, privacy: .public) targetBecameFrontmost=\(targetBecameFrontmost, privacy: .public) preparationFrontmostPid=\(session.frontmostPIDAtPreparation, privacy: .public) currentFrontmostPid=\(currentFrontmostPID, privacy: .public) systemFocusPid=\(systemFocusPID, privacy: .public) retainedBoundary=\(retainedBoundary, privacy: .public) fullBoundary=\(fullBoundary, privacy: .public) composerElementReplaced=\(composerElementReplaced, privacy: .public) beforeChars=\(beforeCharacterCount, privacy: .public) afterReadable=\(afterReadable, privacy: .public) afterChars=\(afterCharacterCount, privacy: .public) charDelta=\(characterDelta, privacy: .public) beforeNewlines=\(beforeNewlineCount, privacy: .public) afterNewlines=\(afterNewlineCount, privacy: .public) newlineDelta=\(newlineDelta, privacy: .public) endsWithNewline=\(endsWithNewlineDescription, privacy: .public) placeholderReadable=\(placeholderReadable, privacy: .public) matchesPlaceholder=\(matchesPlaceholderDescription, privacy: .public) trimmedEmpty=\(trimmedEmptyDescription, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public) samples=\(sampleCount, privacy: .public)")
    }

    func backgroundWindowContains(
        _ text: String,
        for session: BackgroundDeliverySession,
        excludingSavedInput: Bool = false
    ) -> Bool {
        guard backgroundFocusBoundaryIsSafeAfterSubmission(session) else {
            return false
        }
        return descendants(of: session.window).contains { element in
            if excludingSavedInput, CFEqual(element, session.element) {
                return false
            }
            return stringAttribute(kAXValueAttribute, from: element)?.contains(text) == true
        }
    }

    /// Same-app/different-input delivery is element-addressed. Never replace a generic
    /// AXValue: rich editors can lose formatting. If AXSelectedText is unavailable,
    /// fail closed instead of internally focusing the saved input.
    func insertTextUsingAccessibility(
        _ text: String,
        for session: BackgroundDeliverySession
    ) -> BackgroundTextInsertionResult {
        guard session.mode == .directExactElement,
              !text.isEmpty,
              backgroundSessionRemainsPrepared(session) else {
            return .unavailable
        }
        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            session.element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else {
            return .unavailable
        }
        guard backgroundSessionRemainsPrepared(session) else {
            return .focusSafetyViolation
        }
        let result = AXUIElementSetAttributeValue(
            session.element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard backgroundSessionRemainsPrepared(session) else {
            return .focusSafetyViolation
        }
        return result == .success
            ? .acceptedSelectedText
            : .failed(result.rawValue)
    }

    func backgroundDeliveryBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        backgroundSessionRemainsPrepared(session)
    }

    /// Cheap per-chunk/readback guard. Full document/task re-resolution happens before,
    /// at bounded checkpoints, and after targeted typing; every individual 20-unit
    /// chunk still proves the retained wrapper, window, internal focus, and system-focus
    /// boundary without repeatedly walking a large Chromium tree.
    func backgroundDeliveryFastBoundaryMatches(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard backgroundFocusBoundaryIsSafeAfterSubmission(session),
              stringAttribute(kAXRoleAttribute, from: session.element).map({
                  isEditableInput(
                      role: $0,
                      subrole: stringAttribute(
                          kAXSubroleAttribute,
                          from: session.element
                      )
                  )
              }) == true,
              owningWindow(for: session.element).map({
                  CFEqual($0, session.window)
              }) == true else {
            return false
        }
        guard session.mode == .preparedTargetedInput else { return true }
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        return elementAttribute(kAXFocusedWindowAttribute, from: appElement).map({
            CFEqual($0, session.window)
        }) == true && elementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ).map({
            CFEqual($0, session.element)
        }) == true
    }

    func pressNearbySubmitButton(
        for session: BackgroundDeliverySession
    ) async -> NearbySubmitButtonResult {
        guard backgroundSessionRemainsPrepared(session) else {
            logger.error("Background submit refused because exact internal focus or target-not-frontmost proof was lost pid=\(session.processIdentifier, privacy: .public)")
            return .unavailable
        }
        return await pressNearbySubmitButton(
            element: session.element,
            window: session.window,
            app: session.app,
            pid: session.processIdentifier,
            preserveSystemFocusAcrossAction: session.mode == .directExactElement,
            allowsTargetedBackgroundClick: session.mode == .preparedTargetedInput,
            waitForUnavailableCandidate: true,
            traversalPreflight: { [weak self] in
                self?.backgroundDeliveryFastBoundaryMatches(session) == true
            },
            actionPreflight: { [weak self] in
                self?.backgroundSessionRemainsPrepared(session) == true
            },
            postActionFocusGuard: { [weak self] in
                self?.backgroundFocusBoundaryIsSafeAfterSubmission(session) == true
            }
        )
    }

    /// Read the live editor text for bounded delivery verification. This is not used
    /// to infer focus or choose a destination; it only lets the OpenAI composer path
    /// detect the otherwise invisible "Return was issued but ignored" failure after
    /// the transcript has already been pasted into the saved target.
    func focusedInputText(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) -> String? {
        focusedInputTextSnapshot(
            for: target,
            allowApplicationFallback: allowApplicationFallback
        )?.text
    }

    /// Read the value and placeholder from one resolved editor wrapper. Codex may
    /// expose its empty reset state through AXValue as the same string published in
    /// AXPlaceholderValue, so foreground post-Return verification needs both values
    /// from one snapshot. Delivery never logs either string.
    func focusedInputTextSnapshot(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) -> FocusedInputTextSnapshot? {
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
        guard let text = value as? String else { return nil }
        return FocusedInputTextSnapshot(
            text: text,
            placeholder: stringAttribute(kAXPlaceholderValueAttribute, from: element)
        )
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

    /// Cheap, read-only proof for the exact retained wrapper. Unlike full replay-safe
    /// resolution this performs no task-tree scan, so the uninterrupted Primary path
    /// can arm optional post-Return verification without delaying its first Return.
    func retainedInputOwnsSystemKeyboardFocus(_ target: Target) -> Bool {
        guard let retainedElement = target.element,
              let retainedWindow = target.window,
              let focusedInput = systemFocusedElement(),
              focusedInput.pid == target.pid,
              CFEqual(focusedInput.element, retainedElement),
              owningWindow(for: retainedElement).map({
                  CFEqual($0, retainedWindow)
              }) == true else {
            return false
        }
        return true
    }

    /// A recording-start application fallback is only a capture-time convenience.
    /// Before foreground Cmd-V, freeze the one editable element that currently owns
    /// keyboard focus so paste, verification, and Return all share exact identity.
    func promoteForegroundApplicationFallbackToExactInput(_ target: Target) -> Target? {
        guard !target.hasExactInput,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              let focused = systemFocusedElement(),
              focused.pid == target.pid else {
            return nil
        }
        let role = stringAttribute(kAXRoleAttribute, from: focused.element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: focused.element)
        guard isEditableInput(role: role, subrole: subrole),
              let window = owningWindow(for: focused.element),
              let identity = exactInputIdentity(for: focused.element, in: window) else {
            return nil
        }
        return Target(
            element: focused.element,
            window: window,
            identity: identity,
            app: target.app,
            pid: target.pid,
            bundleIdentifier: target.bundleIdentifier,
            displayInfo: Target.DisplayInfo(
                applicationName: target.displayInfo.applicationName,
                inputName: inputDisplayName(for: focused.element),
                applicationIcon: target.displayInfo.applicationIcon
            )
        )
    }

    /// OpenAI chat surfaces expose Send in a sibling FooterActions subtree rather than
    /// as a direct editor sibling. Discovery is bounded to the exact editor's ancestor
    /// chain and same window. Exact system keyboard focus is the authority here: a
    /// non-activating panel may own it while NSWorkspace reports another app frontmost.
    /// The action is revalidated after the asynchronous walk so an idle Send wrapper
    /// that turns into Stop can never cross the AXPress boundary.
    func pressNearbySubmitButton(
        for target: Target,
        allowApplicationFallback: Bool = false
    ) async -> NearbySubmitButtonResult {
        guard AXIsProcessTrusted() else {
            return .failed(AXError.apiDisabled.rawValue)
        }
        guard !target.app.isTerminated,
              targetOwnsSystemKeyboardFocus(target),
              let element = liveElement(
                  for: target,
                  allowApplicationFallback: allowApplicationFallback
              ),
              let window = owningWindow(for: element) else {
            return .unavailable
        }

        return await pressNearbySubmitButton(
            element: element,
            window: window,
            app: target.app,
            pid: target.pid,
            preserveSystemFocusAcrossAction: false,
            allowsTargetedBackgroundClick: false,
            waitForUnavailableCandidate: false,
            traversalPreflight: { [weak self] in
                self?.retainedInputOwnsSystemKeyboardFocus(target) == true
            },
            actionPreflight: { [weak self] in
                self?.targetOwnsSystemKeyboardFocus(target) == true
            },
            postActionFocusGuard: { true }
        )
    }

    private func pressNearbySubmitButton(
        element: AXUIElement,
        window: AXUIElement,
        app: NSRunningApplication,
        pid: pid_t,
        preserveSystemFocusAcrossAction: Bool,
        allowsTargetedBackgroundClick: Bool,
        waitForUnavailableCandidate: Bool,
        traversalPreflight: () -> Bool,
        actionPreflight: () -> Bool,
        postActionFocusGuard: () -> Bool
    ) async -> NearbySubmitButtonResult {
        guard !app.isTerminated, traversalPreflight() else { return .unavailable }
        // React may publish or enable the exact Send wrapper just after Accessibility
        // insertion completes. Background delivery has no safe key fallback, so give
        // only that route a bounded chance to re-resolve the complete relationship.
        // Foreground callers return immediately to their exact-focus HID path.
        let readinessDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        var candidate: NearbySubmitButtonCandidate?
        repeat {
            let lookup = await nearbySubmitButtonLookup(
                editor: element,
                window: window,
                app: app,
                pid: pid,
                boundary: traversalPreflight
            )
            switch lookup {
            case .ready(let readyCandidate):
                candidate = readyCandidate
            case .ambiguous:
                logger.notice("Semantic Send lookup was ambiguous; no action issued pid=\(pid, privacy: .public)")
                return .unavailable
            case .boundaryChanged:
                return .unavailable
            case .unavailable:
                guard waitForUnavailableCandidate,
                      traversalPreflight(),
                      !Task.isCancelled,
                      ProcessInfo.processInfo.systemUptime < readinessDeadline else {
                    return .unavailable
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        } while candidate == nil
        guard let candidate else { return .unavailable }
        guard actionPreflight() else { return .focusLostBeforeAction }
        guard !Task.isCancelled else { return .refusedAfterCandidate }

        // The first traversal discovers a candidate; the second is the irreversible
        // action-time topology proof. Re-run the entire nearest-composer lookup and
        // require the same sole candidate so a newly appeared sibling Send/Stop button
        // cannot be hidden by merely rechecking the retained wrapper's own attributes.
        let actionTimeLookup = await nearbySubmitButtonLookup(
            editor: element,
            window: window,
            app: app,
            pid: pid,
            boundary: traversalPreflight
        )
        guard actionPreflight() else { return .focusLostBeforeAction }
        guard case .ready(let actionTimeCandidate) = actionTimeLookup,
              CFEqual(actionTimeCandidate.element, candidate.element),
              !Task.isCancelled else {
            logger.notice("Semantic Send action-time topology changed; no action issued pid=\(pid, privacy: .public)")
            return .refusedAfterCandidate
        }
        let result = await pressVerifiedSubmitButton(
            actionTimeCandidate,
            editor: element,
            window: window,
            app: app,
            pid: pid,
            preserveSystemFocusAcrossAction: preserveSystemFocusAcrossAction,
            allowsTargetedBackgroundClick: allowsTargetedBackgroundClick,
            preflight: actionPreflight,
            postActionFocusGuard: postActionFocusGuard
        )
        // A candidate existed and was uniquely re-found, so a final refusal means its
        // semantics or exact boundary changed (for example idle Send became Stop).
        // Preserve that distinction so callers never reinterpret it as permission to
        // fall back to Return.
        if result == .unavailable {
            return actionPreflight()
                ? .refusedAfterCandidate
                : .focusLostBeforeAction
        }
        return result
    }

    private func nearbySubmitButtonLookup(
        editor: AXUIElement,
        window: AXUIElement,
        app: NSRunningApplication,
        pid: pid_t,
        boundary: () -> Bool
    ) async -> NearbySubmitButtonLookup {
        guard boundary() else {
            logger.notice("Bounded OpenAI FooterActions sibling search stopped reason=initialBoundaryChanged pid=\(pid, privacy: .public)")
            return .boundaryChanged
        }
        guard let editorFrame = frame(of: editor) else {
            logger.notice("Bounded OpenAI FooterActions sibling search stopped reason=editorFrameUnreadable pid=\(pid, privacy: .public)")
            return .unavailable
        }

        let searchStarted = ProcessInfo.processInfo.systemUptime
        let deadline = searchStarted + Self.semanticSendSearchSeconds
        let traversalState = BoundedTraversalState(
            nodeBudget: Self.semanticSendNodeBudget
        )
        var ancestorsVisited = 0
        var editorBranch = editor
        var ancestor = elementAttribute(kAXParentAttribute, from: editor)
        for _ in 0..<16 {
            guard boundary(), !Task.isCancelled,
                  ProcessInfo.processInfo.systemUptime < deadline,
                  traversalState.remainingNodeBudget > 0,
                  let container = ancestor,
                  !CFEqual(container, window) else {
                break
            }
            ancestorsVisited += 1
            ancestor = elementAttribute(kAXParentAttribute, from: container)
            var candidates: [NearbySubmitButtonCandidate] = []
            let siblingBranches = traversalChildren(
                of: container,
                state: traversalState
            ).filter {
                !CFEqual($0, editorBranch)
            }
            for sibling in siblingBranches {
                let traversal = await visitBoundedDescendants(
                    of: sibling,
                    maximumDepth: 10,
                    state: traversalState,
                    deadline: deadline,
                    boundary: boundary,
                    visitor: { candidateElement in
                        if let candidate = self.semanticSendCandidate(
                            candidateElement,
                            editor: editor,
                            window: window,
                            editorFrame: editorFrame,
                            app: app,
                            pid: pid,
                            diagnostics: traversalState
                        ) {
                            candidates.append(candidate)
                        }
                        return self.uniqueCandidateCount(candidates) < 2
                    }
                )
                switch traversal.completion {
                case .completed:
                    break
                case .stoppedByVisitor:
                    return .ambiguous
                case .cancelled:
                    logSemanticSendSearchFailure(
                        reason: "cancelled",
                        pid: pid,
                        searchStarted: searchStarted,
                        ancestorsVisited: ancestorsVisited,
                        state: traversalState
                    )
                    return .boundaryChanged
                case .boundaryChanged:
                    logSemanticSendSearchFailure(
                        reason: "boundaryChanged",
                        pid: pid,
                        searchStarted: searchStarted,
                        ancestorsVisited: ancestorsVisited,
                        state: traversalState
                    )
                    return .boundaryChanged
                case .exhausted:
                    let reason: String
                    if traversalState.remainingNodeBudget <= 0 {
                        reason = "nodeBudgetExhausted"
                    } else if ProcessInfo.processInfo.systemUptime >= deadline {
                        reason = "deadlineExhausted"
                    } else {
                        reason = "depthOrQueueTruncated"
                    }
                    logSemanticSendSearchFailure(
                        reason: reason,
                        pid: pid,
                        searchStarted: searchStarted,
                        ancestorsVisited: ancestorsVisited,
                        state: traversalState
                    )
                    return .unavailable
                }
            }

            let unique = uniqueCandidates(candidates)
            if unique.count == 1, let candidate = unique.first {
                let elapsedMilliseconds = Int(
                    (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
                )
                logger.info("Resolved OpenAI FooterActions Send sibling pid=\(pid, privacy: .public) ancestorsVisited=\(ancestorsVisited, privacy: .public) nodesVisited=\(Self.semanticSendNodeBudget - traversalState.remainingNodeBudget, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return .ready(candidate)
            }
            if unique.count > 1 { return .ambiguous }
            editorBranch = container
        }
        logSemanticSendSearchFailure(
            reason: "completedWithoutCandidate",
            pid: pid,
            searchStarted: searchStarted,
            ancestorsVisited: ancestorsVisited,
            state: traversalState
        )
        return .unavailable
    }

    /// Keep failed live searches diagnosable without logging labels, editor contents,
    /// window titles, or any other user data. Counts reveal which irreversible Send
    /// gate rejected Codex while preserving the exact same fail-closed contract.
    private func logSemanticSendSearchFailure(
        reason: String,
        pid: pid_t,
        searchStarted: TimeInterval,
        ancestorsVisited: Int,
        state: BoundedTraversalState
    ) {
        let elapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - searchStarted) * 1_000
        )
        logger.notice("Bounded OpenAI FooterActions sibling search found no candidate reason=\(reason, privacy: .public) pid=\(pid, privacy: .public) ancestorsVisited=\(ancestorsVisited, privacy: .public) nodesVisited=\(Self.semanticSendNodeBudget - state.remainingNodeBudget, privacy: .public) remainingNodeBudget=\(state.remainingNodeBudget, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
        logger.notice("Bounded OpenAI FooterActions child counts pid=\(pid, privacy: .public) nav=\(state.navigationChildEdges, privacy: .public) visible=\(state.visibleChildEdges, privacy: .public) ordinary=\(state.ordinaryChildEdges, privacy: .public) merged=\(state.mergedChildEdges, privacy: .public) buttons=\(state.buttonNodes, privacy: .public)")
        logger.notice("Bounded OpenAI FooterActions rejection counts pid=\(pid, privacy: .public) labelSend=\(state.labelledSendButtons, privacy: .public) labelOther=\(state.labelledOtherButtons, privacy: .public) labelUnlabelled=\(state.unlabelledButtons, privacy: .public) labelUnreadable=\(state.unreadableLabelButtons, privacy: .public) auditedUnlabelled=\(state.auditedUnlabelledButtons, privacy: .public) enabled=\(state.enabledButtons, privacy: .public) disabled=\(state.disabledButtons, privacy: .public) enabledUnreadable=\(state.unreadableEnabledButtons, privacy: .public) pressable=\(state.pressableButtons, privacy: .public) unpressable=\(state.unpressableButtons, privacy: .public) windowMatch=\(state.matchingWindowButtons, privacy: .public) windowMismatch=\(state.mismatchedWindowButtons, privacy: .public) frameReadable=\(state.readableFrameButtons, privacy: .public) frameUnreadable=\(state.unreadableFrameButtons, privacy: .public) geometryMatch=\(state.matchingGeometryButtons, privacy: .public) geometryMismatch=\(state.mismatchedGeometryButtons, privacy: .public)")
    }

    private func semanticSendCandidate(
        _ candidateElement: AXUIElement,
        editor: AXUIElement,
        window: AXUIElement,
        editorFrame: CGRect,
        app: NSRunningApplication,
        pid: pid_t,
        diagnostics: BoundedTraversalState? = nil
    ) -> NearbySubmitButtonCandidate? {
        guard !CFEqual(candidateElement, editor),
              stringAttribute(kAXRoleAttribute, from: candidateElement)
                == kAXButtonRole else {
            return nil
        }
        diagnostics?.buttonNodes += 1

        var candidatePID: pid_t = 0
        guard AXUIElementGetPid(candidateElement, &candidatePID) == .success,
              candidatePID == pid else {
            return nil
        }

        let labelState = submitLabelState(for: candidateElement)
        let label: String?
        let usesAuditedUnlabelledContract: Bool
        switch labelState {
        case .labelled(let value):
            label = value
            usesAuditedUnlabelledContract = false
            if Self.isProvenSemanticSendLabel(value) {
                diagnostics?.labelledSendButtons += 1
            } else {
                diagnostics?.labelledOtherButtons += 1
            }
        case .unlabelled:
            label = nil
            usesAuditedUnlabelledContract = Self.matchesAuditedOpenAISubmitBuild(app)
            diagnostics?.unlabelledButtons += 1
            if usesAuditedUnlabelledContract {
                diagnostics?.auditedUnlabelledButtons += 1
            }
        case .unreadable:
            diagnostics?.unreadableLabelButtons += 1
            return nil
        }
        guard Self.isProvenSemanticSendLabel(label)
                || usesAuditedUnlabelledContract else {
            return nil
        }

        switch boolAttribute(kAXEnabledAttribute, from: candidateElement) {
        case true:
            diagnostics?.enabledButtons += 1
        case false:
            diagnostics?.disabledButtons += 1
            return nil
        case nil:
            diagnostics?.unreadableEnabledButtons += 1
            return nil
        }

        guard supportsPressAction(candidateElement) else {
            diagnostics?.unpressableButtons += 1
            return nil
        }
        diagnostics?.pressableButtons += 1

        guard owningWindow(for: candidateElement).map({
            CFEqual($0, window)
        }) == true else {
            diagnostics?.mismatchedWindowButtons += 1
            return nil
        }
        diagnostics?.matchingWindowButtons += 1

        guard let candidateFrame = frame(of: candidateElement) else {
            diagnostics?.unreadableFrameButtons += 1
            return nil
        }
        diagnostics?.readableFrameButtons += 1
        guard Self.semanticSendGeometryMatches(
            editorFrame: editorFrame,
            candidateFrame: candidateFrame
        ) else {
            diagnostics?.mismatchedGeometryButtons += 1
            return nil
        }
        diagnostics?.matchingGeometryButtons += 1

        let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)
        return NearbySubmitButtonCandidate(
            element: candidateElement,
            usesAuditedUnlabelledContract: usesAuditedUnlabelledContract,
            score: abs(center.x - editorFrame.maxX)
                + abs(center.y - editorFrame.maxY)
        )
    }

    private func pressVerifiedSubmitButton(
        _ candidate: NearbySubmitButtonCandidate,
        editor: AXUIElement,
        window: AXUIElement,
        app: NSRunningApplication,
        pid: pid_t,
        preserveSystemFocusAcrossAction: Bool,
        allowsTargetedBackgroundClick: Bool,
        preflight: () -> Bool,
        postActionFocusGuard: () -> Bool
    ) async -> NearbySubmitButtonResult {
        guard preflight(), !Task.isCancelled,
              let editorFrame = frame(of: editor),
              let candidateFrame = frame(of: candidate.element) else {
            return .unavailable
        }
        let revalidatedCandidate = semanticSendCandidate(
            candidate.element,
            editor: editor,
            window: window,
            editorFrame: editorFrame,
            app: app,
            pid: pid
        )
        let revalidatedSameElement = revalidatedCandidate.map {
            CFEqual($0.element, candidate.element)
        } == true
        var candidatePID: pid_t = 0
        guard revalidatedSameElement,
              AXUIElementGetPid(candidate.element, &candidatePID) == .success,
              candidatePID == pid,
              owningWindow(for: candidate.element).map({
                  CFEqual($0, window)
              }) == true,
              Self.semanticSendGeometryMatches(
                  editorFrame: editorFrame,
                  candidateFrame: candidateFrame
              ),
              stringAttribute(kAXRoleAttribute, from: candidate.element)
                == kAXButtonRole,
              boolAttribute(kAXEnabledAttribute, from: candidate.element) == true,
              supportsPressAction(candidate.element),
              !Task.isCancelled else {
            return .unavailable
        }

        let auditedBuildStillMatches = candidate.usesAuditedUnlabelledContract
            && Self.matchesAuditedOpenAISubmitBuild(app)
        guard preflight(), !Task.isCancelled else { return .unavailable }
        let focusBeforeAction: (element: AXUIElement, pid: pid_t)?
        if preserveSystemFocusAcrossAction {
            guard let currentFocus = systemFocusedElement() else {
                return .unavailable
            }
            focusBeforeAction = currentFocus
        } else {
            focusBeforeAction = nil
        }

        // This must be the final AX read before AXPress. Codex reuses the same control
        // for idle Send and active Stop, so an earlier label snapshot is not semantic
        // proof at the irreversible boundary. A renderer/read failure is fail-closed,
        // never treated as the audited genuinely-unlabelled idle state.
        let finalLabelState = submitLabelState(for: candidate.element)
        let currentLabel: String?
        let labelWasReadable: Bool
        let currentAuditedUnlabelledContract: Bool
        switch finalLabelState {
        case .labelled(let value):
            currentLabel = value
            labelWasReadable = true
            currentAuditedUnlabelledContract = false
        case .unlabelled:
            currentLabel = nil
            labelWasReadable = true
            currentAuditedUnlabelledContract = auditedBuildStillMatches
        case .unreadable:
            currentLabel = nil
            labelWasReadable = false
            currentAuditedUnlabelledContract = false
        }

        let semanticBoundaryProven = Self.isProvenSemanticSendBoundary(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: currentLabel,
            labelWasReadable: labelWasReadable,
            allowsAuditedUnlabelledSend: currentAuditedUnlabelledContract,
            hasPressAction: true,
            boundaryMatches: true
        )
        guard semanticBoundaryProven else { return .unavailable }

        if allowsTargetedBackgroundClick,
           currentAuditedUnlabelledContract {
            guard preflight(), !Task.isCancelled,
                  let windowFrame = frame(of: window),
                  let windowID = SkyLightTargetedMouseEventPost.windowID(
                    for: window
                  ) else {
                return .unavailable
            }
            let targetPoint = CGPoint(
                x: candidateFrame.midX,
                y: candidateFrame.midY
            )
            guard windowFrame.contains(targetPoint) else { return .unavailable }
            let targetPointInWindow = CGPoint(
                x: targetPoint.x - windowFrame.minX,
                y: targetPoint.y - windowFrame.minY
            )
            // This point is outside the exact window in both screen and local
            // coordinates, including on multi-monitor layouts with negative origins.
            let offWindowPoint = CGPoint(
                x: windowFrame.minX - max(windowFrame.width, 2_048),
                y: windowFrame.minY - max(windowFrame.height, 2_048)
            )
            let actionStarted = ProcessInfo.processInfo.systemUptime
            let clickResult = await CursorPaster.performTargetedOpenAISendClick(
                targetPID: pid,
                windowID: windowID,
                targetPoint: targetPoint,
                targetPointInWindow: targetPointInWindow,
                offWindowPoint: offWindowPoint,
                canPost: preflight
            )
            let elapsedMilliseconds = Int(
                (ProcessInfo.processInfo.systemUptime - actionStarted) * 1_000
            )
            switch clickResult {
            case .actionGuardRefused:
                logger.notice("Targeted OpenAI Send click refused at its final exact-input boundary pid=\(pid, privacy: .public) windowId=\(windowID, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return .focusLostBeforeAction
            case .commandNotPosted:
                logger.error("Targeted OpenAI Send click transport unavailable pid=\(pid, privacy: .public) windowId=\(windowID, privacy: .public) bridgeAvailable=\(SkyLightTargetedMouseEventPost.isAvailable, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return .failed(AXError.cannotComplete.rawValue)
            case .commandPosted:
                guard postActionFocusGuard() else {
                    logger.error("Targeted OpenAI Send click violated the non-activating focus boundary pid=\(pid, privacy: .public) windowId=\(windowID, privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                    return .failed(AXError.cannotComplete.rawValue)
                }
                logger.info("Targeted OpenAI Send click attempted pid=\(pid, privacy: .public) windowId=\(windowID, privacy: .public) auditedTuple=true labelState=unlabelledAudited buttonIdentityStable=true buttonEnabled=true buttonWidth=\(Int(candidateFrame.width), privacy: .public) buttonHeight=\(Int(candidateFrame.height), privacy: .public) elapsedMs=\(elapsedMilliseconds, privacy: .public)")
                return .targetedClick
            }
        }

        var actionResult: AXError?
        let result = Self.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: currentLabel,
            labelWasReadable: labelWasReadable,
            allowsAuditedUnlabelledSend: currentAuditedUnlabelledContract,
            hasPressAction: true,
            boundaryMatches: true,
            action: {
                let value = AXUIElementPerformAction(
                    candidate.element,
                    kAXPressAction as CFString
                )
                actionResult = value
                return value.rawValue
            }
        )
        guard result != .unavailable else { return result }

        if let focusBeforeAction {
            let focusAfterAction = systemFocusedElement()
            guard focusAfterAction?.pid == focusBeforeAction.pid,
                  focusAfterAction.map({
                      CFEqual($0.element, focusBeforeAction.element)
                  }) == true else {
                logger.error("Semantic Send changed the user's system-focused input pid=\(pid, privacy: .public)")
                return .failed(AXError.cannotComplete.rawValue)
            }
        }
        guard postActionFocusGuard() else {
            logger.error("Semantic Send violated the non-activating focus boundary pid=\(pid, privacy: .public)")
            return .failed(AXError.cannotComplete.rawValue)
        }
        logger.info("Verified semantic Send press attempted pid=\(pid, privacy: .public) route=\(currentAuditedUnlabelledContract ? "auditedOpenAIIdleSend" : "labelledSend", privacy: .public) label=\(currentLabel ?? "nil", privacy: .public) result=\(actionResult?.rawValue ?? -1, privacy: .public)")
        return result
    }

    private func uniqueCandidates(
        _ candidates: [NearbySubmitButtonCandidate]
    ) -> [NearbySubmitButtonCandidate] {
        var unique: [NearbySubmitButtonCandidate] = []
        for candidate in candidates.sorted(by: { $0.score < $1.score }) where
            !unique.contains(where: { CFEqual($0.element, candidate.element) }) {
            unique.append(candidate)
        }
        return unique
    }

    private func uniqueCandidateCount(
        _ candidates: [NearbySubmitButtonCandidate]
    ) -> Int {
        min(uniqueCandidates(candidates).count, 2)
    }

    private func backgroundFocusBoolean(
        _ slot: BackgroundFocusBooleanSlot,
        targetWindow: AXUIElement,
        targetElement: AXUIElement,
        previousWindow: AXUIElement?,
        previousElement: AXUIElement?
    ) -> Bool? {
        guard let (element, attribute) = backgroundFocusBooleanTarget(
            for: slot,
            targetWindow: targetWindow,
            targetElement: targetElement,
            previousWindow: previousWindow,
            previousElement: previousElement
        ) else {
            return nil
        }
        return boolAttribute(attribute, from: element)
    }

    private func backgroundFocusBooleanTarget(
        for slot: BackgroundFocusBooleanSlot,
        session: BackgroundDeliverySession
    ) -> (AXUIElement, String)? {
        backgroundFocusBooleanTarget(
            for: slot,
            targetWindow: session.window,
            targetElement: session.element,
            previousWindow: session.previouslyFocusedWindow,
            previousElement: session.previouslyFocusedElement
        )
    }

    private func backgroundFocusBooleanTarget(
        for slot: BackgroundFocusBooleanSlot,
        targetWindow: AXUIElement,
        targetElement: AXUIElement,
        previousWindow: AXUIElement?,
        previousElement: AXUIElement?
    ) -> (AXUIElement, String)? {
        switch slot {
        case .targetWindowMain:
            return (targetWindow, kAXMainAttribute)
        case .targetWindowFocused:
            return (targetWindow, kAXFocusedAttribute)
        case .targetElementFocused:
            return (targetElement, kAXFocusedAttribute)
        case .previousWindowMain:
            return previousWindow.map { ($0, kAXMainAttribute) }
        case .previousWindowFocused:
            return previousWindow.map { ($0, kAXFocusedAttribute) }
        case .previousElementFocused:
            return previousElement.map { ($0, kAXFocusedAttribute) }
        }
    }

    private func requiredBackgroundFocusBooleanSlots(
        targetWindow: AXUIElement,
        targetElement: AXUIElement,
        previousWindow: AXUIElement?,
        previousElement: AXUIElement?,
        mode: BackgroundDeliverySession.Mode
    ) -> [BackgroundFocusBooleanSlot] {
        guard mode == .preparedTargetedInput else { return [] }
        var required: [BackgroundFocusBooleanSlot] = [
            .targetWindowMain,
            .targetWindowFocused,
            .targetElementFocused
        ]
        if let previousWindow {
            if !CFEqual(previousWindow, targetWindow) {
                required.append(contentsOf: [
                    .previousWindowMain,
                    .previousWindowFocused
                ])
            }
        } else {
            // A prepared session may never exist without an exact prior window;
            // include its slots so the defensive apply-time guard also fails closed.
            required.append(contentsOf: [
                .previousWindowMain,
                .previousWindowFocused
            ])
        }
        if let previousElement {
            if !CFEqual(previousElement, targetElement) {
                required.append(.previousElementFocused)
            }
        }
        return required
    }

    private func applyBackgroundFocus(_ session: BackgroundDeliverySession) async -> Bool {
        let requiredBooleanSlots = requiredBackgroundFocusBooleanSlots(
            targetWindow: session.window,
            targetElement: session.element,
            previousWindow: session.previouslyFocusedWindow,
            previousElement: session.previouslyFocusedElement,
            mode: session.mode
        )
        guard session.mode == .preparedTargetedInput,
              preparedTargetFocusBoundaryIsSafe(session),
              session.lifecycle.canBegin,
              session.focusBooleanSnapshot.containsAll(requiredBooleanSlots) else {
            logger.error("Background exact focus refused before its one bounded activation-state session targetPid=\(session.processIdentifier, privacy: .public)")
            return false
        }
        let targetPID = session.processIdentifier
        guard session.lifecycle.begin(open: {
            CursorPaster.beginTargetedInputSession(pid: targetPID)
        }) else {
            logger.error("Background exact focus could not begin its one bounded activation-state session targetPid=\(session.processIdentifier, privacy: .public)")
            return false
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        guard preparedTargetFocusBoundaryIsSafe(session) else {
            logger.error("Background exact focus refused because the target became frontmost during activation-state settlement targetPid=\(session.processIdentifier, privacy: .public)")
            return false
        }
        let appElement = AXUIElementCreateApplication(session.processIdentifier)
        guard preparedTargetFocusBoundaryIsSafe(session) else { return false }
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

        let actualWindow = elementAttribute(kAXFocusedWindowAttribute, from: appElement)
        let actualElement = elementAttribute(kAXFocusedUIElementAttribute, from: appElement)
        // Setter/action return codes are diagnostics, not proof. Electron has
        // returned success while ignoring events, and some apps report an unsupported
        // redundant setter after accepting the essential focus change. The verified
        // live internal window + element and target-not-system-focused check are the
        // load-bearing conditions. Ethan may move freely between unrelated apps.
        let verified = actualWindow.map { CFEqual($0, session.window) } == true
            && actualElement.map { CFEqual($0, session.element) } == true
            && preparedTargetFocusBoundaryIsSafe(session)

        if !verified {
            logger.error("Background exact focus verification failed targetPid=\(session.processIdentifier, privacy: .public) expectedWindowHash=\(CFHash(session.window), privacy: .public) actualWindowHash=\(actualWindow.map { String(CFHash($0)) } ?? "nil", privacy: .public) expectedElementHash=\(CFHash(session.element), privacy: .public) actualElementHash=\(actualElement.map { String(CFHash($0)) } ?? "nil", privacy: .public) mainAX=\(mainResult.rawValue, privacy: .public) windowAX=\(windowResult.rawValue, privacy: .public) windowFocusedAX=\(windowFocusedResult.rawValue, privacy: .public) elementAX=\(elementResult.rawValue, privacy: .public) elementFocusedAX=\(elementFocusedResult.rawValue, privacy: .public) preparationFrontmostPid=\(session.frontmostPIDAtPreparation, privacy: .public) actualFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        }
        return verified
    }

    private func preparedTargetFocusBoundaryIsSafe(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        preparedTargetFocusBoundaryStatus(session) == .safe
    }

    private func preparedTargetFocusBoundaryStatus(
        _ session: BackgroundDeliverySession
    ) -> BackgroundTeardownBoundaryStatus {
        guard !session.app.isTerminated else { return .targetTerminated }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        let systemFocus = systemFocusedElement()
        if frontmostPID == session.processIdentifier
            || systemFocus?.pid == session.processIdentifier {
            return .targetOwnsSystemFocus
        }
        guard frontmostPID != nil else { return .frontmostUnavailable }
        guard systemFocus != nil else { return .systemFocusUnavailable }
        return .safe
    }

    private func backgroundFocusBoundaryIsSafeAfterSubmission(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard !session.app.isTerminated,
              let systemFocus = systemFocusedElement() else {
            return false
        }
        switch session.mode {
        case .preparedTargetedInput:
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
                    != session.processIdentifier
                && systemFocus.pid != session.processIdentifier
        case .directExactElement:
            return systemFocus.pid != session.processIdentifier
                || !CFEqual(systemFocus.element, session.element)
        }
    }

    /// Read-only proof for every insertion chunk and irreversible Send boundary.
    /// It intentionally permits Ethan to move from unrelated app A to B.
    private func backgroundSessionRemainsPrepared(
        _ session: BackgroundDeliverySession
    ) -> Bool {
        guard backgroundDeliveryFastBoundaryMatches(session),
              resolvedExactElement(for: session.target).map({
                  CFEqual($0, session.element)
              }) == true,
              liveWindow(for: session.target, resolvedElement: session.element).map({
                  CFEqual($0, session.window)
              }) == true else {
            return false
        }
        return true
    }

    private func visitBoundedDescendants(
        of root: AXUIElement,
        maximumDepth: Int,
        state: BoundedTraversalState,
        deadline: TimeInterval,
        boundary: () -> Bool,
        visitor: (AXUIElement) -> Bool
    ) async -> BoundedTraversalResult {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var visitedCount = 0
        var truncated = false
        while cursor < queue.count {
            guard boundary() else {
                return BoundedTraversalResult(completion: .boundaryChanged)
            }
            guard !Task.isCancelled else {
                return BoundedTraversalResult(completion: .cancelled)
            }
            guard state.remainingNodeBudget > 0,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                return BoundedTraversalResult(completion: .exhausted)
            }
            let (element, depth) = queue[cursor]
            cursor += 1
            guard state.visitedNodeHashes.insert(CFHash(element)).inserted else {
                continue
            }
            state.remainingNodeBudget -= 1
            visitedCount += 1
            guard visitor(element) else {
                return BoundedTraversalResult(completion: .stoppedByVisitor)
            }
            if visitedCount.isMultiple(of: 24) {
                await Task.yield()
                guard boundary() else {
                    return BoundedTraversalResult(completion: .boundaryChanged)
                }
            }
            let children = traversalChildren(of: element, state: state)
            guard depth < maximumDepth else {
                if !children.isEmpty { truncated = true }
                continue
            }
            let pendingCount = queue.count - cursor
            let availableSlots = max(
                0,
                state.remainingNodeBudget - pendingCount
            )
            if children.count > availableSlots { truncated = true }
            queue.append(contentsOf: children.prefix(availableSlots).map {
                ($0, depth + 1)
            })
        }
        guard boundary() else {
            return BoundedTraversalResult(completion: .boundaryChanged)
        }
        return BoundedTraversalResult(
            completion: truncated ? .exhausted : .completed
        )
    }

    static func isAuditedOpenAISubmitBuild(
        applicationBundleName: String?,
        bundleIdentifier: String?,
        shortVersion: String?,
        build: String?,
        chromium: String?
    ) -> Bool {
        guard bundleIdentifier == "com.openai.codex" else { return false }
        switch applicationBundleName {
        case auditedCodexSubmitBuild.applicationBundleName:
            return shortVersion == auditedCodexSubmitBuild.shortVersion
                && build == auditedCodexSubmitBuild.build
                && chromium == auditedCodexSubmitBuild.chromium
        case auditedChatGPTSubmitBuild.applicationBundleName:
            return shortVersion == auditedChatGPTSubmitBuild.shortVersion
                && build == auditedChatGPTSubmitBuild.build
                && chromium == auditedChatGPTSubmitBuild.chromium
        default:
            return false
        }
    }

    static func semanticSendGeometryMatches(
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
        return editorFrame.insetBy(dx: -360, dy: -320).contains(center)
    }

    /// Own the action closure inside the final semantic proof so rejected states have
    /// zero side effects in production and unit tests. The unlabelled exception remains
    /// valid only when the caller has re-proven the exact audited Codex/ChatGPT app
    /// name plus build tuple and the button still has no accepted label at this same
    /// boundary.
    static func performProvenSemanticSend(
        isUnambiguous: Bool,
        pidMatches: Bool,
        windowMatches: Bool,
        geometryMatches: Bool,
        roleMatches: Bool,
        enabled: Bool,
        label: String?,
        labelWasReadable: Bool,
        allowsAuditedUnlabelledSend: Bool,
        hasPressAction: Bool,
        boundaryMatches: Bool,
        action: () -> Int32
    ) -> NearbySubmitButtonResult {
        guard isProvenSemanticSendBoundary(
            isUnambiguous: isUnambiguous,
            pidMatches: pidMatches,
            windowMatches: windowMatches,
            geometryMatches: geometryMatches,
            roleMatches: roleMatches,
            enabled: enabled,
            label: label,
            labelWasReadable: labelWasReadable,
            allowsAuditedUnlabelledSend: allowsAuditedUnlabelledSend,
            hasPressAction: hasPressAction,
            boundaryMatches: boundaryMatches
        ) else {
            return .unavailable
        }
        let result = action()
        return result == AXError.success.rawValue
            ? .pressed
            : .failed(result)
    }

    static func isProvenSemanticSendBoundary(
        isUnambiguous: Bool,
        pidMatches: Bool,
        windowMatches: Bool,
        geometryMatches: Bool,
        roleMatches: Bool,
        enabled: Bool,
        label: String?,
        labelWasReadable: Bool,
        allowsAuditedUnlabelledSend: Bool,
        hasPressAction: Bool,
        boundaryMatches: Bool
    ) -> Bool {
        isUnambiguous
            && pidMatches
            && windowMatches
            && geometryMatches
            && roleMatches
            && enabled
            && labelWasReadable
            && (isProvenSemanticSendLabel(label)
                || (allowsAuditedUnlabelledSend && label == nil))
            && hasPressAction
            && boundaryMatches
    }

    static func isProvenSemanticSendLabel(_ label: String?) -> Bool {
        guard let label else { return false }
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "send", "send message", "send follow-up", "submit":
            return true
        default:
            return false
        }
    }

    private static func matchesAuditedOpenAISubmitBuild(
        _ app: NSRunningApplication
    ) -> Bool {
        guard let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL) else {
            return false
        }
        return isAuditedOpenAISubmitBuild(
            applicationBundleName: bundleURL.lastPathComponent,
            bundleIdentifier: bundle.bundleIdentifier,
            shortVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            chromium: bundle.object(
                forInfoDictionaryKey: "ChromiumBaseVersion"
            ) as? String
        )
    }

    private static func applicationIdentitySnapshot(
        for app: NSRunningApplication
    ) -> ApplicationIdentitySnapshot {
        let bundleURL = app.bundleURL
        let bundle = bundleURL.flatMap(Bundle.init(url:))
        return ApplicationIdentitySnapshot(
            applicationBundleName: bundleURL?.lastPathComponent ?? "unknown",
            bundleIdentifier: bundle?.bundleIdentifier ?? "unknown",
            shortVersion: bundle?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            build: bundle?.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            chromium: bundle?.object(
                forInfoDictionaryKey: "ChromiumBaseVersion"
            ) as? String ?? "unknown"
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

    /// A modifier/media-key transition can briefly make the system-wide focused-element
    /// read unavailable even though both the saved target and Ethan's foreground app
    /// are still valid. This retry is read-only and tightly bounded: it never activates
    /// an app, rewrites focus, or retries any irreversible delivery action.
    private func systemFocusedElementWithBoundedRetry()
        async -> (element: AXUIElement, pid: pid_t)? {
        let attempts = 3
        for attempt in 0..<attempts {
            if let focused = systemFocusedElement() {
                return focused
            }
            guard attempt + 1 < attempts else { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
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

    private func elementReferenceAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> ElementReferenceRead {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        switch result {
        case .success:
            guard let value else { return .absent }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return .failed(AXError.illegalArgument.rawValue)
            }
            return .value(value as! AXUIElement)
        case .noValue:
            return .absent
        default:
            return .failed(result.rawValue)
        }
    }

    private func elementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    /// Chromium can publish FooterActions only through navigation order even while it
    /// also exposes a populated but incomplete ordinary child list. Start with the
    /// compact navigation order, then merge visible and ordinary children, deduplicated
    /// by AX identity. The existing node/depth/deadline bounds still cap the walk.
    static func mergedTraversalChildren<Element>(
        visible: [Element],
        ordinary: [Element],
        navigationOrder: [Element],
        areEquivalent: (Element, Element) -> Bool
    ) -> [Element] {
        var merged: [Element] = []
        for candidate in navigationOrder + visible + ordinary where
            !merged.contains(where: { areEquivalent($0, candidate) }) {
            merged.append(candidate)
        }
        return merged
    }

    private func traversalChildren(
        of element: AXUIElement,
        state: BoundedTraversalState
    ) -> [AXUIElement] {
        let visible = elementArrayAttribute(kAXVisibleChildrenAttribute, from: element)
        let ordinary = elementArrayAttribute(kAXChildrenAttribute, from: element)
        let navigationOrder = elementArrayAttribute(
            "AXChildrenInNavigationOrder",
            from: element
        )
        let merged = Self.mergedTraversalChildren(
            visible: visible,
            ordinary: ordinary,
            navigationOrder: navigationOrder,
            areEquivalent: { CFEqual($0, $1) }
        )
        state.navigationChildEdges += navigationOrder.count
        state.visibleChildEdges += visible.count
        state.ordinaryChildEdges += ordinary.count
        state.mergedChildEdges += merged.count
        return merged
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func submitLabelState(for element: AXUIElement) -> SubmitLabelState {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            )
            switch result {
            case .success:
                guard let value else { continue }
                guard let string = value as? String else { return .unreadable }
                let normalized = string.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !normalized.isEmpty {
                    return .labelled(normalized.lowercased())
                }
            case .noValue, .attributeUnsupported:
                continue
            default:
                return .unreadable
            }
        }
        return .unlabelled
    }

    private func supportsPressAction(_ element: AXUIElement) -> Bool {
        var actionNames: CFArray?
        guard AXUIElementCopyActionNames(element, &actionNames) == .success,
              let names = actionNames as? [String] else {
            return false
        }
        return names.contains(kAXPressAction as String)
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
