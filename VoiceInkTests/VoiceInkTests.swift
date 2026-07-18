//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import ApplicationServices
import AppKit
@testable import VoiceInkPlusPlus

struct VoiceInkTests {

    @MainActor
    @Test func exactInputDeliveryFlagDefaultsToLegacyAndRemainsSwitchable() {
        let suiteName = "VoiceInkDeliveryFeatureFlagsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!VoiceInkDeliveryFeatureFlags
            .exactInputDeliveryEnabled(defaults: defaults))
        #expect(TranscriptionDelivery.pasteDeliveryStrategy(
            exactInputDeliveryEnabled: false
        ) == .legacyCurrentKeyboardInput)
        #expect(!VoiceInkDeliveryFeatureFlags
            .shouldShowLockedDestinationIndicator(
                recordingState: .recording,
                isExactInputDeliveryEnabled: false
            ))

        defaults.set(
            true,
            forKey: VoiceInkDeliveryFeatureFlags.exactInputDeliveryDefaultsKey
        )
        #expect(VoiceInkDeliveryFeatureFlags
            .exactInputDeliveryEnabled(defaults: defaults))
        #expect(TranscriptionDelivery.pasteDeliveryStrategy(
            exactInputDeliveryEnabled: true
        ) == .exactSavedInput)
        #expect(VoiceInkDeliveryFeatureFlags
            .shouldShowLockedDestinationIndicator(
                recordingState: .recording,
                isExactInputDeliveryEnabled: true
            ))
        #expect(!VoiceInkDeliveryFeatureFlags
            .shouldShowLockedDestinationIndicator(
                recordingState: .idle,
                isExactInputDeliveryEnabled: true
            ))

        defaults.set(
            false,
            forKey: VoiceInkDeliveryFeatureFlags.exactInputDeliveryDefaultsKey
        )
        #expect(!VoiceInkDeliveryFeatureFlags
            .exactInputDeliveryEnabled(defaults: defaults))
    }

    @Test func recorderVersionSplitsMarketingAndBuildAcrossTwoRows() {
        let presentation = RecorderVersionPresentation(
            marketingVersion: "2.0",
            buildNumber: "214"
        )

        #expect(presentation.topLine == "v2.0")
        #expect(presentation.bottomLine == ".214")
        #expect(presentation.accessibilityLabel == "VoiceInk++ version 2.0, build 214")
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

        session.setStopPasteTarget(RecordingPasteTarget(
            destination: .focusedAtStop,
            focusedInput: nil,
            mode: destinationMode
        ))
        #expect(session.canAcceptSecondChancePasteRetarget)
        #expect(session.retargetPaste(to: retargeted))
        let acceptedPulse = session.iconActionPulse
        #expect(acceptedPulse?.icon == .lockedDestination)
        #expect(session.lockedDestinationIconActionPulseID == acceptedPulse?.id)
        #expect(session.currentFocusIconActionPulseID == nil)
        #expect(!session.canAcceptSecondChancePasteRetarget)
        #expect(!session.retargetPaste(to: RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: ModeConfig(
                name: "Later focus",
                isAIEnhancementEnabled: false,
                autoSendKey: .none
            )
        )))
        #expect(session.pasteTarget.destination == .focusedDuringTranscription)
        #expect(session.iconActionPulse == acceptedPulse)
        let resolvedDecision = session.resolveDeliveryDecision()
        let resolvedTarget = resolvedDecision.pasteTarget
        #expect(resolvedTarget.destination == .focusedDuringTranscription)
        #expect(resolvedTarget.autoSendKey == .enter)
        #expect(resolvedTarget.mode == destinationMode)
        #expect(resolvedTarget.mode?.isAIEnhancementEnabled == true)
        #expect(resolvedTarget.mode?.isTextFormattingEnabled == true)
        #expect(resolvedDecision.postProcessingMode == destinationMode)
        #expect(!session.retargetPaste(to: RecordingPasteTarget(destination: .recordingStart, focusedInput: nil)))
        #expect(session.pasteTarget.destination == .focusedDuringTranscription)
        #expect(session.iconActionPulse == acceptedPulse)
    }

    @MainActor
    @Test func secondChanceUsesOnlyNewestPrimaryNormalStopAndNeverSkipsBackward() {
        let olderPrimaryStop = RecordingSession(phase: .transcribing)
        olderPrimaryStop.setStopPasteTarget(RecordingPasteTarget(
            destination: .focusedAtStop,
            focusedInput: nil
        ))
        let newerNextStop = RecordingSession(phase: .transcribing)
        newerNextStop.setStopPasteTarget(RecordingPasteTarget(
            destination: .recordingStart,
            focusedInput: nil
        ))

        // A newer recordingStart result closes the route. Never search backward and
        // unexpectedly retarget the older primary-stop transcript.
        let blockedByNewerNextStop = VoiceInkEngine
            .newestPendingSessionForSecondChance(
                in: [olderPrimaryStop, newerNextStop]
            )
        #expect(blockedByNewerNextStop?.id == nil)

        newerNextStop.setStopPasteTarget(RecordingPasteTarget(
            destination: .focusedAtStop,
            focusedInput: nil
        ))
        #expect(VoiceInkEngine.newestPendingSessionForSecondChance(
            in: [olderPrimaryStop, newerNextStop]
        )?.id == newerNextStop.id)

        newerNextStop.shouldCancel = true
        #expect(VoiceInkEngine.newestPendingSessionForSecondChance(
            in: [olderPrimaryStop, newerNextStop]
        )?.id == nil)
        newerNextStop.shouldCancel = false

        #expect(newerNextStop.retargetPaste(to: RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil
        )))
        #expect(!newerNextStop.canAcceptSecondChancePasteRetarget)
        let blockedAfterOneShotLatch = VoiceInkEngine
            .newestPendingSessionForSecondChance(
                in: [olderPrimaryStop, newerNextStop]
            )
        #expect(blockedAfterOneShotLatch?.id == nil)
    }

    @MainActor
    @Test func postProcessingFreezeClosesSecondChanceBeforeModeResolution() {
        let originalMode = ModeConfig(
            name: "Original destination",
            isAIEnhancementEnabled: false,
            isTextFormattingEnabled: true,
            autoSendKey: .enter
        )
        let laterMode = ModeConfig(
            name: "Too late",
            isAIEnhancementEnabled: false,
            isTextFormattingEnabled: false,
            autoSendKey: .none
        )
        let session = RecordingSession(phase: .transcribing)
        session.setStopPasteTarget(RecordingPasteTarget(
            destination: .focusedAtStop,
            focusedInput: nil,
            mode: originalMode
        ))

        let frozen = session.resolveDeliveryDecision()

        #expect(frozen.pasteTarget.mode == originalMode)
        #expect(frozen.postProcessingMode == originalMode)
        #expect(!session.canAcceptSecondChancePasteRetarget)
        #expect(!session.retargetPaste(to: RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: laterMode
        )))
        #expect(session.postProcessingMode == originalMode)
    }

    @MainActor
    @Test func contextCaptureResetDoesNotCancelRecordingStartModeResolution() async {
        let boundMode = ModeConfig(
            name: "Captured browser URL",
            isAIEnhancementEnabled: false,
            autoSendKey: .enter
        )
        let session = RecordingSession()
        session.recordingStartModeResolutionTask = Task { boundMode }

        // Microphone startup resets only screenshot/selection context. It must not
        // cancel the separately owned recording-start app/URL Mode decision.
        session.clearContext()

        #expect(session.recordingStartModeResolutionTask != nil)
        let resolved = await session.recordingStartModeResolutionTask?.value
        #expect(resolved == boundMode)

        session.clearSessionResources()
        #expect(session.recordingStartModeResolutionTask == nil)
    }

    @MainActor
    @Test func newestCapturedDestinationModeRefinementWinsBeforeFreeze() async {
        let primaryImmediate = ModeConfig(
            name: "Primary app fallback",
            isAIEnhancementEnabled: false,
            autoSendKey: .none
        )
        let primaryLate = ModeConfig(
            name: "Stale primary URL",
            isAIEnhancementEnabled: true,
            autoSendKey: .commandEnter
        )
        let secondChanceImmediate = ModeConfig(
            name: "Second chance app fallback",
            isAIEnhancementEnabled: false,
            autoSendKey: .none
        )
        let secondChanceFinal = ModeConfig(
            name: "Second chance captured URL",
            isAIEnhancementEnabled: true,
            autoSendKey: .enter
        )
        let session = RecordingSession(phase: .transcribing)

        session.setStopPasteTarget(
            RecordingPasteTarget(
                destination: .focusedAtStop,
                focusedInput: nil,
                mode: primaryImmediate
            ),
            finalModeResolutionTask: Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                return primaryLate
            }
        )
        #expect(session.retargetPaste(
            to: RecordingPasteTarget(
                destination: .focusedDuringTranscription,
                focusedInput: nil,
                mode: secondChanceImmediate
            ),
            finalModeResolutionTask: Task { secondChanceFinal }
        ))

        let decision = await session
            .resolveDeliveryDecisionAfterPendingModeResolution()

        #expect(decision.pasteTarget.destination == .focusedDuringTranscription)
        #expect(decision.pasteTarget.mode == secondChanceFinal)
        #expect(decision.postProcessingMode == secondChanceFinal)
        #expect(decision.pasteTarget.autoSendKey == .enter)
        #expect(!session.canAcceptSecondChancePasteRetarget)
    }

    @MainActor
    @Test func recordingStartModeUpdatePreservesCompletedTargetEnrichment() async {
        let captureID = UUID()
        guard let captured = FocusLockService.makeTestingTarget(
            captureID: captureID,
            inputName: "AX terminal input"
        ), let enriched = FocusLockService.makeTestingTarget(
            captureID: captureID,
            inputName: "Native window plus session identity"
        ) else {
            Issue.record("No running application was available for the target seam")
            return
        }
        let initialMode = ModeConfig(
            name: "Captured terminal Mode",
            isAIEnhancementEnabled: false,
            autoSendKey: .none
        )
        let finalMode = ModeConfig(
            name: "Final terminal Mode",
            isAIEnhancementEnabled: false,
            autoSendKey: .enter
        )
        let session = RecordingSession(
            phase: .transcribing,
            recordingStartFocusedInput: captured
        )
        session.setStopPasteTarget(
            RecordingPasteTarget(
                destination: .recordingStart,
                focusedInput: captured,
                mode: initialMode
            ),
            finalTargetEnrichmentTask: Task { enriched }
        )

        for _ in 0..<20
        where session.pasteTarget.focusedInput?.displayInfo.inputName
            != enriched.displayInfo.inputName {
            await Task.yield()
        }
        #expect(session.pasteTarget.focusedInput?.displayInfo.inputName
            == enriched.displayInfo.inputName)

        // This ordering reproduced the bug: enrichment completed first, then the
        // capture-bound Mode task completed. The Mode write must not rebuild the target
        // from the older un-enriched recording-start wrapper.
        session.setRecordingStartModeSnapshot(finalMode)

        #expect(session.pasteTarget.focusedInput?.displayInfo.inputName
            == enriched.displayInfo.inputName)
        #expect(session.pasteTarget.mode == finalMode)
        #expect(FocusLockService.shared.representsSameCaptureDecision(
            session.pasteTarget.focusedInput!,
            captured
        ))
    }

    @MainActor
    @Test func cancellationIgnoringStaleModeResolutionCannotDelaySecondChanceFreeze() async {
        let staleGate = AsyncTestGate()
        let staleMode = ModeConfig(
            name: "Stale stop target",
            isAIEnhancementEnabled: false,
            autoSendKey: .none
        )
        let secondChanceMode = ModeConfig(
            name: "Second chance target",
            isAIEnhancementEnabled: true,
            autoSendKey: .enter
        )
        let staleTask = Task<ModeConfig?, Never> {
            // Deliberately ignores cancellation while suspended. A replaced lookup in
            // production can behave the same way if its provider does not cooperate.
            await staleGate.wait()
            return staleMode
        }
        let session = RecordingSession(phase: .transcribing)
        session.setStopPasteTarget(
            RecordingPasteTarget(
                destination: .focusedAtStop,
                focusedInput: nil,
                mode: staleMode
            ),
            finalModeResolutionTask: staleTask
        )
        #expect(session.retargetPaste(to: RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: secondChanceMode
        )))

        // Keep the test bounded even if a future regression starts awaiting the stale
        // task again. The accepted implementation must freeze long before this release.
        let safetyRelease = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await staleGate.open()
        }
        let started = ProcessInfo.processInfo.systemUptime
        let decision = await session
            .resolveDeliveryDecisionAfterPendingModeResolution()
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        #expect(elapsed < 0.25)
        #expect(decision.pasteTarget.destination == .focusedDuringTranscription)
        #expect(decision.pasteTarget.mode == secondChanceMode)
        #expect(decision.pasteTarget.autoSendKey == .enter)

        safetyRelease.cancel()
        await staleGate.open()
        _ = await staleTask.value
    }

    @MainActor
    @Test func skipPostProcessingRemainsMutableUntilItsPostTranscriptionCutoff() {
        let session = RecordingSession(phase: .transcribing)
        #expect(session.canChangeSkipPostProcessing)

        session.skipPostProcessing = true
        let frozen = session.resolveSkipPostProcessingForPostProcessing()

        #expect(frozen)
        #expect(!session.canChangeSkipPostProcessing)
        session.skipPostProcessing = false
        #expect(session.skipPostProcessing)
        #expect(session.resolveSkipPostProcessingForPostProcessing())
    }

    @MainActor
    @Test func recordingStartPromotionIsSessionOwnedAndCancellable() async {
        let session = RecordingSession()
        let promotionTask: Task<FocusLockService.Target?, Never> = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return nil
        }
        session.recordingStartPromotionTask = promotionTask

        session.cancelRecordingStartPromotion()

        #expect(promotionTask.isCancelled)
        #expect(session.recordingStartPromotionTask?.isCancelled == nil)
        _ = await promotionTask.value
    }

    @MainActor
    @Test func modifierOnlyDecisionBoundaryRequiresTheCompleteMacro() {
        let shortcut = Shortcut.modifierOnly(
            keyCode: nil,
            modifierFlags: [.shift, .control, .option]
        )
        #expect(!shortcut.modifierSequenceIsActive(
            keyCode: 56,
            modifierFlags: [.shift]
        ))
        #expect(shortcut.modifierSequenceIsActive(
            keyCode: 58,
            modifierFlags: [.shift, .control, .option]
        ))
        #expect(!shortcut.modifierSequenceIsActive(
            keyCode: 59,
            modifierFlags: [.control]
        ))
        #expect(!shortcut.modifierSequenceIsActive(
            keyCode: 59,
            modifierFlags: [.command]
        ))
        #expect(!shortcut.modifierSequenceIsActive(
            keyCode: 59,
            modifierFlags: []
        ))

        var isDown = false
        var orderedActions: [String] = []
        var downstreamSuppression: [Bool] = []
        func apply(
            keyCode: UInt16,
            flags: NSEvent.ModifierFlags
        ) {
            let transition = ShortcutMonitor.modifierOnlySequenceTransition(
                shortcut: shortcut,
                wasDown: isDown,
                keyCode: keyCode,
                modifierFlags: flags
            )
            if transition.dispatchKeyDown {
                orderedActions.append("down")
            }
            if transition.dispatchKeyUp {
                orderedActions.append("up")
            }
            downstreamSuppression.append(transition.suppressDownstream)
            isDown = transition.isDown
        }

        apply(keyCode: 56, flags: [.shift])
        apply(keyCode: 59, flags: [.shift, .control])
        #expect(orderedActions.isEmpty)
        apply(keyCode: 58, flags: [.shift, .control, .option])
        #expect(orderedActions == ["down"])
        apply(keyCode: 58, flags: [.shift, .control, .option])
        #expect(orderedActions == ["down"])
        apply(keyCode: 58, flags: [.shift, .control])
        #expect(orderedActions == ["down", "up"])
        apply(keyCode: 59, flags: [.shift])
        apply(keyCode: 56, flags: [])
        #expect(downstreamSuppression == [
            false, false, true, true, false, false, false
        ])
        apply(keyCode: 56, flags: [.shift])
        apply(keyCode: 59, flags: [.shift, .control])
        apply(keyCode: 58, flags: [.shift, .control, .option])
        #expect(orderedActions == [
            "down", "up", "down"
        ])

        // A tap reset clears both latches. The next completed macro must therefore
        // behave as a fresh physical press rather than inheriting a stale stop token.
        isDown = false
        apply(keyCode: 58, flags: [.shift, .control, .option])
        #expect(orderedActions.last == "down")
        #expect(downstreamSuppression.last == true)

        // G HUB/macOS can release the same three modifiers in the opposite order.
        // The first release ends VoiceInk++'s logical press, but all three physical
        // releases must pass through so Codex/ChatGPT never inherit a stuck modifier.
        var reverseIsDown = false
        var reverseSuppression: [Bool] = []
        var reverseCallbacks: [String] = []
        let reverseReleaseEvents: [(UInt16, NSEvent.ModifierFlags)] = [
            (UInt16(56), NSEvent.ModifierFlags.shift),
            (UInt16(59), [.shift, .control]),
            (UInt16(58), [.shift, .control, .option]),
            (UInt16(56), [.control, .option]),
            (UInt16(59), .option),
            (UInt16(58), NSEvent.ModifierFlags())
        ]
        for (keyCode, flags) in reverseReleaseEvents {
            let transition = ShortcutMonitor.modifierOnlySequenceTransition(
                shortcut: shortcut,
                wasDown: reverseIsDown,
                keyCode: keyCode,
                modifierFlags: flags
            )
            if transition.dispatchKeyDown { reverseCallbacks.append("down") }
            if transition.dispatchKeyUp { reverseCallbacks.append("up") }
            reverseSuppression.append(transition.suppressDownstream)
            reverseIsDown = transition.isDown
        }
        #expect(reverseSuppression == [false, false, true, false, false, false])
        #expect(reverseCallbacks == ["down", "up"])

        // A one-modifier shortcut follows the same rule: completed downs/repeats are
        // consumed, while the release is delivered so downstream modifier state clears.
        let singleModifier = Shortcut.modifierOnly(
            keyCode: nil,
            modifierFlags: [.shift]
        )
        var singleIsDown = false
        var singleSuppression: [Bool] = []
        var singleCallbacks: [String] = []
        for (keyCode, flags) in [
            (UInt16(56), NSEvent.ModifierFlags.shift),
            (UInt16(56), NSEvent.ModifierFlags.shift),
            (UInt16(56), NSEvent.ModifierFlags())
        ] {
            let transition = ShortcutMonitor.modifierOnlySequenceTransition(
                shortcut: singleModifier,
                wasDown: singleIsDown,
                keyCode: keyCode,
                modifierFlags: flags
            )
            if transition.dispatchKeyDown { singleCallbacks.append("down") }
            if transition.dispatchKeyUp { singleCallbacks.append("up") }
            singleSuppression.append(transition.suppressDownstream)
            singleIsDown = transition.isDown
        }
        #expect(singleSuppression == [true, true, false])
        #expect(singleCallbacks == ["down", "up"])
    }

    @Test func sharedOpenAIBundleUsesCapturedApplicationForModeLookup() {
        #expect(ActiveWindowService.modeLookupBundleIdentifier(
            capturedBundleIdentifier: "com.openai.codex",
            applicationBundleName: "ChatGPT.app"
        ) == "com.openai.chat")
        #expect(ActiveWindowService.modeLookupBundleIdentifier(
            capturedBundleIdentifier: "com.openai.codex",
            applicationBundleName: "Codex.app"
        ) == "com.openai.codex")
        #expect(ActiveWindowService.modeLookupBundleIdentifier(
            capturedBundleIdentifier: "com.anthropic.claudefordesktop",
            applicationBundleName: "Claude.app"
        ) == "com.anthropic.claudefordesktop")
    }

    @MainActor
    @Test func retainedFocusedComposerMayIgnoreOnlyAncestorPathDrift() {
        #expect(FocusLockService.retainedFocusedAncestorDriftAllowed(
            isTelegram: false,
            retainedInputOwnsSystemKeyboardFocus: true,
            directContextMatches: true,
            hasHardenedApplicationScope: false
        ))
        #expect(FocusLockService.retainedFocusedAncestorDriftAllowed(
            isTelegram: false,
            retainedInputOwnsSystemKeyboardFocus: true,
            directContextMatches: false,
            hasHardenedApplicationScope: true
        ))
        #expect(!FocusLockService.retainedFocusedAncestorDriftAllowed(
            isTelegram: true,
            retainedInputOwnsSystemKeyboardFocus: true,
            directContextMatches: true,
            hasHardenedApplicationScope: true
        ))
        #expect(!FocusLockService.retainedFocusedAncestorDriftAllowed(
            isTelegram: false,
            retainedInputOwnsSystemKeyboardFocus: false,
            directContextMatches: true,
            hasHardenedApplicationScope: true
        ))
        #expect(!FocusLockService.retainedFocusedAncestorDriftAllowed(
            isTelegram: false,
            retainedInputOwnsSystemKeyboardFocus: true,
            directContextMatches: false,
            hasHardenedApplicationScope: false
        ))
    }

    @MainActor
    @Test func toggleLifecycleStartsAgainWhileOlderSessionKeepsPanelVisible() async {
        let action = ShortcutAction.primaryRecording
        let recordingID = UUID()
        var activeRecordingID: UUID?
        var state = RecordingState.idle
        var panelVisible = false
        var invocations: [RecordingPasteDestination] = []

        let handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { state == .idle || state == .recording },
            isRecorderVisible: { panelVisible },
            recordingState: { state },
            activeRecordingIdentifier: { activeRecordingID },
            toggleRecorderPanel: { _, destination in
                invocations.append(destination)
                if state == .recording {
                    activeRecordingID = nil
                    state = .idle
                    // An older queued transcription intentionally keeps the mirrored
                    // recorder panels visible after this microphone session stops.
                    panelVisible = true
                } else {
                    activeRecordingID = recordingID
                    state = .recording
                    panelVisible = true
                }
            },
            cancelRecording: {},
            shortcutForAction: { _ in
                Shortcut.modifierOnly(
                    keyCode: nil,
                    modifierFlags: [.shift, .control, .option]
                )
            },
            shortcutPressCooldown: 0
        )

        await handler.handleKeyDown(
            action: action,
            eventTime: 1,
            mode: .toggle
        )
        await handler.handleKeyUp(
            action: action,
            eventTime: 1.1,
            mode: .toggle
        )
        await handler.handleKeyDown(
            action: action,
            eventTime: 2,
            mode: .toggle
        )
        await handler.handleKeyUp(
            action: action,
            eventTime: 2.1,
            mode: .toggle
        )
        await handler.handleKeyDown(
            action: action,
            eventTime: 3,
            mode: .toggle
        )

        #expect(invocations.count == 3)
        #expect(invocations == [
            .focusedAtStop, .focusedAtStop, .focusedAtStop
        ])
        #expect(state == .recording)
        #expect(activeRecordingID == recordingID)
        #expect(panelVisible)
    }

    @MainActor
    @Test func nextTrackRoutingUsesMicOwnerInsteadOfRecorderVisibility() {
        let activeRecordingID = UUID()
        #expect(RecordingShortcutManager
            .shouldConsumeNextTrackForActiveRecording(
                activeRecordingIdentifier: activeRecordingID,
                recordingState: .recording
            ))
        #expect(RecordingShortcutManager
            .shouldConsumeNextTrackForActiveRecording(
                activeRecordingIdentifier: activeRecordingID,
                recordingState: .starting
            ))
        #expect(!RecordingShortcutManager
            .shouldConsumeNextTrackForActiveRecording(
                activeRecordingIdentifier: nil,
                recordingState: .recording
            ))
        #expect(!RecordingShortcutManager
            .shouldConsumeNextTrackForActiveRecording(
                activeRecordingIdentifier: activeRecordingID,
                recordingState: .transcribing
            ))
    }

    @MainActor
    @Test func recordingStartPromotionCannotAdoptAfterQuickStopOrSessionReplacement() {
        #expect(VoiceInkEngine.shouldAdoptRecordingStartPromotion(
            liveRecordingState: .recording,
            phase: .recording,
            startIDMatches: true,
            sessionStillExists: true,
            shouldCancel: false
        ))
        #expect(!VoiceInkEngine.shouldAdoptRecordingStartPromotion(
            liveRecordingState: .transcribing,
            phase: .transcribing,
            startIDMatches: false,
            sessionStillExists: true,
            shouldCancel: false
        ))
        #expect(!VoiceInkEngine.shouldAdoptRecordingStartPromotion(
            liveRecordingState: .recording,
            phase: .recording,
            startIDMatches: true,
            sessionStillExists: false,
            shouldCancel: false
        ))
        #expect(!VoiceInkEngine.shouldAdoptRecordingStartPromotion(
            liveRecordingState: .recording,
            phase: .recording,
            startIDMatches: true,
            sessionStillExists: true,
            shouldCancel: true
        ))
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
    @Test func lockedDestinationOutlineAppearsOnlyForFrozenRealTargets() {
        #expect(!RecordingSession.pasteDestinationOutlineIsVisible(
            phase: .recording,
            hasFrozenInput: true
        ))
        #expect(RecordingSession.pasteDestinationOutlineIsVisible(
            phase: .transcribing,
            hasFrozenInput: true
        ))
        #expect(RecordingSession.pasteDestinationOutlineIsVisible(
            phase: .delivering,
            hasFrozenInput: true
        ))
        #expect(!RecordingSession.pasteDestinationOutlineIsVisible(
            phase: .transcribing,
            hasFrozenInput: false
        ))
        #expect(!RecordingSession.pasteDestinationOutlineIsVisible(
            phase: .done,
            hasFrozenInput: true
        ))
    }

    @MainActor
    @Test func foregroundDeliveryLifecycleWaitsForOperationBeforeResolving() async {
        var operationFinished = false

        await TranscriptionDelivery.awaitForegroundDeliveryLifecycle {
            await Task.yield()
            operationFinished = true
        }

        // The engine removes the session immediately after delivery returns. This
        // assertion protects the persistent outline by proving that foreground paste,
        // verification, and auto-send cannot outlive that return boundary.
        #expect(operationFinished)
    }

    @MainActor
    @Test func transientModifiedChatComposerKeepsPollingForARealSubmit() {
        #expect(!TranscriptionDelivery
            .chatSubmissionVerificationIsConclusiveBeforeDeadline(
                .modifiedWithoutSubmit
            ))
        #expect(!TranscriptionDelivery
            .chatSubmissionVerificationIsConclusiveBeforeDeadline(.unchanged))
        #expect(!TranscriptionDelivery
            .chatSubmissionVerificationIsConclusiveBeforeDeadline(.unavailable))
        #expect(TranscriptionDelivery
            .chatSubmissionVerificationIsConclusiveBeforeDeadline(.verified))

        var alreadyIssuedActionCount = 1
        let eventuallyCleared = TranscriptionDelivery
            .settledChatSubmissionVerification([
                .modifiedWithoutSubmit,
                .modifiedWithoutSubmit,
                .verified
            ])
        #expect(eventuallyCleared == .verified)
        #expect(alreadyIssuedActionCount == 1)

        let persistentMutation = TranscriptionDelivery
            .settledChatSubmissionVerification([
                .modifiedWithoutSubmit,
                .modifiedWithoutSubmit,
                .modifiedWithoutSubmit
            ])
        #expect(persistentMutation == .modifiedWithoutSubmit)
        // Polling has no action closure and therefore cannot issue a second Send/Return.
        #expect(alreadyIssuedActionCount == 1)
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

        session.setStopPasteTarget(RecordingPasteTarget(
            destination: .focusedAtStop,
            focusedInput: nil,
            mode: destinationMode
        ))
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
        ) == .verified)
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
        #expect(!TranscriptionDelivery.pasteChangeProvesInsertedText(
            insertedText: "This is a test",
            previousText: "This is a test draft",
            currentText: "This is a test draft\n"
        ))
        #expect(TranscriptionDelivery.pasteChangeProvesInsertedText(
            insertedText: "This is a test",
            previousText: "This is a test",
            currentText: "This is a testThis is a test"
        ))
        #expect(TranscriptionDelivery.pasteChangeProvesInsertedText(
            insertedText: "This is a test",
            previousText: "draft",
            currentText: "This is a test"
        ))
        #expect(!TranscriptionDelivery.pasteChangeProvesInsertedText(
            insertedText: "This is a test",
            previousText: nil,
            currentText: "This is a test"
        ))
        #expect(TranscriptionDelivery.classifyExactPasteChange(
            insertedText: "This is a test",
            previousText: "draft",
            currentText: "draft"
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyExactPasteChange(
            insertedText: "This is a test",
            previousText: nil,
            currentText: "This is a test"
        ) == .unavailable)

        #expect(TranscriptionDelivery.foregroundPastePreflightMatches(
            expectedFrontmostPID: 100,
            currentFrontmostPID: 100,
            savedInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.foregroundPastePreflightMatches(
            expectedFrontmostPID: 100,
            currentFrontmostPID: 200,
            savedInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.foregroundPastePreflightMatches(
            expectedFrontmostPID: 100,
            currentFrontmostPID: 100,
            savedInputOwnsKeyboardFocus: false
        ))

        #expect(TranscriptionDelivery.exactInputInitialDeliveryRoute(
            exactInputOwnsKeyboardFocus: true
        ) == .foregroundWithoutFocusMutation)
        #expect(TranscriptionDelivery.exactInputInitialDeliveryRoute(
            exactInputOwnsKeyboardFocus: true
        ) == .foregroundWithoutFocusMutation)
        #expect(TranscriptionDelivery.exactInputInitialDeliveryRoute(
            exactInputOwnsKeyboardFocus: false
        ) == .nonActivatingExactInput)
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
            initialPlan: .verifyOnly,
            semanticResult: .pressed,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .verifyOnly,
            semanticResult: .failed(AXError.cannotComplete.rawValue),
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.anthropic.claudefordesktop",
            initialPlan: .verifyOnly,
            semanticResult: .pressed,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .verifyOnly,
            semanticResult: .pressed,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: false
        ))
        #expect(TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .issueExactFocusReturn,
            semanticResult: .unavailable,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundSemanticSendWithReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .issueExactFocusReturn,
            semanticResult: .unavailable,
            verification: .modifiedWithoutSubmit,
            exactInputOwnsKeyboardFocus: true
        ))

        #expect(TranscriptionDelivery.usesHumanizedHIDForegroundReturn(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(TranscriptionDelivery.usesHumanizedHIDForegroundReturn(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(TranscriptionDelivery.usesHumanizedHIDForegroundReturn(
            bundleIdentifier: "com.anthropic.claudefordesktop"
        ))
        #expect(!TranscriptionDelivery.usesHumanizedHIDForegroundReturn(
            bundleIdentifier: "com.google.Chrome"
        ))
        #expect(TranscriptionDelivery.foregroundAutoSendIsVerifiedSuccess(
            .succeeded
        ))
        #expect(!TranscriptionDelivery.foregroundAutoSendIsVerifiedSuccess(
            .indeterminate
        ))
        #expect(!TranscriptionDelivery.foregroundAutoSendIsVerifiedSuccess(
            .focusMoved
        ))
        #expect(!TranscriptionDelivery.foregroundAutoSendIsVerifiedSuccess(
            .failed
        ))
    }

    @MainActor
    @Test func backgroundChatSemanticFallbackIsOneShotAndOpenAIRetryBounded() {
        #expect(TranscriptionDelivery.backgroundSemanticActionPlan(
            result: .pressed,
            exactInputOwnsKeyboardFocus: true
        ) == .verifyOnly)
        #expect(TranscriptionDelivery.backgroundSemanticActionPlan(
            result: .failed(AXError.cannotComplete.rawValue),
            exactInputOwnsKeyboardFocus: true
        ) == .verifyOnly)
        #expect(TranscriptionDelivery.backgroundSemanticActionPlan(
            result: .unavailable,
            exactInputOwnsKeyboardFocus: true
        ) == .issueExactFocusReturn)
        #expect(TranscriptionDelivery.backgroundSemanticActionPlan(
            result: .unavailable,
            exactInputOwnsKeyboardFocus: false
        ) == .failNoSafeAction)

        #expect(TranscriptionDelivery.shouldRetryBackgroundExactFocusReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .issueExactFocusReturn,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryBackgroundExactFocusReturn(
            bundleIdentifier: "com.anthropic.claudefordesktop",
            initialPlan: .issueExactFocusReturn,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryBackgroundExactFocusReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .verifyOnly,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryBackgroundExactFocusReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .issueExactFocusReturn,
            verification: .modifiedWithoutSubmit,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryBackgroundExactFocusReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .issueExactFocusReturn,
            verification: .unavailable,
            exactInputOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryBackgroundExactFocusReturn(
            bundleIdentifier: "com.openai.codex",
            initialPlan: .issueExactFocusReturn,
            verification: .unchanged,
            exactInputOwnsKeyboardFocus: false
        ))

        // An unverified foreground paste never reaches any Return planner. The exact
        // readiness classifier remains false for unchanged/unreadable composer state.
        #expect(!TranscriptionDelivery.foregroundChatPasteIsReady(
            insertedText: "new transcript",
            previousText: "draft",
            currentText: "draft"
        ))
        #expect(!TranscriptionDelivery.foregroundChatPasteIsReady(
            insertedText: "new transcript",
            previousText: "draft",
            currentText: nil
        ))
    }

    @MainActor
    @Test func genericForegroundAutoSendDisablesRedundantEnterAtOrchestrationBoundary() async {
        var issueCount = 0
        var observedRedundantEnter: Bool?
        let outcome = await TranscriptionDelivery
            .executeOneShotGenericForegroundAutoSend { sendRedundantEnter in
                issueCount += 1
                observedRedundantEnter = sendRedundantEnter
                return .commandPosted
            }

        #expect(issueCount == 1)
        #expect(observedRedundantEnter == false)
        #expect(outcome == .indeterminate)
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
    @Test func semanticSendSurfaceKeepsOpenAIAppsDistinctAndTelegramForegroundOnly() {
        #expect(FocusLockService.semanticSendSurface(
            bundleIdentifier: "com.openai.codex",
            applicationBundleName: "ChatGPT.app"
        ) == .openAIChatGPT)
        #expect(FocusLockService.semanticSendSurface(
            bundleIdentifier: "com.openai.codex",
            applicationBundleName: "Codex.app"
        ) == .openAICodex)
        #expect(FocusLockService.semanticSendSurface(
            bundleIdentifier: "com.openai.codex",
            applicationBundleName: "Lookalike.app"
        ) == nil)
        #expect(FocusLockService.semanticSendSurface(
            bundleIdentifier: "com.anthropic.claudefordesktop",
            applicationBundleName: "Claude.app"
        ) == .claudeDesktop)
        #expect(FocusLockService.semanticSendSurface(
            bundleIdentifier: "ru.keepcoder.Telegram",
            applicationBundleName: "Telegram.app"
        ) == .telegramForegroundOnly)

        #expect(FocusLockService.supportsBackgroundSemanticSend(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(FocusLockService.supportsBackgroundSemanticSend(
            bundleIdentifier: "com.anthropic.claudefordesktop"
        ))
        #expect(!FocusLockService.supportsBackgroundSemanticSend(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
    }

    @MainActor
    @Test func recordingStartMainComposerEvidenceDoesNotDependOnSendReadiness() {
        #expect(FocusLockService.supportsRecordingStartMainComposer(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(FocusLockService.supportsRecordingStartMainComposer(
            bundleIdentifier: "com.openai.chat"
        ))
        #expect(FocusLockService.supportsRecordingStartMainComposer(
            bundleIdentifier: "com.anthropic.claudefordesktop"
        ))
        #expect(!FocusLockService.supportsRecordingStartMainComposer(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.supportsRecordingStartMainComposer(
            bundleIdentifier: "com.apple.Terminal"
        ))
        #expect(!FocusLockService.supportsRecordingStartMainComposer(
            bundleIdentifier: "com.google.Chrome"
        ))

        #expect(FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Message ChatGPT",
            placeholder: "Message ChatGPT"
        ))
        #expect(FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Message ChatGPT",
            placeholder: nil
        ))
        #expect(FocusLockService.openAIComposerProduct(
            description: "Ask for follow-up changes",
            placeholder: nil
        ) == .codex)
        #expect(FocusLockService.openAIComposerProduct(
            description: "Ask Codex to do anything",
            placeholder: "Ask Codex to do anything"
        ) == .codex)
        #expect(FocusLockService.openAIComposerProduct(
            description: "Ask ChatGPT anything locally",
            placeholder: "Ask ChatGPT anything locally"
        ) == .chatGPT)
        // ChatGPT.app is the audited host artifact for Ethan's current Codex task.
        // Its embedded Codex composer must gain hardened capture scope without being
        // reclassified as Codex.app for the separate versioned Send allowlist.
        #expect(FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Ask for follow-up changes",
            placeholder: "Ask for follow-up changes"
        ))
        #expect(FocusLockService.exactMainComposerCaptureEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Ask Codex to do anything",
            placeholder: "Ask Codex to do anything",
            windowIsModal: false,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAICodex,
            description: "Ask for follow-up changes",
            placeholder: "Ask for follow-up changes"
        ))
        #expect(FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAICodex,
            description: "Ask for follow-up changes",
            placeholder: nil
        ))
        #expect(FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .claudeDesktop,
            description: "Prompt",
            placeholder: nil
        ))
        #expect(!FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Stop",
            placeholder: "Message ChatGPT"
        ))
        #expect(!FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Share feedback",
            placeholder: "Share feedback"
        ))
        #expect(!FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAICodex,
            description: "Describe this bug",
            placeholder: "Describe this bug"
        ))
        #expect(!FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .openAICodex,
            description: "Message ChatGPT",
            placeholder: "Message ChatGPT"
        ))
        #expect(FocusLockService.openAIComposerProduct(
            description: "Ask Codex to do anything",
            placeholder: "Different modal placeholder"
        ) == nil)
        #expect(!FocusLockService.recordingStartComposerEvidenceMatches(
            surface: .telegramForegroundOnly,
            description: "Write a message",
            placeholder: "Write a message"
        ))

        #expect(FocusLockService.exactMainComposerCaptureEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Message ChatGPT",
            placeholder: "Message ChatGPT",
            windowIsModal: false,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(!FocusLockService.exactMainComposerCaptureEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Share feedback",
            placeholder: "Share feedback",
            windowIsModal: false,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(!FocusLockService.exactMainComposerCaptureEvidenceMatches(
            surface: .openAICodex,
            description: "Ask for follow-up changes",
            placeholder: "Ask for follow-up changes",
            windowIsModal: true,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(!FocusLockService.exactMainComposerCaptureEvidenceMatches(
            surface: .openAIChatGPT,
            description: "Ask for follow-up changes",
            placeholder: "Ask for follow-up changes",
            windowIsModal: true,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(!FocusLockService.exactMainComposerCaptureEvidenceMatches(
            surface: .claudeDesktop,
            description: "Prompt",
            placeholder: nil,
            windowIsModal: false,
            hasDisallowedSecondaryAncestor: true
        ))

        #expect(FocusLockService.isProvenSemanticStopLabel("Stop"))
        #expect(FocusLockService.isProvenSemanticStopLabel("Stop generating"))
        #expect(!FocusLockService.isProvenSemanticSendLabel("Stop"))
        #expect(!FocusLockService.isProvenSemanticStopLabel("Submit"))
    }

    @MainActor
    @Test func noCaretFallbackRequiresSelectedTaskOrDistinctPanelEvidence() {
        #expect(FocusLockService.uniqueStableTaskKey(
            identifier: "task-row",
            domIdentifier: "task-019f5cec-30d7-7d53-a564-2f73ed8e0784",
            identifierOccurrences: 4,
            domIdentifierOccurrences: 1
        ) == "dom:task-019f5cec-30d7-7d53-a564-2f73ed8e0784")
        #expect(FocusLockService.uniqueStableTaskKey(
            identifier: "task-019f5cec-30d7-7d53-a564-2f73ed8e0784",
            domIdentifier: nil,
            identifierOccurrences: 1,
            domIdentifierOccurrences: 0
        ) == "ax:task-019f5cec-30d7-7d53-a564-2f73ed8e0784")
        #expect(FocusLockService.uniqueStableTaskKey(
            identifier: "virtual-row",
            domIdentifier: nil,
            identifierOccurrences: 12,
            domIdentifierOccurrences: 0
        ) == nil)
        #expect(FocusLockService.uniqueStableTaskKey(
            identifier: "virtual-row",
            domIdentifier: nil,
            identifierOccurrences: 1,
            domIdentifierOccurrences: 0
        ) == nil)
        #expect(!FocusLockService.stableTaskIdentifierHasInstanceEvidence(
            "row-1"
        ))
        #expect(!FocusLockService.stableTaskIdentifierHasInstanceEvidence(
            "task-42"
        ))
        #expect(!FocusLockService.stableTaskIdentifierHasInstanceEvidence(
            "virtualized-row-a91b2c3d4e5f678901234567890"
        ))
        #expect(FocusLockService.stableTaskIdentifierHasInstanceEvidence(
            "conversation-019f5cec-30d7-7d53-a564-2f73ed8e0784"
        ))
        #expect(!FocusLockService.exactInputIdentifierHasInstanceEvidence(
            identifier: "prompt-textarea",
            domIdentifier: "prompt-textarea"
        ))
        #expect(FocusLockService.exactInputIdentifierHasInstanceEvidence(
            identifier: nil,
            domIdentifier: "composer-019f5cec-30d7-7d53-a564-2f73ed8e0784"
        ))
        #expect(!FocusLockService.directCapturedElementContextAllowed(
            bundleIdentifier: "com.openai.codex",
            hasInstanceSpecificIdentifier: false,
            capturedContextAnchors: [],
            currentContextAnchors: []
        ))
        #expect(!FocusLockService.directCapturedElementContextAllowed(
            bundleIdentifier: "com.openai.codex",
            hasInstanceSpecificIdentifier: true,
            capturedContextAnchors: [],
            currentContextAnchors: []
        ))
        #expect(FocusLockService.directCapturedElementContextAllowed(
            bundleIdentifier: "com.example.NativeEditor",
            hasInstanceSpecificIdentifier: true,
            capturedContextAnchors: [],
            currentContextAnchors: []
        ))
        #expect(!FocusLockService.retainedForegroundInputBoundaryAllowed(
            rendererRequiresIdentityOrContext: true,
            hasExactIdentity: false,
            hasHardenedApplicationScope: false
        ))
        #expect(FocusLockService.retainedForegroundInputBoundaryAllowed(
            rendererRequiresIdentityOrContext: true,
            hasExactIdentity: false,
            hasHardenedApplicationScope: true
        ))
        #expect(FocusLockService.genericMainInputPromotionIsAllowed(
            traversalCompleted: true,
            candidateCount: 1,
            appIsStillFrontmost: true,
            sourceFocusStillMatches: true,
            focusedWindowStillMatches: true
        ))
        #expect(!FocusLockService.genericMainInputPromotionIsAllowed(
            traversalCompleted: false,
            candidateCount: 1,
            appIsStillFrontmost: true,
            sourceFocusStillMatches: true,
            focusedWindowStillMatches: true
        ))
        #expect(!FocusLockService.genericMainInputPromotionIsAllowed(
            traversalCompleted: true,
            candidateCount: 2,
            appIsStillFrontmost: true,
            sourceFocusStillMatches: true,
            focusedWindowStillMatches: true
        ))
        #expect(!FocusLockService.genericMainInputPromotionIsAllowed(
            traversalCompleted: true,
            candidateCount: 1,
            appIsStillFrontmost: false,
            sourceFocusStillMatches: true,
            focusedWindowStillMatches: true
        ))
        #expect(!FocusLockService.inferredGenericMainInputCaptureIsUsable(
            hasExactIdentity: false,
            focusVerified: false
        ))
        #expect(FocusLockService.inferredGenericMainInputCaptureIsUsable(
            hasExactIdentity: true,
            focusVerified: false
        ))
        #expect(FocusLockService.inferredGenericMainInputCaptureIsUsable(
            hasExactIdentity: false,
            focusVerified: true
        ))
        #expect(FocusLockService.uniqueStableTaskKey(
            identifier: "shared",
            domIdentifier: "shared",
            identifierOccurrences: 2,
            domIdentifierOccurrences: 2
        ) == nil)
        #expect(FocusLockService.promotedStableSelectionMatches(
            sameWindow: true,
            sameRetainedWrapper: true,
            selected: true,
            roleMatches: true,
            stableTaskKeyMatches: true
        ))
        #expect(!FocusLockService.promotedStableSelectionMatches(
            sameWindow: true,
            sameRetainedWrapper: true,
            selected: false,
            roleMatches: true,
            stableTaskKeyMatches: true
        ))
        #expect(!FocusLockService.promotedStableSelectionMatches(
            sameWindow: true,
            sameRetainedWrapper: true,
            selected: true,
            roleMatches: true,
            stableTaskKeyMatches: false
        ))

        #expect(FocusLockService.selectedTaskScopeEvidenceMatches(
            surface: .openAIChatGPT,
            role: "AXRow",
            selected: true,
            identifier: "chat-row-42",
            domIdentifier: nil,
            label: "Disposable chat",
            containerDescriptor: "Chat history"
        ))
        #expect(FocusLockService.selectedTaskScopeEvidenceMatches(
            surface: .openAICodex,
            role: "AXTab",
            selected: true,
            identifier: nil,
            domIdentifier: "task-tab-42",
            label: "Disposable task",
            containerDescriptor: "Tasks"
        ))
        #expect(!FocusLockService.selectedTaskScopeEvidenceMatches(
            surface: .openAIChatGPT,
            role: "AXGroup",
            selected: true,
            identifier: "renderer-group",
            domIdentifier: nil,
            label: "Shared renderer group",
            containerDescriptor: "Chat history"
        ))
        #expect(!FocusLockService.selectedTaskScopeEvidenceMatches(
            surface: .openAIChatGPT,
            role: "AXRow",
            selected: false,
            identifier: "chat-row-41",
            domIdentifier: nil,
            label: "Previous task",
            containerDescriptor: "Chat history"
        ))
        #expect(!FocusLockService.selectedTaskScopeEvidenceMatches(
            surface: .openAIChatGPT,
            role: "AXRow",
            selected: true,
            identifier: nil,
            domIdentifier: nil,
            label: "Disposable chat",
            containerDescriptor: "Chat history"
        ))
        #expect(!FocusLockService.selectedTaskScopeEvidenceMatches(
            surface: .openAICodex,
            role: "AXRow",
            selected: true,
            identifier: "settings-model-row",
            domIdentifier: nil,
            label: "GPT-5",
            containerDescriptor: "Model settings"
        ))
        #expect(!FocusLockService.selectedTaskScopeEvidenceMatches(
            surface: .claudeDesktop,
            role: "AXRow",
            selected: true,
            identifier: "filter-row",
            domIdentifier: nil,
            label: "Today",
            containerDescriptor: "Filters"
        ))

        #expect(FocusLockService.recordingStartScopeScanIsAcceptable(
            completed: true,
            matchingScopeCount: 1
        ))
        #expect(!FocusLockService.recordingStartScopeScanIsAcceptable(
            completed: false,
            matchingScopeCount: 1
        ))
        #expect(!FocusLockService.recordingStartScopeScanIsAcceptable(
            completed: true,
            matchingScopeCount: 2
        ))

        #expect(FocusLockService.recordingStartFloatingPanelEvidenceMatches(
            surface: .openAIChatGPT,
            subrole: "AXFloatingWindow",
            isModal: false
        ))
        #expect(!FocusLockService.recordingStartFloatingPanelEvidenceMatches(
            surface: .openAIChatGPT,
            subrole: "AXDialog",
            isModal: false
        ))
        #expect(!FocusLockService.recordingStartFloatingPanelEvidenceMatches(
            surface: .openAIChatGPT,
            subrole: "AXFloatingWindow",
            isModal: true
        ))
        #expect(!FocusLockService.recordingStartFloatingPanelEvidenceMatches(
            surface: .openAICodex,
            subrole: "AXFloatingWindow",
            isModal: false
        ))
        #expect(!FocusLockService.recordingStartFloatingPanelEvidenceMatches(
            surface: .claudeDesktop,
            subrole: "AXFloatingWindow",
            isModal: false
        ))

        #expect(!FocusLockService.exactMainComposerWindowIdentityIsUsable(
            windowTitle: "Codex",
            windowDocument: nil,
            windowIdentifier: "main-window"
        ))
        #expect(!FocusLockService.exactMainComposerWindowIdentityIsUsable(
            windowTitle: "ChatGPT",
            windowDocument: "https://chatgpt.com/",
            windowIdentifier: "browser-window"
        ))
        #expect(!FocusLockService.exactMainComposerWindowIdentityIsUsable(
            windowTitle: "VoiceInk++ delivery investigation",
            windowDocument: nil,
            windowIdentifier: "main-window"
        ))
        let taskUUID = "019f5cec-30d7-7d53-a564-2f73ed8e0784"
        #expect(!FocusLockService.exactMainComposerWindowIdentityIsUsable(
            windowTitle: "Codex",
            windowDocument: nil,
            windowIdentifier: "window-\(taskUUID)"
        ))
        #expect(FocusLockService.exactMainComposerWindowIdentityIsUsable(
            windowTitle: "Codex",
            windowDocument: "codex://task/\(taskUUID)",
            windowIdentifier: "main-window"
        ))
        #expect(FocusLockService.exactMainComposerWindowIdentityMatches(
            capturedTitle: "Codex",
            capturedDocument: "codex://task/\(taskUUID)",
            capturedIdentifier: "main-window",
            currentTitle: "Codex",
            currentDocument: "codex://task/\(taskUUID)",
            currentIdentifier: "main-window"
        ))
        #expect(!FocusLockService.exactMainComposerWindowIdentityMatches(
            capturedTitle: "Codex",
            capturedDocument: "codex://task/\(taskUUID)",
            capturedIdentifier: "main-window",
            currentTitle: "Codex",
            currentDocument: "codex://task/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            currentIdentifier: "main-window"
        ))

        #expect(FocusLockService.recordingStartComposerContainmentAllowed(
            scopeKind: .selectedTask,
            windowIsModal: false,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(FocusLockService.recordingStartComposerContainmentAllowed(
            scopeKind: .floatingQuickComposer,
            windowIsModal: false,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(!FocusLockService.recordingStartComposerContainmentAllowed(
            scopeKind: .selectedTask,
            windowIsModal: true,
            hasDisallowedSecondaryAncestor: false
        ))
        #expect(!FocusLockService.recordingStartComposerContainmentAllowed(
            scopeKind: .selectedTask,
            windowIsModal: false,
            hasDisallowedSecondaryAncestor: true
        ))
    }

    @MainActor
    @Test func boundedIdentityEvidenceFailsClosedWhenIncompleteOrInterrupted() {
        #expect(FocusLockService.boundedIdentityEvidenceIsComplete(
            traversalCompleted: true,
            withinDeadline: true,
            boundaryMatches: true,
            isCancelled: false
        ))
        #expect(!FocusLockService.boundedIdentityEvidenceIsComplete(
            traversalCompleted: false,
            withinDeadline: true,
            boundaryMatches: true,
            isCancelled: false
        ))
        #expect(!FocusLockService.boundedIdentityEvidenceIsComplete(
            traversalCompleted: true,
            withinDeadline: false,
            boundaryMatches: true,
            isCancelled: false
        ))
        #expect(!FocusLockService.boundedIdentityEvidenceIsComplete(
            traversalCompleted: true,
            withinDeadline: true,
            boundaryMatches: false,
            isCancelled: false
        ))
        #expect(!FocusLockService.boundedIdentityEvidenceIsComplete(
            traversalCompleted: true,
            withinDeadline: true,
            boundaryMatches: true,
            isCancelled: true
        ))

        #expect(FocusLockService.exactInputCaptureIsUsable(
            hasElement: true,
            hasIdentity: true
        ))
        #expect(!FocusLockService.exactInputCaptureIsUsable(
            hasElement: true,
            hasIdentity: false
        ))
        #expect(!FocusLockService.exactInputCaptureIsUsable(
            hasElement: false,
            hasIdentity: true
        ))

        #expect(FocusLockService.scopedRetainedWrapperMayIgnoreContextDrift(
            hasHardenedApplicationScope: true,
            captureScopeStillMatches: true
        ))
        #expect(!FocusLockService.scopedRetainedWrapperMayIgnoreContextDrift(
            hasHardenedApplicationScope: true,
            captureScopeStillMatches: false
        ))
        #expect(!FocusLockService.scopedRetainedWrapperMayIgnoreContextDrift(
            hasHardenedApplicationScope: false,
            captureScopeStillMatches: true
        ))
    }

    @MainActor
    @Test func semanticSendReadinessReresolvesUnavailableDisabledThenReadyOnce() {
        let observations: [FocusLockService.SemanticSendReadinessObservation] = [
            .unavailable,
            .disabled,
            .ready
        ]
        var actionCount = 0
        for observation in observations {
            switch FocusLockService.semanticSendReadinessDecision(
                for: observation
            ) {
            case .wait:
                break
            case .press:
                actionCount += 1
            case .stop:
                Issue.record("Readiness unexpectedly stopped before ready")
            }
        }
        #expect(actionCount == 1)
        #expect(FocusLockService.semanticSendReadinessDecision(
            for: .ambiguous
        ) == .stop)
        #expect(FocusLockService.semanticSendReadinessDecision(
            for: .cancelledOrBoundaryLost
        ) == .stop)
    }

    @MainActor
    @Test func semanticSendGeometryUsesPerSurfaceComposerBounds() {
        let editor = CGRect(x: 100, y: 100, width: 300, height: 44)
        let footerSibling = CGRect(x: 515, y: 230, width: 24, height: 24)
        let directSibling = CGRect(x: 405, y: 110, width: 24, height: 24)
        let unrelated = CGRect(x: 900, y: 900, width: 24, height: 24)
        let oversized = CGRect(x: 405, y: 110, width: 120, height: 24)

        #expect(FocusLockService.semanticSendGeometryMatches(
            surface: .openAIChatGPT,
            editorFrame: editor,
            candidateFrame: footerSibling
        ))
        #expect(!FocusLockService.semanticSendGeometryMatches(
            surface: .claudeDesktop,
            editorFrame: editor,
            candidateFrame: footerSibling
        ))
        #expect(FocusLockService.semanticSendGeometryMatches(
            surface: .claudeDesktop,
            editorFrame: editor,
            candidateFrame: directSibling
        ))
        #expect(!FocusLockService.semanticSendGeometryMatches(
            surface: .openAICodex,
            editorFrame: editor,
            candidateFrame: unrelated
        ))
        #expect(!FocusLockService.semanticSendGeometryMatches(
            surface: .openAICodex,
            editorFrame: editor,
            candidateFrame: oversized
        ))
        #expect(!FocusLockService.semanticSendGeometryMatches(
            surface: .telegramForegroundOnly,
            editorFrame: editor,
            candidateFrame: directSibling
        ))
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
            labelAttribute: "AXDescription",
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
            labelAttribute: "AXDescription",
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
            labelAttribute: "AXDescription",
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        #expect(ambiguous == .unavailable)
        #expect(wrongPID == .unavailable)
        #expect(wrongWindow == .unavailable)
        #expect(actionCount == 0)

        let identifierOnly = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: "send-button",
            labelAttribute: "AXIdentifier",
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        #expect(identifierOnly == .unavailable)
        #expect(actionCount == 0)

        let valid = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: "Send",
            labelAttribute: "AXTitle",
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        #expect(valid == .pressed)
        #expect(actionCount == 1)
    }

    @MainActor
    @Test func chromiumTraversalUsesNavigationOrderOnlyWhenOtherChildListsAreEmpty() {
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
        #expect(FocusLockService.preferredTraversalChildren(
            visible: [Int](),
            ordinary: [],
            navigationOrder: []
        ).isEmpty)
    }

    @MainActor
    @Test func auditedOpenAIBuildsMayPressOnlyTheirStillUnlabelledIdleSend() {
        #expect(FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAIChatGPT,
            applicationBundleName: "ChatGPT.app",
            marketingVersion: "26.715.21425",
            buildNumber: "5488",
            chromiumBaseVersion: "150.0.7871.124"
        ))
        #expect(!FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAIChatGPT,
            applicationBundleName: "ChatGPT.app",
            marketingVersion: "26.715.21425",
            buildNumber: "5489",
            chromiumBaseVersion: "150.0.7871.124"
        ))
        #expect(FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAIChatGPT,
            applicationBundleName: "ChatGPT.app",
            marketingVersion: "26.715.31925",
            buildNumber: "5551",
            chromiumBaseVersion: "150.0.7871.124"
        ))
        #expect(!FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAICodex,
            applicationBundleName: "Codex.app",
            marketingVersion: "26.715.21425",
            buildNumber: "5488",
            chromiumBaseVersion: "150.0.7871.124"
        ))
        #expect(FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAICodex,
            applicationBundleName: "Codex.app",
            marketingVersion: "26.707.31428",
            buildNumber: "5059",
            chromiumBaseVersion: "150.0.7871.101"
        ))
        #expect(FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAICodex,
            applicationBundleName: "Codex.app",
            marketingVersion: "26.707.72221",
            buildNumber: "5307",
            chromiumBaseVersion: "150.0.7871.115"
        ))
        #expect(!FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAICodex,
            applicationBundleName: "Codex.app",
            marketingVersion: "26.707.72221",
            buildNumber: "5308",
            chromiumBaseVersion: "150.0.7871.115"
        ))
        #expect(!FocusLockService.versionedUnlabelledOpenAISendIsAllowed(
            surface: .openAICodex,
            applicationBundleName: "Codex.app",
            marketingVersion: "26.707.31428",
            buildNumber: "5060",
            chromiumBaseVersion: "150.0.7871.101"
        ))

        var actionCount = 0
        let action = { () -> Int32 in
            actionCount += 1
            return AXError.success.rawValue
        }
        let auditedIdleSend = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: nil,
            labelAttribute: nil,
            allowsVersionedUnlabelledOpenAISend: true,
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        #expect(auditedIdleSend == .pressed)
        #expect(actionCount == 1)

        // React labels this same slot Stop as soon as a turn starts. Even if a stale
        // lookup carried the version token, the action-time label must cancel AXPress.
        let changedToStop = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: "Stop",
            labelAttribute: "AXDescription",
            allowsVersionedUnlabelledOpenAISend: true,
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        let unauditedUnlabelled = FocusLockService.performProvenSemanticSend(
            isUnambiguous: true,
            pidMatches: true,
            windowMatches: true,
            geometryMatches: true,
            roleMatches: true,
            enabled: true,
            label: nil,
            labelAttribute: nil,
            allowsVersionedUnlabelledOpenAISend: false,
            hasPressAction: true,
            boundaryMatches: true,
            action: action
        )
        #expect(changedToStop == .unavailable)
        #expect(unauditedUnlabelled == .unavailable)
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

    @MainActor
    @Test func terminalAutomationIdentityRequiresWindowAndSessionPair() {
        let contents = "distinct terminal prompt and decision content"
        let encoded = "8123\n/dev/ttys004\n2\n\(contents.count)\n\(contents)"
        #expect(FocusLockService.terminalCaptureScriptResult(encoded)
            == FocusLockService.TerminalCaptureScriptResult(
                windowID: 8123,
                sessionIdentity: "/dev/ttys004",
                windowSessionCount: 2,
                contents: contents
            ))
        #expect(FocusLockService.terminalCaptureScriptResult(
            "not-a-window\n/dev/ttys004\n2\n\(contents.count)\n\(contents)"
        ) == nil)
        #expect(FocusLockService.terminalCaptureScriptResult(
            "8123\n/dev/ttys004\n0\n\(contents.count)\n\(contents)"
        ) == nil)

        let anchors = FocusLockService.terminalContentAnchors("""
        one distinctive terminal line that identifies this session
        another distinctive terminal line for identity
        """)
        #expect(FocusLockService.terminalDecisionFingerprintMatches(
            captured: anchors,
            native: anchors + ["new output line that arrived after capture"],
            windowSessionCount: 2
        ))
        #expect(!FocusLockService.terminalDecisionFingerprintMatches(
            captured: anchors,
            native: ["different terminal session content entirely"],
            windowSessionCount: 2
        ))
        #expect(FocusLockService.terminalSelectionMultiplicityIsSafe(
            selectedControlCount: 0,
            windowSessionCount: 1
        ))
        #expect(!FocusLockService.terminalSelectionMultiplicityIsSafe(
            selectedControlCount: 0,
            windowSessionCount: 2
        ))
    }

    @MainActor
    @Test func nativeTerminalDeliveryIsSingleOperationAndPromptVerified() {
        #expect(!TranscriptionDelivery.nativeTerminalExactSessionDeliveryEnabled)
        #expect(FocusLockService.terminalTextIsSafeForSingleNativeOperation(
            "hello from VoiceInk++"
        ))
        #expect(!FocusLockService.terminalTextIsSafeForSingleNativeOperation(
            "first command\nsecond command"
        ))
        #expect(!FocusLockService.terminalTextIsSafeForSingleNativeOperation(
            "escape\u{001B}sequence"
        ))

        let previous = "ethan@mini % "
        let inserted = "echo terminal-native-test"
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: previous,
            to: previous + inserted + "\nterminal-native-test\nethan@mini % ",
            insertedText: inserted,
            autoSendEnabled: true
        ) == .verified)
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: previous,
            to: previous + inserted,
            insertedText: inserted,
            autoSendEnabled: true
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: previous,
            to: previous + inserted,
            insertedText: inserted,
            autoSendEnabled: false
        ) == .verified)
        #expect(TranscriptionDelivery.classifyNativeTerminalDelivery(
            from: previous,
            to: previous,
            insertedText: inserted,
            autoSendEnabled: true
        ) == .unchanged)
    }

    @MainActor
    @Test func nativeTerminalDeliveryNeverAcquiresPreviouslyUnownedFocus() {
        #expect(FocusLockService.terminalDeliveryFocusStayedSafe(
            targetPID: 42,
            targetWasFrontmost: false,
            targetOwnedKeyboardFocus: false,
            currentFrontmostPID: 7,
            currentKeyboardFocusPID: 8
        ))
        #expect(!FocusLockService.terminalDeliveryFocusStayedSafe(
            targetPID: 42,
            targetWasFrontmost: false,
            targetOwnedKeyboardFocus: false,
            currentFrontmostPID: 42,
            currentKeyboardFocusPID: 8
        ))
        #expect(!FocusLockService.terminalDeliveryFocusStayedSafe(
            targetPID: 42,
            targetWasFrontmost: false,
            targetOwnedKeyboardFocus: false,
            currentFrontmostPID: 7,
            currentKeyboardFocusPID: 42
        ))
        #expect(FocusLockService.terminalDeliveryFocusStayedSafe(
            targetPID: 42,
            targetWasFrontmost: true,
            targetOwnedKeyboardFocus: true,
            currentFrontmostPID: 42,
            currentKeyboardFocusPID: 42
        ))
    }

}

private actor AsyncTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
