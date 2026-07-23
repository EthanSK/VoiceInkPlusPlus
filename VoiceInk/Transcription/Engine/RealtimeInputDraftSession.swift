import Foundation
import os

/// The live-input writer is deliberately narrower than the normal destination engine.
/// It exists only while a proven realtime provider is producing cumulative hypotheses,
/// and it owns only the exact UTF-16 range that this recording inserted. It never saves
/// a Primary delivery destination, activates an app, rewrites an entire AXValue, or
/// changes either Next-button route.
enum RealtimeInputDraftFeature {
    static let userDefaultsKey = "VIPPRealtimeInputStreamingEnabled"

    @MainActor
    static func isEnabled(
        for configuration: TranscriptionRuntimeConfiguration,
        useCase: RecordingSession.UseCase
    ) -> Bool {
        guard UserDefaults.standard.bool(forKey: userDefaultsKey),
              !useCase.isAssistantFollowUp,
              configuration.isRealtimeEnabled,
              configuration.model.provider == .soniox else {
            return false
        }
        return true
    }
}

/// AX selected-text ranges use UTF-16 offsets. Keep the range and the exact text that
/// VoiceInk++ inserted together so a mutable realtime hypothesis can replace only its
/// own bytes. `originalText` is retained solely to restore a pre-existing selection
/// during a provably safe same-app migration or explicit cancellation.
struct RealtimeDraftTextRange: Equatable {
    let location: Int
    var insertedText: String
    let originalText: String

    var nsRange: NSRange {
        NSRange(location: location, length: insertedText.utf16.count)
    }

    func ownedSubstringMatches(in value: String) -> Bool {
        let value = value as NSString
        let range = nsRange
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= value.length else {
            return false
        }
        return value.substring(with: range) == insertedText
    }

    func replacingOwnedText(in value: String, with replacement: String) -> String? {
        guard ownedSubstringMatches(in: value) else { return nil }
        return (value as NSString).replacingCharacters(in: nsRange, with: replacement)
    }

    func replacingInsertedText(with replacement: String) -> RealtimeDraftTextRange {
        RealtimeDraftTextRange(
            location: location,
            insertedText: replacement,
            originalText: originalText
        )
    }
}

/// One exact input range owned by one recording. Multiple entries are intentional:
/// when Ethan changes focus during speech, the complete hypothesis is seeded into the
/// new input. A prior draft is removed only when the same foreground app exposes a
/// verifiable direct AXSelectedText path; otherwise it stays as crash-resilient text
/// rather than risking unrelated content through an app activation or whole-value set.
struct RealtimeInputDraftOwnership {
    let id: UUID
    let target: FocusLockService.Target
    var textRange: RealtimeDraftTextRange

    init(
        id: UUID = UUID(),
        target: FocusLockService.Target,
        textRange: RealtimeDraftTextRange
    ) {
        self.id = id
        self.target = target
        self.textRange = textRange
    }
}

enum RealtimeDraftMutationResult {
    case applied(RealtimeInputDraftOwnership)
    /// Every preflight failed before a text mutation. A fresh Primary target may still
    /// use base VoiceInk's ordinary Cmd-V without duplicating text in that input.
    case unavailableBeforeMutation
    /// The range no longer contains the exact text this recording inserted. Never paste
    /// over it, select it, or append a final transcript as a speculative fallback.
    case ownershipConflict
    /// AX reported an error or the post-state could not be proven after an irreversible
    /// setter/event. Preserve the final transcript on the clipboard and never retry.
    case indeterminateAfterMutation
}

enum PreparedRealtimeDraftReplacement {
    case applied(RealtimeInputDraftOwnership)
    /// The exact owned range is selected inside one already-prepared non-activating
    /// session. The caller may issue one bounded targeted-Unicode replacement and must
    /// verify the complete expected value before updating ownership.
    case selectedForTargetedUnicode(
        ownership: RealtimeInputDraftOwnership,
        expectedValue: String
    )
    case unavailableBeforeMutation
    case ownershipConflict
    case indeterminateAfterMutation
}

