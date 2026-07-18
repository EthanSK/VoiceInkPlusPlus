import Foundation
import AppKit   // NSWorkspace (frontmost-app pid for VIPPDebug paste logging)
import os

@MainActor
final class TranscriptionDelivery {
    enum PasteDeliveryStrategy: Equatable {
        case legacyCurrentKeyboardInput
        case exactSavedInput
    }

    static func pasteDeliveryStrategy(
        exactInputDeliveryEnabled: Bool = VoiceInkDeliveryFeatureFlags
            .exactInputDeliveryEnabled()
    ) -> PasteDeliveryStrategy {
        exactInputDeliveryEnabled
            ? .exactSavedInput
            : .legacyCurrentKeyboardInput
    }

    /// The native Terminal/iTerm implementation remains compiled and unit-testable,
    /// but its decision-time tab/pane and same-process focus proofs are not yet strong
    /// enough for a numbered release. Until those gates pass, preserve the ordinary
    /// exact-current-input foreground path and fail closed for a background terminal.
    static let nativeTerminalExactSessionDeliveryEnabled = false
    enum ExactInputInitialDeliveryRoute: Equatable {
        case foregroundWithoutFocusMutation
        case nonActivatingExactInput
    }

    static func exactInputInitialDeliveryRoute(
        exactInputOwnsKeyboardFocus: Bool
    ) -> ExactInputInitialDeliveryRoute {
        // ChatGPT's Option-Space panel can own real system keyboard focus without its
        // process becoming NSWorkspace.frontmostApplication. Normal HID paste belongs
        // to the keyboard-focused input, so frontmost equality is not a requirement.
        // The same rule keeps focused Codex/ChatGPT on the proven foreground Cmd-V path:
        // forcing an already-focused exact composer through background preparation made
        // insertion succeed and then lose its Send boundary during a redundant refresh.
        // The foreground path still freezes the unrelated frontmost PID separately so a
        // later user switch cancels the pending key sequence without activating anything.
        return exactInputOwnsKeyboardFocus
            ? .foregroundWithoutFocusMutation
            : .nonActivatingExactInput
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")
    // VIPPDebug: see RecorderUIManager for the filter predicate. Tracks which delivery
    // branch runs and the actual paste (text length) so an empty/suppressed paste is
    // distinguishable from a real one in the unified log.
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")
    private static let openAIComposerBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.chat"
    ]
    private static let chatComposerBundleIdentifiers =
        openAIComposerBundleIdentifiers.union([
            "com.anthropic.claudefordesktop",
            "ru.keepcoder.Telegram"
        ])

