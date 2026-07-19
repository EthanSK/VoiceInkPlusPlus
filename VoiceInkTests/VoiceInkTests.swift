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
            buildNumber: "236"
        )

        #expect(presentation.topLine == "v2.0")
        #expect(presentation.bottomLine == ".236")
        #expect(presentation.accessibilityLabel == "VoiceInk++ version 2.0, build 236")
    }

    @Test func primaryForegroundContinuityRejectsSwitchAwayAndBack() {
        let continuity = PrimaryForegroundContinuity(
            activationGeneration: 12,
            processIdentifier: 345,
            bundleIdentifier: "com.openai.codex"
        )

        #expect(continuity.isUnbroken(
            currentActivationGeneration: 12,
            currentProcessIdentifier: 345
        ))
        #expect(!continuity.isUnbroken(
            currentActivationGeneration: 13,
            currentProcessIdentifier: 345
        ))
        #expect(!continuity.isUnbroken(
            currentActivationGeneration: 12,
            currentProcessIdentifier: 678
        ))

        #expect(RecordingPasteTarget(
            destination: .focusedAtStop,
            focusedInput: nil,
            primaryForegroundContinuity: continuity
        ).primaryForegroundContinuity == continuity)
        #expect(RecordingPasteTarget(
            destination: .recordingStart,
            focusedInput: nil,
            primaryForegroundContinuity: continuity
        ).primaryForegroundContinuity == nil)
        #expect(RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            primaryForegroundContinuity: continuity
        ).primaryForegroundContinuity == nil)
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
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "Ask for follow-up changes",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .verifiedCleared)
        #expect(TranscriptionDelivery.classifyBackgroundAutoSendVerification(
            previousText: "latched transcript",
            currentText: "unrelated reset status",
            currentPlaceholder: nil
        ) == .unreadable)

        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: nil,
            currentPlaceholder: "Ask for follow-up changes"
        ) == .unreadable)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript\n",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "Ask for follow-up changes",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .verifiedCleared)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "Ask for follow-up changes",
            currentText: "Ask for follow-up changes",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .unchanged)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "latched transcript\nnew draft",
            currentPlaceholder: "Ask for follow-up changes"
        ) == .modifiedWithoutSubmit)
        #expect(TranscriptionDelivery.classifyForegroundOpenAIAutoSendVerification(
            previousText: "latched transcript",
            currentText: "unrelated reset status",
            currentPlaceholder: nil
        ) == .unreadable)

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

        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .verifiedCleared,
            exactTargetStillOwnsKeyboardFocus: false
        ) == .verified)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ) == .failed)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .modifiedWithoutSubmit,
            exactTargetStillOwnsKeyboardFocus: true
        ) == .failed)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: false
        ) == .indeterminate)
        #expect(TranscriptionDelivery.foregroundOpenAIAutoSendOutcome(
            verification: .modifiedWithoutSubmit,
            exactTargetStillOwnsKeyboardFocus: false
        ) == .indeterminate)
    }

    @MainActor
    @Test func backgroundFocusSnapshotRestoresFalseAndOmitsUnreadableValues() {
        typealias Slot = FocusLockService.BackgroundFocusBooleanSlot
        let snapshot = FocusLockService.BackgroundFocusBooleanSnapshot { slot in
            switch slot {
            case .targetWindowMain: false
            case .targetWindowFocused: false
            case .targetElementFocused: true
            case .previousWindowMain: true
            case .previousWindowFocused: true
            case .previousElementFocused: nil
            }
        }
        var restored: [Slot: Bool] = [:]

        #expect(snapshot.restore { slot, value in
            restored[slot] = value
            return true
        })
        #expect(restored[.targetWindowMain] == false)
        #expect(restored[.targetWindowFocused] == false)
        #expect(restored[.targetElementFocused] == true)
        #expect(restored[.previousWindowMain] == true)
        #expect(restored[.previousWindowFocused] == true)
        #expect(restored[.previousElementFocused] == nil)
        #expect(snapshot.matches { restored[$0] })
        #expect(!snapshot.containsAll([.previousElementFocused]))
        #expect(snapshot.missing(from: [.targetWindowMain, .previousElementFocused]) == [
            .previousElementFocused
        ])

        var restorationOrder: [Slot] = []
        #expect(snapshot.restore { slot, _ in
            restorationOrder.append(slot)
            return true
        })
        #expect(restorationOrder == [
            .targetWindowMain,
            .targetWindowFocused,
            .targetElementFocused,
            .previousWindowMain,
            .previousWindowFocused
        ])

        var attempted: [Slot] = []
        #expect(!snapshot.restore { slot, _ in
            attempted.append(slot)
            return slot != .targetWindowFocused
        })
        #expect(attempted.contains(.previousWindowFocused))
    }

    @MainActor
    @Test func backgroundFocusPreservesExplicitlyAbsentPriorEditor() {
        #expect(FocusLockService.priorFocusedElementReadIsRestorable(.value))
        #expect(FocusLockService.priorFocusedElementReadIsRestorable(.absent))
        #expect(!FocusLockService.priorFocusedElementReadIsRestorable(.failed))

        #expect(FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .absent,
            restoredElementMatchesTarget: false,
            restoredTargetFocused: nil,
            expectedTargetFocused: false
        ))
        #expect(FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .value,
            restoredElementMatchesTarget: true,
            restoredTargetFocused: false,
            expectedTargetFocused: false
        ))
        #expect(!FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .value,
            restoredElementMatchesTarget: false,
            restoredTargetFocused: false,
            expectedTargetFocused: false
        ))
        #expect(!FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .value,
            restoredElementMatchesTarget: true,
            restoredTargetFocused: true,
            expectedTargetFocused: false
        ))
        #expect(!FocusLockService.absentPriorFocusedElementRestorationMatches(
            restoredAvailability: .failed,
            restoredElementMatchesTarget: false,
            restoredTargetFocused: nil,
            expectedTargetFocused: false
        ))
    }

    @Test func cooperativeQuitIsBlockedWhileAnySessionIsInFlight() {
        #expect(AppDelegate.shouldBlockTermination(hasInFlightSessions: true))
        #expect(!AppDelegate.shouldBlockTermination(hasInFlightSessions: false))
    }

    @MainActor
    @Test func backgroundFocusSessionLifecycleIsOneShotAndOwnsPartialCleanup() {
        var lifecycle = FocusLockService.BackgroundFocusSessionLifecycle()
        var beginCount = 0
        var endCount = 0

        #expect(lifecycle.canBegin)
        let began = lifecycle.begin {
            beginCount += 1
            return true
        }
        #expect(began)
        #expect(beginCount == 1)
        #expect(!lifecycle.canBegin)
        let beganAgain = lifecycle.begin {
            beginCount += 1
            return true
        }
        #expect(!beganAgain)
        #expect(beginCount == 1)
        #expect(lifecycle.requiresTeardown)
        let scheduledRetry = lifecycle.markTeardownRetryScheduled()
        #expect(scheduledRetry)
        #expect(lifecycle.state == .teardownRetryScheduled)
        let scheduledRetryAgain = lifecycle.markTeardownRetryScheduled()
        #expect(!scheduledRetryAgain)
        let finished = lifecycle.finish { endCount += 1 }
        #expect(finished)
        #expect(endCount == 1)
        #expect(lifecycle.state == .finished)
        let finishedAgain = lifecycle.finish { endCount += 1 }
        #expect(!finishedAgain)
        #expect(endCount == 1)

        var beginFailed = FocusLockService.BackgroundFocusSessionLifecycle()
        let failedToBegin = beginFailed.begin {
            beginCount += 1
            return false
        }
        #expect(!failedToBegin)
        #expect(beginFailed.state == .ready)
        let finishedWithoutBegin = beginFailed.finish { endCount += 1 }
        #expect(!finishedWithoutBegin)
        #expect(endCount == 1)

        var waived = FocusLockService.BackgroundFocusSessionLifecycle()
        let beganWaivedSession = waived.begin { true }
        #expect(beganWaivedSession)
        let waivedSession = waived.waiveTeardown()
        #expect(waivedSession)
        #expect(waived.state == .teardownWaived)
        let finishedWaivedSession = waived.finish { endCount += 1 }
        #expect(!finishedWaivedSession)
        #expect(endCount == 1)

        var waivedAfterRetry = FocusLockService.BackgroundFocusSessionLifecycle()
        let beganRetryWaiver = waivedAfterRetry.begin { true }
        #expect(beganRetryWaiver)
        let scheduledRetryBeforeWaiver = waivedAfterRetry.markTeardownRetryScheduled()
        #expect(scheduledRetryBeforeWaiver)
        let waivedRetry = waivedAfterRetry.waiveTeardown()
        #expect(waivedRetry)
        #expect(waivedAfterRetry.state == .teardownWaived)
        let finishedRetryWaiver = waivedAfterRetry.finish { endCount += 1 }
        #expect(!finishedRetryWaiver)
        #expect(endCount == 1)
    }

    @MainActor
    @Test func backgroundTeardownDecisionCoversEveryTerminalBoundary() {
        typealias Decision = FocusLockService.BackgroundTeardownDecision
        typealias Boundary = FocusLockService.BackgroundTeardownBoundaryStatus

        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: false,
            retryCount: 0
        ) == Decision.restoreNow)
        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: false,
            retryCount: 1
        ) == Decision.restoreNow)
        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: true,
            retryCount: 0
        ) == Decision.retryFullRestoration)
        #expect(FocusLockService.backgroundTeardownDecision(
            boundary: .safe,
            restorationIncomplete: true,
            retryCount: 1
        ) == Decision.finishPartialAndEnd)

        for unavailable in [Boundary.frontmostUnavailable, .systemFocusUnavailable] {
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: unavailable,
                restorationIncomplete: false,
                retryCount: 0
            ) == Decision.retryFullRestoration)
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: unavailable,
                restorationIncomplete: false,
                retryCount: 1
            ) == Decision.waiveWithoutMutation)
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: unavailable,
                restorationIncomplete: true,
                retryCount: 1
            ) == Decision.waiveWithoutMutation)
        }

        for terminal in [Boundary.targetOwnsSystemFocus, .targetTerminated] {
            #expect(FocusLockService.backgroundTeardownDecision(
                boundary: terminal,
                restorationIncomplete: true,
                retryCount: 0
            ) == Decision.waiveWithoutMutation)
        }

        let takeover = FocusLockService.preservedBackgroundTeardownBoundary(
            current: .safe,
            observed: .targetOwnsSystemFocus
        )
        #expect(takeover == .targetOwnsSystemFocus)
        #expect(FocusLockService.preservedBackgroundTeardownBoundary(
            current: takeover,
            observed: .frontmostUnavailable
        ) == .targetOwnsSystemFocus)
        #expect(FocusLockService.preservedBackgroundTeardownBoundary(
            current: takeover,
            observed: .safe
        ) == .targetOwnsSystemFocus)
    }

    @MainActor
    @Test func failedBackgroundFocusPreparationBehaviorallyInvokesOwnedCleanup() async {
        var cleanupCount = 0
        let failed = await FocusLockService.runBackgroundPreparationWithOwnedFailureCleanup(
            prepare: { false },
            cleanup: { cleanupCount += 1 }
        )
        #expect(!failed)
        #expect(cleanupCount == 1)

        let succeeded = await FocusLockService.runBackgroundPreparationWithOwnedFailureCleanup(
            prepare: { true },
            cleanup: { cleanupCount += 1 }
        )
        #expect(succeeded)
        #expect(cleanupCount == 1)

        var lifecycle = FocusLockService.BackgroundFocusSessionLifecycle()
        var beginCount = 0
        var endCount = 0
        let failedAfterBegin = await FocusLockService.runBackgroundPreparationWithOwnedFailureCleanup(
            prepare: {
                let began = lifecycle.begin {
                    beginCount += 1
                    return true
                }
                #expect(began)
                return false
            },
            cleanup: {
                let finished = lifecycle.finish { endCount += 1 }
                #expect(finished)
            }
        )
        #expect(!failedAfterBegin)
        #expect(beginCount == 1)
        #expect(endCount == 1)
        #expect(lifecycle.state == .finished)
        let finishedAgain = lifecycle.finish { endCount += 1 }
        #expect(!finishedAgain)
        #expect(endCount == 1)
    }

    @MainActor
    @Test func unlabelledOpenAISendExceptionIsPinnedToExactAppAndBuildTuples() {
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72221",
            build: "5307",
            chromium: "150.0.7871.115"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: "150.0.7871.124"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72221",
            build: "5307",
            chromium: "150.0.7871.115"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: "150.0.7871.124"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "Codex.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.707.72222",
            build: "5308",
            chromium: "150.0.7871.115"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: nil
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.chat",
            shortVersion: "26.715.31925",
            build: "5551",
            chromium: "150.0.7871.124"
        ))

    }

    @Test func targetedOpenAISendClickIsFailClosedAndOneShot() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let delivery = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let backgroundStart = try #require(delivery.range(
            of: "    private func performBackgroundAutoSend("
        ))
        let backgroundEnd = try #require(delivery.range(
            of: "    private func waitForBackgroundInsertion(",
            range: backgroundStart.upperBound..<delivery.endIndex
        ))
        let backgroundRoute = delivery[
            backgroundStart.lowerBound..<backgroundEnd.lowerBound
        ]
        #expect(backgroundRoute.contains("case .targetedClick:"))
        #expect(backgroundRoute.contains("skyLightTargetedSendClick"))
        #expect(backgroundRoute.contains("semanticAXPress"))
        #expect(!backgroundRoute.contains("authenticatedSkyLightReturn"))
        #expect(!backgroundRoute.contains("performAuthenticatedTargetedReturn"))
        #expect(!backgroundRoute.contains("CursorPaster.performAutoSend"))

        let bridge = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Paste/SkyLightTargetedMouseEventPost.swift"
            ),
            encoding: .utf8
        )
        #expect(bridge.contains("SLEventPostToPid"))
        #expect(bridge.contains("SLEventSetIntegerValueField"))
        #expect(bridge.contains("CGEventSetWindowLocation"))
        #expect(bridge.contains("_AXUIElementGetWindow"))
        #expect(bridge.contains("clock_gettime_nsec_np(CLOCK_UPTIME_RAW)"))
        #expect(!bridge.contains("SLEventSetAuthenticationMessage"))
        #expect(!bridge.contains("event.postToPid("))
        #expect(!bridge.contains("event.post(tap:"))

        let paster = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Paste/CursorPaster.swift"
            ),
            encoding: .utf8
        )
        let primitiveStart = try #require(paster.range(
            of: "    static func performTargetedOpenAISendClick("
        ))
        let primitiveEnd = try #require(paster.range(
            of: "    @MainActor\n    private static func makeOtherEvent(",
            range: primitiveStart.upperBound..<paster.endIndex
        ))
        let primitive = paster[
            primitiveStart.lowerBound..<primitiveEnd.lowerBound
        ]
        let lastPreparation = try #require(primitive.range(
            of: "targetUp,\n                targetPID: targetPID"
        ))
        let firstPost = try #require(primitive.range(
            of: "postPreparedEvent(\n            move"
        ))
        #expect(lastPreparation.lowerBound < firstPost.lowerBound)
        #expect(primitive.contains("postPreparedEvent(\n            primerDown"))
        #expect(primitive.contains("postPreparedEvent(\n            primerUp"))
        #expect(primitive.contains("postPreparedEvent(\n            targetDown"))
        #expect(primitive.contains("postPreparedEvent(\n            targetUp"))
        #expect(!primitive.contains("performAutoSend("))
        #expect(!primitive.contains("AXUIElementPerformAction"))
        #expect(!primitive.contains("postToPid("))
        #expect(!primitive.contains("post(tap:"))
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
    @Test func CodexTraversalMergesNavigationVisibleAndOrdinaryChildren() {
        #expect(FocusLockService.mergedTraversalChildren(
            visible: [1],
            ordinary: [2],
            navigationOrder: [3],
            areEquivalent: { $0 == $1 }
        ) == [3, 1, 2])
        #expect(FocusLockService.mergedTraversalChildren(
            visible: [],
            ordinary: [2],
            navigationOrder: [3, 2],
            areEquivalent: { $0 == $1 }
        ) == [3, 2])
        #expect(FocusLockService.mergedTraversalChildren(
            visible: [2, 3],
            ordinary: [1, 3],
            navigationOrder: [3, 2],
            areEquivalent: { $0 == $1 }
        ) == [3, 2, 1])
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
        ) == .foregroundExactInput)
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
        #expect(TranscriptionDelivery.deferredForegroundAutoSendRoute(
            hasExactInput: false,
            exactInputOwnsKeyboardFocus: false,
            targetIsFrontmost: true
        ) == .foregroundExactInput)
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
        #expect(!pasteBody.contains("waitForForegroundInsertion"))
        #expect(!pasteBody.contains("Task { @MainActor in"))
    }

    @Test func foregroundAutoSendUsesImmediateOneShotHIDWithoutAXReadback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let autoSendStart = try #require(source.range(
            of: "    private func performAutoSend("
        ))
        let feedbackStart = try #require(source.range(
            of: "    private func showAutoSendFailure(",
            range: autoSendStart.upperBound..<source.endIndex
        ))
        let autoSendBody = source[autoSendStart.lowerBound..<feedbackStart.lowerBound]

        #expect(autoSendBody.contains("method: .cgEvent"))
        #expect(autoSendBody.contains("verification=notRequired"))
        #expect(autoSendBody.contains("case .actionGuardRefused:"))
        #expect(autoSendBody.contains("return .needsNonActivatingExactInput"))
        #expect(!autoSendBody.contains("focusedInputText"))
        #expect(!autoSendBody.contains("pressNearbySubmitButton"))
        #expect(!autoSendBody.contains("performAuthenticatedTargetedReturn"))
        #expect(!autoSendBody.contains("method: .systemEvents"))
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