/// Per-recording coordinator for cumulative realtime hypotheses. The HUD continues to
/// display `RecordingSession.partialTranscript`; this object independently mirrors the
/// same text into the real input without allowing one recording to inherit another
/// recording's target, range, callback, or final transcript.
@MainActor
final class RealtimeInputDraftSession {
    enum PrimaryFinalizationResult {
        case notApplicable
        case reconciled(FocusLockService.Target)
        case unsafeToFallback
    }

    private let sessionID: UUID
    private let focusService: FocusLockService
    private let logger = Logger(
        subsystem: "com.ethansk.VoiceInkPlusPlus",
        category: "VIPPRealtimeInput"
    )
    private(set) var latestTranscript = ""
    private var ownerships: [RealtimeInputDraftOwnership] = []
    private var activeOwnershipID: UUID?
    private var updateTask: Task<Void, Never>?
    private var latestRevision = 0
    private var mayWriteCurrentMode = true
    private var acceptsLiveUpdates = true
    let isEnabled: Bool

    init(
        sessionID: UUID,
        isEnabled: Bool,
        focusService: FocusLockService = .shared
    ) {
        self.sessionID = sessionID
        self.isEnabled = isEnabled
        self.focusService = focusService
    }

    deinit {
        updateTask?.cancel()
    }

    /// Coalesce provider bursts to at most one AX mutation every 40 ms. This is a
    /// throttle, not a trailing-edge debounce: continuous Soniox hypotheses still
    /// advance visibly instead of being postponed until the speaker pauses.
    func receive(_ transcript: String, mayWriteCurrentMode: Bool) {
        latestTranscript = transcript
        self.mayWriteCurrentMode = mayWriteCurrentMode
        latestRevision += 1
        guard isEnabled, acceptsLiveUpdates else { return }
        scheduleUpdateIfNeeded()
    }

    /// The stop press is an explicit ordering boundary. Flush the newest hypothesis
    /// synchronously before the recorder callback is detached, then freeze partial
    /// updates. The final committed/processed text is reconciled later by delivery.
    func flushBeforeStop() {
        updateTask?.cancel()
        updateTask = nil
        guard isEnabled, acceptsLiveUpdates else {
            acceptsLiveUpdates = false
            return
        }
        applyLatestToCurrentInput()
        acceptsLiveUpdates = false
        logger.info(
            "realtime draft STOP flush session=\(self.sessionID.uuidString, privacy: .public) chars=\(self.latestTranscript.count, privacy: .public) ownedInputs=\(self.ownerships.count, privacy: .public)"
        )
    }

    /// A transcription-time Next press is the existing second-chance latch. Seed the
    /// complete realtime text into that exact currently focused input immediately; the
    /// later exact delivery will reconcile this owned range to the final processed text
    /// and submit once instead of appending a duplicate.
    func seedSecondChanceTarget(
        _ target: FocusLockService.Target,
        mayWriteTargetMode: Bool
    ) {
        guard isEnabled,
              mayWriteTargetMode,
              !latestTranscript.isEmpty else {
            return
        }
        apply(latestTranscript, to: target)
    }