    static func isChatComposer(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return chatComposerBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Every allowlisted foreground chat fallback uses one ordinary humanized HID
    /// Return. Never use System Events here: AppleScript targets whichever app is
    /// frontmost when execution reaches it and can drift if Ethan clicks away after the
    /// preflight. The exact-focus preflight runs again at the HID Return-down boundary.
    static func usesHumanizedHIDForegroundReturn(
        bundleIdentifier: String?
    ) -> Bool {
        isChatComposer(bundleIdentifier: bundleIdentifier)
    }

    static func shouldUseTargetedUnicodeFallback(
        after result: FocusLockService.BackgroundTextInsertionResult,
        requiresDirectAccessibilityInsertion: Bool
    ) -> Bool {
        result == .unavailable && !requiresDirectAccessibilityInsertion
    }

    /// Accessibility-first insertion is deliberately orchestrated through closures so
    /// tests can count every mutation attempt without touching a live app. Telegram may
    /// reuse one editor/window wrapper across chats, so its Unicode fallback receives
    /// the complete readable-chat boundary before every irreversible chunk—not a cheap
    /// wrapper-only checkpoint. A setter error is verified without retry because the
    /// target may already have accepted the text.
    static func executeAccessibilityFirstBackgroundInsertion(
        requiresDirectAccessibilityInsertion: Bool,
        attemptAccessibility: () -> FocusLockService.BackgroundTextInsertionResult,
        fullBoundaryMatches: @escaping () -> Bool,
        onUnicodeFallback: () -> Void = {},
        onAccessibilityError: (Int32) -> Void = { _ in },
        targetedUnicode: (@escaping (Int) -> Bool) async -> Bool
    ) async -> Bool {
        let accessibilityResult = attemptAccessibility()
        switch accessibilityResult {
        case .acceptedSelectedText:
            return true
        case .unavailable:
            guard shouldUseTargetedUnicodeFallback(
                after: accessibilityResult,
                requiresDirectAccessibilityInsertion:
                    requiresDirectAccessibilityInsertion
            ), fullBoundaryMatches() else {
                return false
            }
            onUnicodeFallback()
            return await targetedUnicode { _ in
                fullBoundaryMatches()
            }
        case .failed(let error):
            onAccessibilityError(error)
            return true
        case .focusSafetyViolation:
            return false
        }
    }

    enum ChatComposerSubmissionVerification: Equatable {
        case verified
        case unchanged
        case modifiedWithoutSubmit
        case unavailable
    }

    enum NativeTerminalDeliveryVerification: Equatable {
        case verified
        case unchanged
        case modifiedWithoutSubmit
        case unavailable
    }

    static func classifyNativeTerminalDelivery(
        from previousText: String,
        to currentText: String?,
        insertedText: String,
        autoSendEnabled: Bool
    ) -> NativeTerminalDeliveryVerification {
        guard !insertedText.isEmpty, let currentText else {
            return .unavailable
        }
        guard currentText != previousText else { return .unchanged }
        let previousOccurrences = previousText
            .components(separatedBy: insertedText).count - 1
        let currentOccurrences = currentText
            .components(separatedBy: insertedText).count - 1
        guard currentOccurrences > previousOccurrences,
              let insertedRange = currentText.range(
                of: insertedText,
                options: .backwards
              ) else {
            // Full-screen Claude/Codex TUIs and aggressive scrollback trimming may
            // repaint away the prompt before the bounded read. That is indeterminate,
            // never permission to repeat the one native mutation.
            return .unavailable
        }
        guard autoSendEnabled else { return .verified }
        let suffix = currentText[insertedRange.upperBound...]
        return suffix.contains("\n") || suffix.contains("\r")
            ? .verified
            : .modifiedWithoutSubmit
    }

    enum ForegroundSemanticActionPlan: Equatable {
        /// AXPress returned either success or an error. Both mean one irreversible
        /// action may have reached the app, so verification is the only safe next step.
        case verifyOnly
        /// No semantic action was issued; one normal Return is allowed only while the
        /// exact frozen composer still owns system keyboard focus.
        case issueExactFocusReturn
        /// Focus moved before any fallback action. The caller may continue through its
        /// frozen non-activating exact-input session, but must not reactivate the app.
        case focusMoved
    }

    enum BackgroundSemanticActionPlan: Equatable {
        /// AXPress may have reached the app whether it returned success or an AX error;
        /// never issue a second action until the exact composer post-state is known.
        case verifyOnly
        /// No semantic action was issued. One ordinary HID Return is allowed because
        /// the full saved composer boundary still owns system keyboard focus.
        case issueExactFocusReturn
        /// No labelled Send exists and the saved composer does not own keyboard focus.
        /// A background/process-targeted key is forbidden, so fail without an action.
        case failNoSafeAction
    }

    enum ForegroundAutoSendOutcome: String {
        case succeeded
        case indeterminate
        case focusMoved
        case failed
    }

    static func foregroundAutoSendIsVerifiedSuccess(
        _ outcome: ForegroundAutoSendOutcome
    ) -> Bool {
        outcome == .succeeded
    }

    /// Chat composers can briefly expose a newline or another non-empty mutation
    /// after accepting Return and before React replaces/clears the editor. Only a
    /// verified clear is conclusive before the deadline; `modifiedWithoutSubmit`
    /// remains a valid final failure classification after the full settling window.
    static func chatSubmissionVerificationIsConclusiveBeforeDeadline(
        _ verification: ChatComposerSubmissionVerification
    ) -> Bool {
        verification == .verified
    }

    /// Settle observations for one already-issued Send/Return action. Verification is
    /// read-only: transient non-empty mutations keep polling, a later clear wins, and a
    /// persistent mutation remains the final failure classification. Keeping action
    /// issuance outside this helper makes it impossible for polling to double-submit.
    static func settledChatSubmissionVerification(
        _ observations: [ChatComposerSubmissionVerification]
    ) -> ChatComposerSubmissionVerification {
        observations.first(where: { $0 == .verified })
            ?? observations.last
            ?? .unavailable
    }

    /// Generic foreground targets get exactly one key action. The historical
    /// CursorPaster default issues a redundant plain Enter; that retry is unsafe for
    /// terminals/editors and belongs only to the separately verified OpenAI unchanged-
    /// composer branch below. Keep this wrapper injectable so tests assert the real
    /// orchestration argument and action count without posting a live keyboard event.
    static func executeOneShotGenericForegroundAutoSend(
        issue: (_ sendRedundantEnter: Bool) async -> CursorPaster.AutoSendResult
    ) async -> ForegroundAutoSendOutcome {
        let result = await issue(false)
        // Event creation/posting is not surface verification. Keep a successfully
        // issued generic key quiet but indeterminate; only chat clear/reset or a
        // host-native Terminal/iTerm session transition may report `.succeeded`.
        return result.didPostAutoSendCommand ? .indeterminate : .failed
    }

    static func foregroundPastePreflightMatches(
        expectedFrontmostPID: pid_t?,
        currentFrontmostPID: pid_t?,
        savedInputOwnsKeyboardFocus: Bool
    ) -> Bool {
        guard let expectedFrontmostPID,
              currentFrontmostPID == expectedFrontmostPID else {
            return false
        }
        return savedInputOwnsKeyboardFocus
    }

    static func foregroundSemanticActionPlan(
        result: FocusLockService.NearbySubmitButtonResult,
        exactInputOwnsKeyboardFocus: Bool
    ) -> ForegroundSemanticActionPlan {
        switch result {
        case .pressed, .failed:
            return .verifyOnly
        case .unavailable:
            return exactInputOwnsKeyboardFocus
                ? .issueExactFocusReturn
                : .focusMoved
        }
    }

    static func backgroundSemanticActionPlan(
        result: FocusLockService.NearbySubmitButtonResult,
        exactInputOwnsKeyboardFocus: Bool
    ) -> BackgroundSemanticActionPlan {
        switch result {
        case .pressed, .failed:
            return .verifyOnly
        case .unavailable:
            return exactInputOwnsKeyboardFocus
                ? .issueExactFocusReturn
                : .failNoSafeAction
        }
    }

    static func shouldRetryBackgroundExactFocusReturn(
        bundleIdentifier: String?,
        initialPlan: BackgroundSemanticActionPlan,
        verification: ChatComposerSubmissionVerification,
        exactInputOwnsKeyboardFocus: Bool
    ) -> Bool {
        openAIComposerBundleIdentifiers.contains(bundleIdentifier ?? "")
            && initialPlan == .issueExactFocusReturn
            && verification == .unchanged
            && exactInputOwnsKeyboardFocus
    }

    static func shouldRetryForegroundSemanticSendWithReturn(
        bundleIdentifier: String?,
        initialPlan: ForegroundSemanticActionPlan,
        semanticResult: FocusLockService.NearbySubmitButtonResult,
        verification: ChatComposerSubmissionVerification,
        exactInputOwnsKeyboardFocus: Bool
    ) -> Bool {
        guard openAIComposerBundleIdentifiers.contains(bundleIdentifier ?? ""),
              verification == .unchanged,
              exactInputOwnsKeyboardFocus else {
            return false
        }
        // A proven semantic press that left the readable composer unchanged may fall
        // back to one HID Return. If no labelled Send existed, the first exact-focus HID
        // Return may itself be dropped by Electron; that readable unchanged state permits
        // exactly one retry. An AX error may already have triggered the action and never
        // retries, and modified/unreadable states are excluded by the guard above.
        return semanticResult == .pressed
            || (semanticResult == .unavailable
                && initialPlan == .issueExactFocusReturn)
    }

    /// A chat submit is proven by the exact composer clearing/resetting. Electron
    /// contenteditables can expose a reset editor as whitespace/newline scaffolding,
    /// so whitespace-only is equivalent to empty; the previous transcript plus a
    /// newline remains a non-empty mutation and must still fail verification. A rendered
    /// message echo is useful telemetry, but Codex/ChatGPT can omit or delay that text
    /// in a background Accessibility tree after Return has already been handled. Conversely,
    /// any mutation retaining non-whitespace text (for example, the transcript plus a
    /// newline) is not proof of submission.
    /// Keep this classifier pure so classification is unit tested independently from
    /// the app-specific Accessibility transport.
    static func classifyChatComposerSubmission(
        from previousText: String,
        to currentText: String?
    ) -> ChatComposerSubmissionVerification {
        guard let currentText else { return .unavailable }
        guard currentText != previousText else { return .unchanged }
        return currentText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            ? .verified
            : .modifiedWithoutSubmit
    }

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let pasteTarget: RecordingPasteTarget
        // VIPP (skip-mode-processing feature): when true, THIS delivery must paste the RAW
        // transcript and run NO mode post-processing — no custom-command/script
        // (deliverCustomCommand), no `.respond` (deliverResponse). The pipeline already
        // forces `output.outputMode == .paste` when this is set, but we also branch on this
        // explicitly in deliver() so the raw-paste guarantee holds even if `output` were
        // ever wrong. Defaults to false (normal mode processing). One-shot, per-recording.
        var skipPostProcessing: Bool = false
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        vippLog.info("deliver: enter status=\(request.transcription.transcriptionStatus ?? "nil", privacy: .public) outputMode=\(String(describing: request.output.outputMode), privacy: .public) textChars=\(request.text?.count ?? -1, privacy: .public) followUp=\(request.isAssistantFollowUp, privacy: .public) skip=\(request.skipPostProcessing, privacy: .public)")

        // ── VIPP (skip-mode-processing feature) — RAW-PASTE GUARANTEE ────────────────
        // This is THE decision point the user's "skip script" button must control:
        // TranscriptionDelivery routes purely on request.output.outputMode below
        // (.respond → deliverResponse, .customCommand → deliverCustomCommand/script,
        // else → paste). If the one-shot skip flag is set, we DETERMINISTICALLY take the
        // raw-paste branch here — bypassing both deliverCustomCommand (the Mode's shell
        // script) and deliverResponse — regardless of what request.output.outputMode says.
        // This closes the reported bug where the mode's script still ran with skip engaged:
        // even if the upstream `.paste` override were ever lost, this branch forces raw paste.
        // (Assistant follow-ups are a different flow entirely and never carry skip.)
        if request.skipPostProcessing,
           !request.isAssistantFollowUp,
           request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
            vippLog.info("deliver: skipPostProcessing ON → FORCING raw paste (bypassing custom-command/respond) outputModeWas=\(String(describing: request.output.outputMode), privacy: .public)")
            // The paste path consumes/clears the focus lock itself; nothing else to release.
            if let text = request.text {
                // Force a plain `.paste` config: strip the customCommand AND disable
                // auto-send. The skip toggle means "raw transcript, do nothing else" —
                // and "nothing else" includes the mode's auto-send Enter. If we kept
                // request.output.autoSendKey here, a paste-mode (or custom-command-mode)
                // configured to hit Return would STILL send after the raw paste, which is
                // exactly what the user did NOT want. `.none` = paste the text, no Enter.
                let rawOutput = OutputRuntimeConfiguration(
                    mode: request.output.mode,
                    outputMode: .paste,
                    autoSendKey: .none,
                    customCommand: nil
                )
                await paste(
                    text,
                    target: request.pasteTarget,
                    output: rawOutput,
                    actions: actions,
                    legacyUsesCurrentModeAutoSend: false
                )
            } else {
                FocusLockService.shared.clearLock()
                await actions.dismiss()
            }
            return
        }

        // Feature A (focus lock): ONLY the paste path consumes a focus lock. Every
        // other delivery outcome below (incomplete transcription, assistant
        // follow-up, respond mode, custom command, or empty text) must release any
        // armed lock here so it can't leak into the next recording. The paste path
        // does its own restore+clear, so we leave the lock intact only for it.
        let isPlainPaste = !request.isAssistantFollowUp
            && request.output.outputMode == .paste
            && request.text != nil
            && request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue
        if !isPlainPaste {
            FocusLockService.shared.clearLock()
        }

        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
           request.responseConfig != nil || request.responseError != nil {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(text, target: request.pasteTarget, output: request.output, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
                  item.responseConfig != nil {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
              let command = customCommand.trimmedCommand else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: commandText)
        }
    }

