import Foundation
import AppKit   // NSWorkspace (frontmost-app pid for VIPPDebug paste logging)
import os

@MainActor
final class TranscriptionDelivery {
    enum BackgroundAutoSendVerification: Equatable {
        case verifiedCleared
        case unchanged
        case modifiedWithoutSubmit
        case unreadable
    }

    enum DeferredForegroundAutoSendRoute: Equatable {
        case foregroundExactInput
        case nonActivatingExactInput
        case failClosed
    }

    enum BackgroundAutoSendUserFeedback: Equatable {
        case none
        case unchangedComposerError
        case modifiedWithoutSubmitError
    }

    enum AutoSendOutcome: Equatable {
        case verified
        case indeterminate
        case failed
        case needsNonActivatingExactInput
    }

    private struct BackgroundAutoSendObservation {
        let verification: BackgroundAutoSendVerification
        let snapshot: FocusLockService.FocusedInputTextSnapshot?
        let elapsedMilliseconds: Int
        let sampleCount: Int
    }

    private struct ForegroundOpenAIVerificationContext {
        let target: FocusLockService.Target
        let textBeforeSubmit: String
    }

    static func classifyBackgroundAutoSendVerification(
        previousText: String,
        currentText: String?,
        currentPlaceholder: String? = nil
    ) -> BackgroundAutoSendVerification {
        guard let currentText else { return .unreadable }
        let previous = previousText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let current = currentText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let placeholder = currentPlaceholder?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if current.isEmpty {
            return .verifiedCleared
        }
        if let placeholder,
           !placeholder.isEmpty,
           current == placeholder,
           current != previous {
            return .verifiedCleared
        }
        // Preserve the raw editor value at this boundary. Trimming before equality
        // would collapse "transcript" and "transcript\n" into the same state even
        // though the latter is the exact background-Return failure we need to expose.
        if currentText == previousText {
            return .unchanged
        }
        return !previousText.isEmpty && currentText.contains(previousText)
            ? .modifiedWithoutSubmit
            : .unreadable
    }

    static func classifyForegroundOpenAIAutoSendVerification(
        previousText: String,
        currentText: String?,
        currentPlaceholder: String?
    ) -> BackgroundAutoSendVerification {
        guard let currentText else { return .unreadable }
        let previous = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = currentPlaceholder?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if current.isEmpty {
            return .verifiedCleared
        }
        // Codex can keep one focused AXTextArea wrapper after submission while its
        // empty visual composer reports the placeholder through AXValue. Treat that
        // as a proven reset only when AXPlaceholderValue agrees and the pre-submit
        // text was different; dictating the literal placeholder must still be sent.
        if let placeholder,
           !placeholder.isEmpty,
           current == placeholder,
           current != previous {
            return .verifiedCleared
        }
        // Preserve the raw value. Trimming before equality incorrectly turns
        // "transcript\n" into an unchanged composer and authorizes a second Return
        // even though the first Return visibly mutated the draft without submitting.
        if currentText == previousText {
            return .unchanged
        }
        // A changed value proves failure only while it still contains the complete
        // submitted transcript. An unrelated Codex reset/status value is not proof
        // that Return failed, so preserve it as indeterminate telemetry and never
        // retry or show a false red error.
        if !previous.isEmpty,
           current.contains(previous) {
            return .modifiedWithoutSubmit
        }
        return .unreadable
    }

    static func shouldRetryForegroundOpenAIReturn(
        bundleIdentifier: String?,
        autoSendKey: AutoSendKey,
        verification: BackgroundAutoSendVerification,
        exactTargetStillOwnsKeyboardFocus: Bool
    ) -> Bool {
        openAIComposerBundleIdentifiers.contains(bundleIdentifier ?? "")
            && autoSendKey == .enter
            && verification == .unchanged
            && exactTargetStillOwnsKeyboardFocus
    }

    static func deferredForegroundAutoSendRoute(
        hasExactInput: Bool,
        exactInputOwnsKeyboardFocus: Bool,
        targetIsFrontmost: Bool
    ) -> DeferredForegroundAutoSendRoute {
        // Cmd-V was already guarded by exact keyboard focus immediately before it was
        // posted. Return follows without an AX-value read-back delay. A transient AX
        // focus read must not suppress ordinary foreground Return while the same target
        // app is still frontmost; a genuinely backgrounded target remains on the exact,
        // non-activating route. Non-activating panels (notably ChatGPT Option-Space)
        // remain eligible through their real exact system keyboard focus.
        if exactInputOwnsKeyboardFocus || targetIsFrontmost {
            return .foregroundExactInput
        }
        return hasExactInput ? .nonActivatingExactInput : .failClosed
    }