    /// Primary remains current-input policy. This realtime-only preflight does not save
    /// a destination on `RecordingPasteTarget`: at delivery it captures whichever input
    /// owns the system caret now, reconciles/creates one owned range there, and returns
    /// that exact target only as a last-millisecond Return guard. If no live mutation was
    /// possible before any setter, the caller falls back to base VoiceInk Cmd-V.
    func finalizePrimary(with finalText: String) -> PrimaryFinalizationResult {
        updateTask?.cancel()
        updateTask = nil
        guard isEnabled,
              !finalText.isEmpty,
              let target = focusService.captureFocusedInput() else {
            return .notApplicable
        }

        let existing = ownership(matching: target)
        let result: RealtimeDraftMutationResult
        if let existing {
            result = focusService.replaceForegroundRealtimeDraft(
                finalText,
                ownership: existing
            )
        } else {
            result = focusService.insertForegroundRealtimeDraft(
                finalText,
                into: target
            )
        }

        switch result {
        case .applied(let ownership):
            store(ownership, makeActive: true)
            logger.info(
                "realtime draft PRIMARY finalized session=\(self.sessionID.uuidString, privacy: .public) chars=\(finalText.count, privacy: .public) targetPid=\(target.processIdentifier, privacy: .public) reusedOwnedRange=\(existing != nil, privacy: .public)"
            )
            return .reconciled(target)
        case .unavailableBeforeMutation:
            // Base Cmd-V is safe only when this current input had no existing owned
            // draft. If it did, appending the full final transcript would duplicate it.
            return existing == nil ? .notApplicable : .unsafeToFallback
        case .ownershipConflict, .indeterminateAfterMutation:
            return .unsafeToFallback
        }
    }

    func ownership(
        matching target: FocusLockService.Target
    ) -> RealtimeInputDraftOwnership? {
        ownerships.first {
            focusService.targetsReferToSameExactInput($0.target, target)
        }
    }

    func storeReconciledOwnership(_ ownership: RealtimeInputDraftOwnership) {
        store(ownership, makeActive: true)
    }

    /// Explicit Cancel retains crash resilience but still honors intentional discard
    /// where it is safe: restore only the draft that currently owns real keyboard focus.
    /// Background/app-switch cleanup remains fail-closed and never activates anything.
    func discardCurrentDraftForExplicitCancel() {
        updateTask?.cancel()
        updateTask = nil
        acceptsLiveUpdates = false
        guard let active = activeOwnership,
              focusService.targetOwnsSystemKeyboardFocus(active.target) else {
            return
        }
        switch focusService.restoreForegroundRealtimeDraft(active) {
        case .applied:
            ownerships.removeAll { $0.id == active.id }
            activeOwnershipID = nil
        case .unavailableBeforeMutation, .ownershipConflict, .indeterminateAfterMutation:
            break
        }
    }

    func finish() {
        updateTask?.cancel()
        updateTask = nil
        acceptsLiveUpdates = false
    }

    private var activeOwnership: RealtimeInputDraftOwnership? {
        guard let activeOwnershipID else { return nil }
        return ownerships.first { $0.id == activeOwnershipID }
    }