    private func runCustomCommand(command: String, commandText: String) async {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice("Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error("Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)")
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(
        _ text: String,
        target: RecordingPasteTarget,
        output: OutputRuntimeConfiguration,
        actions: Actions,
        legacyUsesCurrentModeAutoSend: Bool = true
    ) async {
        let textToPaste = deliverableText(from: text)
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")

        // Compatibility escape hatch, deliberately before every saved-target guard.
        // When exact delivery is disabled, a stale/missing `RecordingPasteTarget` must
        // not block the dependable base-VoiceInk workflow. This path never activates,
        // internally focuses, re-resolves, or sends to the saved app: it uses only the
        // input that owns real keyboard focus when delivery occurs. The full exact
        // destination engine below remains intact and can be restored by the runtime
        // Settings flag after its physical Codex tests pass.
        if Self.pasteDeliveryStrategy() == .legacyCurrentKeyboardInput {
            await deliverToCurrentKeyboardInputLegacy(
                pastedText,
                usesCurrentModeAutoSend: legacyUsesCurrentModeAutoSend,
                actions: actions
            )
            return
        }

        vippLog.info("paste: BEGIN len=\(pastedText.count, privacy: .public) destination=\(String(describing: target.destination), privacy: .public) targetCaptured=\(target.focusedInput != nil, privacy: .public) exactInput=\(target.focusedInput?.hasExactInput ?? false, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        SoundManager.shared.playStopSound()
        FocusLockService.shared.setStartInputIndicatorVisible(target.destination == .recordingStart)
        await actions.dismiss()

        guard let focusedInput = target.focusedInput else {
            // A no-caret recordingStart application fallback is allowed to become an
            // exact composer only immediately after microphone start, while its saved
            // window/task identity is still the capture-time one. Never retry that
            // discovery here: Ethan may have changed tasks/tabs during dictation.
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }

        let autoSendKey = output.outputMode == .paste
            ? output.autoSendKey
            : .none
        let exactTargetOwnsKeyboardFocus = FocusLockService.shared
            .targetOwnsSystemKeyboardFocus(focusedInput)
        // Terminal/iTerm editor wrappers are not tab/session identities. Route these
        // hosts before every generic foreground/background branch so selecting terminal
        // B after capturing terminal A cannot split text and Return across sessions.
        // Missing native identity or an unsupported key fails closed before mutation;
        // there is deliberately no PID/AX/clipboard fallback into the host.
        if FocusLockService.shared.requiresNativeTerminalSessionBinding(
            for: focusedInput
        ) {
            if Self.nativeTerminalExactSessionDeliveryEnabled {
                await deliverToNativeTerminalSession(
                    pastedText,
                    target: target,
                    focusedInput: focusedInput,
                    autoSendKey: autoSendKey
                )
                return
            }
            guard exactTargetOwnsKeyboardFocus else {
                handleBackgroundPasteFailure(
                    pastedText,
                    destination: target.destination,
                    detail: "background Terminal/iTerm exact-session delivery is disabled until its tab/pane identity proof is complete"
                )
                return
            }
        }
        guard focusedInput.hasForegroundInput else {
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }

        let targetPID = focusedInput.processIdentifier
        let previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication

        if Self.exactInputInitialDeliveryRoute(
            exactInputOwnsKeyboardFocus: exactTargetOwnsKeyboardFocus
        ) == .nonActivatingExactInput {
            guard focusedInput.hasExactInput else {
                // A retained-focused-only wrapper is intentionally incapable of
                // following Ethan after focus moves. Copy and report instead of
                // re-resolving or activating it.
                handleMissingPasteTarget(pastedText, destination: target.destination)
                return
            }
            await deliverToBackgroundExactInput(
                pastedText,
                target: target,
                focusedInput: focusedInput,
                autoSendKey: autoSendKey
            )
            return
        }

        // Do not call restoreFocus here. Ethan can click another app—or input B in
        // this same app—after the route check above. An activating/focus-setting
        // restore would steal control or rewrite B back to saved input A. The target
        // was non-mutatingly verified above, and the Cmd-V preflight below repeats
        // that exact check at the irreversible key boundary; drift falls through to
        // the frozen non-activating background route.
        let foregroundInput = focusedInput
        guard let expectedFrontmostPID =
                previouslyFrontmostApplication?.processIdentifier else {
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }

        vippLog.info("paste: foreground target verified without focus mutation exactBackgroundCapable=\(foregroundInput.hasExactInput, privacy: .public); issuing paste keystroke targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")

        let textBeforeForegroundPaste = FocusLockService.shared
            .focusedExactInputTextFast(foregroundInput)
        let pasteTask = CursorPaster.startPasteAtCursor(
            pastedText,
            preflight: {
                Self.foregroundPastePreflightMatches(
                    expectedFrontmostPID: expectedFrontmostPID,
                    currentFrontmostPID: NSWorkspace.shared.frontmostApplication?
                        .processIdentifier,
                    savedInputOwnsKeyboardFocus: FocusLockService.shared
                        .retainedInputOwnsSystemKeyboardFocus(foregroundInput)
                )
            }
        ) // Use the proven foreground Cmd-V path from cba45ba, but cancel before Cmd-V if Ethan moved; the frozen exact-input route below can then continue without focus theft.

        // This path never activates or internally focuses another app, so there is no
        // displaced workspace to restore—even for ChatGPT's non-activating panel.
        let applicationToRestore: NSRunningApplication? = nil
        vippLog.info("paste: delivery scheduled targetPid=\(targetPID, privacy: .public) autoSend=\(autoSendKey.rawValue, privacy: .public) restorePid=\(applicationToRestore?.processIdentifier ?? -1, privacy: .public)")
        // Capture length for downstream telemetry/settlement policy. Generic foreground
        // delivery is one-shot: it never enables CursorPaster's historical redundant
        // Enter. Only the separately verified OpenAI unchanged-composer branch may
        // issue one bounded retry while that exact input still owns keyboard focus.
        let pastedLength = pastedText.count
        await Self.awaitForegroundDeliveryLifecycle { [self] in
            defer { FocusLockService.shared.clearLock() }

            let pasteResult = await pasteTask.value
            vippLog.info("paste: command completed result=\(String(describing: pasteResult), privacy: .public) targetPid=\(targetPID, privacy: .public)")
            guard pasteResult.didPostPasteCommand else {
                if foregroundInput.hasExactInput,
                   !Self.foregroundPastePreflightMatches(
                    expectedFrontmostPID: expectedFrontmostPID,
                    currentFrontmostPID: NSWorkspace.shared.frontmostApplication?
                        .processIdentifier,
                    savedInputOwnsKeyboardFocus: FocusLockService.shared
                        .retainedInputOwnsSystemKeyboardFocus(foregroundInput)
                   ) {
                    vippLog.notice("paste: user focus moved before foreground Cmd-V; retrying once through frozen non-activating exact-input delivery targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
                    await deliverToBackgroundExactInput(
                        pastedText,
                        target: target,
                        focusedInput: foregroundInput,
                        autoSendKey: autoSendKey
                    )
                    return
                }
                _ = ClipboardManager.copyToClipboard(pastedText)
                NotificationManager.shared.showNotification(
                    title: String(localized: "Couldn’t send the paste to the saved input — transcription copied to clipboard"),
                    type: .error
                )
                vippLog.error("paste: command was not posted; copied transcription to clipboard and skipped auto-send")
                if let applicationToRestore {
                    await restorePreviousApplication(applicationToRestore, displacedBy: targetPID)
                }
                return
            }

            if autoSendKey.isEnabled {
                let usesSemanticChatSubmit = autoSendKey == .enter
                    && Self.isChatComposer(
                        bundleIdentifier: foregroundInput.bundleIdentifier
                    )
                    && FocusLockService.supportsSemanticSend(
                        bundleIdentifier: foregroundInput.bundleIdentifier
                    )
                let autoSendOutcome: ForegroundAutoSendOutcome
                if usesSemanticChatSubmit {
                    if !FocusLockService.shared.retainedInputOwnsSystemKeyboardFocus(
                        foregroundInput
                    ) {
                        guard foregroundInput.hasExactInput else {
                            showAutoSendFailure(
                                "Transcription pasted, but the saved chat input lost focus before Send",
                                detail: "foreground-only input cannot detach targetPid=\(targetPID)"
                            )
                            return
                        }
                        await performDetachedChatAutoSendAfterForegroundPaste(
                            autoSendKey,
                            pastedText: pastedText,
                            previousText: textBeforeForegroundPaste,
                            target: foregroundInput
                        )
                        return
                    }
                    // Do not impose the old fixed 500 ms chat delay. Cmd-V has already
                    // been issued; poll the exact still-focused wrapper and continue as
                    // soon as it proves the transcript arrived. The full document/chat
                    // identity is revalidated below and again immediately before AXPress.
                    guard await waitForForegroundChatPaste(
                        pastedText,
                        previousText: textBeforeForegroundPaste,
                        target: foregroundInput
                    ) else {
                        showAutoSendFailure(
                            "Transcription paste was issued, but the saved chat input could not be verified before Send",
                            detail: "foreground chat paste readiness failed targetPid=\(targetPID)"
                        )
                        if let applicationToRestore {
                            await restorePreviousApplication(applicationToRestore, displacedBy: targetPID)
                        }
                        return
                    }
                    if !FocusLockService.shared.retainedInputOwnsSystemKeyboardFocus(
                        foregroundInput
                    ) {
                        guard foregroundInput.hasExactInput else {
                            showAutoSendFailure(
                                "Transcription pasted, but the saved chat input lost focus before Send",
                                detail: "foreground-only input cannot detach targetPid=\(targetPID)"
                            )
                            return
                        }
                        await performDetachedChatAutoSendAfterForegroundPaste(
                            autoSendKey,
                            pastedText: pastedText,
                            previousText: textBeforeForegroundPaste,
                            target: foregroundInput
                        )
                        return
                    }
                    // Do not call activating restoreFocus here. The exact composer was
                    // just verified; every semantic/Return action below rechecks it at
                    // the irreversible boundary. If Ethan moves, continue detached.
                    autoSendOutcome = await performAutoSend(
                        autoSendKey,
                        to: foregroundInput,
                        allowsApplicationFallback: false,
                        transcriptLength: pastedLength,
                        expectedFrontmostPID: expectedFrontmostPID
                    )
                    if autoSendOutcome == .focusMoved {
                        guard foregroundInput.hasExactInput else {
                            showAutoSendFailure(
                                "Transcription pasted, but the saved chat input lost focus before Send",
                                detail: "foreground-only input cannot detach targetPid=\(targetPID)"
                            )
                            return
                        }
                        await performDetachedChatAutoSendAfterForegroundPaste(
                            autoSendKey,
                            pastedText: pastedText,
                            previousText: textBeforeForegroundPaste,
                            target: foregroundInput
                        )
                        return
                    }
                } else {
                    // A posted Cmd-V is not proof that the destination accepted the
                    // transcript. Before any generic Return, require the exact retained
                    // input to expose a readable before/after delta containing this
                    // transcript. Unreadable or unchanged state fails closed; otherwise
                    // Return could submit stale text or an empty terminal command.
                    guard await waitForForegroundChatPaste(
                        pastedText,
                        previousText: textBeforeForegroundPaste,
                        target: foregroundInput
                    ) else {
                        showAutoSendFailure(
                            "Transcription paste was issued, but the saved input could not be verified before Return",
                            detail: "generic foreground insertion unverified targetPid=\(targetPID)"
                        )
                        return
                    }
                    guard Self.foregroundPastePreflightMatches(
                        expectedFrontmostPID: expectedFrontmostPID,
                        currentFrontmostPID: NSWorkspace.shared.frontmostApplication?
                            .processIdentifier,
                        savedInputOwnsKeyboardFocus: FocusLockService.shared
                            .retainedInputOwnsSystemKeyboardFocus(foregroundInput)
                    ) else {
                        showAutoSendFailure(
                            "Transcription pasted, but the saved input no longer had focus for Return",
                            detail: "foreground Return skipped without reactivating targetPid=\(targetPID)"
                        )
                        return
                    }
                    autoSendOutcome = await performAutoSend(
                        autoSendKey,
                        to: foregroundInput,
                        allowsApplicationFallback: false,
                        transcriptLength: pastedLength,
                        expectedFrontmostPID: expectedFrontmostPID
                    )
                }

                // Indeterminate means the one action may have worked but post-state was
                // unreadable. Keep it quiet for Ethan, but never emit success=true: the
                // release trace gate must represent verified submission only.
                let autoSendSucceeded = Self.foregroundAutoSendIsVerifiedSuccess(
                    autoSendOutcome
                )
                vippLog.info("paste: foreground auto-send finished success=\(autoSendSucceeded, privacy: .public) outcome=\(autoSendOutcome.rawValue, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
                if let applicationToRestore {
                    await restorePreviousApplication(applicationToRestore, displacedBy: targetPID)
                }

                guard autoSendOutcome != .failed else {
                    showAutoSendFailure(
                        "Transcription pasted, but couldn’t press Return automatically",
                        detail: "foreground Return produced no verified submit targetPid=\(targetPID)"
                    )
                    return
                }
            } else {
                // A posted Cmd-V is not proof that the exact input accepted the text.
                // Verify a readable before/after value without ever retrying the
                // mutation. Unreadable state remains quiet/indeterminate; a readable
                // unchanged or unrelated mutation is a real paste failure and keeps the
                // transcript safe on the clipboard.
                let verification = await waitForForegroundPasteVerification(
                    pastedText,
                    previousText: textBeforeForegroundPaste,
                    target: foregroundInput
                )
                switch verification {
                case .verified:
                    vippLog.info("paste: foreground text verified success=true targetPid=\(targetPID, privacy: .public) chars=\(pastedText.count, privacy: .public)")
                case .unavailable:
                    vippLog.notice("paste: foreground text post-state unreadable after one posted Cmd-V; no retry and no visible false-failure targetPid=\(targetPID, privacy: .public)")
                case .unchanged, .modifiedUnexpectedly:
                    _ = ClipboardManager.copyToClipboard(pastedText)
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Couldn’t verify the paste in the saved input — transcription copied to clipboard"),
                        type: .error
                    )
                    vippLog.error("paste: foreground Cmd-V did not produce the exact transcript change verification=\(String(describing: verification), privacy: .public) targetPid=\(targetPID, privacy: .public)")
                }
                if let applicationToRestore {
                    await restorePreviousApplication(
                        applicationToRestore,
                        displacedBy: targetPID
                    )
                }
            }
        }
    }

    /// Temporary base-VoiceInk compatibility route. It intentionally does not inspect
    /// the per-session saved target, so it cannot paste into an old/latching input or
    /// steal focus from Ethan. The only identity retained across the short Cmd-V/Return
    /// sequence is the keyboard-focused process plus the frontmost process; if either
    /// changes, the pending key is cancelled rather than drifting into another app.
    /// Same-app field selection remains ordinary macOS cursor behavior by design.
    private func deliverToCurrentKeyboardInputLegacy(
        _ pastedText: String,
        usesCurrentModeAutoSend: Bool,
        actions: Actions
    ) async {
        SoundManager.shared.playStopSound()
        FocusLockService.shared.setStartInputIndicatorVisible(false)
        FocusLockService.shared.clearLock()

        // Re-resolve the Mode from the app that owns keyboard focus at this final
        // delivery boundary. This reproduces upstream's live/current Mode behavior
        // instead of carrying the saved destination's Mode into an unrelated input.
        let currentModeResolution = ActiveWindowService.shared
            .beginApplyingConfiguration()
        let currentOutput = ModeRuntimeResolver
            .pasteTargetOutputConfiguration(
                mode: currentModeResolution.immediateConfiguration
            )
        let autoSendKey = usesCurrentModeAutoSend
            ? currentOutput.autoSendKey
            : .none

        await actions.dismiss()

        guard let expectedFrontmostPID = NSWorkspace.shared
                .frontmostApplication?.processIdentifier,
              let expectedKeyboardPID = FocusLockService.shared
                .systemKeyboardFocusedProcessIdentifier() else {
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Couldn’t find the current input — transcription copied to clipboard"),
                type: .error
            )
            vippLog.error("paste: legacy current-input delivery could not capture the live foreground/keyboard process boundary")
            return
        }

        let currentInputStillOwnsKeyboard = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == expectedFrontmostPID
                && FocusLockService.shared
                    .systemKeyboardFocusedProcessIdentifier()
                    == expectedKeyboardPID
        }

        vippLog.notice("paste: legacy current-input delivery BEGIN len=\(pastedText.count, privacy: .public) autoSend=\(autoSendKey.rawValue, privacy: .public) keyboardPid=\(expectedKeyboardPID, privacy: .public) frontmostPid=\(expectedFrontmostPID, privacy: .public)")
        let pasteResult = await CursorPaster.startPasteAtCursor(
            pastedText,
            preflight: currentInputStillOwnsKeyboard
        ).value
        guard pasteResult.didPostPasteCommand else {
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Couldn’t paste into the current input — transcription copied to clipboard"),
                type: .error
            )
            vippLog.error("paste: legacy current-input Cmd-V was cancelled or not posted keyboardPid=\(expectedKeyboardPID, privacy: .public)")
            return
        }

        vippLog.info("paste: legacy current-input Cmd-V posted success=true keyboardPid=\(expectedKeyboardPID, privacy: .public)")
        guard autoSendKey.isEnabled else { return }

        // Match upstream VoiceInk's simple current-cursor contract: let the foreground
        // paste settle, then issue one ordinary key. Do not run exact-input verification,
        // semantic Send discovery, background events, or a retry in compatibility mode.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let autoSendResult = await CursorPaster.performAutoSend(
            autoSendKey,
            transcriptLength: pastedText.count,
            expectedFrontmostPID: expectedFrontmostPID,
            method: .cgEvent,
            sendRedundantEnter: false,
            preflight: currentInputStillOwnsKeyboard
        )
        vippLog.info("paste: legacy current-input auto-send finished posted=\(autoSendResult.didPostAutoSendCommand, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) keyboardPid=\(expectedKeyboardPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")

