import Foundation
import AppKit   // NSWorkspace (frontmost-app pid for VIPPDebug paste logging)
import os

@MainActor
final class TranscriptionDelivery {
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

    private enum ForegroundAutoSendOutcome: String {
        case succeeded
        case indeterminate
        case focusMoved
        case failed
    }

    static func foregroundPastePreflightMatches(
        targetPID: pid_t,
        frontmostPID: pid_t?,
        hasExactInput: Bool,
        exactInputOwnsKeyboardFocus: Bool
    ) -> Bool {
        guard frontmostPID == targetPID else { return false }
        return !hasExactInput || exactInputOwnsKeyboardFocus
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

    static func shouldRetryForegroundSemanticSendWithReturn(
        bundleIdentifier: String?,
        semanticResult: FocusLockService.NearbySubmitButtonResult,
        verification: ChatComposerSubmissionVerification,
        exactInputOwnsKeyboardFocus: Bool
    ) -> Bool {
        openAIComposerBundleIdentifiers.contains(bundleIdentifier ?? "")
            && semanticResult == .pressed
            && verification == .unchanged
            && exactInputOwnsKeyboardFocus
    }

    /// A chat submit is proven by the exact composer clearing/resetting. A rendered
    /// message echo is useful telemetry, but Codex/ChatGPT can omit or delay that text
    /// in a background Accessibility tree after Return has already been handled. Conversely,
    /// any non-empty mutation (for example, a newline) is not proof of submission.
    /// Keep this classifier pure so classification is unit tested independently from
    /// the app-specific Accessibility transport.
    static func classifyChatComposerSubmission(
        from previousText: String,
        to currentText: String?
    ) -> ChatComposerSubmissionVerification {
        guard let currentText else { return .unavailable }
        guard currentText != previousText else { return .unchanged }
        return currentText.isEmpty
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
                await paste(text, target: request.pasteTarget, output: rawOutput, actions: actions)
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
        actions: Actions
    ) async {
        let textToPaste = deliverableText(from: text)
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        let pastedText = textToPaste + (appendSpace ? " " : "")
        vippLog.info("paste: BEGIN len=\(pastedText.count, privacy: .public) destination=\(String(describing: target.destination), privacy: .public) targetCaptured=\(target.focusedInput != nil, privacy: .public) exactInput=\(target.focusedInput?.hasExactInput ?? false, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        SoundManager.shared.playStopSound()
        FocusLockService.shared.setStartInputIndicatorVisible(target.destination == .recordingStart)
        await actions.dismiss()

        guard let focusedInput = target.focusedInput else {
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }
        let targetPID = focusedInput.processIdentifier
        let previouslyFrontmostApplication = NSWorkspace.shared.frontmostApplication
        let allowsApplicationFallback = target.destination == .recordingStart
        let autoSendKey = output.outputMode == .paste ? output.autoSendKey : .none

        let exactTargetOwnsKeyboardFocus = FocusLockService.shared
            .targetOwnsSystemKeyboardFocus(focusedInput)
        if focusedInput.hasExactInput,
           (previouslyFrontmostApplication?.processIdentifier != targetPID
            || !exactTargetOwnsKeyboardFocus) {
            await deliverToBackgroundExactInput(
                pastedText,
                target: target,
                focusedInput: focusedInput,
                autoSendKey: autoSendKey
            )
            return
        }

        guard await FocusLockService.shared.restoreFocus(to: focusedInput, allowApplicationFallback: allowsApplicationFallback) else { // Next Track must reactivate and verify the saved app before Cmd-V; posting to a background PID reported false success when VS Code ignored it.
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }

        // A recording-start app fallback is permission to choose that app's one current
        // editable input, not permission to keep targeting only a PID. Promote it once
        // after activation and freeze that exact wrapper before clipboard settlement,
        // paste verification, or Return. If no exact input is exposed, fail closed.
        let foregroundInput: FocusLockService.Target
        if focusedInput.hasExactInput {
            foregroundInput = focusedInput
        } else if allowsApplicationFallback,
                  let promoted = FocusLockService.shared.captureFocusedInput(),
                  promoted.processIdentifier == targetPID,
                  promoted.hasExactInput {
            foregroundInput = promoted
            vippLog.info("paste: promoted recording-start application fallback to one frozen exact foreground input targetPid=\(targetPID, privacy: .public)")
        } else {
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }

        vippLog.info("paste: target restored; issuing paste keystroke targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")

        let textBeforeForegroundPaste = FocusLockService.shared
            .focusedExactInputTextFast(foregroundInput)
        let pasteTask = CursorPaster.startPasteAtCursor(
            pastedText,
            preflight: {
                Self.foregroundPastePreflightMatches(
                    targetPID: targetPID,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?
                        .processIdentifier,
                    hasExactInput: foregroundInput.hasExactInput,
                    exactInputOwnsKeyboardFocus: FocusLockService.shared
                        .targetOwnsSystemKeyboardFocus(foregroundInput)
                )
            }
        ) // Use the proven foreground Cmd-V path from cba45ba, but cancel before Cmd-V if Ethan moved; the frozen exact-input route below can then continue without focus theft.

        let applicationToRestore = previouslyFrontmostApplication?.processIdentifier == targetPID
            ? nil
            : previouslyFrontmostApplication
        vippLog.info("paste: delivery scheduled targetPid=\(targetPID, privacy: .public) autoSend=\(autoSendKey.rawValue, privacy: .public) restorePid=\(applicationToRestore?.processIdentifier ?? -1, privacy: .public)")
        // Feature B: capture transcript length now so the auto-send can scale its
        // redundant-Enter delay with how much text was pasted (longer paste => the
        // field settles slower under load, so the second Enter gets more headroom).
        let pastedLength = pastedText.count
        Task { @MainActor in
            defer { FocusLockService.shared.clearLock() }

            let pasteResult = await pasteTask.value
            vippLog.info("paste: command completed result=\(String(describing: pasteResult), privacy: .public) targetPid=\(targetPID, privacy: .public)")
            guard pasteResult.didPostPasteCommand else {
                if foregroundInput.hasExactInput,
                   !Self.foregroundPastePreflightMatches(
                    targetPID: targetPID,
                    frontmostPID: NSWorkspace.shared.frontmostApplication?
                        .processIdentifier,
                    hasExactInput: true,
                    exactInputOwnsKeyboardFocus: FocusLockService.shared
                        .targetOwnsSystemKeyboardFocus(foregroundInput)
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
                    if !FocusLockService.shared.targetOwnsSystemKeyboardFocus(
                        foregroundInput
                    ) {
                        await performDetachedChatAutoSendAfterForegroundPaste(
                            autoSendKey,
                            pastedText: pastedText,
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
                    if !FocusLockService.shared.targetOwnsSystemKeyboardFocus(
                        foregroundInput
                    ) {
                        await performDetachedChatAutoSendAfterForegroundPaste(
                            autoSendKey,
                            pastedText: pastedText,
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
                        expectedFrontmostPID: targetPID
                    )
                    if autoSendOutcome == .focusMoved {
                        await performDetachedChatAutoSendAfterForegroundPaste(
                            autoSendKey,
                            pastedText: pastedText,
                            target: foregroundInput
                        )
                        return
                    }
                } else {
                    // Non-chat foreground targets still use their established settlement
                    // window until a surface-specific verifier exists for them.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard await FocusLockService.shared.restoreFocus(
                        to: foregroundInput,
                        allowApplicationFallback: false
                    ) else {
                        showAutoSendFailure(
                            "Transcription pasted, but couldn’t focus the destination to press Return",
                            detail: "foreground Return restore failed targetPid=\(targetPID)"
                        )
                        if let applicationToRestore {
                            await restorePreviousApplication(applicationToRestore, displacedBy: targetPID)
                        }
                        return
                    }
                    autoSendOutcome = await performAutoSend(
                        autoSendKey,
                        to: foregroundInput,
                        allowsApplicationFallback: false,
                        transcriptLength: pastedLength,
                        expectedFrontmostPID: targetPID
                    )
                }

                let autoSendSucceeded = autoSendOutcome != .failed
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
            } else if let applicationToRestore {
                // Plain paste still gets a short settlement window before returning
                // to the workspace that was active when delivery began.
                try? await Task.sleep(nanoseconds: 100_000_000)
                await restorePreviousApplication(applicationToRestore, displacedBy: targetPID)
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
    /// the same process may own the internal key route. Background chat submission is
    /// therefore one explicitly labelled semantic Send action followed by composer-state
    /// verification. Missing labels and ambiguity fail visibly without stealing focus.
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
              FocusLockService.supportsSemanticSend(
                bundleIdentifier: session.bundleIdentifier
              ) else {
            showAutoSendFailure(
                "Transcription inserted, but this saved background input has no safe auto-send action",
                detail: "process-targeted background key events are forbidden key=\(autoSendKey.rawValue) targetPid=\(session.processIdentifier)"
            )
            return
        }

        let submitRoute: String
        switch FocusLockService.shared.pressNearbySubmitButton(for: session) {
        case .pressed:
            submitRoute = "semanticSend"
        case .unavailable:
            showAutoSendFailure(
                "Transcription inserted, but no verified Send control was available in the saved background input",
                detail: "semantic Send unavailable or ambiguous targetPid=\(session.processIdentifier)"
            )
            return
        case .failed(let error):
            // AX can report an error after a button handled its press. Treat this as
            // one issued action and classify the exact composer; never retry Return or
            // Send because that could submit the transcript twice.
            submitRoute = "semanticSendAXError"
            vippLog.error("paste: background semantic Send returned AXError=\(error, privacy: .public); verifying without retry targetPid=\(session.processIdentifier, privacy: .public)")
        }

        let verification = await waitForBackgroundChatComposerSubmission(
            from: textBeforeSubmit,
            session: session
        )
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
        let verificationText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let currentText = FocusLockService.shared.backgroundInputTextFast(for: session),
               currentText != previousText,
               currentText.contains(verificationText),
               let verifiedText = FocusLockService.shared.backgroundInputText(for: session),
               verifiedText != previousText,
               verifiedText.contains(verificationText) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let currentText = FocusLockService.shared.backgroundInputText(for: session) else {
            return false
        }
        return currentText != previousText && currentText.contains(verificationText)
    }

    static func foregroundChatPasteIsReady(
        insertedText: String,
        previousText: String?,
        currentText: String?
    ) -> Bool {
        let verificationText = insertedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !verificationText.isEmpty,
              let currentText,
              currentText != previousText else {
            return false
        }
        return currentText.contains(verificationText)
    }

    private func waitForForegroundChatPaste(
        _ insertedText: String,
        previousText: String?,
        target: FocusLockService.Target
    ) async -> Bool {
        if Self.foregroundChatPasteIsReady(
            insertedText: insertedText,
            previousText: previousText,
            currentText: FocusLockService.shared.focusedInputText(for: target)
        ) {
            vippLog.info("paste: foreground chat text was immediately ready for semantic Send targetPid=\(target.processIdentifier, privacy: .public)")
            return true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Self.foregroundChatPasteIsReady(
                insertedText: insertedText,
                previousText: previousText,
                currentText: FocusLockService.shared.focusedExactInputTextFast(target)
            ) {
                vippLog.info("paste: foreground chat text became ready for semantic Send without fixed delay targetPid=\(target.processIdentifier, privacy: .public)")
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return Self.foregroundChatPasteIsReady(
            insertedText: insertedText,
            previousText: previousText,
            currentText: FocusLockService.shared.focusedInputText(for: target)
        )
    }

    private func waitForDetachedForegroundChatPaste(
        _ insertedText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> Bool {
        let verificationText = insertedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !verificationText.isEmpty else { return false }
        let containsTranscript: (String?) -> Bool = { currentText in
            currentText?.contains(verificationText) == true
        }
        if containsTranscript(
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
            if containsTranscript(
                FocusLockService.shared.backgroundInputTextFast(for: session)
            ), containsTranscript(
                FocusLockService.shared.backgroundInputText(for: session)
            ) {
                vippLog.info("paste: detached foreground chat text became ready without a fixed delay targetPid=\(session.processIdentifier, privacy: .public)")
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return containsTranscript(
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
        while ProcessInfo.processInfo.systemUptime < deadline {
            if latest == .verified || latest == .modifiedWithoutSubmit {
                return latest
            }
            let fast = Self.classifyChatComposerSubmission(
                from: previousText,
                to: FocusLockService.shared.focusedExactInputTextFast(target)
            )
            if fast == .verified || fast == .modifiedWithoutSubmit {
                let confirmed = Self.classifyChatComposerSubmission(
                    from: previousText,
                    to: FocusLockService.shared.focusedInputText(
                        for: target,
                        allowApplicationFallback: allowsApplicationFallback
                    )
                )
                if confirmed == .verified || confirmed == .modifiedWithoutSubmit {
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
            }
            iteration += 1
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return Self.classifyChatComposerSubmission(
            from: previousText,
            to: FocusLockService.shared.focusedInputText(
                for: target,
                allowApplicationFallback: allowsApplicationFallback
            )
        )
    }

    private func waitForBackgroundChatComposerSubmission(
        from previousText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> ChatComposerSubmissionVerification {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var latest: ChatComposerSubmissionVerification = .unavailable
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
                if fullyVerified == .verified {
                    return .verified
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return Self.classifyChatComposerSubmission(
            from: previousText,
            to: FocusLockService.shared.backgroundInputText(
                for: session,
                allowReplacementAfterSubmission: true
            )
        )
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
                targetPID: expectedFrontmostPID,
                frontmostPID: NSWorkspace.shared.frontmostApplication?
                    .processIdentifier,
                hasExactInput: target.hasExactInput,
                exactInputOwnsKeyboardFocus: FocusLockService.shared
                    .targetOwnsSystemKeyboardFocus(target)
            )
        }

        guard key == .enter, isSemanticChatComposer else {
            let result = await CursorPaster.performAutoSend(
                key,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                preflight: exactFocusPreflight
            )
            return result.didPostAutoSendCommand ? .succeeded : .failed
        }

        // Allowlisted chat composers have ignored synthetic Return on some surfaces.
        // Use the tightly-scoped explicitly labelled Send button first. While a response
        // is already running an OpenAI button can become Stop, so label verification is
        // mandatory; only a still-foreground exact input may fall back to real Return.
        let textBeforeSubmit = FocusLockService.shared.focusedInputText(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        )
        let semanticResult = FocusLockService.shared.pressNearbySubmitButton(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        )
        switch Self.foregroundSemanticActionPlan(
            result: semanticResult,
            exactInputOwnsKeyboardFocus: FocusLockService.shared
                .targetOwnsSystemKeyboardFocus(target)
        ) {
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
            let result = await CursorPaster.performAutoSend(
                .enter,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                method: .systemEvents,
                sendRedundantEnter: false,
                preflight: exactFocusPreflight
            )
            guard result.didPostAutoSendCommand else {
                return exactFocusPreflight() ? .failed : .focusMoved
            }
            vippLog.info("paste: foreground chat nearby Send unavailable; issued one exact-focus-gated System Events Return targetPid=\(expectedFrontmostPID, privacy: .public)")
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
