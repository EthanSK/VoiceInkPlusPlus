//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import CoreGraphics
import Foundation
@testable import VoiceInkPlusPlus

struct VoiceInkTests {

    @Test func recorderVersionSplitsMarketingAndBuildAcrossTwoRows() {
        let presentation = RecorderVersionPresentation(
            marketingVersion: "2.0",
            buildNumber: "225"
        )

        #expect(presentation.topLine == "v2.0")
        #expect(presentation.bottomLine == ".225")
        #expect(presentation.accessibilityLabel == "VoiceInk++ version 2.0, build 225")
    }

    @MainActor
    @Test func backgroundAutoSendSeparatesUnreadableFromReadableNoOp() {
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: nil
        ) == .unreadable)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript"
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: ""
        ) == .verifiedCleared)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript\n"
        ) == .modifiedWithoutSubmit)

        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .unreadable
        ) == .none)
        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .verifiedCleared
        ) == .none)
        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .unchanged
        ) == .unchangedComposerError)
        #expect(TranscriptionDelivery.backgroundAutoSendUserFeedback(
            verification: .modifiedWithoutSubmit
        ) == .modifiedWithoutSubmitError)

        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .verifiedCleared
        ) == .verified)
        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .unreadable
        ) == .indeterminate)
        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .unchanged
        ) == .failed)
        #expect(TranscriptionDelivery.autoSendOutcome(
            verification: .modifiedWithoutSubmit
        ) == .failed)
    }

    @MainActor
    @Test func unlabelledCodexSendExceptionIsPinnedToTheAuditedBuildTuple() {
        #expect(FocusLockService.isAuditedCodexSubmitBuild(
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72221",
            build: "5307",
            chromium: "150.0.7871.115"
        ))
        #expect(!FocusLockService.isAuditedCodexSubmitBuild(
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72222",
            build: "5308",
            chromium: "150.0.7871.115"
        ))
        #expect(!FocusLockService.isAuditedCodexSubmitBuild(
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72221",
            build: "5307",
            chromium: nil
        ))
        #expect(!FocusLockService.isAuditedCodexSubmitBuild(
            bundleIdentifier: "com.openai.chat",
            shortVersion: "26.707.72221",
            build: "5307",
            chromium: "150.0.7871.115"
        ))
    }

    @MainActor
    @Test func semanticSendFinalGateRejectsStopAndUnauditedUnlabelledButtons() {
        var actionCount = 0
        func attempt(
            label: String?,
            allowsAuditedUnlabelledSend: Bool,
            labelWasReadable: Bool = true
        ) -> FocusLockService.NearbySubmitButtonResult {
            FocusLockService.performProvenSemanticSend(
                isUnambiguous: true,
                pidMatches: true,
                windowMatches: true,
                geometryMatches: true,
                roleMatches: true,
                enabled: true,
                label: label,
                labelWasReadable: labelWasReadable,
                allowsAuditedUnlabelledSend: allowsAuditedUnlabelledSend,
                hasPressAction: true,
                boundaryMatches: true,
                action: {
                    actionCount += 1
                    return 0
                }
            )
        }

        #expect(attempt(label: "Stop", allowsAuditedUnlabelledSend: true) == .unavailable)
        #expect(attempt(label: nil, allowsAuditedUnlabelledSend: false) == .unavailable)
        #expect(attempt(
            label: nil,
            allowsAuditedUnlabelledSend: true,
            labelWasReadable: false
        ) == .unavailable)
        #expect(actionCount == 0)
        #expect(attempt(label: "Send", allowsAuditedUnlabelledSend: false) == .pressed)
        #expect(actionCount == 1)
        #expect(attempt(label: nil, allowsAuditedUnlabelledSend: true) == .pressed)
        #expect(actionCount == 2)
    }

    @MainActor
    @Test func CodexTraversalFallsBackToNavigationOrderOnlyWhenNeeded() {
        #expect(FocusLockService.preferredTraversalChildren(
            visible: [1],
            ordinary: [2],
            navigationOrder: [3]
        ) == [1])
        #expect(FocusLockService.preferredTraversalChildren(
            visible: [],
            ordinary: [2],
            navigationOrder: [3]
        ) == [2])
        #expect(FocusLockService.preferredTraversalChildren(
            visible: [],
            ordinary: [],
            navigationOrder: [3]
        ) == [3])
    }

    @MainActor
    @Test func semanticSendGeometryRejectsRemoteButtons() {
        let editor = CGRect(x: 100, y: 100, width: 600, height: 100)
        #expect(FocusLockService.semanticSendGeometryMatches(
            editorFrame: editor,
            candidateFrame: CGRect(x: 650, y: 150, width: 32, height: 32)
        ))
        #expect(!FocusLockService.semanticSendGeometryMatches(
            editorFrame: editor,
            candidateFrame: CGRect(x: 1_500, y: 900, width: 32, height: 32)
        ))
    }

    @MainActor
    @Test func deferredForegroundAutoSendNeverReactivatesAnExactInput() {
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: true,
            targetIsFrontmost: true
        ) == .foregroundExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: false
        ) == .nonActivatingExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: true
        ) == .nonActivatingExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: true,
            targetIsFrontmost: false
        ) == .foregroundExactInput)
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: false,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: false
        ) == .failClosed)
    }

    @Test func foregroundDeliveryRemainsAwaitedInsideSerializedPipeline() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let pasteStart = try #require(source.range(of: "    private func paste("))
        let backgroundStart = try #require(source.range(
            of: "    private func deliverToBackgroundExactInput(",
            range: pasteStart.upperBound..<source.endIndex
        ))
        let pasteBody = source[pasteStart.lowerBound..<backgroundStart.lowerBound]

        #expect(pasteBody.contains("let pasteResult = await pasteTask.value"))
        #expect(pasteBody.contains("defer { FocusLockService.shared.clearLock() }"))
        #expect(!pasteBody.contains("Task { @MainActor in"))
    }

    @Test func foregroundSemanticSendFocusLossReroutesWithoutReturn() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let focusLossCase = try #require(source.range(
            of: "        case .focusLostBeforeAction:"
        ))
        let semanticChangeCase = try #require(source.range(
            of: "        case .refusedAfterCandidate:",
            range: focusLossCase.upperBound..<source.endIndex
        ))
        let focusLossBody = source[focusLossCase.lowerBound..<semanticChangeCase.lowerBound]

        #expect(focusLossBody.contains("return .needsNonActivatingExactInput"))
        #expect(!focusLossBody.contains("CursorPaster.performAutoSend"))
    }

    @MainActor
    @Test func secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt() {
        let session = RecordingSession()
        let destinationMode = ModeConfig(
            name: "Codex destination",
            isAIEnhancementEnabled: true,
            isTextFormattingEnabled: true,
            outputMode: .paste,
            autoSendKey: .enter
        )
        let retargeted = RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: destinationMode
        )

        #expect(session.retargetPaste(to: retargeted))
        let acceptedPulse = session.iconActionPulse
        #expect(acceptedPulse?.icon == .lockedDestination)
        #expect(session.lockedDestinationIconActionPulseID == acceptedPulse?.id)
        #expect(session.currentFocusIconActionPulseID == nil)
        let resolvedTarget = session.resolvePasteTargetForDelivery()
        #expect(resolvedTarget.destination == .focusedDuringTranscription)
        #expect(resolvedTarget.autoSendKey == .enter)
        #expect(resolvedTarget.mode == destinationMode)
        #expect(resolvedTarget.mode?.isAIEnhancementEnabled == true)
        #expect(resolvedTarget.mode?.isTextFormattingEnabled == true)
        #expect(!session.retargetPaste(to: RecordingPasteTarget(destination: .recordingStart, focusedInput: nil)))
        #expect(session.pasteTarget.destination == .focusedDuringTranscription)
        #expect(session.iconActionPulse == acceptedPulse)
    }

    @MainActor
    @Test func recorderIconPulseMapsPrimaryAndNextRoutesToSeparateIcons() {
        let session = RecordingSession()

        session.signalDestinationAction(.focusedAtStop)
        let primaryPulse = session.iconActionPulse
        #expect(primaryPulse?.icon == .currentFocus)
        #expect(session.currentFocusIconActionPulseID == primaryPulse?.id)
        #expect(session.lockedDestinationIconActionPulseID == nil)

        session.signalDestinationAction(.recordingStart)
        let nextPulse = session.iconActionPulse
        #expect(nextPulse?.icon == .lockedDestination)
        #expect(nextPulse?.id != primaryPulse?.id)
        #expect(session.currentFocusIconActionPulseID == nil)
        #expect(session.lockedDestinationIconActionPulseID == nextPulse?.id)
    }

    @MainActor
    @Test func neutralPasteTargetModeDoesNotFallBackToCurrentMode() {
        let formatting = ModeRuntimeResolver.pasteTargetTranscriptionFormattingConfiguration(
            mode: nil
        )
        let output = ModeRuntimeResolver.pasteTargetOutputConfiguration(mode: nil)

        #expect(formatting.mode == nil)
        #expect(output.mode == nil)
        #expect(output.outputMode == .paste)
        #expect(output.autoSendKey == .none)
        #expect(output.customCommand == nil)
    }

    @MainActor
    @Test func explicitTriggerWordModeOverridesDestinationWithoutReadingGlobalMode() {
        let session = RecordingSession()
        let destinationMode = ModeConfig(
            name: "Destination",
            isAIEnhancementEnabled: false,
            autoSendKey: .enter
        )
        let triggerMode = ModeConfig(
            name: "Explicit trigger",
            isAIEnhancementEnabled: true,
            outputMode: .respond
        )

        #expect(session.retargetPaste(to: RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: destinationMode
        )))
        session.applyTriggerWordModeOverride(triggerMode)

        #expect(session.postProcessingMode == triggerMode)
        #expect(session.pasteTarget.autoSendKey == .enter)
    }

    @MainActor
    @Test func exactInputContextFingerprintFailsClosedAcrossDifferentDocuments() {
        let captured = ["unique original task prompt", "stable original response"]

        #expect(FocusLockService.contextFingerprintMatches(
            captured: captured,
            current: ["stable original response", "unique original task prompt", "new reply"]
        ))
        #expect(!FocusLockService.contextFingerprintMatches(
            captured: captured,
            current: ["unique original task prompt", "different task response"]
        ))
        #expect(!FocusLockService.contextFingerprintMatches(
            captured: captured,
            current: []
        ))
    }

}
