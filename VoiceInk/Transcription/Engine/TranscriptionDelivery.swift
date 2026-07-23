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
    private static let chatComposerBundleIdentifiers =
        openAIComposerBundleIdentifiers.union(["ru.keepcoder.Telegram"])

    static func isChatComposer(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return chatComposerBundleIdentifiers.contains(bundleIdentifier)
    }

    static func foregroundAutoSendMethod(
        bundleIdentifier: String?,
        autoSendKey: AutoSendKey
    ) -> CursorPaster.AutoSendMethod {
        // System Events key code 36 is the closest public scripted equivalent of a
        // physical Return for the frontmost OpenAI Electron composer. The previously
        // accepted immediate HID event can be accepted by macOS yet dropped while the
        // just-pasted composer is busy. Keep every background route unchanged, and keep
        // HID as the bounded retry only after a readable unchanged exact composer proves
        // that this first foreground action did not submit.
        guard autoSendKey == .enter,
              bundleIdentifier.map(openAIComposerBundleIdentifiers.contains) == true else {
            return .cgEvent
        }
        return .systemEvents
    }

    static func shouldUseTargetedUnicodeFallback(
        after result: FocusLockService.BackgroundTextInsertionResult,
        allowsFallback: Bool
    ) -> Bool {
        result == .unavailable && allowsFallback
    }

    /// Keep Telegram's one-shot insertion policy independently testable. AXSelectedText
    /// is preferred because it addresses the exact retained editor. Targeted Unicode is
    /// allowed only when the attribute was unavailable before any mutation. A setter
    /// error may mean Telegram already inserted, so verify it without retrying.
    static func executeAccessibilityFirstBackgroundInsertion(
        allowsTargetedUnicodeFallback: Bool,
        attemptAccessibility: () -> FocusLockService.BackgroundTextInsertionResult,
        fullBoundaryMatches: @escaping () -> Bool,
        onUnicodeFallback: () -> Void = {},
        onAccessibilityError: (Int32) -> Void = { _ in },
        targetedUnicode: (@escaping () -> Bool) async -> Bool
    ) async -> Bool {
        let accessibilityResult = attemptAccessibility()
        switch accessibilityResult {
        case .acceptedSelectedText:
            return true
        case .unavailable:
            guard shouldUseTargetedUnicodeFallback(
                after: accessibilityResult,
                allowsFallback: allowsTargetedUnicodeFallback
            ), fullBoundaryMatches() else {
                return false
            }
            onUnicodeFallback()
            return await targetedUnicode { fullBoundaryMatches() }
        case .failed(let error):
            onAccessibilityError(error)
            return true
        case .focusSafetyViolation:
            return false
        }
    }

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let pasteTarget: RecordingPasteTarget
        /// Realtime input ownership is orthogonal to route ownership. Primary still has
        /// no saved destination; this ledger merely proves which selected-text range is
        /// already present so final delivery can replace it instead of pasting twice.
        var realtimeInputDraftSession: RealtimeInputDraftSession? = nil
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
                    realtimeInputDraftSession: request.realtimeInputDraftSession,
                    actions: actions
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
            // A trigger word can choose Respond only after Soniox partials have already
            // appeared in the input. That live range is not final paste output: restore
            // it only while its exact input still owns real keyboard focus. Never wake
            // a background app merely to erase a resilient copy.
            request.realtimeInputDraftSession?.discardCurrentDraftForNonPasteOutput()
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            // Custom Command consumes the transcript outside the editor. Apply the same
            // focused-only owned-range cleanup as Respond so raw live text does not look
            // like a completed paste, while background/cross-app residue stays untouched.
            request.realtimeInputDraftSession?.discardCurrentDraftForNonPasteOutput()
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(
                text,
                target: request.pasteTarget,
                output: request.output,
                realtimeInputDraftSession: request.realtimeInputDraftSession,
                actions: actions
            )
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
        realtimeInputDraftSession targetRealtimeDraftSession: RealtimeInputDraftSession?,
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

        // PRIMARY IS ALWAYS BASE VOICEINK. The normal toggle never owns a saved input
        // and never runs Telegram/OpenAI/Terminal capture, focus, insertion, Send, or
        // verification code. Ordinary system Cmd-V goes to whichever keyboard input
        // macOS owns when the command is posted, followed immediately by the current
        // Mode's generic HID Return. Switching apps before delivery is expected and
        // changes the destination; only a physical Next press may freeze an exact one.
        if target.destination.usesBaseCurrentInputDelivery {
            if let realtimeInputDraftSession = targetRealtimeDraftSession,
               await deliverRealtimePrimaryToCurrentSystemInput(
                    pastedText,
                    autoSendKey: autoSendKey,
                    draftSession: realtimeInputDraftSession
               ) {
                return
            }
            await deliverPrimaryToCurrentSystemInput(
                pastedText,
                autoSendKey: autoSendKey
            )
            return
        }

        // Structural route boundary: everything below is app-specific exact delivery
        // and is legal only because the physical Next button selected recordingStart
        // or focusedDuringTranscription. Primary can never fall through to this code.
        precondition(
            target.destination.usesAppSpecificExactDelivery,
            "Only Next-button routes may enter app-specific exact delivery"
        )
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
                autoSendKey: autoSendKey,
                realtimeInputDraftSession: targetRealtimeDraftSession
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

        // Delivery is FIFO-serialized by TranscriptionPipeline. Keep paste verification,
        // fallback, auto-send, and lock cleanup in this awaited call; an unstructured
        // Task here would let the queue remove this session and start the next one while
        // clipboard/focus state from this delivery was still live.
        defer { FocusLockService.shared.clearLock() }

        if let draftSession = targetRealtimeDraftSession,
           draftSession.isMutationBlocked(for: deliveryInput) {
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Couldn’t safely finalize the realtime draft — final transcription copied to clipboard"),
                type: .error
            )
            vippLog.error("paste: foreground realtime draft blocked after an earlier indeterminate mutation; skipped duplicate paste/Return targetPid=\(targetPID, privacy: .public)")
            return
        } else if let draftSession = targetRealtimeDraftSession,
           let ownership = draftSession.ownership(matching: deliveryInput) {
            // The transcript is already present in this exact input. Replace only the
            // range owned by this recording with the final processed text; ordinary
            // Cmd-V would append a duplicate. A conflict fails closed and preserves the
            // final transcript on the clipboard.
            switch FocusLockService.shared.replaceForegroundRealtimeDraft(
                pastedText,
                ownership: ownership
            ) {
            case .applied(let updated):
                draftSession.storeReconciledOwnership(updated)
                vippLog.info("paste: foreground realtime draft reconciled success=true targetPid=\(targetPID, privacy: .public) chars=\(pastedText.count, privacy: .public) duplicatePasteAvoided=true")
            case .unavailableBeforeMutation, .ownershipConflict, .indeterminateAfterMutation:
                _ = ClipboardManager.copyToClipboard(pastedText)
                NotificationManager.shared.showNotification(
                    title: String(localized: "Couldn’t safely finalize the realtime draft — final transcription copied to clipboard"),
                    type: .error
                )
                vippLog.error("paste: foreground realtime draft reconciliation failed; copied final transcription and skipped duplicate paste/Return targetPid=\(targetPID, privacy: .public)")
                return
            }
        } else {
            vippLog.info("paste: foreground exact input verified; scheduling guarded Cmd-V targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            let pasteTask = CursorPaster.startPasteAtCursor(
                pastedText,
                canPost: {
                    FocusLockService.shared.targetOwnsSystemKeyboardFocus(deliveryInput)
                }
            )
            vippLog.info("paste: foreground guarded delivery scheduled targetPid=\(targetPID, privacy: .public) autoSend=\(autoSendKey.rawValue, privacy: .public)")
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
                    autoSendKey: autoSendKey,
                    realtimeInputDraftSession: targetRealtimeDraftSession
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

    /// Realtime Primary is still delivery-time current-input policy. The only difference
    /// is that the transcript may already occupy one exact selected-text range. Reconcile
    /// that range (or seed the complete final text into the input focused right now), then
    /// issue the same one generic HID auto-send with an exact last-millisecond focus guard.
    /// No saved destination, app classifier, background preparation, semantic Send,
    /// activation, read-back retry, or target-owned Mode is introduced here.
    private func deliverRealtimePrimaryToCurrentSystemInput(
        _ pastedText: String,
        autoSendKey: AutoSendKey,
        draftSession: RealtimeInputDraftSession
    ) async -> Bool {
        switch draftSession.finalizePrimary(with: pastedText) {
        case .notApplicable:
            return false
        case .unsafeToFallback:
            defer { FocusLockService.shared.clearLock() }
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Couldn’t safely finalize the realtime draft — final transcription copied to clipboard"),
                type: .error
            )
            vippLog.error("paste: realtime Primary finalization refused duplicate fallback; copied final transcription and skipped Return")
            return true
        case .reconciled(let currentTarget):
            defer { FocusLockService.shared.clearLock() }
            vippLog.info("paste: realtime Primary current-input range finalized success=true targetPid=\(currentTarget.processIdentifier, privacy: .public) chars=\(pastedText.count, privacy: .public) duplicatePasteAvoided=true appSpecificDelivery=false")
            guard autoSendKey.isEnabled else {
                vippLog.info("paste: realtime Primary delivery finished autoSend=none verification=notRequired")
                return true
            }

            let sendResult = await CursorPaster.performAutoSend(
                autoSendKey,
                targetPID: currentTarget.processIdentifier,
                method: .cgEvent,
                canPost: {
                    FocusLockService.shared.targetOwnsSystemKeyboardFocus(
                        currentTarget
                    )
                }
            )
            switch sendResult {
            case .commandPosted:
                vippLog.info("paste: realtime Primary immediate HID auto-send issued=true verification=notRequired key=\(autoSendKey.rawValue, privacy: .public) targetPid=\(currentTarget.processIdentifier, privacy: .public)")
            case .actionGuardRefused:
                showAutoSendFailure(
                    "Realtime transcription was finalized, but the input changed before Return",
                    detail: "realtime Primary exact focus guard refused Return targetPid=\(currentTarget.processIdentifier)"
                )
            case .commandNotPosted:
                showAutoSendFailure(
                    "Realtime transcription was finalized, but couldn’t press Return automatically",
                    detail: "realtime Primary Return was not posted targetPid=\(currentTarget.processIdentifier)"
                )
            }
            return true
        }
    }

    /// Base VoiceInk's current-input route, intentionally free of every app-specific
    /// saved-input mechanism. The system keyboard focus at each ordinary event decides
    /// where it goes; there is no exact-wrapper fallback, semantic Send, read-back,
    /// retry, or app allowlist. This must remain the only Primary delivery path.
    private func deliverPrimaryToCurrentSystemInput(
        _ pastedText: String,
        autoSendKey: AutoSendKey
    ) async {
        vippLog.info("paste: primary current-input compatibility selected exactCaptureRequired=false appSpecificDelivery=false")
        let pasteTask = CursorPaster.startPasteAtCursor(pastedText)
        defer { FocusLockService.shared.clearLock() }

        let pasteResult = await pasteTask.value
        vippLog.info("paste: primary current-input command completed result=\(String(describing: pasteResult), privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        switch pasteResult {
        case .actionGuardRefused, .commandNotPosted:
            _ = ClipboardManager.copyToClipboard(pastedText)
            NotificationManager.shared.showNotification(
                title: String(localized: "Couldn’t paste into the current input — transcription copied to clipboard"),
                type: .error
            )
            vippLog.error("paste: primary current-input Cmd-V was not posted; copied transcription to clipboard")
            return
        case .commandPosted:
            break
        }

        guard autoSendKey.isEnabled else {
            vippLog.info("paste: primary current-input delivery finished autoSend=none verification=notRequired")
            return
        }

        // No delay and no app classification: this is the same generic system-focused
        // key path for Telegram, Codex, Terminal, and every other current input.
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let sendResult = await CursorPaster.performAutoSend(
            autoSendKey,
            targetPID: currentPID,
            method: .cgEvent,
            canPost: { true }
        )
        switch sendResult {
        case .commandPosted:
            vippLog.info("paste: primary current-input immediate HID auto-send issued=true verification=notRequired key=\(autoSendKey.rawValue, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        case .actionGuardRefused:
            showAutoSendFailure(
                "Transcription pasted, but Return could not be issued",
                detail: "base current-input Return was unexpectedly refused"
            )
        case .commandNotPosted:
            showAutoSendFailure(
                "Transcription pasted, but couldn’t press Return automatically",
                detail: "base current-input Return was not posted"
            )
        }
    }

    private func deliverToBackgroundExactInput(
        _ pastedText: String,
        target: RecordingPasteTarget,
        focusedInput: FocusLockService.Target,
        autoSendKey: AutoSendKey,
        realtimeInputDraftSession: RealtimeInputDraftSession?
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
        let insertionVerified: Bool
        if let draftSession = realtimeInputDraftSession,
           draftSession.isMutationBlocked(for: focusedInput) {
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "realtime draft mutation was previously indeterminate for this app"
            )
            return
        } else if let draftSession = realtimeInputDraftSession,
           let ownership = draftSession.ownership(matching: focusedInput) {
            // The exact background target already contains an earlier realtime
            // hypothesis. Select and replace only that owned range; falling through to
            // ordinary insertion would append the full final transcript a second time.
            switch FocusLockService.shared.prepareRealtimeDraftReplacement(
                pastedText,
                ownership: ownership,
                for: session
            ) {
            case .applied(let updated):
                draftSession.storeReconciledOwnership(updated)
                insertionVerified = true
            case .selectedForTargetedUnicode(let updated, let expectedValue):
                let posted = await CursorPaster.typeTextIntoPreparedTargetedProcess(
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
                if posted {
                    insertionVerified = await waitForExactBackgroundValue(
                        expectedValue,
                        session: session
                    )
                } else {
                    insertionVerified = false
                }
                if insertionVerified {
                    draftSession.storeReconciledOwnership(updated)
                }
            case .unavailableBeforeMutation, .ownershipConflict, .indeterminateAfterMutation:
                handleBackgroundPasteFailure(
                    pastedText,
                    destination: target.destination,
                    detail: "owned realtime draft could not be reconciled without duplicate insertion"
                )
                return
            }
            vippLog.info("paste: background realtime draft reconciled success=\(insertionVerified, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) chars=\(pastedText.count, privacy: .public) duplicatePasteAvoided=true")
        } else {
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
                // Telegram's parentless composer exposes no AX chat title. Its audited
                // visual header digest is therefore re-sampled at the irreversible text
                // boundary, after all earlier readback and immediately before the one
                // AXSelectedText attempt. A mismatch must fail without mutation.
                guard await FocusLockService.shared
                    .revalidateTelegramVisualIdentityIfRequired(for: session) else {
                    handleBackgroundPasteFailure(
                        pastedText,
                        destination: target.destination,
                        detail: "saved Telegram chat identity changed before insertion"
                    )
                    return
                }
                let fullBoundaryMatches = {
                    FocusLockService.shared.backgroundDeliveryBoundaryMatches(
                        session
                    )
                }
                textEventsPosted = await Self
                    .executeAccessibilityFirstBackgroundInsertion(
                        allowsTargetedUnicodeFallback:
                            session.allowsTargetedUnicodeFallback,
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
                            vippLog.error("paste: exact AXSelectedText returned an error after its one allowed attempt; verifying without retry AXError=\(error, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
                        },
                        targetedUnicode: { canPost in
                            await CursorPaster.typeTextIntoPreparedTargetedProcess(
                                pastedText,
                                pid: session.processIdentifier,
                                canPost: canPost,
                                canRevalidateContext: fullBoundaryMatches
                            )
                        }
                    )
            }
            if textEventsPosted {
                insertionVerified = await waitForBackgroundInsertion(
                    pastedText,
                    previousText: textBeforeInsertion,
                    session: session
                )
            } else {
                insertionVerified = false
            }
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

        let isChatComposer = Self.isChatComposer(
            bundleIdentifier: session.bundleIdentifier
        )
        // A background app cannot receive a normal global HID Return without stealing
        // the user's keyboard focus. Generic process-targeted Return was ignored by
        // Electron/Telegram, and authenticated Return changed ChatGPT without
        // submitting it. Telegram has one narrower, physically proven exception: the
        // public HID-source/modifier-boundary sequence is addressed to its already-
        // verified exact composer after a fresh chat-identity check. OpenAI may use
        // one exact PID/window-addressed click. Neither app-specific route may fall
        // through after its irreversible action; clear/reset remains authoritative.
        guard autoSendKey == .enter, isChatComposer else {
            showAutoSendFailure(
                "Transcription inserted, but this saved background input has no safe Send action",
                detail: "background process-targeted Return is disabled key=\(autoSendKey.rawValue) targetPid=\(session.processIdentifier)"
            )
            return
        }

        let actionStarted = ProcessInfo.processInfo.systemUptime
        let submitRoute: String
        if FocusLockService.isTelegram(
            bundleIdentifier: session.bundleIdentifier
        ) {
            // Telegram publishes no AX Send control or chat title in the audited
            // build. Re-sample its privacy-bounded exact-chat identity at the action
            // boundary, then issue the sole proven Return sequence exactly once.
            guard await FocusLockService.shared
                .revalidateTelegramVisualIdentityIfRequired(for: session) else {
                showAutoSendFailure(
                    "Transcription inserted, but the saved Telegram chat could not be re-verified for Return",
                    detail: "background Telegram chat identity changed before Return targetPid=\(session.processIdentifier)"
                )
                return
            }
            switch CursorPaster.performTargetedTelegramHIDReturn(
                targetPID: session.processIdentifier,
                canPost: {
                    FocusLockService.shared.backgroundDeliveryBoundaryMatches(
                        session
                    )
                }
            ) {
            case .commandPosted:
                submitRoute = "telegramTargetedHIDReturn"
            case .commandNotPosted, .actionGuardRefused:
                showAutoSendFailure(
                    "Transcription inserted, but Telegram Return could not be issued safely",
                    detail: "background Telegram targeted Return unavailable targetPid=\(session.processIdentifier)"
                )
                return
            }
        } else {
            switch await FocusLockService.shared.pressNearbySubmitButton(
                for: session
            ) {
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
                // The action may already have reached the app before a post-action
                // guard or AX result failed. It remains the sole irreversible attempt:
                // verify only and never fall through to Return or a second click.
                submitRoute = "semanticActionError"
                vippLog.error("paste: background semantic action returned error=\(error, privacy: .public); verifying without fallback targetPid=\(session.processIdentifier, privacy: .public)")
            }
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
            excludingSavedInput: isChatComposer && autoSendKey == .enter
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

    /// Realtime reconciliation is stricter than ordinary append verification. The
    /// complete composer value must equal the one value predicted by replacing the
    /// owned UTF-16 range; merely finding the transcript elsewhere could accept a
    /// duplicate occurrence or an unrelated pre-existing phrase.
    private func waitForExactBackgroundValue(
        _ expectedValue: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FocusLockService.shared.backgroundInputText(for: session)
                == expectedValue {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return FocusLockService.shared.backgroundInputText(for: session)
            == expectedValue
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
        case .primaryCurrentInput:
            preconditionFailure("Primary cannot enter background exact delivery")
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
        let sendMethod = Self.foregroundAutoSendMethod(
            bundleIdentifier: target.bundleIdentifier,
            autoSendKey: key
        )
        let result = await CursorPaster.performAutoSend(
            key,
            targetPID: targetPID,
            method: sendMethod,
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
                vippLog.info("paste: foreground immediate auto-send issued=true method=\(String(describing: sendMethod), privacy: .public) verification=unavailablePreState key=\(key.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public)")
                return .indeterminate
            }
            vippLog.info("paste: foreground immediate auto-send issued=true method=\(String(describing: sendMethod), privacy: .public) verification=pending key=\(key.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public)")
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
        case .primaryCurrentInput:
            preconditionFailure("Primary cannot require a saved paste target")
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