    static func backgroundAutoSendUserFeedback(
        verification: BackgroundAutoSendVerification
    ) -> BackgroundAutoSendUserFeedback {
        switch verification {
        case .verifiedCleared, .unreadable:
            return .none
        case .unchanged:
            return .unchangedComposerError
        case .modifiedWithoutSubmit:
            return .modifiedWithoutSubmitError
        }
    }

    static func autoSendOutcome(
        verification: BackgroundAutoSendVerification
    ) -> AutoSendOutcome {
        switch verification {
        case .verifiedCleared:
            return .verified
        case .unreadable:
            return .indeterminate
        case .unchanged, .modifiedWithoutSubmit:
            return .failed
        }
    }

    static func foregroundOpenAIAutoSendOutcome(
        verification: BackgroundAutoSendVerification,
        exactTargetStillOwnsKeyboardFocus: Bool
    ) -> AutoSendOutcome {
        // Codex replaces its composer AX wrapper after a successful submission. Once
        // the frozen wrapper no longer owns keyboard focus, a readable value from that
        // old wrapper is stale telemetry: it cannot prove that Return was ignored or
        // that the new composer failed to clear. The irreversible Return has already
        // happened, so classify that post-state as indeterminate and never retry or
        // show Ethan a false failure. A readable non-empty value is a real failure only
        // while the exact same saved composer still owns system keyboard focus.
        if verification != .verifiedCleared,
           !exactTargetStillOwnsKeyboardFocus {
            return .indeterminate
        }
        return autoSendOutcome(verification: verification)
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

        let autoSendKey = output.outputMode == .paste ? output.autoSendKey : .none

        // PRIMARY-ONLY COMPATIBILITY ROUTE: when no genuine app activation has occurred
        // since recording began and that same app still owns keyboard focus, behave like
        // base VoiceInk. Paste at the live caret and immediately issue the ordinary HID
        // Return. This intentionally does not require stop-time AX capture/identity,
        // restore focus, semantic Send, background preparation, or read-back. Electron
        // can transiently expose AXGroup while the correct composer still owns the real
        // caret; making that AX snapshot a prerequisite broke the normal workflow.
        //
        // Any app activation—including switching away and back—rejects this route. The
        // saved exact focusedAtStop target then handles delivery, while recordingStart
        // and focusedDuringTranscription never enter this branch at all.
        if await deliverToUninterruptedPrimaryCurrentInputIfEligible(
            pastedText,
            target: target,
            autoSendKey: autoSendKey
        ) {
            return
        }

        guard let capturedInput = target.focusedInput else {
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }
        let allowsApplicationFallback = target.destination == .recordingStart
        let initiallyFrontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier

        // Recording-start may capture only an application container while shortcut
        // modifiers are down. That is not a delivery identity. Promote it to the one
        // current editable input only while the saved app is already foreground; never
        // activate a background fallback or guess from its retained internal focus.
        let deliveryInput: FocusLockService.Target
        if !capturedInput.hasExactInput {
            guard allowsApplicationFallback,
                  initiallyFrontmostPID == capturedInput.processIdentifier,
                  let promoted = FocusLockService.shared
                    .promoteForegroundApplicationFallbackToExactInput(capturedInput) else {
                handleMissingPasteTarget(pastedText, destination: target.destination)
                return
            }
            deliveryInput = promoted
        } else {
            deliveryInput = capturedInput
        }

        // Freeze the promoted/captured wrapper before any escaping action guard or
        // asynchronous delivery task. Every later boundary must prove this exact input;
        // a mutable capture could race with fallback promotion or user focus changes.
        let targetPID = deliveryInput.processIdentifier
        if !FocusLockService.shared.targetOwnsSystemKeyboardFocus(deliveryInput) {
            await deliverToBackgroundExactInput(
                pastedText,
                target: target,
                focusedInput: deliveryInput,
                autoSendKey: autoSendKey
            )
            return
        }

        // Foreground delivery is allowed only when the frozen exact input already owns
        // system keyboard focus. Do not call restoreFocus here: a check-then-restore
        // race can overwrite a newer click in the same app or reactivate a target after
        // Ethan switches away.
        guard FocusLockService.shared.targetOwnsSystemKeyboardFocus(deliveryInput) else {
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }

        vippLog.info("paste: foreground exact input verified; scheduling guarded Cmd-V targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        let pasteTask = CursorPaster.startPasteAtCursor(
            pastedText,
            canPost: {
                FocusLockService.shared.targetOwnsSystemKeyboardFocus(deliveryInput)
            }
        )
        vippLog.info("paste: foreground guarded delivery scheduled targetPid=\(targetPID, privacy: .public) autoSend=\(autoSendKey.rawValue, privacy: .public)")
        // Delivery is FIFO-serialized by TranscriptionPipeline. Keep paste verification,
        // fallback, auto-send, and lock cleanup in this awaited call; an unstructured
        // Task here would let the queue remove this session and start the next one while
        // clipboard/focus state from this delivery was still live.
        defer { FocusLockService.shared.clearLock() }

        let pasteResult = await pasteTask.value
        vippLog.info("paste: command completed result=\(String(describing: pasteResult), privacy: .public) targetPid=\(targetPID, privacy: .public)")
        if pasteResult == .actionGuardRefused {
            // Ethan switched to another app or another input in this same app
            // during clipboard settlement. Nothing was pasted, so continue exactly
            // once through the non-activating exact route. Its preparation chooses
            // direct AXSelectedText for the same-app/different-input case.
            await deliverToBackgroundExactInput(
                pastedText,
                target: target,
                focusedInput: deliveryInput,
                autoSendKey: autoSendKey
            )
            return
        }
        guard pasteResult.didPostPasteCommand else {
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Couldn’t send the paste to the saved input — transcription copied to clipboard"),
                type: .error
            )
            vippLog.error("paste: command was not posted; copied transcription to clipboard and skipped auto-send")
            return
        }

