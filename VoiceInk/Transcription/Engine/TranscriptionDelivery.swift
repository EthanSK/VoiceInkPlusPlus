import Foundation
import AppKit   // NSWorkspace (frontmost-app pid for VIPPDebug paste logging)
import os

/// Clipboard state and background app-internal focus are process-global resources.
/// MainActor alone does not serialize across `await`: two completed transcriptions
/// can otherwise interleave their clipboard or same-PID internal-focus sessions.
@MainActor
final class DeliverySerializationGate {
    static let shared = DeliverySerializationGate()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

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
    private static let terminalHostBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable"
    ]

    enum BackgroundSubmissionSurface: Equatable {
        case chatComposer
        case terminal
        case generic
    }

    enum BackgroundSubmissionVerification: Equatable {
        case verified
        case unchanged
        case modifiedWithoutSubmit
        case unavailable
    }

    static func submissionSurface(
        for bundleIdentifier: String?
    ) -> BackgroundSubmissionSurface {
        guard let bundleIdentifier else { return .generic }
        if openAIComposerBundleIdentifiers.contains(bundleIdentifier)
            || bundleIdentifier == "ru.keepcoder.Telegram" {
            return .chatComposer
        }
        if terminalHostBundleIdentifiers.contains(bundleIdentifier) {
            return .terminal
        }
        return .generic
    }

    static func classifyBackgroundSubmission(
        from previousText: String,
        to currentText: String?,
        surface: BackgroundSubmissionSurface
    ) -> BackgroundSubmissionVerification {
        guard let currentText else { return .unavailable }
        guard currentText != previousText else { return .unchanged }

        switch surface {
        case .chatComposer:
            // Chat submission is proven only by a reset/clear of the exact composer.
            // A newline, spellcheck rewrite, or concurrent edit is not submission and
            // must never trigger another Return.
            return currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .verified
                : .modifiedWithoutSubmit
        case .terminal:
            // Terminal AXValue generally exposes the terminal buffer. A one-shot
            // Return is proven only when a bounded tail of the submitted prompt is
            // still present and is followed by a line transition. Scrollback trims
            // or full-screen TUI rewrites are indeterminate, not visible failures,
            // and must never trigger another Return.
            let anchor = String(previousText.suffix(512))
            guard !anchor.isEmpty,
                  let anchorRange = currentText.range(
                    of: anchor,
                    options: .backwards
                  ) else {
                return .unavailable
            }
            let suffix = currentText[anchorRange.upperBound...]
            return suffix.contains("\n") || suffix.contains("\r")
                ? .verified
                : .unavailable
        case .generic:
            // For a generic editor, applying Enter/Shift-Enter/Command-Enter may
            // intentionally change the field rather than clear it. The exact readable
            // change proves the configured key was handled, but is never used to
            // justify a retry.
            return .verified
        }
    }

    static func classifyNativeTerminalDelivery(
        from previousText: String,
        to currentText: String?,
        insertedText: String,
        autoSendEnabled: Bool
    ) -> BackgroundSubmissionVerification {
        guard let currentText else { return .unavailable }
        guard currentText != previousText else { return .unchanged }
        guard backgroundInsertionIsVerified(
            previousText: previousText,
            currentText: currentText,
            insertedText: insertedText,
            selectionLocation: nil,
            selectionLength: nil
        ) else {
            // A full-screen TUI can immediately repaint away both the prompt and
            // submitted text. That is indeterminate—not permission to issue the
            // exact-session operation twice.
            return .unavailable
        }
        guard autoSendEnabled else { return .verified }
        guard let insertedRange = currentText.range(
            of: insertedText,
            options: .backwards
        ) else {
            return .unavailable
        }
        let suffix = currentText[insertedRange.upperBound...]
        return suffix.contains("\n") || suffix.contains("\r")
            ? .verified
            : .modifiedWithoutSubmit
    }

    static func shouldUseNonActivatingDelivery(
        targetIsFrontmost: Bool,
        hasExactInput: Bool,
        exactTargetIsCurrentInput: Bool
    ) -> Bool {
        !targetIsFrontmost || (hasExactInput && !exactTargetIsCurrentInput)
    }

    static func allowsBackgroundReturnRetry(
        surface: BackgroundSubmissionSurface,
        isOpenAIComposer: Bool,
        keyAttempts: Int,
        verification: BackgroundSubmissionVerification
    ) -> Bool {
        surface == .chatComposer
            && isOpenAIComposer
            && keyAttempts == 1
            && verification == .unchanged
    }

    static func backgroundInsertionIsVerified(
        previousText: String,
        currentText: String?,
        insertedText: String,
        selectionLocation: Int?,
        selectionLength: Int?
    ) -> Bool {
        guard let currentText,
              !insertedText.isEmpty,
              currentText != previousText else {
            return false
        }

        if let selectionLocation,
           let selectionLength,
           selectionLocation >= 0,
           selectionLength >= 0,
           selectionLocation + selectionLength
                <= (previousText as NSString).length {
            let expected = NSMutableString(string: previousText)
            expected.replaceCharacters(
                in: NSRange(
                    location: selectionLocation,
                    length: selectionLength
                ),
                with: insertedText
            )
            if currentText == (expected as String) {
                return true
            }
        }

        // If selection metadata is unavailable or the app normalizes its editor
        // value, require a new occurrence of the exact transcript. Merely seeing a
        // transcript that already existed before delivery cannot prove insertion.
        return occurrenceCount(of: insertedText, in: currentText)
            > occurrenceCount(of: insertedText, in: previousText)
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
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

        await DeliverySerializationGate.shared.acquire()
        defer {
            DeliverySerializationGate.shared.release()
            FocusLockService.shared.clearLock()
        }

        guard let requestedFocusedInput = target.focusedInput else {
            handleMissingPasteTarget(pastedText, destination: target.destination)
            return
        }
        let allowsApplicationFallback = target.destination == .recordingStart
        let targetPID = requestedFocusedInput.processIdentifier
        let focusedInput: FocusLockService.Target
        if allowsApplicationFallback,
           !requestedFocusedInput.hasExactInput,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID {
            // A recording-start application fallback is only permission to resolve
            // one currently focused editable element in that saved app. Promote that
            // element to a fresh exact target before the foreground transaction so
            // paste verification and Return remain tied to one wrapper. Otherwise a
            // PID-only fallback could paste nowhere and submit pre-existing text—or
            // follow Ethan into a different input during the auto-send delay.
            guard let exactFallback = FocusLockService.shared
                .captureFocusedInputSnapshot(),
                  exactFallback.hasExactInput,
                  exactFallback.processIdentifier == targetPID else {
                handleForegroundPasteFailure(
                    pastedText,
                    destination: target.destination,
                    detail: "recording-start application fallback did not resolve one exact foreground input"
                )
                return
            }
            focusedInput = exactFallback
            vippLog.notice("paste: promoted foreground recording-start app fallback to one exact input targetPid=\(targetPID, privacy: .public)")
        } else {
            focusedInput = requestedFocusedInput
        }
        let autoSendKey = output.outputMode == .paste ? output.autoSendKey : .none

        // Terminal/iTerm AX editors are not session identities. Route them through
        // one native window+TTY/session operation even when they are currently
        // foreground, so text and Return can never split across two tabs/panes.
        // Missing native identity or unsupported paste-only/modified-Return policy
        // fails closed inside that route; it must not fall through to PID Unicode.
        if FocusLockService.shared.requiresNativeTerminalSessionBinding(
            for: focusedInput
        ) {
            await deliverToBackgroundExactInput(
                pastedText,
                target: target,
                focusedInput: focusedInput,
                autoSendKey: autoSendKey,
                allowsApplicationFallback: allowsApplicationFallback
            )
            return
        }

        let exactTargetIsCurrentInput = focusedInput.hasExactInput
            && FocusLockService.shared.targetIsCurrentKeyboardInput(focusedInput)
        if Self.shouldUseNonActivatingDelivery(
            targetIsFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
            hasExactInput: focusedInput.hasExactInput,
            exactTargetIsCurrentInput: exactTargetIsCurrentInput
        ) {
            await deliverToBackgroundExactInput(
                pastedText,
                target: target,
                focusedInput: focusedInput,
                autoSendKey: autoSendKey,
                allowsApplicationFallback: allowsApplicationFallback
            )
            return
        }

        // The foreground route is allowed only while the saved exact input already
        // owns keyboard focus. Never reactivate/refocus it after Ethan moves; switch
        // to the non-activating route instead.
        guard FocusLockService.shared.foregroundTargetStillOwnsKeyboardInput(
            focusedInput,
            allowApplicationFallback: allowsApplicationFallback
        ) else {
            await deliverToBackgroundExactInput(
                pastedText,
                target: target,
                focusedInput: focusedInput,
                autoSendKey: autoSendKey,
                allowsApplicationFallback: allowsApplicationFallback
            )
            return
        }

        guard let insertionSnapshot = FocusLockService.shared.focusedInputSnapshot(
            for: focusedInput
        ) else {
            handleForegroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "saved foreground input was unreadable before paste"
            )
            return
        }

        vippLog.info("paste: exact foreground target verified; issuing paste targetPid=\(targetPID, privacy: .public)")
        let pasteResult = await CursorPaster.pasteAtCursorAndWaitUntilPosted(
            pastedText
        ) {
            FocusLockService.shared.foregroundTargetStillOwnsKeyboardInput(
                focusedInput,
                allowApplicationFallback: allowsApplicationFallback
            )
        }
        if pasteResult == .clipboardOwnershipLost {
            // The transcript remains in VoiceInk++ history. Do not apply the normal
            // clipboard recovery here: Ethan copied something after this delivery
            // began, and that newer clipboard must win.
            NotificationManager.shared.showNotification(
                title: String(localized: "Paste cancelled because your clipboard changed — transcription remains in history"),
                type: .error
            )
            vippLog.error("paste: foreground delivery cancelled because clipboard session ownership changed; newer clipboard preserved targetPid=\(targetPID, privacy: .public)")
            return
        }
        guard pasteResult.didPostPasteCommand else {
            handleForegroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "paste command was not posted because exact focus changed"
            )
            return
        }

        guard await waitForForegroundInsertion(
            pastedText,
            previousSnapshot: insertionSnapshot,
            target: focusedInput
        ) else {
            handleForegroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "paste command was issued but the exact saved input did not contain the expected edit"
            )
            return
        }
        vippLog.info("paste: foreground text verified success=true targetPid=\(targetPID, privacy: .public) chars=\(pastedText.count, privacy: .public)")

        guard autoSendKey.isEnabled else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)

        if FocusLockService.shared.foregroundTargetStillOwnsKeyboardInput(
            focusedInput,
            allowApplicationFallback: allowsApplicationFallback
        ) {
            let autoSendSucceeded = await performAutoSend(
                autoSendKey,
                to: focusedInput,
                allowsApplicationFallback: allowsApplicationFallback,
                transcriptLength: pastedText.count,
                expectedFrontmostPID: targetPID
            )
            vippLog.info("paste: foreground auto-send finished success=\(autoSendSucceeded, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) targetPid=\(targetPID, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            if !autoSendSucceeded {
                showAutoSendFailure(
                    "Transcription pasted, but couldn’t press Return automatically",
                    detail: "foreground Return produced no verified submit targetPid=\(targetPID)"
                )
            }
            return
        }

        // Ethan moved after the verified paste. Continue auto-send through the exact
        // non-activating route; never restore or reactivate the old input. App-only
        // fallbacks cannot prove that their internally focused editor is still the
        // one that received the paste, so they fail visibly here.
        guard focusedInput.hasExactInput,
              let backgroundSession = await FocusLockService.shared
                .prepareBackgroundDelivery(to: focusedInput) else {
            showAutoSendFailure(
                "Transcription pasted, but couldn’t press Return without taking focus",
                detail: "foreground destination changed before auto-send targetPid=\(targetPID)"
            )
            return
        }
        defer { FocusLockService.shared.finishBackgroundDelivery(backgroundSession) }
        await performBackgroundAutoSend(
            pastedText,
            autoSendKey: autoSendKey,
            session: backgroundSession
        )
    }

    private func deliverToBackgroundExactInput(
        _ pastedText: String,
        target: RecordingPasteTarget,
        focusedInput: FocusLockService.Target,
        autoSendKey: AutoSendKey,
        allowsApplicationFallback: Bool
    ) async {
        guard let session = await FocusLockService.shared.prepareBackgroundDelivery(
            to: focusedInput,
            allowApplicationFallback: allowsApplicationFallback
        ) else {
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "exact background focus preparation failed"
            )
            return
        }
        defer { FocusLockService.shared.finishBackgroundDelivery(session) }

        vippLog.info("paste: background exact focus verified targetPid=\(session.processIdentifier, privacy: .public) startFrontmostPid=\(session.expectedFrontmostProcessIdentifier, privacy: .public) resolution=\(session.resolutionDescription, privacy: .public) focusMode=\(session.focusModeDescription, privacy: .public) destination=\(String(describing: target.destination), privacy: .public)")

        if FocusLockService.shared.requiresNativeTerminalSessionBinding(
            for: focusedInput
        ) {
            await deliverToNativeTerminalSession(
                pastedText,
                target: target,
                autoSendKey: autoSendKey,
                session: session
            )
            return
        }

        guard let insertionSnapshot = FocusLockService.shared.backgroundInputSnapshot(
            for: session
        ) else {
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "saved input does not expose readable text for verification"
            )
            return
        }

        var insertionRoute = "targetedUnicode"
        var insertionIssued = false
        var insertionVerified = false

        if FocusLockService.shared.prefersAccessibilityTextInsertion(for: session)
            || session.requiresDirectAccessibilityInsertion {
            switch FocusLockService.shared.insertTextUsingAccessibility(
                pastedText,
                for: session
            ) {
            case .acceptedSelectedText:
                insertionRoute = "AXSelectedText"
                insertionIssued = true
                insertionVerified = await waitForBackgroundInsertion(
                    pastedText,
                    previousSnapshot: insertionSnapshot,
                    session: session
                )

                // AX success alone is not proof. If the exact readable value is still
                // byte-for-byte unchanged, the native setter was safely a no-op and
                // targeted Unicode can be tried without risking duplicate insertion.
                if !insertionVerified,
                   FocusLockService.shared.backgroundInputText(for: session)
                    == insertionSnapshot.text,
                   session.allowsTargetedKeyboardEvents,
                   FocusLockService.shared.backgroundFocusSafetyVerified(for: session) {
                    insertionRoute = "AXSelectedText+targetedUnicode"
                    insertionIssued = await CursorPaster.typeTextIntoTargetedProcess(
                        pastedText,
                        pid: session.processIdentifier,
                        prepareInputSession: false,
                        preflight: {
                            FocusLockService.shared
                                .backgroundKeyboardEventTargetIsVerified(for: session)
                        },
                        fastPreflight: {
                            FocusLockService.shared
                                .backgroundKeyboardEventFastBoundaryMatches(for: session)
                        }
                    )
                    if insertionIssued,
                       FocusLockService.shared.backgroundFocusSafetyVerified(for: session) {
                        insertionVerified = await waitForBackgroundInsertion(
                            pastedText,
                            previousSnapshot: insertionSnapshot,
                            session: session
                        )
                    }
                }
            case .unavailable:
                break
            case .failed(let error):
                // A setter error does not prove that the app performed no mutation.
                // Do not risk duplicate insertion through a second transport.
                insertionRoute = "AXSelectedTextFailed(\(error))"
                insertionIssued = true
            case .focusSafetyViolation:
                insertionRoute = "AXSelectedTextFocusViolation"
                insertionIssued = true
            }
        }

        if !insertionIssued,
           session.allowsTargetedKeyboardEvents,
           FocusLockService.shared.backgroundFocusSafetyVerified(for: session) {
            insertionRoute = "targetedUnicode"
            insertionIssued = await CursorPaster.typeTextIntoTargetedProcess(
                pastedText,
                pid: session.processIdentifier,
                prepareInputSession: false,
                preflight: {
                    FocusLockService.shared
                        .backgroundKeyboardEventTargetIsVerified(for: session)
                },
                fastPreflight: {
                    FocusLockService.shared
                        .backgroundKeyboardEventFastBoundaryMatches(for: session)
                }
            )
            if insertionIssued,
               FocusLockService.shared.backgroundFocusSafetyVerified(for: session) {
                insertionVerified = await waitForBackgroundInsertion(
                    pastedText,
                    previousSnapshot: insertionSnapshot,
                    session: session
                )
            }
        }

        let targetStayedBackground = session.targetWasFrontmostAtStart
            || NSWorkspace.shared.frontmostApplication?.processIdentifier
                != session.processIdentifier
        let keyboardFocusStayedSafe = FocusLockService.shared
            .backgroundFocusSafetyVerified(for: session)
        guard insertionVerified,
              targetStayedBackground,
              keyboardFocusStayedSafe else {
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "non-activating insertion verification failed route=\(insertionRoute) issued=\(insertionIssued) frontmostSafe=\(targetStayedBackground) keyboardSafe=\(keyboardFocusStayedSafe)"
            )
            return
        }

        vippLog.info("paste: background text verified success=true targetPid=\(session.processIdentifier, privacy: .public) chars=\(pastedText.count, privacy: .public) route=\(insertionRoute, privacy: .public) startFrontmostPid=\(session.expectedFrontmostProcessIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
        guard autoSendKey.isEnabled else {
            vippLog.info("paste: background exact delivery finished success=true autoSend=none targetPid=\(session.processIdentifier, privacy: .public)")
            return
        }

        await performBackgroundAutoSend(
            pastedText,
            autoSendKey: autoSendKey,
            session: session
        )
    }

    private func deliverToNativeTerminalSession(
        _ pastedText: String,
        target: RecordingPasteTarget,
        autoSendKey: AutoSendKey,
        session: FocusLockService.BackgroundDeliverySession
    ) async {
        let result = await FocusLockService.shared.performTerminalTextDelivery(
            pastedText,
            autoSendKey: autoSendKey,
            for: session
        )
        switch result {
        case .unavailable:
            handleBackgroundPasteFailure(
                pastedText,
                destination: target.destination,
                detail: "native terminal session delivery is unavailable for this host/key; Apple Terminal paste-only and modified Return intentionally fail closed"
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
                detail: "native terminal operation could not prove that keyboard/frontmost focus remained safe"
            )
        case .issued(let previousContents, let currentContents):
            let verification = Self.classifyNativeTerminalDelivery(
                from: previousContents,
                to: currentContents,
                insertedText: pastedText,
                autoSendEnabled: autoSendKey == .enter
            )
            let frontmostSafe = session.targetWasFrontmostAtStart
                || NSWorkspace.shared.frontmostApplication?.processIdentifier
                    != session.processIdentifier
            let keyboardSafe = FocusLockService.shared.backgroundFocusSafetyVerified(
                for: session,
                allowReplacementAfterSubmission: autoSendKey == .enter
            )

            if autoSendKey == .none {
                let succeeded = verification == .verified
                    && frontmostSafe
                    && keyboardSafe
                vippLog.info("paste: background exact terminal delivery finished success=\(succeeded, privacy: .public) route=terminalNativeText verification=\(String(describing: verification), privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
                if !succeeded {
                    handleBackgroundPasteFailure(
                        pastedText,
                        destination: target.destination,
                        detail: "exact iTerm paste-only mutation was not verified verification=\(verification) frontmostSafe=\(frontmostSafe) keyboardSafe=\(keyboardSafe)"
                    )
                }
                return
            }

            let succeeded = verification == .verified
                && frontmostSafe
                && keyboardSafe
            vippLog.info("paste: background text verified success=\(verification == .verified, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) chars=\(pastedText.count, privacy: .public) route=terminalNativeAtomic startFrontmostPid=\(session.expectedFrontmostProcessIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            vippLog.info("paste: background auto-send finished success=\(succeeded, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) route=terminalNativeAtomic verification=\(String(describing: verification), privacy: .public) surface=terminal startFrontmostPid=\(session.expectedFrontmostProcessIdentifier, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")
            if succeeded { return }

            switch verification {
            case .unavailable where frontmostSafe && keyboardSafe:
                // A full-screen Claude/Codex TUI may repaint the native contents
                // before the bounded read returns. The exact-session write+newline
                // was one atomic issued action, so preserve telemetry without a
                // misleading red error or dangerous retry.
                vippLog.notice("paste: exact terminal text+Return post-state became unreadable; no retry and no visible false-failure targetPid=\(session.processIdentifier, privacy: .public)")
            case .modifiedWithoutSubmit:
                showAutoSendFailure(
                    "Transcription inserted into the saved terminal session, but Return was not verified",
                    detail: "terminalNativeAtomic modifiedWithoutSubmit targetPid=\(session.processIdentifier)"
                )
            case .unchanged:
                handleBackgroundPasteFailure(
                    pastedText,
                    destination: target.destination,
                    detail: "exact terminal session contents remained unchanged after native text+Return"
                )
            case .verified, .unavailable:
                showAutoSendFailure(
                    "Terminal delivery could not preserve focus safely",
                    detail: "terminalNativeAtomic verification=\(verification) frontmostSafe=\(frontmostSafe) keyboardSafe=\(keyboardSafe) targetPid=\(session.processIdentifier)"
                )
            }
        }
    }

    private func performBackgroundAutoSend(
        _ pastedText: String,
        autoSendKey: AutoSendKey,
        session: FocusLockService.BackgroundDeliverySession
    ) async {
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
        let submissionSurface = Self.submissionSurface(
            for: session.bundleIdentifier
        )
        var submitRoutes: [String] = []
        var submitIssued = false
        var keyAttempts = 0
        var verification: BackgroundSubmissionVerification = .unchanged
        var retryAllowed = true

        // A proven explicitly labelled Send control is the least synthetic route.
        // Never press an unlabelled OpenAI square: the same exact wrapper/geometry may
        // become Stop while an agent runs. No loose delivery-time or whole-window
        // button search occurs.
        if autoSendKey == .enter {
            switch FocusLockService.shared.pressNearbySubmitButton(for: session) {
            case .pressed:
                submitIssued = true
                submitRoutes.append("semanticSend")
                verification = await waitForBackgroundSubmission(
                    from: textBeforeSubmit,
                    session: session,
                    surface: submissionSurface
                )
            case .unavailable:
                break
            case .failed(let error):
                // AX can report an error after the control already handled the
                // action. Verify post-state before any fallback so a false error
                // cannot produce a duplicate submission.
                submitIssued = true
                submitRoutes.append("semanticSendAXError")
                vippLog.error("paste: background semantic Send failed AXError=\(error, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
                verification = await waitForBackgroundSubmission(
                    from: textBeforeSubmit,
                    session: session,
                    surface: submissionSurface
                )
                retryAllowed = verification == .unchanged
            case .focusSafetyViolation:
                submitIssued = true
                submitRoutes.append("semanticSendFocusChanged")
                retryAllowed = false
                verification = .unavailable
                vippLog.error("paste: background semantic Send stopped because keyboard focus changed targetPid=\(session.processIdentifier, privacy: .public)")
            }
        }

        if verification == .unchanged,
           retryAllowed,
           await FocusLockService.shared.refreshBackgroundFocus(session),
           FocusLockService.shared.backgroundFocusSafetyVerified(for: session) {
            let autoSendResult: FocusLockService.BackgroundAutoSendResult
            let route: String
            if session.usesCurrentSystemKeyboardFocus {
                autoSendResult = await FocusLockService.shared
                    .performKeyboardFocusedAutoSend(autoSendKey, for: session)
                route = "keyboardFocusedHID"
            } else {
                autoSendResult = .unavailable
                route = "unavailable"
            }

            switch autoSendResult {
            case .issued:
                submitIssued = true
                keyAttempts += 1
                submitRoutes.append(route)
                if !FocusLockService.shared.backgroundFocusSafetyVerified(
                    for: session,
                    allowReplacementAfterSubmission: true
                ) {
                    verification = .unavailable
                    retryAllowed = false
                    vippLog.error("paste: non-activating auto-send violated keyboard-focus safety route=\(route, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
                } else {
                    verification = await waitForBackgroundSubmission(
                        from: textBeforeSubmit,
                        session: session,
                        surface: submissionSurface
                    )
                }
            case .unavailable:
                break
            case .failed(let detail):
                vippLog.error("paste: non-activating auto-send failed route=\(route, privacy: .public) detail=\(detail, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
            case .focusSafetyViolation:
                verification = .unavailable
                retryAllowed = false
                vippLog.error("paste: non-activating auto-send stopped after focus-safety violation route=\(route, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public)")
            }
        }

        // Only OpenAI chat composers get one redundant Return, and only after a
        // readable unchanged composer proves the first key was a no-op. Terminals are
        // strictly one-shot; generic/Chrome inputs and Telegram never double-fire.
        if Self.allowsBackgroundReturnRetry(
            surface: submissionSurface,
            isOpenAIComposer: isOpenAIComposer,
            keyAttempts: keyAttempts,
            verification: verification
        ),
           retryAllowed,
           autoSendKey == .enter,
           session.usesCurrentSystemKeyboardFocus,
           await FocusLockService.shared.refreshBackgroundFocus(session),
           FocusLockService.shared.backgroundFocusSafetyVerified(for: session) {
            let retryResult = await FocusLockService.shared.performKeyboardFocusedAutoSend(
                .enter,
                for: session
            )
            if retryResult == .issued {
                submitIssued = true
                submitRoutes.append("keyboardFocusedHIDRetry")
                if FocusLockService.shared.backgroundFocusSafetyVerified(
                    for: session,
                    allowReplacementAfterSubmission: true
                ) {
                    verification = await waitForBackgroundSubmission(
                        from: textBeforeSubmit,
                        session: session,
                        surface: submissionSurface
                    )
                } else {
                    verification = .unavailable
                    retryAllowed = false
                }
            } else if retryResult == .focusSafetyViolation {
                verification = .unavailable
                retryAllowed = false
            }
        }

        guard submitIssued else {
            showAutoSendFailure(
                "Transcription inserted, but couldn’t press Return in the saved input without taking focus",
                detail: "no safe non-activating auto-send route targetPid=\(session.processIdentifier) focusMode=\(session.focusModeDescription)"
            )
            return
        }

        let frontmostSafe = session.targetWasFrontmostAtStart
            || NSWorkspace.shared.frontmostApplication?.processIdentifier
                != session.processIdentifier
        let keyboardSafe = FocusLockService.shared.backgroundFocusSafetyVerified(
            for: session,
            allowReplacementAfterSubmission: true
        )
        let submittedTextVisible = isOpenAIComposer
            && FocusLockService.shared.backgroundWindowContains(
                pastedText.trimmingCharacters(in: .whitespacesAndNewlines),
                for: session,
                excludingSavedInput: true
            )
        let succeeded = verification == .verified && frontmostSafe && keyboardSafe
        let submitRoute = submitRoutes.joined(separator: "+")
        vippLog.info("paste: background auto-send finished success=\(succeeded, privacy: .public) key=\(autoSendKey.rawValue, privacy: .public) route=\(submitRoute, privacy: .public) verification=\(String(describing: verification), privacy: .public) surface=\(String(describing: submissionSurface), privacy: .public) submittedTextVisible=\(submittedTextVisible, privacy: .public) startFrontmostPid=\(session.expectedFrontmostProcessIdentifier, privacy: .public) targetPid=\(session.processIdentifier, privacy: .public) frontmostPid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, privacy: .public)")

        if succeeded { return }

        switch verification {
        case .unavailable where frontmostSafe && keyboardSafe:
            // An issued action with unreadable post-state is indeterminate, not a
            // proven failure. Keep detailed telemetry but avoid the false red error
            // Ethan saw after Codex had actually submitted successfully.
            vippLog.notice("paste: background auto-send verification unavailable after issued action; no visible false-failure notification targetPid=\(session.processIdentifier, privacy: .public) route=\(submitRoute, privacy: .public)")
        case .modifiedWithoutSubmit:
            showAutoSendFailure(
                "Transcription inserted, but Return changed the saved input without submitting it",
                detail: "background auto-send modifiedWithoutSubmit route=\(submitRoute) targetPid=\(session.processIdentifier)"
            )
        case .unchanged:
            showAutoSendFailure(
                "Transcription inserted, but the saved input ignored Return",
                detail: "background auto-send unchanged route=\(submitRoute) targetPid=\(session.processIdentifier)"
            )
        case .verified, .unavailable:
            showAutoSendFailure(
                "Transcription inserted, but background delivery could not preserve focus safely",
                detail: "background auto-send focusSafe=\(keyboardSafe) frontmostSafe=\(frontmostSafe) verification=\(verification) route=\(submitRoute) targetPid=\(session.processIdentifier)"
            )
        }
    }

    private func waitForForegroundInsertion(
        _ insertedText: String,
        previousSnapshot: FocusLockService.BackgroundInputSnapshot,
        target: FocusLockService.Target
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Self.backgroundInsertionIsVerified(
                previousText: previousSnapshot.text,
                currentText: FocusLockService.shared.focusedInputText(for: target),
                insertedText: insertedText,
                selectionLocation: previousSnapshot.selectionLocation,
                selectionLength: previousSnapshot.selectionLength
            ) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return Self.backgroundInsertionIsVerified(
            previousText: previousSnapshot.text,
            currentText: FocusLockService.shared.focusedInputText(for: target),
            insertedText: insertedText,
            selectionLocation: previousSnapshot.selectionLocation,
            selectionLength: previousSnapshot.selectionLength
        )
    }

    private func waitForBackgroundInsertion(
        _ insertedText: String,
        previousSnapshot: FocusLockService.BackgroundInputSnapshot,
        session: FocusLockService.BackgroundDeliverySession
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Self.backgroundInsertionIsVerified(
                previousText: previousSnapshot.text,
                currentText: FocusLockService.shared.backgroundInputText(for: session),
                insertedText: insertedText,
                selectionLocation: previousSnapshot.selectionLocation,
                selectionLength: previousSnapshot.selectionLength
            ) {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return Self.backgroundInsertionIsVerified(
            previousText: previousSnapshot.text,
            currentText: FocusLockService.shared.backgroundInputText(for: session),
            insertedText: insertedText,
            selectionLocation: previousSnapshot.selectionLocation,
            selectionLength: previousSnapshot.selectionLength
        )
    }

    private func waitForBackgroundSubmission(
        from previousText: String,
        session: FocusLockService.BackgroundDeliverySession,
        surface: BackgroundSubmissionSurface
    ) async -> BackgroundSubmissionVerification {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.25
        var latest: BackgroundSubmissionVerification = .unavailable
        while ProcessInfo.processInfo.systemUptime < deadline {
            latest = Self.classifyBackgroundSubmission(
                from: previousText,
                to: FocusLockService.shared.backgroundInputText(
                    for: session,
                    allowReplacementAfterSubmission: true
                ),
                surface: surface
            )
            if latest == .verified {
                return .verified
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return Self.classifyBackgroundSubmission(
            from: previousText,
            to: FocusLockService.shared.backgroundInputText(
                for: session,
                allowReplacementAfterSubmission: true
            ),
            surface: surface
        )
    }

    private func handleForegroundPasteFailure(
        _ pastedText: String,
        destination: RecordingPasteDestination,
        detail: String
    ) {
        _ = ClipboardManager.copyToClipboard(pastedText)
        NotificationManager.shared.showNotification(
            title: String(localized: "Couldn’t verify the paste in the saved input — transcription copied to clipboard"),
            type: .error
        )
        vippLog.error("paste: foreground exact delivery failed destination=\(String(describing: destination), privacy: .public) detail=\(detail, privacy: .public)")
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
        let exactFocusPreflight = {
            FocusLockService.shared.foregroundTargetStillOwnsKeyboardInput(
                target,
                allowApplicationFallback: allowsApplicationFallback
            )
        }
        guard exactFocusPreflight() else { return false }

        guard key == .enter, isOpenAIComposer else {
            let textBeforeSubmit = FocusLockService.shared.focusedInputText(
                for: target,
                allowApplicationFallback: allowsApplicationFallback
            )
            let issued = await CursorPaster.performAutoSend(
                key,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                sendRedundantEnter: false,
                preflight: exactFocusPreflight
            ).didPostAutoSendCommand
            guard issued else { return false }
            guard let textBeforeSubmit else { return true }
            try? await Task.sleep(nanoseconds: 350_000_000)
            let surface = Self.submissionSurface(
                for: target.bundleIdentifier
            )
            let verification = Self.classifyBackgroundSubmission(
                from: textBeforeSubmit,
                to: FocusLockService.shared.focusedInputText(
                    for: target,
                    allowApplicationFallback: allowsApplicationFallback
                ),
                surface: surface
            )
            return verification == .verified || verification == .unavailable
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
                sendRedundantEnter: false,
                preflight: exactFocusPreflight
            )
            primaryIssued = result.didPostAutoSendCommand
            vippLog.info("paste: OpenAI composer nearby Send unavailable; System Events Return issued=\(primaryIssued, privacy: .public) targetPid=\(expectedFrontmostPID, privacy: .public)")
        case .failed(let error):
            // AX may return an error after the button already handled the press.
            // Treat it as attempted and verify before considering any fallback.
            primaryIssued = true
            vippLog.error("paste: OpenAI composer nearby Send returned AXError=\(error, privacy: .public); verifying before any fallback targetPid=\(expectedFrontmostPID, privacy: .public)")
        case .focusSafetyViolation:
            vippLog.error("paste: OpenAI composer nearby Send changed keyboard focus unexpectedly targetPid=\(expectedFrontmostPID, privacy: .public)")
            return false
        }

        guard primaryIssued else {
            return await CursorPaster.performAutoSend(
                .enter,
                transcriptLength: transcriptLength,
                expectedFrontmostPID: expectedFrontmostPID,
                method: .cgEvent,
                sendRedundantEnter: false,
                preflight: exactFocusPreflight
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
        let primaryVerification = Self.classifyBackgroundSubmission(
            from: textBeforeSubmit,
            to: FocusLockService.shared.focusedInputText(
            for: target,
            allowApplicationFallback: allowsApplicationFallback
            ),
            surface: .chatComposer
        )
        switch primaryVerification {
        case .verified:
            vippLog.info("paste: OpenAI composer changed after primary auto-send targetPid=\(expectedFrontmostPID, privacy: .public)")
            return true
        case .unavailable:
            vippLog.notice("paste: OpenAI composer verification became unreadable after primary auto-send; treating issued action as indeterminate instead of a visible false failure targetPid=\(expectedFrontmostPID, privacy: .public)")
            return true
        case .modifiedWithoutSubmit:
            vippLog.error("paste: OpenAI composer changed without clearing after primary auto-send; refusing a duplicate Return targetPid=\(expectedFrontmostPID, privacy: .public)")
            return false
        case .unchanged:
            break
        }

        vippLog.notice("paste: OpenAI composer ignored primary auto-send; trying humanized CGEvent Return targetPid=\(expectedFrontmostPID, privacy: .public)")
        let fallback = await CursorPaster.performAutoSend(
            .enter,
            transcriptLength: transcriptLength,
            expectedFrontmostPID: expectedFrontmostPID,
            method: .cgEvent,
            sendRedundantEnter: false,
            preflight: exactFocusPreflight
        )
        guard fallback.didPostAutoSendCommand else { return false }

        try? await Task.sleep(nanoseconds: 350_000_000)
        let fallbackVerification = Self.classifyBackgroundSubmission(
            from: textBeforeSubmit,
            to: FocusLockService.shared.focusedInputText(
                for: target,
                allowApplicationFallback: allowsApplicationFallback
            ),
            surface: .chatComposer
        )
        guard fallbackVerification != .unchanged else {
            vippLog.error("paste: OpenAI composer still contained identical text after both auto-send routes targetPid=\(expectedFrontmostPID, privacy: .public)")
            return false
        }
        if fallbackVerification == .modifiedWithoutSubmit {
            vippLog.error("paste: OpenAI composer changed without clearing after humanized CGEvent fallback targetPid=\(expectedFrontmostPID, privacy: .public)")
            return false
        }
        vippLog.info("paste: OpenAI composer verified or became unreadable after humanized CGEvent fallback verification=\(String(describing: fallbackVerification), privacy: .public) targetPid=\(expectedFrontmostPID, privacy: .public)")
        return true
    }

    private func showAutoSendFailure(_ title: String, detail: String) {
        NotificationManager.shared.showNotification(
            title: title,
            type: .error
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