    private func scheduleUpdateIfNeeded() {
        guard updateTask == nil else { return }
        let scheduledRevision = latestRevision
        updateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, !Task.isCancelled else { return }
            self.updateTask = nil
            self.applyLatestToCurrentInput()
            if self.acceptsLiveUpdates,
               self.latestRevision > scheduledRevision {
                self.scheduleUpdateIfNeeded()
            }
        }
    }

    private func applyLatestToCurrentInput() {
        guard mayWriteCurrentMode,
              !latestTranscript.isEmpty else {
            return
        }

        if let active = activeOwnership,
           focusService.targetOwnsSystemKeyboardFocus(active.target) {
            apply(latestTranscript, toExisting: active)
            return
        }

        guard let target = focusService.captureFocusedInput() else {
            logger.notice(
                "realtime draft skipped because no editable system-focused input is available session=\(self.sessionID.uuidString, privacy: .public) chars=\(self.latestTranscript.count, privacy: .public)"
            )
            return
        }
        apply(latestTranscript, to: target)
    }

    private func apply(_ transcript: String, to target: FocusLockService.Target) {
        if let existing = ownership(matching: target) {
            apply(transcript, toExisting: existing)
            return
        }

        let previousActive = activeOwnership
        switch focusService.insertForegroundRealtimeDraft(transcript, into: target) {
        case .applied(let ownership):
            store(ownership, makeActive: true)
            logger.info(
                "realtime draft migrated session=\(self.sessionID.uuidString, privacy: .public) chars=\(transcript.count, privacy: .public) targetPid=\(target.processIdentifier, privacy: .public) ownedInputs=\(self.ownerships.count, privacy: .public)"
            )
            if let previousActive,
               previousActive.target.processIdentifier == target.processIdentifier,
               !focusService.targetsReferToSameExactInput(
                    previousActive.target,
                    target
               ) {
                scheduleSafeSameAppCleanup(of: previousActive)
            }
        case .unavailableBeforeMutation:
            logger.notice(
                "realtime draft target does not expose a safe selected-text mutation session=\(self.sessionID.uuidString, privacy: .public) targetPid=\(target.processIdentifier, privacy: .public)"
            )
        case .ownershipConflict:
            logger.error(
                "realtime draft fresh insertion unexpectedly conflicted before mutation session=\(self.sessionID.uuidString, privacy: .public) targetPid=\(target.processIdentifier, privacy: .public)"
            )
        case .indeterminateAfterMutation:
            logger.error(
                "realtime draft fresh insertion became indeterminate after one setter session=\(self.sessionID.uuidString, privacy: .public) targetPid=\(target.processIdentifier, privacy: .public)"
            )
        }
    }

    private func apply(
        _ transcript: String,
        toExisting ownership: RealtimeInputDraftOwnership
    ) {
        switch focusService.replaceForegroundRealtimeDraft(
            transcript,
            ownership: ownership
        ) {
        case .applied(let updated):
            store(updated, makeActive: true)
        case .unavailableBeforeMutation, .ownershipConflict:
            logger.error(
                "realtime draft ownership no longer matches; update refused session=\(self.sessionID.uuidString, privacy: .public) targetPid=\(ownership.target.processIdentifier, privacy: .public) priorChars=\(ownership.textRange.insertedText.count, privacy: .public) nextChars=\(transcript.count, privacy: .public)"
            )
        case .indeterminateAfterMutation:
            logger.error(
                "realtime draft update post-state is indeterminate; no retry session=\(self.sessionID.uuidString, privacy: .public) targetPid=\(ownership.target.processIdentifier, privacy: .public)"
            )
        }
    }

    private func store(
        _ ownership: RealtimeInputDraftOwnership,
        makeActive: Bool
    ) {
        if let index = ownerships.firstIndex(where: { $0.id == ownership.id }) {
            ownerships[index] = ownership
        } else if let index = ownerships.firstIndex(where: {
            focusService.targetsReferToSameExactInput($0.target, ownership.target)
        }) {
            ownerships[index] = ownership
        } else {
            ownerships.append(ownership)
        }
        if makeActive {
            activeOwnershipID = ownership.id
        }
    }

    private func scheduleSafeSameAppCleanup(
        of ownership: RealtimeInputDraftOwnership
    ) {
        Task { [weak self] in
            guard let self,
                  self.ownerships.contains(where: { $0.id == ownership.id }),
                  let deliverySession = await self.focusService
                    .prepareBackgroundDelivery(to: ownership.target) else {
                return
            }
            defer {
                self.focusService.finishBackgroundDelivery(deliverySession)
            }
            guard deliverySession.allowsDirectRealtimeDraftMutation else {
                return
            }
            switch self.focusService.restorePreparedRealtimeDraft(
                ownership,
                for: deliverySession
            ) {
            case .applied:
                self.ownerships.removeAll { $0.id == ownership.id }
                self.logger.info(
                    "realtime draft removed provable prior same-app range session=\(self.sessionID.uuidString, privacy: .public) targetPid=\(ownership.target.processIdentifier, privacy: .public)"
                )
            case .unavailableBeforeMutation, .ownershipConflict, .indeterminateAfterMutation:
                // Leaving a stale draft is explicitly safer than guessing at another
                // input's content or app-internal focus.
                break
            }
        }
    }
}
