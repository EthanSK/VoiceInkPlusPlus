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

        if focusedInput.hasExactInput,
           previouslyFrontmostApplication?.processIdentifier != targetPID {
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

        vippLog.info("paste: target restored; issuing paste keystroke targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")

        let pasteTask = CursorPaster.startPasteAtCursor(pastedText) // Use the proven foreground Cmd-V path from cba45ba; CGEvent.postToPid can succeed without the background app accepting the paste.

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
                // Keep the destination frontmost for the complete atomic delivery.
                // The live Codex trace proved that AXConfirm can return `.success`
                // without submitting an Electron editor, while Terminal happened to
                // accept it. A real foreground key-code Return is the reliable public
                // macOS route; restore the user's previous app only after it is posted.
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard await FocusLockService.shared.restoreFocus(
                    to: focusedInput,
                    allowApplicationFallback: allowsApplicationFallback
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

                let autoSendSucceeded = await performAutoSend(
                    autoSendKey,
                    to: focusedInput,
                    allowsApplicationFallback: allowsApplicationFallback,
                    transcriptLength: pastedLength,
                    expectedFrontmostPID: targetPID
                )

                vippLog.info("paste: foreground auto-send finished success=\(autoSendSucceeded, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
                if let applicationToRestore {
                    await restorePreviousApplication(applicationToRestore, displacedBy: targetPID)
                }

                guard autoSendSucceeded else {
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

        vippLog.info("paste: background exact focus verified targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(session.expectedFrontmostProcessIdentifier, privacy: .public) destination=\(String(describing: target.destination), privacy: .public)")
        let textEventsPosted = await CursorPaster.typeTextIntoTargetedProcess(
            pastedText,
            pid: session.processIdentifier
        )
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
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == session.expectedFrontmostProcessIdentifier else {
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

        try? await Task.sleep(nanoseconds: 150_000_000)
        guard await FocusLockService.shared.refreshBackgroundFocus(session),
              let textBeforeSubmit = FocusLockService.shared.backgroundInputText(for: session) else {
            showAutoSendFailure(
                "Transcription inserted, but couldn’t restore the saved background input to press Return",
                detail: "background auto-send focus verification failed targetPid=\(session.processIdentifier)"
            )
            return
        }

        let isOpenAIComposer = session.bundleIdentifier.map {
            Self.openAIComposerBundleIdentifiers.contains($0)
        } ?? false
        var submitRoute = "targetedKey"
        var submitIssued = false
        if autoSendKey == .enter, isOpenAIComposer {
            switch FocusLockService.shared.pressNearbySubmitButton(for: session) {
            case .pressed:
                submitRoute = "semanticSend"
                submitIssued = true
            case .unavailable:
                break
            case .failed(let error):
                vippLog.error("paste: background semantic Send failed AXError=\(error, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
            }
        }

        if !submitIssued {
            submitIssued = await CursorPaster.performTargetedAutoSend(
                autoSendKey,
                pid: session.processIdentifier
            ).didPostAutoSendCommand
        }
        guard submitIssued else {
            showAutoSendFailure(
                "Transcription inserted, but couldn’t press Return in the saved background input",
                detail: "no background auto-send event was created targetPid=\(session.processIdentifier)"
            )
            return
        }

        var submitVerified = await waitForBackgroundValueChange(
            from: textBeforeSubmit,
            session: session
        )
        if !submitVerified,
           submitRoute == "semanticSend",
           await FocusLockService.shared.refreshBackgroundFocus(session) {
            submitRoute = "semanticSend+targetedKey"
            let fallbackIssued = await CursorPaster.performTargetedAutoSend(
                autoSendKey,
                pid: session.processIdentifier
            ).didPostAutoSendCommand
            if fallbackIssued {
                submitVerified = await waitForBackgroundValueChange(
                    from: textBeforeSubmit,
                    session: session
                )
            }
        } else if !submitVerified,
                  autoSendKey == .enter,
                  await FocusLockService.shared.refreshBackgroundFocus(session) {
            submitRoute = "targetedKeyRetry"
            let retryIssued = await CursorPaster.performTargetedAutoSend(
                .enter,
                pid: session.processIdentifier
            ).didPostAutoSendCommand
            if retryIssued {
                submitVerified = await waitForBackgroundValueChange(
                    from: textBeforeSubmit,
                    session: session
                )
            }
        }

        let stayedBackground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == session.expectedFrontmostProcessIdentifier
        let requiresVisibleSubmittedMessage = autoSendKey == .enter && isOpenAIComposer
        let submittedTextVisible: Bool
        if requiresVisibleSubmittedMessage {
            submittedTextVisible = await waitForBackgroundSubmittedText(
                pastedText,
                session: session
            )
        } else {
            submittedTextVisible = FocusLockService.shared.backgroundWindowContains(
                pastedText.trimmingCharacters(in: .whitespacesAndNewlines),
                for: session
            )
        }
        let succeeded = submitVerified
            && stayedBackground
            && (!requiresVisibleSubmittedMessage || submittedTextVisible)
        vippLog.info("paste: background auto-send finished success=\(succeeded, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) route=\(submitRoute, privacy: .public) submittedTextVisible=\(submittedTextVisible, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        guard succeeded else {
            showAutoSendFailure(
                "Transcription inserted, but Return could not be verified in the saved background input",
                detail: "background auto-send produced no verified value change targetPid=\(session.processIdentifier)"
            )
            return
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
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FocusLockService.shared.backgroundInputText(for: session) != previousText {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return FocusLockService.shared.backgroundInputText(for: session) != previousText
    }

    private func waitForBackgroundSubmittedText(
        _ submittedText: String,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> Bool {
        let verificationText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !verificationText.isEmpty else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FocusLockService.shared.backgroundWindowContains(
                verificationText,
                for: session,
                excludingSavedInput: true
            ) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return FocusLockService.shared.backgroundWindowContains(
            verificationText,
            for: session,
            excludingSavedInput: true
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
    ) async -> Bool {
        let isOpenAIComposer = target.bundleIdentifier.map {
            Self.openAIComposerBundleIdentifiers.contains($0)
        } ?? false

        guard key == .enter, isOpenAIComposer else {
            return await CursorPaster.performAutoSend(
                key,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID
            ).didPostAutoSendCommand
        }

        // OpenAI's Electron composer has now ignored both a background AXConfirm
        // that returned success and an instantaneous foreground CGEvent pair. First
        // use its tightly-scoped adjacent Send button when present. While a response
        // is already running that button becomes Stop, so fall back to System Events'
        // script-level key code 36—the public equivalent of a real scripted Return.
        let textBeforeSubmit = FocusLockService.shared.focusedInputText(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        )
        var primaryIssued = false
        switch FocusLockService.shared.pressNearbySubmitButton(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        ) {
        case .pressed:
            primaryIssued = true
            vippLog.info("paste: OpenAI composer auto-send used nearby Send button targetPid=\(expectedFrontmostPID, privacy: .public)")
        case .unavailable:
            let result = await CursorPaster.performAutoSend(
                .enter,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                method: .systemEvents,
                sendRedundantEnter: false
            )
            primaryIssued = result.didPostAutoSendCommand
            vippLog.info("paste: OpenAI composer nearby Send unavailable; System Events Return issued=\(primaryIssued, privacy: .public) targetPid=\(expectedFrontmostPID, privacy: .public)")
        case .failed(let error):
            vippLog.error("paste: OpenAI composer nearby Send failed AXError=\(error, privacy: .public); trying System Events Return targetPid=\(expectedFrontmostPID, privacy: .public)")
            let result = await CursorPaster.performAutoSend(
                .enter,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                method: .systemEvents,
                sendRedundantEnter: false
            )
            primaryIssued = result.didPostAutoSendCommand
        }

        guard primaryIssued else {
            return await CursorPaster.performAutoSend(
                .enter,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                method: .cgEvent,
                sendRedundantEnter: false
            ).didPostAutoSendCommand
        }

        // Chat composers clear or replace the editor value when a submit is accepted.
        // If AX cannot read the value, report only that the action was issued. If it
        // can read the value and it remains identical, retry once with a humanized HID
        // CGEvent; if that also leaves the transcript untouched, surface a real error
        // instead of another false-success log.
        guard let textBeforeSubmit, !textBeforeSubmit.isEmpty else {
            vippLog.notice("paste: OpenAI composer submit verification unavailable before action targetPid=\(expectedFrontmostPID, privacy: .public)")
            return true
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard FocusLockService.shared.focusedInputText(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        ) == textBeforeSubmit else {
            vippLog.info("paste: OpenAI composer changed after primary auto-send targetPid=\(expectedFrontmostPID, privacy: .public)")
            return true
        }

        vippLog.notice("paste: OpenAI composer ignored primary auto-send; trying humanized CGEvent Return targetPid=\(expectedFrontmostPID, privacy: .public)")
        let fallback = await CursorPaster.performAutoSend(
            .enter,
            transcriptLength: transcriptLength,
            expectedFrontmostPID: expectedFrontmostPID,
            method: .cgEvent,
            sendRedundantEnter: false
        )
        guard fallback.didPostAutoSendCommand else { return false }

        try? await Task.sleep(nanoseconds: 350_000_000)
        let textAfterFallback = FocusLockService.shared.focusedInputText(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
        )
        guard textAfterFallback != textBeforeSubmit else {
            vippLog.error("paste: OpenAI composer still contained identical text after both auto-send routes targetPid=\(expectedFrontmostPID, privacy: .public)")
            return false
        }

        vippLog.info("paste: OpenAI composer changed after humanized CGEvent fallback targetPid=\(expectedFrontmostPID, privacy: .public)")
        return true
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
