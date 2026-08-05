import Foundation
import SwiftData
import os

/// Chooses whether an explicit in-flight cancellation has useful text to retain.
/// Candidates are ordered from strongest (a finished provider/enhancement result)
/// to weakest (the last realtime HUD partial). Keeping this reducer pure makes the
/// empty-versus-recoverable contract testable without a provider or paste target.
enum TranscriptionCancellationRecovery: Equatable {
    case noResult
    case recover(String)

    static func resolve(_ candidates: [String?]) -> Self {
        for candidate in candidates {
            let trimmed = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return .recover(trimmed)
            }
        }
        return .noResult
    }
}

/// Separates an explicit cancel/reset from an unexpected provider failure. A failure
/// retains the original audio and the strongest HUD draft, while a requested cancel
/// continues through the existing canceled-result path without a second error notice.
enum TranscriptionFailureRecoveryDisposition: Equatable {
    case intentionalCancellation
    case retainAudioOnly
    case retainAudioAndText(String)

    static func resolve(
        cancellationRequested: Bool,
        textCandidates: [String?]
    ) -> Self {
        guard !cancellationRequested else {
            return .intentionalCancellation
        }
        switch TranscriptionCancellationRecovery.resolve(textCandidates) {
        case .noResult:
            return .retainAudioOnly
        case .recover(let text):
            return .retainAudioAndText(text)
        }
    }
}

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery = TranscriptionDelivery()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionPipeline")
    // VIPPDebug: see RecorderUIManager for the filter predicate. Used to log the exact
    // transcription request/result + every cancel-discard decision on this path.
    private let vippLog = Logger(subsystem: "com.ethansk.VoiceInkPlusPlus", category: "VIPPDebug")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        jobIdentity: TranscriptionJobIdentity,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        pasteTarget resolvePasteTarget: @escaping () async -> RecordingPasteTarget,
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        // ── VIPP (skip-mode-processing feature) — EXPLICIT bypass flag ──
        // Resolved at pipeline-run time from the owning RecordingSession's one-shot
        // `skipPostProcessing`. We thread it as a plain Bool (NOT only via the
        // outputConfiguration closure rewrite) so the bypass is DETERMINISTIC and does
        // not depend on the closure-rewrite reaching delivery intact. When true: AI
        // enhancement is skipped AND TranscriptionDelivery is FORCED down the raw-paste
        // branch (deliverCustomCommand / deliverResponse are never taken). This is the
        // load-bearing guarantee for the "skip script" button — see the matching
        // short-circuit in TranscriptionDelivery.deliver and the resolve site in
        // VoiceInkEngine.runPipeline.
        skipPostProcessing: @escaping () -> Bool = { false },
        completionDisposition: @escaping () -> RecordingCompletionDisposition = {
            .normalDelivery
        },
        recoverablePartialTranscript: @escaping () -> String = { "" },
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        // Hard lifecycle authorization is separate from the historical soft cancel
        // behavior below. A completed non-empty response may survive an accidental late
        // cancel, but it may never cross a reset/generation boundary and paste as stale
        // work after a newer recording lifecycle has begun.
        isDeliveryAuthorized: () -> Bool,
        // A newer recording may begin after this job's provider result is ready. Most
        // side effects wait until that capture stops. The only exception is an ordinary
        // Primary FIFO-cohort paste: it may appear during the newer recording, while
        // the last-safe queue decision suppresses its Return so only the final cohort
        // member submits. Exact Next routes and every non-paste action stay exclusive.
        acquireDeliveryLease: @escaping (
            TranscriptionDeliveryLeasePolicy
        ) async -> Bool = { _ in true },
        releaseDeliveryLease: @escaping () -> Void = {},
        // Rapid normal Primary recordings form one FIFO paste cohort. Thread the
        // resolver through to Primary's last pre-Return boundary; evaluating it here
        // would be stale if a queued successor cancels or retargets while Command-V
        // and clipboard settlement are still in flight.
        resolveQueuedPrimaryAutoSend: @escaping (
            AutoSendKey,
            ModeOutputMode,
            RecordingPasteDestination
        ) -> PrimaryQueuedAutoSendResolution = { key, _, _ in
            .unchanged(key)
        },
        onQueuedPrimaryAutoSendIssued: @escaping () -> Void = {},
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var didInsertSessionMetric = false
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?

        // ── VIPP (skip-mode-processing feature) — resolve the one-shot bypass ONCE ──
        // Read the owning session's flag at pipeline-run time (after STOP) so toggling
        // the button any time before this is honored. We capture it into a local Bool and
        // use it as the AUTHORITATIVE gate for both bypass points below, instead of relying
        // solely on the enhancement/output closures' internal checks. This is the fix for
        // "the script still runs when skip is engaged": even if the outputConfiguration
        // closure's rewrite were ever lost downstream, this explicit flag forces the
        // raw-paste branch at delivery.
        let skipPostProcessingNow = skipPostProcessing()
        let completionDispositionNow = completionDisposition()
        let recoverablePartialTranscriptNow = recoverablePartialTranscript()
        if transcription.recoverableRealtimeDraftText == nil,
           !recoverablePartialTranscriptNow
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            // Backstop the stop-boundary save for queued/legacy callers. This is a
            // VoiceInk-local draft snapshot only; it must never be used as permission
            // to resolve, paste into, or mutate another app while recording.
            transcription.snapshotRealtimeDraft(recoverablePartialTranscriptNow)
            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to persist realtime recovery draft at pipeline start: \(error, privacy: .public)")
            }
        }
        if skipPostProcessingNow {
            vippLog.info("pipeline: skipPostProcessing RESOLVED=true → will bypass enhancement + force raw .paste (no mode script/respond) \(jobIdentity.logDescription, privacy: .public)")
        }

        func finishCanceledTranscription(recoveredText: String? = nil) async {
            await onCancel()

            // An explicit no-delivery exit retains its original recording until the
            // user separately deletes it from History. Automatic audio/zero-retention
            // sweeps must not turn a recoverable cancellation into silent data loss.
            transcription.preservesOriginalAudioForRecovery = true

            // A provider result already in hand outranks the last HUD partial. Never
            // retain a synthesized failure string: when status is `.failed`, only a
            // real finalText/override or the recording's HUD snapshot is eligible.
            let storedTextCandidate = transcription.transcriptionStatus ==
                TranscriptionStatus.failed.rawValue
                ? nil
                : transcription.text
            let recovery = TranscriptionCancellationRecovery.resolve([
                recoveredText,
                finalText,
                transcription.enhancedText,
                storedTextCandidate == Transcription.canceledTranscriptionText
                    ? nil
                    : storedTextCandidate,
                recoverablePartialTranscriptNow
            ])
            let retainedText: String?
            switch recovery {
            case .noResult:
                retainedText = nil
                vippLog.info("pipeline: cancellation retained no text because provider/HUD produced no usable result")
            case .recover(let text):
                retainedText = text
                let copied = ClipboardManager.copyToClipboard(text)
                vippLog.info("pipeline: cancellation retained result chars=\(text.count, privacy: .public) digest=\(TranscriptionLineageDigest.make(text), privacy: .public) clipboard=\(copied, privacy: .public)")
                NotificationManager.shared.showNotification(
                    title: copied
                        ? String(localized: "Transcription canceled — available text copied to clipboard")
                        : String(localized: "Transcription canceled — available text was saved in history"),
                    type: copied ? .info : .error
                )
            }

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                preservingRecoveredText: retainedText,
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )

            do {
                try modelContext.save()
                if retainedText != nil {
                    NotificationCenter.default.post(
                        name: .transcriptionCompleted,
                        object: transcription
                    )
                }
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            vippLog.info("pipeline: PRE-transcribe shouldCancel==true → finishCanceled (no network, no paste)")
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            var text: String
            vippLog.info("pipeline: transcribe START model=\(model.displayName, privacy: .public) session=\(session != nil ? "streaming" : "file", privacy: .public) \(jobIdentity.logDescription, privacy: .public)")
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(
                    audioURL: audioURL,
                    model: model,
                    context: transcriptionConfiguration.requestContext
                )
            }
            text = TranscriptionOutputFilter.filter(text)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            vippLog.info("pipeline: transcribe SUCCESS chars=\(text.count, privacy: .public) digest=\(TranscriptionLineageDigest.make(text), privacy: .public) elapsed=\(transcriptionDuration, format: .fixed(precision: 3), privacy: .public)s \(jobIdentity.logDescription, privacy: .public)")

            // ───────────────────────────────────────────────────────────────────────
            // FIX (2026-06-20, defensive guard for the same fork regression as the
            // RecorderUIManager re-entrancy fix): a cancel that raced in AFTER the
            // network round-trip already returned real text must NOT silently eat the
            // user's words. Previously ANY shouldCancel()==true here discarded a perfectly
            // good 200 transcription. Now we only treat a late cancel as "discard" when
            // the returned text is actually EMPTY; non-empty text is delivered. The
            // PRE-transcribe gate above still skips work before any network cost.
            // ───────────────────────────────────────────────────────────────────────
            if shouldCancel() {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vippLog.info("pipeline: POST-transcribe shouldCancel==true AND empty text → finishCanceled (no paste)")
                    await finishCanceledTranscription(); return
                } else {
                    vippLog.info("pipeline: POST-transcribe shouldCancel==true BUT text non-empty (chars=\(text.count, privacy: .public)) → retain to clipboard/history without delivery")
                    await finishCanceledTranscription(recoveredText: text)
                    return
                }
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // ── VIPP (skip-mode-processing feature) — trigger-word bypass ──
            // Trigger-word mode-selection can REWRITE the text (strip the trigger word) and
            // SWITCH the active mode as a side effect (selectTriggerWordModeIfNeeded). For a
            // one-shot RAW transcript the user explicitly wants NEITHER — no mode switching,
            // no text mutation. So skip it entirely when the bypass is on. (Codex review
            // finding #2: skip must also avoid the pre-delivery text/mode mutations.)
            if !assistant.isFollowUp,
               !skipPostProcessingNow,
               let processedText = triggerWordModeSelection(text) {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ??
                    resolvedEnhancementConfiguration?.mode ??
                    resolvedOutputConfiguration.mode ??
                    transcriptionConfiguration.mode
            )

            // ── VIPP (skip-mode-processing feature) — keep the transcript RAW ──
            // Paragraph formatting and word-replacement are part of the mode's
            // post-processing. The one-shot raw bypass should deliver the verbatim
            // transcription, so skip BOTH when it's engaged. (Codex review finding #2.)
            // The transcription record still stores exactly what we paste.
            if !skipPostProcessingNow, formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            if !skipPostProcessingNow {
                text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            }
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            finalText = cleanedText

            if !assistant.isFollowUp {
                // ── VIPP (skip-mode-processing feature) — BYPASS POINT #2 (script/respond) ──
                // When the one-shot flag is on, OVERRIDE whatever the mode resolved to with a
                // plain raw `.paste` — customCommand stripped AND autoSendKey forced to `.none`.
                // This is the deterministic guarantee: TranscriptionDelivery routes on
                // request.output.outputMode, so forcing `.paste` here means deliverCustomCommand
                // (the Mode's shell script) and deliverResponse (`.respond`) are NEVER reached;
                // and dropping autoSendKey means the mode's auto-send Enter does NOT fire either.
                // The skip toggle == "raw transcript, send nothing, do nothing else."
                // We do it HERE — at the single place that feeds `outputForDelivery` — rather
                // than depending only on the outputConfiguration closure's rewrite, so the
                // bypass cannot be silently lost on the way to delivery.
                let outputForThisDelivery: OutputRuntimeConfiguration
                if skipPostProcessingNow {
                    outputForThisDelivery = OutputRuntimeConfiguration(
                        mode: resolvedOutputConfiguration.mode,
                        outputMode: .paste,
                        autoSendKey: .none,
                        customCommand: nil
                    )
                    vippLog.info("pipeline: skip ON → output FORCED to raw .paste (was \(String(describing: resolvedOutputConfiguration.outputMode), privacy: .public))")
                } else {
                    outputForThisDelivery = resolvedOutputConfiguration
                }

                // Clipboard-only finalization must retain the actual transcript.
                // A `.respond` Mode normally turns enhancement into an assistant
                // response, so suppress that request here; returning before final
                // delivery alone would be too late because enhancement starts now.
                let suppressesModeResponse =
                    completionDispositionNow == .clipboardOnly &&
                    outputForThisDelivery.outputMode == .respond
                let shouldRespondInRecorder = !skipPostProcessingNow &&
                    !suppressesModeResponse &&
                    outputForThisDelivery.outputMode == .respond &&
                    resolvedEnhancementConfiguration?.isEnabled == true &&
                    resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = outputForThisDelivery
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipEnhancement = !shouldRespondInRecorder &&
                    isSkipShortEnhancementEnabled &&
                    WordCounter.count(in: text) <= shortEnhancementWordThreshold

                // ── VIPP (skip-mode-processing feature) — BYPASS POINT #1 (AI enhancement) ──
                // Explicit second gate: when skip is on, never enter the enhancement branch,
                // regardless of what the enhancementConfiguration closure returned. (The closure
                // already returns nil on skip, but gating here too makes the bypass independent
                // of that and keeps both bypass points readable in one place.)
                if !skipPostProcessingNow,
                   !suppressesModeResponse,
                   let enhancementService,
                   let resolvedEnhancementConfiguration,
                   resolvedEnhancementConfiguration.isEnabled,
                   enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                   !shouldSkipEnhancement {
                    if shouldCancel() { await finishCanceledTranscription(); return }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        let contextSnapshot = await recordingContextSnapshot()
                        let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                            textForAI,
                            configuration: resolvedEnhancementConfiguration,
                            contextSnapshot: contextSnapshot
                        )
                        transcription.enhancedText = enhancedText
                        transcription.aiEnhancementModelName = resolvedEnhancementConfiguration.modelName ?? resolvedEnhancementConfiguration.provider?.defaultModel
                        transcription.promptName = promptName
                        transcription.enhancementDuration = enhancementDuration
                        transcription.aiRequestSystemMessage = enhancementService.lastSystemMessageSent
                        transcription.aiRequestUserMessage = enhancementService.lastUserMessageSent
                        finalText = enhancedText
                    } catch {
                        let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        transcription.enhancedText = String(format: String(localized: "Enhancement failed: %@"), errorDescription)
                        responseError = errorDescription
                        let shortReason = String(errorDescription.prefix(80))
                        await MainActor.run {
                            NotificationManager.shared.showNotification(
                                title: String(format: String(localized: "Enhancement failed: %@"), shortReason),
                                type: .warning
                            )
                        }
                        if shouldCancel() { await finishCanceledTranscription(); return }
                    }
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // VIPPDebug: transcription threw. A URLError(.cancelled) here means the
            // upload/finalization Task was torn down (including Swift CancellationError
            // and URL cancellation); any other error is a genuine network/decode failure.
            // Intentional cancellation may still retain a prior HUD/final result below.
            let isCancelled = error is CancellationError ||
                (error as? URLError)?.code == .cancelled
            vippLog.error("pipeline: transcribe FAILED isCancelled=\(isCancelled, privacy: .public) error=\(errorDescription, privacy: .public) \(jobIdentity.logDescription, privacy: .public)")

            let failureRecovery = TranscriptionFailureRecoveryDisposition.resolve(
                cancellationRequested: shouldCancel(),
                textCandidates: [
                    transcription.recoverableRealtimeDraftText,
                    recoverablePartialTranscriptNow
                ]
            )
            // Unexpected failures used to live only in logs/history while the bar
            // vanished; surface the reason unless the user deliberately canceled.
            switch failureRecovery {
            case .intentionalCancellation:
                // The normal canceled-result path below retains any useful provider/HUD
                // result without surfacing a second provider error.
                break

            case .retainAudioOnly:
                // A provider/batch failure must not erase the original WAV. This is
                // recovery only: `.failed` jobs never paste or auto-send through
                // Primary or either Next route.
                transcription.preservesOriginalAudioForRecovery = true
                vippLog.info("pipeline: failed transcription retained original audio but no realtime draft was available")
                let shortReason = String(errorDescription.prefix(120))
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: String(
                            format: String(localized: "Transcription failed: %@"),
                            shortReason
                        ),
                        type: .error,
                        duration: 5.0
                    )
                }

            case .retainAudioAndText(let text):
                transcription.preservesOriginalAudioForRecovery = true
                transcription.snapshotRealtimeDraft(text)
                let copied = ClipboardManager.copyToClipboard(text)
                vippLog.info("pipeline: failed transcription retained realtime draft chars=\(text.count, privacy: .public) digest=\(TranscriptionLineageDigest.make(text), privacy: .public) clipboard=\(copied, privacy: .public) audio=true")
                let shortReason = String(errorDescription.prefix(120))
                let recoverySummary = copied
                    ? String(localized: "Partial text copied to clipboard; audio saved in History")
                    : String(localized: "Partial text and audio saved in History")
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        // Recovery must never hide the provider/network reason. The
                        // retained draft is useful context appended to the same failure.
                        title: "\(String(format: String(localized: "Transcription failed: %@"), shortReason)) — \(recoverySummary)",
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        // FINAL pre-delivery cancel gate. Same defensive logic as the post-transcribe
        // gate: only discard if there is NO usable text to deliver. If we have a real
        // finalText, deliver it even if a late cancel raced in — discarding a completed
        // 200 here is the exact "nothing pasted" symptom.
        if shouldCancel() {
            let hasText = !(finalText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if !hasText {
                vippLog.info("pipeline: PRE-delivery shouldCancel==true AND no text → finishCanceled (no paste)")
                await finishCanceledTranscription()
                return
            } else {
                vippLog.info("pipeline: PRE-delivery shouldCancel==true BUT finalText present → retain to clipboard/history without delivery")
                await finishCanceledTranscription(recoveredText: finalText)
                return
            }
        }

        // Unlike `shouldCancel`, this is not a user-intent heuristic. It proves that
        // this exact session/transcription/audio tuple still belongs to the current
        // queue generation. Reset invalidation or any identity mismatch preserves the
        // completed history record but forbids paste/command/response side effects.
        guard isDeliveryAuthorized() else {
            vippLog.notice("pipeline: DELIVERY REFUSED stale lineage finalChars=\(finalText?.count ?? -1, privacy: .public) finalDigest=\(TranscriptionLineageDigest.make(finalText ?? ""), privacy: .public) \(jobIdentity.logDescription, privacy: .public)")
            saveTranscriptionAndPostCompletion()
            return
        }

        // A genuine Primary triple-click is a completion gesture, not a fourth
        // paste destination. Finish the ordinary transcription/format/enhancement
        // work, then copy once and return before resolving any Accessibility target,
        // mode output action, custom command, paste, or Return key.
        if completionDispositionNow == .clipboardOnly {
            FocusLockService.shared.clearLock()
            SoundManager.shared.playStopSound()
            let clipboardText = finalText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue,
               !clipboardText.isEmpty {
                let copied = ClipboardManager.copyToClipboard(clipboardText)
                NotificationManager.shared.showNotification(
                    title: copied
                        ? String(localized: "Transcription copied to clipboard")
                        : String(localized: "Transcription completed, but couldn’t be copied to the clipboard"),
                    type: copied ? .info : .error
                )
                vippLog.info("pipeline: clipboard-only completion chars=\(clipboardText.count, privacy: .public) digest=\(TranscriptionLineageDigest.make(clipboardText), privacy: .public) clipboard=\(copied, privacy: .public) paste=false autoSend=false")
            } else {
                vippLog.info("pipeline: clipboard-only completion had no completed usable text to copy")
            }
            saveTranscriptionAndPostCompletion()
            return
        }

        let pasteTargetForDelivery = await resolvePasteTarget()
        // Re-resolve after the target is frozen so a second-chance Next-button press
        // that arrived during transcription/enhancement supplies the latest target's
        // complete Mode (output action, command, and Return), not just its input. The
        // one-shot raw path keeps the already-forced neutral output below.
        let pipelineOutput = skipPostProcessingNow
            ? (outputForDelivery ?? outputConfiguration())
            : outputConfiguration()
        let routeResolvedOutput: OutputRuntimeConfiguration
        if skipPostProcessingNow {
            // The one-shot raw/skip contract is stronger than any destination Mode:
            // it explicitly means paste only, with no Return or other action.
            routeResolvedOutput = pipelineOutput
        } else {
            // Only a physical Next-button route owns destination Mode/auto-send.
            // Primary is base VoiceInk: whichever input and Mode are current when the
            // result is delivered decide both paste and Return. Keeping this choice on
            // RecordingPasteTarget prevents Primary from inheriting exact-delivery
            // behavior while preserving the two latch routes' atomic destination Mode.
            routeResolvedOutput = OutputRuntimeConfiguration(
                mode: pipelineOutput.mode,
                outputMode: pipelineOutput.outputMode,
                autoSendKey: pasteTargetForDelivery.resolvedAutoSendKey(
                    currentInputKey: pipelineOutput.autoSendKey
                ),
                customCommand: pipelineOutput.customCommand
            )
        }

        let outputForPasteTarget = routeResolvedOutput
        let deliveryLeasePolicy: TranscriptionDeliveryLeasePolicy =
            pasteTargetForDelivery.destination == .primaryCurrentInput
                && outputForPasteTarget.outputMode == .paste
                && !skipPostProcessingNow
                && !assistant.isFollowUp
                ? .primaryPasteDuringCapture
                : .exclusive

        guard await acquireDeliveryLease(deliveryLeasePolicy) else {
            if shouldCancel() {
                vippLog.info("pipeline: delivery lease refused for cancellation → retain result without delivery")
                await finishCanceledTranscription(recoveredText: finalText)
            } else {
                vippLog.notice("pipeline: DELIVERY REFUSED stale lineage after recording barrier finalChars=\(finalText?.count ?? -1, privacy: .public) finalDigest=\(TranscriptionLineageDigest.make(finalText ?? ""), privacy: .public) \(jobIdentity.logDescription, privacy: .public)")
                saveTranscriptionAndPostCompletion()
            }
            return
        }
        defer { releaseDeliveryLease() }

        // The lease rechecks cancellation/reset before any paste/Return/command or
        // response. A Primary cohort paste may coexist with the current capture, but
        // its Return resolver still sees that capture owner at the final boundary.
        if shouldCancel() {
            vippLog.info("pipeline: delivery lease acquired but session was canceled → retain result without delivery")
            await finishCanceledTranscription(recoveredText: finalText)
            return
        }
        guard isDeliveryAuthorized() else {
            vippLog.notice("pipeline: DELIVERY REFUSED stale lineage after lease acquisition finalChars=\(finalText?.count ?? -1, privacy: .public) finalDigest=\(TranscriptionLineageDigest.make(finalText ?? ""), privacy: .public) \(jobIdentity.logDescription, privacy: .public)")
            saveTranscriptionAndPostCompletion()
            return
        }

        vippLog.info("pipeline: about to DELIVER finalChars=\(finalText?.count ?? -1, privacy: .public) finalDigest=\(TranscriptionLineageDigest.make(finalText ?? ""), privacy: .public) outputMode=\(String(describing: outputForPasteTarget.outputMode), privacy: .public) targetAutoSend=\(outputForPasteTarget.autoSendKey.rawValue, privacy: .public) queuedPrimaryDecision=deferredUntilReturnBoundary leasePolicy=\(String(describing: deliveryLeasePolicy), privacy: .public) destination=\(String(describing: pasteTargetForDelivery.destination), privacy: .public) skip=\(skipPostProcessingNow, privacy: .public) \(jobIdentity.logDescription, privacy: .public)")
        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForPasteTarget,
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp,
                pasteTarget: pasteTargetForDelivery, // Resolve at delivery, not pipeline start, so Next Track can change the pending session's destination while transcription or enhancement is still loading.
                resolveQueuedPrimaryAutoSend: { key in
                    resolveQueuedPrimaryAutoSend(
                        key,
                        outputForPasteTarget.outputMode,
                        pasteTargetForDelivery.destination
                    )
                },
                onQueuedPrimaryAutoSendIssued: onQueuedPrimaryAutoSendIssued,
                // VIPP (skip-mode-processing): pass the resolved one-shot flag so delivery
                // can make the raw-paste guarantee at the routing point itself (belt-and-
                // braces on top of the already-forced .paste output above).
                skipPostProcessing: skipPostProcessingNow
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )

        vippLog.info("pipeline: delivery RETURNED finalChars=\(finalText?.count ?? -1, privacy: .public) finalDigest=\(TranscriptionLineageDigest.make(finalText ?? ""), privacy: .public) \(jobIdentity.logDescription, privacy: .public)")

        saveTranscriptionAndPostCompletion()
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }
}