        if autoSendKey.isEnabled {
            let exactInputOwnsKeyboardFocus = FocusLockService.shared
                .targetOwnsSystemKeyboardFocus(deliveryInput)
            switch Self.deferredForegroundAutoSendRoute(
                hasExactInput: deliveryInput.hasExactInput,
                exactInputOwnsKeyboardFocus: exactInputOwnsKeyboardFocus,
                targetIsFrontmost: NSWorkspace.shared.frontmostApplication?
                    .processIdentifier == targetPID
            ) {
            case .nonActivatingExactInput:
                await performDetachedBackgroundAutoSendAfterForegroundPaste(
                    autoSendKey,
                    pastedText: pastedText,
                    target: deliveryInput
                )
                return
            case .failClosed:
                showAutoSendFailure(
                    "Transcription pasted, but the saved input lost focus before Return",
                    detail: "foreground Return skipped without reactivating or rewriting targetPid=\(targetPID)"
                )
                return
            case .foregroundExactInput:
                break
            }

            let autoSendOutcome = await performAutoSend(
                autoSendKey,
                to: deliveryInput,
                targetPID: targetPID,
                pastedText: pastedText
            )
            vippLog.info("paste: foreground auto-send finished outcome=\(String(describing: autoSendOutcome), privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            switch autoSendOutcome {
            case .needsNonActivatingExactInput:
                // The last-moment foreground boundary moved before any key was posted,
                // so transition once to the saved exact session instead of sending
                // Return to whichever app now owns the keyboard.
                await performDetachedBackgroundAutoSendAfterForegroundPaste(
                    autoSendKey,
                    pastedText: pastedText,
                    target: deliveryInput
                )
                return
            case .failed:
                showAutoSendFailure(
                    "Transcription pasted, but couldn’t press Return automatically",
                    detail: "foreground Return produced no verified submit targetPid=\(targetPID)"
                )
                return
            case .verified, .indeterminate:
                break
            }
        }
    }

    /// Returns true once the primary compatibility route handled the delivery. False
    /// means it was ineligible or continuity changed before Cmd-V, so the caller must
    /// continue through the saved exact-input route without guessing a destination.
    private func deliverToUninterruptedPrimaryCurrentInputIfEligible(
        _ pastedText: String,
        target: RecordingPasteTarget,
        autoSendKey: AutoSendKey
    ) async -> Bool {
        guard target.destination == .focusedAtStop,
              let continuity = target.primaryForegroundContinuity,
              ActiveWindowService.shared.primaryForegroundContinuityIsUnbroken(
                continuity
              ) else {
            return false
        }

        vippLog.info("paste: primary current-input compatibility selected targetPid=\(continuity.processIdentifier, privacy: .public) activationGeneration=\(continuity.activationGeneration, privacy: .public) exactCaptureRequired=false")
        let continuityStillMatches: @MainActor () -> Bool = {
            ActiveWindowService.shared.primaryForegroundContinuityIsUnbroken(
                continuity
            )
        }
        let pasteTask = CursorPaster.startPasteAtCursor(
            pastedText,
            canPost: continuityStillMatches
        )
        defer { FocusLockService.shared.clearLock() }

        let pasteResult = await pasteTask.value
        vippLog.info("paste: primary current-input command completed result=\(String(describing: pasteResult), privacy: .public) targetPid=\(continuity.processIdentifier, privacy: .public)")
        switch pasteResult {
        case .actionGuardRefused:
            // Nothing was pasted. Continue once through focusedAtStop's exact route;
            // never substitute the recording-start input.
            vippLog.notice("paste: primary current-input continuity changed before Cmd-V; continuing through focusedAtStop exact route")
            return false
        case .commandNotPosted:
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Couldn’t paste into the current input — transcription copied to clipboard"),
                type: .error
            )
            vippLog.error("paste: primary current-input Cmd-V was not posted; copied transcription to clipboard")
            return true
        case .commandPosted:
            break
        }

        guard autoSendKey.isEnabled else {
            vippLog.info("paste: primary current-input delivery finished autoSend=none targetPid=\(continuity.processIdentifier, privacy: .public)")
            return true
        }

        // A single read of the already-focused retained wrapper may arm read-only
        // verification, but the first Return is never held behind a settling poll or a
        // semantic-button scan. If Electron has not exposed the pasted text yet, keep
        // v2.0.236's immediate one-shot behavior and report the post-state as unknown.
        let verificationContext = foregroundOpenAIVerificationContext(
            autoSendKey: autoSendKey,
            target: target.focusedInput,
            pastedText: pastedText
        )
        let sendResult = await CursorPaster.performAutoSend(
            autoSendKey,
            targetPID: continuity.processIdentifier,
            method: .cgEvent,
            canPost: continuityStillMatches
        )
        switch sendResult {
        case .commandPosted:
            guard let verificationContext else {
                vippLog.info("paste: primary current-input immediate HID auto-send issued=true verification=unavailablePreState key=\(autoSendKey.rawValue, privacy: .public) targetPid=\(continuity.processIdentifier, privacy: .public)")
                break
            }
            vippLog.info("paste: primary current-input immediate HID auto-send issued=true verification=pending key=\(autoSendKey.rawValue, privacy: .public) targetPid=\(continuity.processIdentifier, privacy: .public)")
            let outcome = await verifyAndRetryForegroundOpenAIReturn(
                autoSendKey,
                context: verificationContext,
                targetPID: continuity.processIdentifier,
                canPost: continuityStillMatches
            )
            vippLog.info("paste: primary current-input auto-send verification finished outcome=\(String(describing: outcome), privacy: .public) targetPid=\(continuity.processIdentifier, privacy: .public)")
            if outcome == .failed {
                showAutoSendFailure(
                    "Transcription pasted, but Return did not submit it",
                    detail: "primary current-input OpenAI composer remained readable and non-empty after its bounded Return attempt targetPid=\(continuity.processIdentifier)"
                )
            }
        case .actionGuardRefused:
            showAutoSendFailure(
                "Transcription pasted, but the current app changed before Return",
                detail: "primary current-input continuity changed after paste targetPid=\(continuity.processIdentifier)"
            )
        case .commandNotPosted:
            showAutoSendFailure(
                "Transcription pasted, but couldn’t press Return automatically",
                detail: "primary current-input Return was not posted targetPid=\(continuity.processIdentifier)"
            )
        }
        return true
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

        vippLog.info("paste: background exact focus verified targetPid=\(session.processIdentifier, privacy: .public) preparationFrontmostPid=\(session.frontmostProcessIdentifierAtPreparation, privacy: .public) currentFrontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public) destination=\(String(describing: target.destination), privacy: .public)")
        let textEventsPosted: Bool
        if session.usesPreparedTargetedInput {
            textEventsPosted = await CursorPaster.typeTextIntoPreparedTargetedProcess(
                pastedText,
                pid: session.processIdentifier,
                canPost: {
                    FocusLockService.shared
                        .backgroundDeliveryFastBoundaryMatches(session)
                },
                canRevalidateContext: {
                    FocusLockService.shared
                        .backgroundDeliveryBoundaryMatches(session)
                }
            )
        } else {
            switch FocusLockService.shared.insertTextUsingAccessibility(
                pastedText,
                for: session
            ) {
            case .acceptedSelectedText:
                textEventsPosted = true
            case .unavailable, .failed(_), .focusSafetyViolation:
                textEventsPosted = false
            }
        }
        let insertionVerified: Bool
        if textEventsPosted {
            insertionVerified = await waitForBackgroundInsertion(
                pastedText,
                previousText: textBeforeInsertion,
                session: session
            )
        } else {
            insertionVerified = false
        }
        guard insertionVerified,
              FocusLockService.shared.backgroundDeliveryBoundaryMatches(session) else {
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

        await performBackgroundAutoSend(
            autoSendKey,
            pastedText: pastedText,
            session: session
        )
    }

    /// Foreground Cmd-V may finish just as Ethan moves elsewhere. The saved exact
    /// composer already contains the transcript, so reusing the non-activating session
    /// only for submission preserves both the latch and Ethan's newer workspace. Never
    /// reinsert the text and never activate the destination as a fallback.
    private func performDetachedBackgroundAutoSendAfterForegroundPaste(
        _ autoSendKey: AutoSendKey,
        pastedText: String,
        target: FocusLockService.Target
    ) async {
        guard let session = await FocusLockService.shared.prepareBackgroundDelivery(
            to: target
        ) else {
            showAutoSendFailure(
                "Transcription pasted, but the saved background input could not be re-verified for Return",
                detail: "detached foreground auto-send preparation failed targetPid=\(target.processIdentifier)"
            )
            return
        }
        defer { FocusLockService.shared.finishBackgroundDelivery(session) }

        let verificationText = pastedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !verificationText.isEmpty,
              FocusLockService.shared.backgroundInputText(for: session)?
                .contains(verificationText) == true else {
            showAutoSendFailure(
                "Transcription pasted, but the saved background input no longer contained it for Return",
                detail: "detached foreground paste verification failed targetPid=\(target.processIdentifier)"
            )
            return
        }

        vippLog.notice("paste: user focus moved after foreground paste; continuing auto-send through non-activating exact-input session targetPid=\(target.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        await performBackgroundAutoSend(
            autoSendKey,
            pastedText: pastedText,
            session: session
        )
    }

    private func performBackgroundAutoSend(
        _ autoSendKey: AutoSendKey,
        pastedText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async {
        // Insertion (or the detached foreground readback) already proved that the exact
        // composer contains the transcript. Submit immediately; an arbitrary delay only
        // makes Return feel late and widens the window for Ethan to change workspaces.
        guard let textBeforeSubmit = FocusLockService.shared.backgroundInputText(for: session) else {
            showAutoSendFailure(
                "Transcription inserted, but couldn’t restore the saved background input to press Return",
                detail: "background auto-send focus verification failed targetPid=\(session.processIdentifier)"
            )
            return
        }
        FocusLockService.shared.logBackgroundAutoSendDiagnostic(
            stage: "beforeAction",
            route: "pendingSemanticAction",
            verification: "notStarted",
            beforeText: textBeforeSubmit,
            afterSnapshot: FocusLockService.shared.backgroundInputTextSnapshot(
                for: session
            ),
            session: session,
            elapsedMilliseconds: 0,
            sampleCount: 0
        )

        let isOpenAIComposer = session.bundleIdentifier.map {
            Self.openAIComposerBundleIdentifiers.contains($0)
        } ?? false
        // A background app cannot receive a normal HID Return without stealing the
        // user's keyboard focus. Ordinary process-targeted Return was ignored by
        // Electron, and the later authenticated Return changed this exact ChatGPT
        // composer without submitting it. The audited unlabelled OpenAI control now
        // uses one PID/window-addressed mouse gesture only after the complete
        // Send-vs-Stop boundary is re-proven. Explicitly labelled controls retain
        // semantic AXPress. Neither route may fall through after an irreversible
        // action; clear/reset remains the only authoritative chat success proof.
        guard autoSendKey == .enter, isOpenAIComposer else {
            showAutoSendFailure(
                "Transcription inserted, but this saved background input has no safe Send action",
                detail: "background process-targeted Return is disabled key=\(autoSendKey.rawValue) targetPid=\(session.processIdentifier)"
            )
            return
        }

        let actionStarted = ProcessInfo.processInfo.systemUptime
        let submitRoute: String
        switch await FocusLockService.shared.pressNearbySubmitButton(for: session) {
        case .targetedClick:
            submitRoute = "skyLightTargetedSendClick"
        case .pressed:
            submitRoute = "semanticAXPress"
        case .unavailable, .focusLostBeforeAction, .refusedAfterCandidate:
            showAutoSendFailure(
                "Transcription inserted, but no verified Send control is available",
                detail: "background semantic Send unavailable targetPid=\(session.processIdentifier)"
            )
            return
        case .failed(let error):
            // The action may already have reached the app before a post-action focus
            // guard or AX result failed. It remains the sole irreversible attempt:
            // verify only and never fall through to Return, AXPress, or a second click.
            submitRoute = "semanticActionError"
            vippLog.error("paste: background semantic action returned error=\(error, privacy: .public); verifying without fallback targetPid=\(session.processIdentifier, privacy: .public)")
        }

        let observation = await waitForBackgroundValueChange(
            from: textBeforeSubmit,
            session: session
        )
        let verification = observation.verification
        let totalElapsedMilliseconds = Int(
            (ProcessInfo.processInfo.systemUptime - actionStarted) * 1_000
        )
        FocusLockService.shared.logBackgroundAutoSendDiagnostic(
            stage: "afterAction",
            route: submitRoute,
            verification: String(describing: verification),
            beforeText: textBeforeSubmit,
            afterSnapshot: observation.snapshot,
            session: session,
            elapsedMilliseconds: totalElapsedMilliseconds,
            sampleCount: observation.sampleCount
        )
        let finalFrontmostPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier
        // A rendered message echo is diagnostic only. Do one read without extending
        // delivery or making it part of success: Codex can omit/delay this background
        // AX node even when its exact composer already handled Return.
        let submittedTextVisible = FocusLockService.shared.backgroundWindowContains(
            pastedText.trimmingCharacters(in: .whitespacesAndNewlines),
            for: session,
            excludingSavedInput: isOpenAIComposer && autoSendKey == .enter
        )
        let outcome = Self.autoSendOutcome(verification: verification)
        vippLog.info("paste: background auto-send finished success=\(outcome == .verified, privacy: .public) outcome=\(String(describing: outcome), privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) route=\(submitRoute, privacy: .public) verification=\(String(describing: verification), privacy: .public) verificationElapsedMs=\(observation.elapsedMilliseconds, privacy: .public) verificationSamples=\(observation.sampleCount, privacy: .public) totalElapsedMs=\(totalElapsedMilliseconds, privacy: .public) submittedTextVisible=\(submittedTextVisible, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(finalFrontmostPID ?? -1, privacy: .public)")

        switch Self.backgroundAutoSendUserFeedback(verification: verification) {
        case .unchangedComposerError:
            showAutoSendFailure(
                "Transcription inserted, but the saved background input did not respond to Send",
                detail: "background route=\(submitRoute) left readable composer unchanged targetPid=\(session.processIdentifier)"
            )
            return
        case .modifiedWithoutSubmitError:
            showAutoSendFailure(
                "Transcription inserted, but Send changed the saved input without submitting it",
                detail: "background route=\(submitRoute) modified readable composer without clearing it targetPid=\(session.processIdentifier)"
            )
            return
        case .none:
            break
        }

        switch verification {
        case .verifiedCleared:
            // A rendered-message echo is useful telemetry, but Codex can delay or omit it
            // from its background AX tree after the composer has already changed. Never
            // turn that optional observation into a false user-facing failure.
            return
        case .unreadable:
            // One irreversible action was issued. If the composer wrapper disappeared or
            // became unreadable, Send may already have succeeded; retrying could submit
            // twice, while an error notification/sound would be a false claim. Preserve
            // the uncertainty in telemetry only.
            vippLog.notice("paste: background auto-send post-state unreadable after one issued action; no retry and no visible false-failure targetPid=\(session.processIdentifier, privacy: .public) route=\(submitRoute, privacy: .public)")
        case .unchanged, .modifiedWithoutSubmit:
            return // The feedback policy above already surfaced this proven no-op.
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
            if let currentText = FocusLockService.shared.backgroundInputText(for: session),
               currentText != previousText,
               currentText.contains(verificationText) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let currentText = FocusLockService.shared.backgroundInputText(for: session) else {
            return false
        }
        return currentText != previousText && currentText.contains(verificationText)
    }

    private func waitForBackgroundValueChange(
        from previousText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> BackgroundAutoSendObservation {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var sampleCount = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            sampleCount += 1
            let snapshot = FocusLockService.shared
                .backgroundPostActionInputTextSnapshot(for: session)
            let verification = Self.classifyBackgroundAutoSendVerification(
                previousText: previousText,
                currentText: snapshot?.text,
                currentPlaceholder: snapshot?.placeholder
            )
            if verification == .verifiedCleared {
                return BackgroundAutoSendObservation(
                    verification: verification,
                    snapshot: snapshot,
                    elapsedMilliseconds: Int(
                        (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    ),
                    sampleCount: sampleCount
                )
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        sampleCount += 1
        let snapshot = FocusLockService.shared
            .backgroundPostActionInputTextSnapshot(for: session)
        let verification = Self.classifyBackgroundAutoSendVerification(
            previousText: previousText,
            currentText: snapshot?.text,
            currentPlaceholder: snapshot?.placeholder
        )
        return BackgroundAutoSendObservation(
            verification: verification,
            snapshot: snapshot,
            elapsedMilliseconds: Int(
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
            ),
            sampleCount: sampleCount
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
        targetPID: pid_t,
        pastedText: String
    ) async -> AutoSendOutcome {
        // Foreground/current-input delivery intentionally behaves like a physical
        // paste followed immediately by one physical Return. The guarded Cmd-V above
        // already proved the exact caret at its irreversible boundary; requiring AX
        // text read-back before Return made ordinary delivery wait and then fail when
        // Electron temporarily hid the composer's value. Keep background submission
        // on its separate semantic/authenticated verifier, but do not run that machinery
        // for the app Ethan is actively using.
        let canPost: @MainActor () -> Bool = {
            let exactInputOwnsKeyboardFocus = FocusLockService.shared
                .targetOwnsSystemKeyboardFocus(target)
            let targetIsFrontmost = NSWorkspace.shared.frontmostApplication?
                .processIdentifier == targetPID
            return Self.deferredForegroundAutoSendRoute(
                hasExactInput: target.hasExactInput,
                exactInputOwnsKeyboardFocus: exactInputOwnsKeyboardFocus,
                targetIsFrontmost: targetIsFrontmost
            ) == .foregroundExactInput
        }

        guard canPost() else {
            return target.hasExactInput ? .needsNonActivatingExactInput : .failed
        }
        let verificationContext = foregroundOpenAIVerificationContext(
            autoSendKey: key,
            target: target,
            pastedText: pastedText
        )
        let result = await CursorPaster.performAutoSend(
            key,
            targetPID: targetPID,
            method: .cgEvent,
            canPost: canPost
        )
        switch result {
        case .actionGuardRefused:
            vippLog.notice("paste: foreground changed before immediate HID Return; rerouting to non-activating exact input targetPid=\(targetPID, privacy: .public)")
            return .needsNonActivatingExactInput
        case .commandNotPosted:
            return .failed
        case .commandPosted:
            guard let verificationContext else {
                vippLog.info("paste: foreground immediate HID auto-send issued=true verification=unavailablePreState key=\(key.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public)")
                return .indeterminate
            }
            vippLog.info("paste: foreground immediate HID auto-send issued=true verification=pending key=\(key.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public)")
            return await verifyAndRetryForegroundOpenAIReturn(
                key,
                context: verificationContext,
                targetPID: targetPID,
                canPost: canPost
            )
        }
    }

    /// Build an opportunistic verifier only from the exact composer that already owns
    /// the keyboard and already contains this paste. Failure to read that state never
    /// delays or suppresses the first HID Return; it merely disables retry/error claims.
    private func foregroundOpenAIVerificationContext(
        autoSendKey: AutoSendKey,
        target: FocusLockService.Target?,
        pastedText: String
    ) -> ForegroundOpenAIVerificationContext? {
        let verificationText = pastedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard autoSendKey == .enter,
              !verificationText.isEmpty,
              let target,
              target.bundleIdentifier.map(
                  Self.openAIComposerBundleIdentifiers.contains
              ) == true,
              target.hasExactInput,
              FocusLockService.shared.retainedInputOwnsSystemKeyboardFocus(target),
              let snapshot = FocusLockService.shared.focusedInputTextSnapshot(
                  for: target
              ),
              snapshot.text.contains(verificationText) else {
            return nil
        }
        return ForegroundOpenAIVerificationContext(
            target: target,
            textBeforeSubmit: snapshot.text
        )
    }

    /// Verify the one already-issued foreground OpenAI Return. Only a readable, raw-
    /// unchanged composer which still owns exact keyboard focus may receive one retry.
    /// A newline/non-empty mutation is a proven failure and is never retried; a replaced
    /// or unreadable wrapper stays indeterminate so successful submission cannot produce
    /// a false red warning or a duplicate message.
    private func verifyAndRetryForegroundOpenAIReturn(
        _ key: AutoSendKey,
        context: ForegroundOpenAIVerificationContext,
        targetPID: pid_t,
        canPost: @escaping @MainActor () -> Bool
    ) async -> AutoSendOutcome {
        let firstVerification = await waitForForegroundOpenAIReturnResult(
            from: context.textBeforeSubmit,
            target: context.target
        )
        let stillOwnsFocus = FocusLockService.shared
            .targetOwnsSystemKeyboardFocus(context.target)
        let firstOutcome = Self.foregroundOpenAIAutoSendOutcome(
            verification: firstVerification,
            exactTargetStillOwnsKeyboardFocus: stillOwnsFocus
        )
        vippLog.info("paste: foreground OpenAI Return observed verification=\(String(describing: firstVerification), privacy: .public) outcome=\(String(describing: firstOutcome), privacy: .public) retry=false targetPid=\(targetPID, privacy: .public)")

        guard Self.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: context.target.bundleIdentifier,
            autoSendKey: key,
            verification: firstVerification,
            exactTargetStillOwnsKeyboardFocus: stillOwnsFocus
        ), canPost() else {
            return firstOutcome
        }

        let retry = await CursorPaster.performAutoSend(
            key,
            targetPID: targetPID,
            method: .cgEvent,
            canPost: {
                canPost()
                    && FocusLockService.shared.targetOwnsSystemKeyboardFocus(
                        context.target
                    )
            }
        )
        guard retry == .commandPosted else {
            return FocusLockService.shared.targetOwnsSystemKeyboardFocus(
                context.target
            ) ? .failed : .indeterminate
        }

        let retryVerification = await waitForForegroundOpenAIReturnResult(
            from: context.textBeforeSubmit,
            target: context.target
        )
        let retryOwnsFocus = FocusLockService.shared
            .targetOwnsSystemKeyboardFocus(context.target)
        let retryOutcome = Self.foregroundOpenAIAutoSendOutcome(
            verification: retryVerification,
            exactTargetStillOwnsKeyboardFocus: retryOwnsFocus
        )
        vippLog.info("paste: foreground OpenAI Return observed verification=\(String(describing: retryVerification), privacy: .public) outcome=\(String(describing: retryOutcome), privacy: .public) retry=true targetPid=\(targetPID, privacy: .public)")
        return retryOutcome
    }

    private func waitForForegroundOpenAIReturnResult(
        from previousText: String,
        target: FocusLockService.Target
    ) async -> BackgroundAutoSendVerification {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var latest: BackgroundAutoSendVerification = .unreadable
        while ProcessInfo.processInfo.systemUptime < deadline {
            let snapshot = FocusLockService.shared.focusedInputTextSnapshot(
                for: target
            )
            latest = Self.classifyForegroundOpenAIAutoSendVerification(
                previousText: previousText,
                currentText: snapshot?.text,
                currentPlaceholder: snapshot?.placeholder
            )
            if latest == .verifiedCleared {
                return latest
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let snapshot = FocusLockService.shared.focusedInputTextSnapshot(for: target)
        return Self.classifyForegroundOpenAIAutoSendVerification(
            previousText: previousText,
            currentText: snapshot?.text,
            currentPlaceholder: snapshot?.placeholder
        )
    }

    private func showAutoSendFailure(_ title: String, detail: String) {
        // Paste already succeeded here. Host submission verification is intentionally
        // conservative and can report a false negative after an Electron composer has
        // actually submitted, so keep the selectable warning but do not punish routine
        // dictation with the global error sound. Capture, paste, and transcription
        // failures use their normal notification paths and remain audible.
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            playSound: false
        )
        vippLog.error("paste: auto-send failed after successful paste; \(detail, privacy: .public)")
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