        guard !autoSendResult.didPostAutoSendCommand else { return }
        NotificationManager.shared.showNotification(
            title: String(localized: "Transcription pasted, but couldn’t press Return automatically"),
            type: .error
        )
    }

    private func deliverToNativeTerminalSession(
        _ pastedText: String,
        target: RecordingPasteTarget,
        focusedInput: FocusLockService.Target,
        autoSendKey: AutoSendKey
    ) async {
        defer { FocusLockService.shared.clearLock() }
        let result = await FocusLockService.shared.performTerminalTextDelivery(
            pastedText,
            autoSendKey: autoSendKey,
            to: focusedInput
        )
        switch result {
        case .unavailable:
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "native terminal session/key unavailable; Apple Terminal paste-only and modified Return fail before mutation"
            )
        case .failed(let detail):
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "native terminal session delivery failed: \(detail)"
            )
        case .focusSafetyViolation:
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "native terminal operation did not preserve the non-activating focus boundary"
            )
        case .issued(let previousContents, let currentContents):
            let verification = Self.classifyNativeTerminalDelivery(
                from: previousContents,
                to: currentContents,
                insertedText: pastedText,
                autoSendEnabled: autoSendKey == .enter
            )
            let succeeded = verification == .verified
            vippLog.info("paste: background text verified success=\(succeeded, privacy: .public) targetPid=\(focusedInput.processIdentifier, privacy: .public) chars=\(pastedText.count, privacy: .public) route=terminalNativeAtomic verification=\(String(describing: verification), privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            if autoSendKey.isEnabled {
                vippLog.info("paste: background auto-send finished success=\(succeeded, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) route=terminalNativeAtomic verification=\(String(describing: verification), privacy: .public) surface=terminal targetPid=\(focusedInput.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            }
            if succeeded { return }
            switch verification {
            case .unavailable where autoSendKey == .enter:
                // The exact native write+newline was issued once. TUI repaint or
                // scrollback loss makes post-state unreadable, so keep telemetry quiet
                // and never display a false failure or retry Return.
                vippLog.notice("paste: exact terminal text+Return post-state became unreadable; no retry and no visible false-failure targetPid=\(focusedInput.processIdentifier, privacy: .public)")
            case .modifiedWithoutSubmit:
                showAutoSendFailure(
                    "Transcription inserted into the saved terminal session, but Return was not verified",
                    detail: "terminalNativeAtomic modifiedWithoutSubmit targetPid=\(focusedInput.processIdentifier)"
                )
            case .unchanged:
                handleBackgroundPasteFailure(
                    pastedText,
                    destination: target.destination,
                    detail: "exact terminal session contents remained unchanged after its one native operation"
                )
            case .unavailable, .verified:
                handleBackgroundPasteFailure(
                    pastedText,
                    destination: target.destination,
                    detail: "exact terminal mutation could not be verified"
                )
            }
        }
    }

    /// A user can click away after foreground Cmd-V was issued but before chat submit.
    /// Never reactivate the destination in that race. Re-open the same frozen exact-input
    /// session non-activatingly, prove the pasted transcript is still in that composer,
    /// press its explicit Send control once, and tear the session down. If the target app
    /// changed its own internal input/chat, preparation fails closed instead of stealing
    /// focus or sending into the newly selected surface.
    private func performDetachedChatAutoSendAfterForegroundPaste(
        _ autoSendKey: AutoSendKey,
        pastedText: String,
        previousText: String?,
        target: FocusLockService.Target
    ) async {
        guard let session = await FocusLockService.shared.prepareBackgroundDelivery(
            to: target
        ) else {
            showAutoSendFailure(
                "Transcription pasted, but the saved chat input could not be re-verified after focus moved",
                detail: "detached foreground chat submit preparation failed targetPid=\(target.processIdentifier)"
            )
            return
        }
        defer { FocusLockService.shared.finishBackgroundDelivery(session) }

        guard await waitForDetachedForegroundChatPaste(
            pastedText,
            previousText: previousText,
            session: session
        ) else {
            showAutoSendFailure(
                "Transcription pasted, but the saved chat input no longer contained it after focus moved",
                detail: "detached foreground chat paste settlement or exact-boundary verification failed targetPid=\(target.processIdentifier)"
            )
            return
        }

        vippLog.notice("paste: foreground chat lost keyboard focus after paste; continuing with non-activating exact semantic Send targetPid=\(target.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        await performBackgroundAutoSend(autoSendKey, session: session)
    }

    private func deliverToBackgroundExactInput(
        _ pastedText: String,
        target: RecordingPasteTarget,
        focusedInput: FocusLockService.Target,
        autoSendKey: AutoSendKey
    ) async {
        defer { FocusLockService.shared.clearLock() }
        guard let session = await FocusLockService.shared.prepareBackgroundDelivery(
            to: focusedInput
        ) else {
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "exact background focus preparation failed"
            )
            return
        }
        defer { FocusLockService.shared.finishBackgroundDelivery(session) }

        guard let textBeforeInsertion = FocusLockService.shared.backgroundInputText(
            for: session
        ) else {
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "saved input does not expose readable text for verification"
            )
            return
        }

        vippLog.info("paste: background exact focus verified targetPid=\(session.processIdentifier, privacy: .public) startFrontmostPid=\(session.frontmostProcessIdentifierAtStart, privacy: .public) destination=\(String(describing: target.destination), privacy: .public)")
        let insertionIssued = await issueBackgroundInsertion(
            pastedText,
            session: session
        )
        let insertionVerified: Bool
        if insertionIssued {
            insertionVerified = await waitForBackgroundInsertion(
                pastedText,
                previousText: textBeforeInsertion,
                session: session
            )
        } else {
            insertionVerified = false
        }
        guard insertionVerified,
              FocusLockService.shared.backgroundDeliveryFocusIsSafe(session) else {
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "targeted text was posted but exact insertion/frontmost verification failed"
            )
            return
        }

        vippLog.info("paste: background text verified success=true targetPid=\(session.processIdentifier, privacy: .public) chars=\(pastedText.count, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        guard autoSendKey.isEnabled else {
            vippLog.info("paste: background exact delivery finished success=true autoSend=none targetPid=\(session.processIdentifier, privacy: .public)")
            return
        }

        await performBackgroundAutoSend(autoSendKey, session: session)
    }

    /// Telegram's retained native editor has a real Accessibility insertion primitive.
    /// Prefer AXSelectedText so delivery is bound to the exact saved wrapper. If that
    /// attribute is genuinely unavailable before any mutation, the already-open bounded
    /// internal session may use the same Unicode event route as other exact targets. An
    /// AX setter error is never retried because Telegram may have inserted the text even
    /// while returning an error; verification, not the return code, decides the result.
    private func issueBackgroundInsertion(
        _ pastedText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> Bool {
        guard FocusLockService.shared.prefersAccessibilityTextInsertion(for: session) else {
            return await CursorPaster.typeTextIntoTargetedProcess(
                pastedText,
                pid: session.processIdentifier,
                sessionAlreadyPrepared: true,
                beforeChunk: { _ in
                    FocusLockService.shared
                        .backgroundTextEventBoundaryMatches(session)
                }
            )
        }

        let fullBoundaryMatches = {
            FocusLockService.shared.backgroundTextMutationBoundaryMatches(
                session
            )
        }
        let result = await Self.executeAccessibilityFirstBackgroundInsertion(
            requiresDirectAccessibilityInsertion:
                session.requiresDirectAccessibilityInsertion,
            attemptAccessibility: {
                FocusLockService.shared.insertTextUsingAccessibility(
                    pastedText,
                    for: session
                )
            },
            fullBoundaryMatches: fullBoundaryMatches,
            onUnicodeFallback: {
                vippLog.notice("paste: Telegram AXSelectedText unavailable before mutation; using one bounded Unicode insertion with full chat revalidation before every chunk targetPid=\(session.processIdentifier, privacy: .public)")
            },
            onAccessibilityError: { error in
                vippLog.error("paste: Telegram AXSelectedText returned an error after its one allowed attempt; verifying without retry AXError=\(error, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
            },
            targetedUnicode: { beforeChunk in
                await CursorPaster.typeTextIntoTargetedProcess(
                    pastedText,
                    pid: session.processIdentifier,
                    sessionAlreadyPrepared: true,
                    beforeChunk: beforeChunk
                )
            }
        )
        if !result {
            vippLog.error("paste: Telegram exact insertion stopped before an unsafe mutation or because its exact chat/focus boundary changed targetPid=\(session.processIdentifier, privacy: .public)")
        }
        return result
    }

    /// A fully backgrounded editor cannot safely receive process-targeted Return: macOS
    /// can accept that event while Electron or Telegram ignores it, and another input in
    /// the same process may own the internal key route. Prefer one explicitly labelled
    /// semantic Send action. If no semantic action was issued and this exact saved
    /// composer still owns *system* keyboard focus, one ordinary global HID Return is
    /// allowed instead; this covers foreground and ChatGPT Option-Space without app
    /// activation or process-targeted keys. A truly backgrounded target still fails
    /// visibly when no labelled Send exists.
    private func performBackgroundAutoSend(
        _ autoSendKey: AutoSendKey,
        session: FocusLockService.BackgroundDeliverySession
    ) async {
        // `waitForBackgroundInsertion` already proved the exact composer contains the
        // transcript. Submit immediately; a fixed 150 ms sleep only made the result feel
        // late and widened the window for unrelated user focus changes.
        guard await FocusLockService.shared.refreshBackgroundFocus(session),
              let textBeforeSubmit = FocusLockService.shared.backgroundInputText(for: session) else {
            showAutoSendFailure(
                "Transcription inserted, but couldn’t re-verify the saved background input before Send",
                detail: "background auto-send focus verification failed targetPid=\(session.processIdentifier)"
            )
            return
        }

        let isChatComposer = Self.isChatComposer(
            bundleIdentifier: session.bundleIdentifier
        )
        guard autoSendKey == .enter,
              isChatComposer,
              FocusLockService.supportsBackgroundSemanticSend(
                bundleIdentifier: session.bundleIdentifier
              ) else {
            showAutoSendFailure(
                "Transcription inserted, but this saved background input has no safe auto-send action",
                detail: "process-targeted background key events are forbidden key=\(autoSendKey.rawValue) targetPid=\(session.processIdentifier)"
            )
            return
        }

        let semanticResult = await FocusLockService.shared
            .pressNearbySubmitButton(for: session)
        let exactInputOwnsKeyboardFocus = semanticResult == .unavailable
            && FocusLockService.shared
                .backgroundInputOwnsSystemKeyboardFocus(session)
        let initialPlan = Self.backgroundSemanticActionPlan(
            result: semanticResult,
            exactInputOwnsKeyboardFocus: exactInputOwnsKeyboardFocus
        )
        var submitRoute: String
        switch initialPlan {
        case .verifyOnly:
            switch semanticResult {
            case .pressed:
                submitRoute = "semanticSend"
            case .failed(let error):
                // AX can report an error after a button handled its press. Treat this
                // as one issued action and classify the exact composer; never retry.
                submitRoute = "semanticSendAXError"
                vippLog.error("paste: background semantic Send returned AXError=\(error, privacy: .public); verifying without retry targetPid=\(session.processIdentifier, privacy: .public)")
            case .unavailable:
                showAutoSendFailure(
                    "Transcription inserted, but the saved Send action became unavailable",
                    detail: "background auto-send plan changed unexpectedly targetPid=\(session.processIdentifier)"
                )
                return
            }
        case .failNoSafeAction:
            showAutoSendFailure(
                "Transcription inserted, but no verified Send control was available in the saved background input",
                detail: "semantic Send unavailable and exact input does not own system focus targetPid=\(session.processIdentifier)"
            )
            return
        case .issueExactFocusReturn:
            guard exactInputOwnsKeyboardFocus else {
                showAutoSendFailure(
                    "Transcription inserted, but the saved input lost keyboard focus before Return",
                    detail: "exact-focus HID Return plan lost its decision boundary targetPid=\(session.processIdentifier)"
                )
                return
            }
            let returnResult = await CursorPaster
                .performExactKeyboardFocusAutoSend(.enter) {
                    FocusLockService.shared
                        .backgroundInputOwnsSystemKeyboardFocus(session)
                }
            guard returnResult.didPostAutoSendCommand else {
                showAutoSendFailure(
                    "Transcription inserted, but the saved input lost keyboard focus before Return",
                    detail: "exact-focus HID Return was not issued targetPid=\(session.processIdentifier)"
                )
                return
            }
            submitRoute = "exactFocusHID"
        }

        var verification = await waitForBackgroundChatComposerSubmission(
            from: textBeforeSubmit,
            session: session
        )
        // OpenAI is the sole permitted key retry: the first normal HID Return was
        // issued only to the exact system-focused composer, and a readable unchanged
        // value proves it did not submit. Recheck the complete exact-focus boundary and
        // issue at most one retry; unreadable or modified post-state never retries.
        if Self.shouldRetryBackgroundExactFocusReturn(
            bundleIdentifier: session.bundleIdentifier,
            initialPlan: initialPlan,
            verification: verification,
            exactInputOwnsKeyboardFocus: FocusLockService.shared
                .backgroundInputOwnsSystemKeyboardFocus(session)
        ) {
            let retryResult = await CursorPaster
                .performExactKeyboardFocusAutoSend(.enter) {
                    FocusLockService.shared
                        .backgroundInputOwnsSystemKeyboardFocus(session)
                }
            if retryResult.didPostAutoSendCommand {
                submitRoute += "+retry"
                verification = await waitForBackgroundChatComposerSubmission(
                    from: textBeforeSubmit,
                    session: session
                )
            }
        }
        let focusStayedSafe = FocusLockService.shared
            .backgroundDeliveryFocusIsSafe(
                session,
                allowReplacementAfterSubmission: true
            )
        let targetExecutablePath = FocusLockService.shared
            .backgroundTargetExecutablePath(for: session) ?? "nil"
        let succeeded = verification == .verified && focusStayedSafe
        vippLog.info("paste: background auto-send finished success=\(succeeded, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) route=\(submitRoute, privacy: .public) verification=\(String(describing: verification), privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) targetExecutable=\(targetExecutablePath, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")

        guard focusStayedSafe else {
            showAutoSendFailure(
                "Transcription inserted, but background delivery could not preserve focus safely",
                detail: "semantic Send target became frontmost route=\(submitRoute) targetPid=\(session.processIdentifier)"
            )
            return
        }

        switch verification {
        case .verified:
            return
        case .unavailable:
            // An issued action whose post-state became unreadable is indeterminate,
            // not permission to retry and not a proven user-facing failure. Surface an
            // error only when Accessibility itself disappeared or the app terminated.
            guard FocusLockService.shared.backgroundDeliveryEnvironmentIsAvailable(
                session
            ) else {
                showAutoSendFailure(
                    "Transcription inserted, but Send verification lost access to the saved app",
                    detail: "semantic Send verification unavailable after app termination or Accessibility loss route=\(submitRoute) targetPid=\(session.processIdentifier)"
                )
                return
            }
            vippLog.notice("paste: background semantic Send verification unavailable after one issued action; no retry and no visible false-failure targetPid=\(session.processIdentifier, privacy: .public) route=\(submitRoute, privacy: .public)")
        case .modifiedWithoutSubmit:
            showAutoSendFailure(
                "Transcription inserted, but Send changed the saved input without submitting it",
                detail: "semantic Send modifiedWithoutSubmit route=\(submitRoute) targetPid=\(session.processIdentifier)"
            )
        case .unchanged:
            showAutoSendFailure(
                "Transcription inserted, but the saved input ignored Send",
                detail: "semantic Send remained unchanged after one issued action route=\(submitRoute) targetPid=\(session.processIdentifier)"
            )
        }
    }

    private func waitForBackgroundInsertion(
        _ insertedText: String,
        previousText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let currentText = FocusLockService.shared.backgroundInputTextFast(for: session),
               Self.pasteChangeProvesInsertedText(
                insertedText: insertedText,
                previousText: previousText,
                currentText: currentText
               ),
               let verifiedText = FocusLockService.shared.backgroundInputText(for: session),
               Self.pasteChangeProvesInsertedText(
                insertedText: insertedText,
                previousText: previousText,
                currentText: verifiedText
               ) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let currentText = FocusLockService.shared.backgroundInputText(for: session) else {
            return false
        }
        return Self.pasteChangeProvesInsertedText(
            insertedText: insertedText,
            previousText: previousText,
            currentText: currentText
        )
    }

    enum ExactPasteVerification: Equatable {
        case verified
        case unchanged
        case modifiedUnexpectedly
        case unavailable
    }

    private static func normalizedPasteVerificationText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
    }

    /// Prove that this delivery created one contiguous insertion/replacement equal to
    /// the transcript. Merely finding the phrase in the final value is unsafe: Ethan
    /// often dictates the same test sentence repeatedly, so an unrelated newline could
    /// otherwise "verify" text that was already present and allow stale text to Send.
    /// Fail closed if any other part of the readable value changed concurrently.
    static func pasteChangeProvesInsertedText(
        insertedText: String,
        previousText: String?,
        currentText: String?
    ) -> Bool {
        guard let previousText, let currentText else { return false }
        let previous = normalizedPasteVerificationText(previousText)
        let current = normalizedPasteVerificationText(currentText)
        guard previous != current else { return false }

        let rawInsertion = normalizedPasteVerificationText(insertedText)
        let trimmedInsertion = rawInsertion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var candidates = [rawInsertion]
        if trimmedInsertion != rawInsertion {
            candidates.append(trimmedInsertion)
        }
        candidates = candidates.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return false }

        // For at least one occurrence of the transcript in the new value, prove the
        // surrounding prefix and suffix are unchanged pieces of the previous value and
        // do not overlap there. This models exactly one contiguous selection replacement
        // and handles shared suffix characters correctly (for example replacing "draft"
        // with text that also ends in "t").
        for candidate in candidates {
            var searchStart = current.startIndex
            while searchStart <= current.endIndex,
                  let range = current.range(
                    of: candidate,
                    range: searchStart..<current.endIndex
                  ) {
                let prefix = String(current[..<range.lowerBound])
                let suffix = String(current[range.upperBound...])
                if previous.hasPrefix(prefix),
                   previous.hasSuffix(suffix),
                   prefix.count + suffix.count <= previous.count {
                    return true
                }
                guard range.lowerBound < current.endIndex else { break }
                searchStart = current.index(after: range.lowerBound)
            }
        }
        return false
    }

    static func classifyExactPasteChange(
        insertedText: String,
        previousText: String?,
        currentText: String?
    ) -> ExactPasteVerification {
        guard let previousText, let currentText else { return .unavailable }
        if pasteChangeProvesInsertedText(
            insertedText: insertedText,
            previousText: previousText,
            currentText: currentText
        ) {
            return .verified
        }
        return normalizedPasteVerificationText(previousText)
            == normalizedPasteVerificationText(currentText)
            ? .unchanged
            : .modifiedUnexpectedly
    }

    static func foregroundChatPasteIsReady(
        insertedText: String,
        previousText: String?,
        currentText: String?
    ) -> Bool {
        pasteChangeProvesInsertedText(
            insertedText: insertedText,
            previousText: previousText,
            currentText: currentText
        )
    }

    /// `VoiceInkEngine` removes the owning `RecordingSession` as soon as delivery
    /// returns. Keep foreground Cmd-V, verification, and optional auto-send inside one
    /// awaited lifetime so the locked-destination outline cannot disappear
    /// while that exact session is still capable of mutating its saved input.
    static func awaitForegroundDeliveryLifecycle(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        // Preserve the foreground operation's existing unstructured cancellation
        // behavior, but join it before returning to the engine's session-removal tail.
        let operationTask = Task { @MainActor in
            await operation()
        }
        await operationTask.value
    }

    private func waitForForegroundChatPaste(
        _ insertedText: String,
        previousText: String?,
        target: FocusLockService.Target
    ) async -> Bool {
        await waitForForegroundPasteVerification(
            insertedText,
            previousText: previousText,
            target: target
        ) == .verified
    }

    private func waitForForegroundPasteVerification(
        _ insertedText: String,
        previousText: String?,
        target: FocusLockService.Target
    ) async -> ExactPasteVerification {
        guard previousText != nil else { return .unavailable }
        var latest = Self.classifyExactPasteChange(
            insertedText: insertedText,
            previousText: previousText,
            currentText: FocusLockService.shared.focusedInputText(for: target)
        )
        if latest == .verified {
            vippLog.info("paste: foreground text was immediately ready targetPid=\(target.processIdentifier, privacy: .public)")
            return .verified
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let fast = Self.classifyExactPasteChange(
                insertedText: insertedText,
                previousText: previousText,
                currentText: FocusLockService.shared.focusedExactInputTextFast(target)
            )
            if fast == .verified {
                let confirmed = Self.classifyExactPasteChange(
                    insertedText: insertedText,
                    previousText: previousText,
                    currentText: FocusLockService.shared.focusedInputText(
                        for: target
                    )
                )
                if confirmed == .verified {
                    vippLog.info("paste: foreground text became ready without fixed delay targetPid=\(target.processIdentifier, privacy: .public)")
                    return .verified
                }
                latest = confirmed
            } else if fast != .unavailable {
                latest = fast
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        let final = Self.classifyExactPasteChange(
            insertedText: insertedText,
            previousText: previousText,
            currentText: FocusLockService.shared.focusedInputText(for: target)
        )
        return final == .unavailable ? latest : final
    }

    private func waitForDetachedForegroundChatPaste(
        _ insertedText: String,
        previousText: String?,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> Bool {
        let provesInsertion: (String?) -> Bool = { currentText in
            Self.pasteChangeProvesInsertedText(
                insertedText: insertedText,
                previousText: previousText,
                currentText: currentText
            )
        }
        if provesInsertion(
            FocusLockService.shared.backgroundInputText(for: session)
        ) {
            return true
        }

        // Cmd-V can return before an Electron/Telegram AXValue reflects the paste.
        // Poll the frozen session instead of declaring a false failure or sleeping a
        // fixed amount. Fast reads retain the exact process/window/editor boundary;
        // a full resolver confirms it once text becomes observable.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if provesInsertion(
                FocusLockService.shared.backgroundInputTextFast(for: session)
            ), provesInsertion(
                FocusLockService.shared.backgroundInputText(for: session)
            ) {
                vippLog.info("paste: detached foreground chat text became ready without a fixed delay targetPid=\(session.processIdentifier, privacy: .public)")
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return provesInsertion(
            FocusLockService.shared.backgroundInputText(for: session)
        )
    }

    private func waitForForegroundChatComposerSubmission(
        from previousText: String,
        target: FocusLockService.Target,
        allowsApplicationFallback: Bool
    ) async -> ChatComposerSubmissionVerification {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var iteration = 0
        var latest = Self.classifyChatComposerSubmission(
            from: previousText,
            to: FocusLockService.shared.focusedInputText(
                for: target,
                allowApplicationFallback: allowsApplicationFallback
            )
        )
        var observations = [latest]
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Self.settledChatSubmissionVerification(observations) == .verified {
                return .verified
            }
            let fast = Self.classifyChatComposerSubmission(
                from: previousText,
                to: FocusLockService.shared.focusedExactInputTextFast(target)
            )
            if Self.chatSubmissionVerificationIsConclusiveBeforeDeadline(fast) {
                let confirmed = Self.classifyChatComposerSubmission(
                    from: previousText,
                    to: FocusLockService.shared.focusedInputText(
                        for: target,
                        allowApplicationFallback: allowsApplicationFallback
                    )
                )
                observations.append(confirmed)
                if Self.chatSubmissionVerificationIsConclusiveBeforeDeadline(
                    confirmed
                ) {
                    return confirmed
                }
            }
            // A chat renderer may replace its AXTextArea after Send. Re-run the full
            // resolver at a bounded cadence while cheap exact-wrapper reads cover the
            // common case, avoiding an arbitrary 350 ms sleep and dozens of tree walks.
            if iteration.isMultiple(of: 5) {
                latest = Self.classifyChatComposerSubmission(
                    from: previousText,
                    to: FocusLockService.shared.focusedInputText(
                        for: target,
                        allowApplicationFallback: allowsApplicationFallback
                    )
                )
                observations.append(latest)
            }
            iteration += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        observations.append(Self.classifyChatComposerSubmission(
            from: previousText,
            to: FocusLockService.shared.focusedInputText(
                for: target,
                allowApplicationFallback: allowsApplicationFallback
            )
        ))
        return Self.settledChatSubmissionVerification(observations)
    }

    private func waitForBackgroundChatComposerSubmission(
        from previousText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> ChatComposerSubmissionVerification {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var latest: ChatComposerSubmissionVerification = .unavailable
        var observations = [latest]
        while ProcessInfo.processInfo.systemUptime < deadline {
            latest = Self.classifyChatComposerSubmission(
                from: previousText,
                to: FocusLockService.shared.backgroundInputTextFast(
                    for: session,
                    allowReplacementAfterSubmission: true
                )
            )
            if latest == .verified {
                let fullyVerified = Self.classifyChatComposerSubmission(
                    from: previousText,
                    to: FocusLockService.shared.backgroundInputText(
                        for: session,
                        allowReplacementAfterSubmission: true
                    )
                )
                observations.append(fullyVerified)
                if fullyVerified == .verified {
                    return .verified
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        observations.append(Self.classifyChatComposerSubmission(
            from: previousText,
            to: FocusLockService.shared.backgroundInputText(
                for: session,
                allowReplacementAfterSubmission: true
            )
        ))
        return Self.settledChatSubmissionVerification(observations)
    }

    private func handleBackgroundPasteFailure(
        _ pastedText: String,
        destination: RecordingPasteDestination,
        detail: String
    ) {
        _ = ClipboardManager.copyToClipboard(pastedText)
        let destinationName = switch destination {
        case .recordingStart: "recording-start"
        case .focusedAtStop: "stop-time"
        case .focusedDuringTranscription: "second-chance"
        }
        NotificationManager.shared.showNotification(
            title: String(localized: "Couldn’t verify the saved background input — transcription copied to clipboard"),
            type: .error
        )
        vippLog.error("paste: background exact delivery failed destination=\(destinationName, privacy: .public) detail=\(detail, privacy: .public)")
    }

    private func performAutoSend(
        _ key: AutoSendKey,
        to target: FocusLockService.Target,
        allowsApplicationFallback: Bool,
        transcriptLength: Int,
        expectedFrontmostPID: pid_t
    ) async -> ForegroundAutoSendOutcome {
        let isSemanticChatComposer = Self.isChatComposer(
            bundleIdentifier: target.bundleIdentifier
        ) && FocusLockService.supportsSemanticSend(
            bundleIdentifier: target.bundleIdentifier
        )

        let exactFocusPreflight = {
            Self.foregroundPastePreflightMatches(
                expectedFrontmostPID: expectedFrontmostPID,
                currentFrontmostPID: NSWorkspace.shared.frontmostApplication?
                    .processIdentifier,
                savedInputOwnsKeyboardFocus: FocusLockService.shared
                    .retainedInputOwnsSystemKeyboardFocus(target)
            )
        }

        guard key == .enter, isSemanticChatComposer else {
            return await Self.executeOneShotGenericForegroundAutoSend {
                sendRedundantEnter in
                await CursorPaster.performAutoSend(
                    key,
                    transcriptLength: transcriptLength,
                    expectedFrontmostPID: expectedFrontmostPID,
                    sendRedundantEnter: sendRedundantEnter,
                    preflight: exactFocusPreflight
                )
            }
        }

        // Allowlisted chat composers have ignored synthetic Return on some surfaces.
        // Use the tightly-scoped explicitly labelled Send button first. While a response
        // is already running an OpenAI button can become Stop, so label verification is
        // mandatory; only a still-foreground exact input may fall back to real Return.
        let textBeforeSubmit = FocusLockService.shared.focusedInputText(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        )
        let semanticResult = await FocusLockService.shared.pressNearbySubmitButton(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        )
        let initialPlan = Self.foregroundSemanticActionPlan(
            result: semanticResult,
            exactInputOwnsKeyboardFocus: FocusLockService.shared
                .targetOwnsSystemKeyboardFocus(target)
        )
        switch initialPlan {
        case .verifyOnly:
            switch semanticResult {
            case .pressed:
                vippLog.info("paste: foreground chat auto-send used nearby Send button targetPid=\(expectedFrontmostPID, privacy: .public)")
            case .failed(let error):
                // AX may report an error after the app handled the button. A second
                // Return here could submit twice, so verify the one action only.
                vippLog.error("paste: foreground chat Send returned AXError=\(error, privacy: .public); verifying without fallback targetPid=\(expectedFrontmostPID, privacy: .public)")
            case .unavailable:
                break
            }
        case .issueExactFocusReturn:
            guard Self.usesHumanizedHIDForegroundReturn(
                bundleIdentifier: target.bundleIdentifier
            ) else {
                return .failed
            }
            let result = await CursorPaster.performAutoSend(
                .enter,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                method: .cgEvent,
                sendRedundantEnter: false,
                preflight: exactFocusPreflight
            )
            guard result.didPostAutoSendCommand else {
                return exactFocusPreflight() ? .failed : .focusMoved
            }
            vippLog.info("paste: foreground chat nearby Send unavailable; issued one exact-focus-gated Return route=humanizedHID targetPid=\(expectedFrontmostPID, privacy: .public)")
        case .focusMoved:
            return .focusMoved
        }

        guard let textBeforeSubmit, !textBeforeSubmit.isEmpty else {
            vippLog.notice("paste: foreground chat submit post-state is unreadable after one action; reporting indeterminate without retry or visible false-failure targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .indeterminate
        }

        let verification = await waitForForegroundChatComposerSubmission(
            from: textBeforeSubmit,
            target: target,
            allowsApplicationFallback: allowsApplicationFallback
        )
        switch verification {
        case .verified:
            vippLog.info("paste: foreground chat composer cleared after one auto-send action targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .succeeded
        case .unavailable:
            vippLog.notice("paste: foreground chat submit verification became unreadable after one action; no retry and no visible false-failure targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .indeterminate
        case .modifiedWithoutSubmit:
            vippLog.error("paste: foreground chat auto-send modified the composer without clearing it targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .failed
        case .unchanged:
            break
        }

        guard Self.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: target.bundleIdentifier,
            initialPlan: initialPlan,
            semanticResult: semanticResult,
            verification: verification,
            exactInputOwnsKeyboardFocus: FocusLockService.shared
                .targetOwnsSystemKeyboardFocus(target)
        ) else {
            vippLog.error("paste: foreground chat composer remained unchanged after its one auto-send action; no unsafe retry targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .failed
        }

        // OpenAI is the one proven foreground exception: a successful semantic press
        // that leaves a readable unchanged exact composer may receive one normal HID
        // Return. The action closure rechecks exact focus at Return-down; AX errors,
        // Telegram, and Claude never enter this retry path.
        let fallback = await CursorPaster.performAutoSend(
            .enter,
            transcriptLength: transcriptLength,
            expectedFrontmostPID: expectedFrontmostPID,
            method: .cgEvent,
            sendRedundantEnter: false,
            preflight: exactFocusPreflight
        )
        guard fallback.didPostAutoSendCommand else {
            return .failed
        }
        let fallbackVerification = await waitForForegroundChatComposerSubmission(
            from: textBeforeSubmit,
            target: target,
            allowsApplicationFallback: allowsApplicationFallback
        )
        switch fallbackVerification {
        case .verified:
            vippLog.info("paste: foreground OpenAI composer cleared after its one exact-focus HID Return retry targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .succeeded
        case .unavailable:
            vippLog.notice("paste: foreground OpenAI retry post-state became unreadable; no further action and no visible false-failure targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .indeterminate
        case .unchanged, .modifiedWithoutSubmit:
            vippLog.error("paste: foreground OpenAI composer did not clear after its one permitted HID Return retry targetPid=\(expectedFrontmostPID, privacy: .public)")
            return .failed
        }
    }

    private func showAutoSendFailure(_ title: String, detail: String) {
        NotificationManager.shared.showNotification(
            title: title,
            type: .error
        )
        vippLog.error("paste: auto-send failed after successful paste; \(detail, privacy: .public)")
    }

    private func restorePreviousApplication(_ application: NSRunningApplication, displacedBy targetPID: pid_t) async {
        guard !application.isTerminated else {
            vippLog.info("paste: skipped previous app restore because it terminated restorePid=\(application.processIdentifier, privacy: .public)")
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            vippLog.info("paste: skipped previous app restore because focus already moved frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            return
        }
        let restored = await FocusLockService.shared.activateApplication(application)
        if restored {
            vippLog.info("paste: restored and verified previous app restorePid=\(application.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        } else {
            vippLog.error("paste: failed to restore previous app restorePid=\(application.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        }
    }

    private func handleMissingPasteTarget(_ pastedText: String, destination: RecordingPasteDestination) {
        _ = ClipboardManager.copyToClipboard(pastedText)
        FocusLockService.shared.clearLock()
        let title = switch destination {
        case .recordingStart:
            String(localized: "Couldn’t focus the recording-start input — transcription copied to clipboard")
        case .focusedAtStop:
            String(localized: "Couldn’t focus the stop input — transcription copied to clipboard")
        case .focusedDuringTranscription:
            String(localized: "Couldn’t focus the retargeted input — transcription copied to clipboard")
        }
        NotificationManager.shared.showNotification(title: title, type: .error)
        vippLog.error("paste: target restore failed; copied transcription to clipboard instead of pasting into an unintended input")
    }

    private func deliverableText(from text: String) -> String {
        var textToDeliver = text
        if let restrictionMessage = LicenseViewModel().usageRestrictionMessage {
            textToDeliver = """
                \(restrictionMessage)
                \n\(textToDeliver)
                """
        }

        return textToDeliver
    }
}
