//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import ApplicationServices
@testable import VoiceInkPlusPlus

struct VoiceInkTests {

    @Test func recorderVersionSplitsMarketingAndBuildAcrossTwoRows() {
        let presentation = RecorderVersionPresentation(
            marketingVersion: "2.0",
            buildNumber: "211"
        )

        #expect(presentation.topLine == "v2.0")
        #expect(presentation.bottomLine == ".211")
        #expect(presentation.accessibilityLabel == "VoiceInk++ version 2.0, build 211")
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

    @MainActor
    @Test func chatComposerSubmissionRequiresAReadableClearOrReset() {
        let previous = "This is a test"

        #expect(TranscriptionDelivery.classifyChatComposerSubmission(
            from: previous,
            to: ""
        ) == .verified)
        #expect(TranscriptionDelivery.classifyChatComposerSubmission(
            from: previous,
            to: " \n\t"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyChatComposerSubmission(
            from: previous,
            to: previous
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyChatComposerSubmission(
            from: previous,
            to: previous + "\n"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyChatComposerSubmission(
            from: previous,
            to: "edited but still present"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyChatComposerSubmission(
            from: previous,
            to: nil
        ) == .unavailable)

    }

    @MainActor
    @Test func backgroundDeliveryAllowsUnrelatedForegroundChangesOnly() {
        #expect(FocusLockService.backgroundTargetRemainsNonFrontmost(
            currentFrontmostPID: 101,
            targetPID: 202
        ))
        #expect(!FocusLockService.backgroundTargetRemainsNonFrontmost(
            currentFrontmostPID: 202,
            targetPID: 202
        ))
        #expect(!FocusLockService.backgroundTargetRemainsNonFrontmost(
            currentFrontmostPID: nil,
            targetPID: 202
        ))
    }

    @MainActor
    @Test func backgroundFocusModeSeparatesPreparedFloatingAndDirectRoutes() {
        #expect(FocusLockService.backgroundFocusMode(
            keyboardFocusMatchesTarget: true,
            keyboardFocusOwnedByTarget: true,
            targetIsFrontmost: false
        ) == .alreadyKeyboardFocused)
        #expect(FocusLockService.backgroundFocusMode(
            keyboardFocusMatchesTarget: false,
            keyboardFocusOwnedByTarget: true,
            targetIsFrontmost: true
        ) == .directExactElement)
        #expect(FocusLockService.backgroundFocusMode(
            keyboardFocusMatchesTarget: false,
            keyboardFocusOwnedByTarget: false,
            targetIsFrontmost: true
        ) == .directExactElement)
        #expect(FocusLockService.backgroundFocusMode(
            keyboardFocusMatchesTarget: false,
            keyboardFocusOwnedByTarget: false,
            targetIsFrontmost: false
        ) == .preparedTargetedInput)
    }

    @MainActor
    @Test func telegramRetainedComposerRequiresReadableMatchingChatAndExactInternalFocus() {
        let capturedPrimary = ["Saved Messages"]
        let capturedSecondary = [
            "Earlier disposable verification message",
            "Another stable chat-context anchor",
            "Fourth readable context anchor"
        ]

        #expect(FocusLockService.telegramRetainedInputAllowed(
            capturedPrimaryContextAnchors: capturedPrimary,
            capturedContextAnchors: capturedSecondary,
            currentPrimaryContextAnchors: capturedPrimary,
            currentContextAnchors: capturedSecondary + ["newer message"],
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedPrimaryContextAnchors: capturedPrimary,
            capturedContextAnchors: capturedSecondary,
            currentPrimaryContextAnchors: [],
            currentContextAnchors: [],
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedPrimaryContextAnchors: capturedPrimary,
            capturedContextAnchors: capturedSecondary,
            currentPrimaryContextAnchors: ["Different chat"],
            currentContextAnchors: ["Different chat", "Unrelated conversation"],
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedPrimaryContextAnchors: capturedPrimary,
            capturedContextAnchors: capturedSecondary,
            currentPrimaryContextAnchors: capturedPrimary,
            currentContextAnchors: capturedSecondary,
            internalFocusMatches: false,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedPrimaryContextAnchors: capturedPrimary,
            capturedContextAnchors: capturedSecondary,
            currentPrimaryContextAnchors: capturedPrimary,
            currentContextAnchors: capturedSecondary,
            internalFocusMatches: true,
            structureMatches: false
        ))
    }

    @MainActor
    @Test func telegramShortChatTitleIdentifiesEmptySavedMessagesAndRejectsWrongChat() {
        #expect(FocusLockService.contextAnchorIsEligible(
            "Saved Messages",
            role: "AXStaticText",
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.contextAnchorIsEligible(
            "Saved Messages",
            role: "AXTextField",
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.contextAnchorIsEligible(
            "Saved Messages",
            role: "AXStaticText",
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(!FocusLockService.contextAnchorIsEligible(
            "online",
            role: "AXStaticText",
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.contextAnchorIsEligible(
            "last seen a few minutes ago",
            role: "AXStaticText",
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.contextAnchorIsEligible(
            "248 members",
            role: "AXStaticText",
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.contextAnchorIsEligible(
            "12:48",
            role: "AXStaticText",
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))

        #expect(FocusLockService.telegramContextFingerprintMatches(
            capturedPrimary: ["Saved Messages"],
            capturedSecondary: [],
            currentPrimary: ["Saved Messages"],
            currentSecondary: []
        ))
        #expect(!FocusLockService.telegramContextFingerprintMatches(
            capturedPrimary: ["Saved Messages"],
            capturedSecondary: [],
            currentPrimary: ["Work chat"],
            currentSecondary: []
        ))
        #expect(!FocusLockService.telegramContextFingerprintMatches(
            capturedPrimary: ["Saved Messages"],
            capturedSecondary: ["Earlier disposable verification message"],
            currentPrimary: ["Different chat"],
            currentSecondary: [
                "Saved Messages",
                "Earlier disposable verification message"
            ]
        ))
        #expect(!FocusLockService.telegramContextFingerprintMatches(
            capturedPrimary: ["Engineering Project Chat"],
            capturedSecondary: [
                "First overlapping generic context anchor",
                "Second overlapping generic context anchor",
                "Third overlapping generic context anchor"
            ],
            currentPrimary: ["Different Project Chat"],
            currentSecondary: [
                "First overlapping generic context anchor",
                "Second overlapping generic context anchor",
                "Third overlapping generic context anchor"
            ]
        ))

        let selection = FocusLockService.selectContextAnchors(
            [
                FocusLockService.ContextAnchorCandidate(
                    value: "Saved Messages",
                    isPrimary: false
                )
            ] + (0..<20).map {
                FocusLockService.ContextAnchorCandidate(
                    value: "Long populated message history anchor number \($0)",
                    isPrimary: false
                )
            } + [
                FocusLockService.ContextAnchorCandidate(
                    value: "Saved Messages",
                    isPrimary: true
                )
            ],
            limit: 16
        )
        #expect(selection.primary == ["Saved Messages"])
        #expect(selection.secondary.count == 15)
        #expect(!selection.secondary.contains("Saved Messages"))
    }

    @MainActor
    @Test func telegramPrefersExactAccessibilityInsertionAndUsesChatVerification() {
        #expect(FocusLockService.prefersAccessibilityTextInsertion(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.prefersAccessibilityTextInsertion(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "com.anthropic.claudefordesktop"
        ))
        #expect(FocusLockService.supportsSemanticSend(
            bundleIdentifier: "com.anthropic.claudefordesktop"
        ))
        #expect(!TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "com.apple.TextEdit"
        ))

        #expect(TranscriptionDelivery.shouldUseTargetedUnicodeFallback(
            after: .unavailable,
            requiresDirectAccessibilityInsertion: false
        ))
        #expect(!TranscriptionDelivery.shouldUseTargetedUnicodeFallback(
            after: .focusSafetyViolation,
            requiresDirectAccessibilityInsertion: false
        ))
        #expect(!TranscriptionDelivery.shouldUseTargetedUnicodeFallback(
            after: .failed(AXError.cannotComplete.rawValue),
            requiresDirectAccessibilityInsertion: false
        ))
        #expect(!TranscriptionDelivery.shouldUseTargetedUnicodeFallback(
            after: .acceptedSelectedText,
            requiresDirectAccessibilityInsertion: false
        ))
        #expect(!TranscriptionDelivery.shouldUseTargetedUnicodeFallback(
            after: .unavailable,
            requiresDirectAccessibilityInsertion: true
        ))
    }

    @MainActor
    @Test func foregroundChatSubmitWaitsOnlyUntilTheExactPasteAppears() {
        #expect(TranscriptionDelivery.foregroundChatPasteIsReady(
            insertedText: "This is a test ",
            previousText: "draft",
            currentText: "draftThis is a test "
        ))
        #expect(!TranscriptionDelivery.foregroundChatPasteIsReady(
            insertedText: "This is a test",
            previousText: "draft",
            currentText: "draft"
        ))
        #expect(!TranscriptionDelivery.foregroundChatPasteIsReady(
            insertedText: "This is a test",
            previousText: "draft",
            currentText: nil
        ))

        #expect(TranscriptionDelivery.foregroundPastePreflightMatches(
            targetPID: 100,
            frontmostPID: 100,
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.foregroundPastePreflightMatches(
            targetPID: 100,
            frontmostPID: 200,
            hasExactInput: false,
            exactInputOwnsKeyboardFocus: false
        ))
        #expect(!TranscriptionDelivery.foregroundPastePreflightMatches(
            targetPID: 100,
            frontmostPID: 100,
            hasExactInput: true,
            exactInputOwnsKeyboardFocus: false
        ))
    }

    @MainActor
    @Test func foregroundChatSemanticFallbackIsOneShotAndExactFocusGated() {
        #expect(TranscriptionDelivery.foregroundSemanticActionPlan(
            result: .pressed,
            exactInputOwnsKeyboardFocus: false
        ) == .verifyOnly)
        #expect(TranscriptionDelivery.foregroundSemanticActionPlan(
            result: .failed(AXError.cannotComplete.rawValue),
            exactInputOwnsKeyboardFocus: true
        ) == .verifyOnly)
        #expect(TranscriptionDelivery.foregroundSemanticActionPlan(
            result: .unavailable,
            exactInputOwnsKeyboardFocus: true
        ) == .issueExactFocusReturn)
        #expect(TranscriptionDelivery.foregroundSemanticActionPlan(
            result: .unavailable,
            exactInputOwnsKeyboardFocus: false
        ) == .focusMoved)

        #expect(TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.openai.codex",
            semanticResult: .pressed,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.openai.codex",
            semanticResult: .failed(AXError.cannotComplete.rawValue),
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.anthropic.claudefordesktop",
            semanticResult: .pressed,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.openai.codex",
            semanticResult: .pressed,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: false
        ))
    }

    @MainActor
    @Test func telegramUnicodeFallbackChecksFullChatBeforeEveryChunk() async {
        var accessibilityAttempts = 0
        var fullBoundaryChecks = 0
        var postedChunks = 0

        let result = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                requiresDirectAccessibilityInsertion: false,
                attemptAccessibility: {
                    accessibilityAttempts += 1
                    return .unavailable
                },
                fullBoundaryMatches: {
                    fullBoundaryChecks += 1
                    // Initial fallback gate and chunk zero are safe. The chat then
                    // changes before chunk two, which must never be posted.
                    return fullBoundaryChecks <= 2
                },
                targetedUnicode: { beforeChunk in
                    await CursorPaster.runTargetedUnicodeChunks(
                        Array(repeating: UInt16(65), count: 60),
                        beforeChunk: beforeChunk
                    ) { _ in
                        postedChunks += 1
                        return true
                    }
                }
            )

        #expect(!result)
        #expect(accessibilityAttempts == 1)
        #expect(fullBoundaryChecks == 3)
        #expect(postedChunks == 1)
    }

    @MainActor
    @Test func telegramInsertionFallbackIsOneShotAndSetterErrorsNeverRetry() async {
        var directUnicodeCalls = 0
        let directResult = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                requiresDirectAccessibilityInsertion: true,
                attemptAccessibility: { .unavailable },
                fullBoundaryMatches: { true },
                targetedUnicode: { _ in
                    directUnicodeCalls += 1
                    return true
                }
            )
        #expect(!directResult)
        #expect(directUnicodeCalls == 0)

        var accessibilityAttempts = 0
        var unicodeCallsAfterSetterError = 0
        var observedError: Int32?
        let setterErrorResult = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                requiresDirectAccessibilityInsertion: false,
                attemptAccessibility: {
                    accessibilityAttempts += 1
                    return .failed(AXError.cannotComplete.rawValue)
                },
                fullBoundaryMatches: { true },
                onAccessibilityError: { observedError = $0 },
                targetedUnicode: { _ in
                    unicodeCallsAfterSetterError += 1
                    return true
                }
            )
        #expect(setterErrorResult)
        #expect(accessibilityAttempts == 1)
        #expect(unicodeCallsAfterSetterError == 0)
        #expect(observedError == AXError.cannotComplete.rawValue)
    }

    @MainActor
    @Test func semanticSendLabelsAcceptSendAndRejectStopOrUnlabelledControls() {
        for label in ["Send", "Send message", "Send follow-up", "Submit", "send-button", "sendbutton"] {
            #expect(FocusLockService.isProvenSemanticSendLabel(label))
        }
        for label in [nil, "", "Stop", "Cancel", "Pause", "Voice message"] as [String?] {
            #expect(!FocusLockService.isProvenSemanticSendLabel(label))
        }
    }

    @MainActor
    @Test func semanticSendGatePerformsNoActionForAmbiguousOrWrongTarget() {
        var actionCount = 0
        let action = { () -> Int32 in
            actionCount += 1
            return AXError.success.rawValue
        }

        let ambiguous = FocusLockService.performProvenSemanticSend(
            isUnambiguous: false,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: "Send",
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        let wrongPID = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: false,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: "Send",
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        let wrongWindow = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: false,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: "Send",
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        #expect(ambiguous == .unavailable)
        #expect(wrongPID == .unavailable)
        #expect(wrongWindow == .unavailable)
        #expect(actionCount == 0)

        let valid = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: "Send",
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        #expect(valid == .pressed)
        #expect(actionCount == 1)
    }

    @MainActor
    @Test func postSubmitReplacementRequiresExactIdentityFocusAndGeometry() {
        let expected = CGRect(x: 100, y: 200, width: 500, height: 80)
        let nearby = CGRect(x: 104, y: 202, width: 500, height: 80)

        #expect(FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: false,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: false,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: false,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: false,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: CGRect(x: 180, y: 200, width: 500, height: 80)
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: false,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: false,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: false,
            expectedFrame: expected,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: nil,
            currentFrame: nearby
        ))
        #expect(!FocusLockService.postSubmissionReplacementAllowed(
            sameProcess: true,
            sameWindow: true,
            internallyFocused: true,
            roleMatches: true,
            subroleMatches: true,
            stableIdentifierMatches: true,
            domIdentifierMatches: true,
            expectedFrame: expected,
            currentFrame: nil
        ))
    }

}
