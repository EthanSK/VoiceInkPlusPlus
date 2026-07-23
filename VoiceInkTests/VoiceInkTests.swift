//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ApplicationServices
@testable import VoiceInkPlusPlus

private actor TranscriptionQueueTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class TranscriptionQueueTestState {
    var currentIdentities = Set<TranscriptionJobIdentity>()
    var events: [String] = []
}

struct VoiceInkTests {

    @Test func primaryModifierChordSuppressesOnlyTheCompletedPress() {
        let shortcut = Shortcut.modifierOnly(
            keyCode: nil,
            modifierFlags: [.shift, .control, .option]
        )

        let partialShift = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Shift),
            modifierFlags: [.shift]
        )
        #expect(partialShift == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))

        let partialControl = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Control),
            modifierFlags: [.shift, .control]
        )
        #expect(partialControl == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))

        let completedPress = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.shift, .control, .option]
        )
        #expect(completedPress == .init(
            isDown: true,
            suppressDownstream: true,
            dispatchKeyDown: true,
            dispatchKeyUp: false
        ))

        let completedRepeat = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: true,
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.shift, .control, .option]
        )
        #expect(completedRepeat == .init(
            isDown: true,
            suppressDownstream: true,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))

        let firstRelease = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: true,
            keyCode: UInt16(kVK_Option),
            modifierFlags: [.shift, .control]
        )
        #expect(firstRelease == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: true
        ))

        let remainingRelease = ShortcutMonitor.modifierOnlySequenceTransition(
            shortcut: shortcut,
            wasDown: false,
            keyCode: UInt16(kVK_Control),
            modifierFlags: [.shift]
        )
        #expect(remainingRelease == .init(
            isDown: false,
            suppressDownstream: false,
            dispatchKeyDown: false,
            dispatchKeyUp: false
        ))
    }

    @Test func recordingStartReservationRejectsDuplicatePendingStarts() {
        var reservation = RecordingStartReservation()
        let first = UUID()
        let second = UUID()

        #expect(reservation.reserve(id: first) == first)
        #expect(reservation.reserve(id: second) == nil)
        let consumedWrongReservation = reservation.consume(second)
        #expect(!consumedWrongReservation)
        let consumedFirstReservation = reservation.consume(first)
        #expect(consumedFirstReservation)
        #expect(reservation.reserve(id: second) == second)

        reservation.invalidate()
        #expect(reservation.pendingID == nil)
    }

    @Test func transcriptionJobRegistryBindsUniqueSessionTranscriptionAndAudio() throws {
        var registry = TranscriptionJobRegistry()
        let sessionA = UUID()
        let transcriptionA = UUID()
        let audioA = URL(fileURLWithPath: "/tmp/session-a.wav")
        let registeredA = registry.register(
            recordingSessionID: sessionA,
            transcriptionID: transcriptionA,
            audioURL: audioA
        )
        let identityA = try #require(registeredA)

        #expect(identityA.enqueueSequence == 1)
        #expect(registry.contains(identityA))
        let duplicateSession = registry.register(
            recordingSessionID: sessionA,
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/other.wav")
        )
        #expect(duplicateSession == nil)
        let duplicateTranscription = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: transcriptionA,
            audioURL: URL(fileURLWithPath: "/tmp/other.wav")
        )
        #expect(duplicateTranscription == nil)
        let duplicateAudio = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: audioA
        )
        #expect(duplicateAudio == nil)

        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        #expect(identityB.enqueueSequence == 2)
        #expect(identityB.recordingSessionID != identityA.recordingSessionID)
        #expect(identityB.transcriptionID != identityA.transcriptionID)
        #expect(identityB.audioURL != identityA.audioURL)
    }

    @Test func transcriptionJobRegistryResetInvalidatesOnlyOldGeneration() throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)

        registry.invalidateAll()
        #expect(!registry.contains(identityA))

        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        #expect(identityB.generation == identityA.generation + 1)
        #expect(identityB.enqueueSequence == identityA.enqueueSequence + 1)
        #expect(registry.contains(identityB))
    }

    @MainActor
    @Test func serialQueueKeepsInjectedResultsBoundToFIFOJobIdentity() async throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)
        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        let injectedResults = [
            identityA.transcriptionID: "result-a",
            identityB.transcriptionID: "result-b",
        ]
        let state = TranscriptionQueueTestState()
        state.currentIdentities = [identityA, identityB]
        let queue = SerialTranscriptionJobQueue()

        for identity in [identityA, identityB] {
            queue.enqueue(
                identity,
                isCurrent: { state.currentIdentities.contains($0) },
                onDiscard: { discarded in
                    state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
                },
                operation: { running in
                    let result = injectedResults[running.transcriptionID] ?? "missing"
                    state.events.append("\(running.audioURL.lastPathComponent):\(result)")
                }
            )
        }

        await queue.waitUntilIdle()
        #expect(state.events == [
            "session-a.wav:result-a",
            "session-b.wav:result-b",
        ])
    }

    @MainActor
    @Test func resetCannotResumeAWaitingJobOrAuthorizeRunningJobDelivery() async throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)
        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        let state = TranscriptionQueueTestState()
        state.currentIdentities = [identityA, identityB]
        let gate = TranscriptionQueueTestGate()
        let queue = SerialTranscriptionJobQueue()

        queue.enqueue(
            identityA,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("start:\(running.audioURL.lastPathComponent)")
                await gate.wait()
                if !Task.isCancelled, state.currentIdentities.contains(running) {
                    state.events.append("deliver:\(running.audioURL.lastPathComponent)")
                }
            }
        )
        queue.enqueue(
            identityB,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("deliver:\(running.audioURL.lastPathComponent)")
            }
        )

        while state.events.isEmpty {
            await Task.yield()
        }
        state.currentIdentities.removeAll()
        let canceledTasks = queue.cancelAll()
        await gate.open()
        for task in canceledTasks {
            await task.value
        }

        #expect(state.events.contains("start:session-a.wav"))
        #expect(!state.events.contains("deliver:session-a.wav"))
        #expect(!state.events.contains("deliver:session-b.wav"))
    }

    @MainActor
    @Test func newGenerationWaitsForCanceledRunningJobToUnwind() async throws {
        var registry = TranscriptionJobRegistry()
        let registeredA = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-a.wav")
        )
        let identityA = try #require(registeredA)
        let state = TranscriptionQueueTestState()
        state.currentIdentities = [identityA]
        let gate = TranscriptionQueueTestGate()
        let queue = SerialTranscriptionJobQueue()

        queue.enqueue(
            identityA,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("start:\(running.audioURL.lastPathComponent)")
                await gate.wait()
                state.events.append("unwind:\(running.audioURL.lastPathComponent)")
            }
        )

        while state.events.isEmpty {
            await Task.yield()
        }

        registry.invalidateAll()
        state.currentIdentities.removeAll()
        _ = queue.cancelAll()

        let registeredB = registry.register(
            recordingSessionID: UUID(),
            transcriptionID: UUID(),
            audioURL: URL(fileURLWithPath: "/tmp/session-b.wav")
        )
        let identityB = try #require(registeredB)
        state.currentIdentities.insert(identityB)
        queue.enqueue(
            identityB,
            isCurrent: { state.currentIdentities.contains($0) },
            onDiscard: { discarded in
                state.events.append("discard:\(discarded.audioURL.lastPathComponent)")
            },
            operation: { running in
                state.events.append("start:\(running.audioURL.lastPathComponent)")
            }
        )

        // B must remain behind the reset barrier while canceled A is still unwinding.
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(state.events == ["start:session-a.wav"])

        await gate.open()
        await queue.waitUntilIdle()
        #expect(state.events == [
            "start:session-a.wav",
            "unwind:session-a.wav",
            "start:session-b.wav",
        ])
    }

    @Test func transcriptionLineageDigestDistinguishesResultsWithoutContainingText() {
        let first = TranscriptionLineageDigest.make("first private transcript")
        let second = TranscriptionLineageDigest.make("second private transcript")

        #expect(first.count == 16)
        #expect(second.count == 16)
        #expect(first != second)
        #expect(!first.contains("first"))
        #expect(!second.contains("second"))
    }

    @Test func sharedTranscriptionResourcesCannotCrossLiveSessionBoundaries() {
        #expect(SharedTranscriptionResourcePolicy.allowsSpeculativePreload(liveSessionCount: 1))
        #expect(!SharedTranscriptionResourcePolicy.allowsSpeculativePreload(liveSessionCount: 2))

        #expect(SharedTranscriptionResourcePolicy.allowsCleanup(
            liveSessionCount: 0,
            retiringOwnerIsCurrent: true
        ))
        #expect(!SharedTranscriptionResourcePolicy.allowsCleanup(
            liveSessionCount: 1,
            retiringOwnerIsCurrent: true
        ))
        #expect(!SharedTranscriptionResourcePolicy.allowsCleanup(
            liveSessionCount: 0,
            retiringOwnerIsCurrent: false
        ))
    }

    @Test func recorderVersionSplitsMarketingAndBuildAcrossTwoRows() {
        let presentation = RecorderVersionPresentation(
            marketingVersion: "2.0",
            buildNumber: "236"
        )

        #expect(presentation.topLine == "v2.0")
        #expect(presentation.bottomLine == ".236")
        #expect(presentation.accessibilityLabel == "VoiceInk++ version 2.0, build 236")
    }

    @MainActor
    @Test func primaryCurrentInputStructurallyRejectsExactDeliveryState() {
        let accidentalDestinationMode = ModeConfig(
            name: "Must be discarded",
            isAIEnhancementEnabled: false,
            outputMode: .paste,
            autoSendKey: .enter
        )
        let primary = RecordingPasteTarget(
            destination: .primaryCurrentInput,
            focusedInput: nil,
            mode: accidentalDestinationMode
        )

        #expect(RecordingPasteDestination.primaryCurrentInput.usesBaseCurrentInputDelivery)
        #expect(!RecordingPasteDestination.primaryCurrentInput.usesAppSpecificExactDelivery)
        #expect(RecordingPasteDestination.recordingStart.usesAppSpecificExactDelivery)
        #expect(RecordingPasteDestination.focusedDuringTranscription.usesAppSpecificExactDelivery)
        #expect(primary.focusedInput == nil)
        #expect(primary.mode == nil)
        #expect(primary.resolvedAutoSendKey(currentInputKey: .commandEnter) == AutoSendKey.commandEnter)

        let latched = RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            mode: accidentalDestinationMode
        )
        #expect(latched.mode == accidentalDestinationMode)
        #expect(latched.resolvedAutoSendKey(currentInputKey: .shiftEnter) == AutoSendKey.enter)
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
        ) == .modifiedWithoutSubmit)
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

        #expect(TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter,
            verification: .modifiedWithoutSubmit,
            exactTargetStillOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: false
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "ru.keepcoder.Telegram",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .shiftEnter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
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
    @Test func telegramRetainedInputRequiresReadableMatchingChatAndInternalFocus() {
        let captured = [
            "VoiceInk Telegram disposable context anchor",
            "Saved Messages stable disposable context"
        ]
        #expect(FocusLockService.isTelegram(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(!FocusLockService.isTelegram(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: captured,
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: [],
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: ["Different disposable chat"],
            internalFocusMatches: true,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: captured,
            internalFocusMatches: false,
            structureMatches: true
        ))
        #expect(!FocusLockService.telegramRetainedInputAllowed(
            capturedContextAnchors: captured,
            currentContextAnchors: captured,
            internalFocusMatches: true,
            structureMatches: false
        ))
    }

    @MainActor
    @Test func telegramParentlessComposerRequiresOneEnclosingWindow() {
        let composer = CGRect(x: 120, y: 740, width: 540, height: 52)
        #expect(FocusLockService.uniqueContainingWindowIndex(
            elementFrame: composer,
            windowFrames: [
                CGRect(x: 900, y: 50, width: 60, height: 20),
                CGRect(x: 80, y: 100, width: 650, height: 760)
            ]
        ) == 1)
        #expect(FocusLockService.uniqueContainingWindowIndex(
            elementFrame: composer,
            windowFrames: [
                CGRect(x: 80, y: 100, width: 650, height: 760),
                CGRect(x: 100, y: 700, width: 600, height: 100)
            ]
        ) == nil)
        #expect(FocusLockService.uniqueContainingWindowIndex(
            elementFrame: composer,
            windowFrames: [nil, CGRect(x: 0, y: 0, width: 40, height: 40)]
        ) == nil)
    }

    @MainActor
    @Test func nextTrackNeverPassesThroughWhileRecorderPanelIsVisible() {
        #expect(RecordingShortcutManager
            .shouldConsumeNextTrackWithoutEligibleRoute(
                isRecorderPanelVisible: true
            ))
        #expect(!RecordingShortcutManager
            .shouldConsumeNextTrackWithoutEligibleRoute(
                isRecorderPanelVisible: false
            ))
    }

    @Test func telegramVisualIdentityPinsTupleCropAndStableDigest() {
        let tuple = TelegramWindowVisualIdentity.ApplicationTuple(
            applicationBundleName: "Telegram.app",
            bundleIdentifier: "ru.keepcoder.Telegram",
            shortVersion: "12.9",
            build: "282526"
        )
        #expect(TelegramWindowVisualIdentityService.isAudited(tuple))
        #expect(TelegramWindowVisualIdentityService.pixelCropRect(
            imageWidth: 407,
            imageHeight: 997
        ) == CGRect(x: 48, y: 34, width: 262, height: 66))
        #expect(TelegramWindowVisualIdentityService.pixelStableChatIdentityRect(
            imageWidth: 262,
            imageHeight: 66
        ) == CGRect(x: 141, y: 22, width: 116, height: 35))

        let stable = TelegramWindowVisualIdentityService.HeaderDigestSample(
            width: 407,
            height: 997,
            digest: Data([1, 2, 3, 4]),
            stableChatIdentityDigest: Data([5, 6, 7, 8])
        )
        let identity = TelegramWindowVisualIdentityService.stableIdentity(
            applicationTuple: tuple,
            processIdentifier: 737,
            windowID: 244,
            first: stable,
            second: stable
        )
        #expect(identity?.windowID == 244)
        #expect(identity?.headerDigest == stable.digest)
        #expect(identity?.stableChatIdentityDigest == stable.stableChatIdentityDigest)

        // Dynamic status pixels may change while the exact avatar/title row remains
        // identical. This is the Telegram v2.0.245 false-rejection regression.
        #expect(TelegramWindowVisualIdentityService.stableIdentity(
            applicationTuple: tuple,
            processIdentifier: 737,
            windowID: 244,
            first: stable,
            second: .init(
                width: 407,
                height: 997,
                digest: Data([9, 9, 9, 9]),
                stableChatIdentityDigest: stable.stableChatIdentityDigest
            )
        ) != nil)

        #expect(TelegramWindowVisualIdentityService.stableIdentity(
            applicationTuple: tuple,
            processIdentifier: 737,
            windowID: 244,
            first: stable,
            second: .init(
                width: 407,
                height: 997,
                digest: Data([9, 9, 9, 9]),
                stableChatIdentityDigest: Data([8, 7, 6, 5])
            )
        ) == nil)
        #expect(!TelegramWindowVisualIdentityService.isAudited(.init(
            applicationBundleName: "Telegram.app",
            bundleIdentifier: "ru.keepcoder.Telegram",
            shortVersion: "12.10",
            build: "282527"
        )))
    }

    @MainActor
    @Test func telegramAccessibilityInsertionFallbackIsOneShot() async {
        var accessibilityAttempts = 0
        var unicodeAttempts = 0
        var accessibilityErrors: [Int32] = []

        let fallbackSucceeded = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                allowsTargetedUnicodeFallback: true,
                attemptAccessibility: {
                    accessibilityAttempts += 1
                    return .unavailable
                },
                fullBoundaryMatches: { true },
                targetedUnicode: { boundary in
                    unicodeAttempts += 1
                    return boundary()
                }
            )
        #expect(fallbackSucceeded)
        #expect(accessibilityAttempts == 1)
        #expect(unicodeAttempts == 1)

        let setterErrorWasNotRetried = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                allowsTargetedUnicodeFallback: true,
                attemptAccessibility: {
                    accessibilityAttempts += 1
                    return .failed(AXError.cannotComplete.rawValue)
                },
                fullBoundaryMatches: { true },
                onAccessibilityError: { accessibilityErrors.append($0) },
                targetedUnicode: { _ in
                    unicodeAttempts += 1
                    return true
                }
            )
        #expect(setterErrorWasNotRetried)
        #expect(accessibilityAttempts == 2)
        #expect(unicodeAttempts == 1)
        #expect(accessibilityErrors == [AXError.cannotComplete.rawValue])

        let directExactInputFailedClosed = await TranscriptionDelivery
            .executeAccessibilityFirstBackgroundInsertion(
                allowsTargetedUnicodeFallback: false,
                attemptAccessibility: { .unavailable },
                fullBoundaryMatches: { true },
                targetedUnicode: { _ in
                    unicodeAttempts += 1
                    return true
                }
            )
        #expect(!directExactInputFailedClosed)
        #expect(unicodeAttempts == 1)
    }

    @MainActor
    @Test func telegramIsAChatComposerButNeverAnOpenAIReturnRetry() {
        #expect(TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "ru.keepcoder.Telegram"
        ))
        #expect(TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "com.openai.codex"
        ))
        #expect(!TranscriptionDelivery.isChatComposer(
            bundleIdentifier: "com.apple.Terminal"
        ))
        #expect(!TranscriptionDelivery.shouldRetryForegroundOpenAIReturn(
            bundleIdentifier: "ru.keepcoder.Telegram",
            autoSendKey: .enter,
            verification: .unchanged,
            exactTargetStillOwnsKeyboardFocus: true
        ))
    }

    @Test func telegramRetainedSessionNeverWritesAXFocusPointers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Modes/FocusLockService.swift"
            ),
            encoding: .utf8
        )
        let prepareStart = try #require(source.range(
            of: "    private func prepareRetainedTelegramBackgroundDelivery("
        ))
        let prepareEnd = try #require(source.range(
            of: "    static func runBackgroundPreparationWithOwnedFailureCleanup(",
            range: prepareStart.upperBound..<source.endIndex
        ))
        let prepareBody = source[
            prepareStart.lowerBound..<prepareEnd.lowerBound
        ]
        #expect(prepareBody.contains("CursorPaster.beginTargetedInputSession"))
        #expect(prepareBody.contains("telegramDeliveryBoundaryMatches"))
        #expect(!prepareBody.contains("AXUIElementSetAttributeValue"))

        let finishStart = try #require(source.range(
            of: "    private func finishRetainedTelegramBackgroundDelivery("
        ))
        let finishEnd = try #require(source.range(
            of: "    func finishBackgroundDelivery(",
            range: finishStart.upperBound..<source.endIndex
        ))
        let finishBody = source[
            finishStart.lowerBound..<finishEnd.lowerBound
        ]
        #expect(finishBody.contains("CursorPaster.endTargetedInputSession"))
        #expect(!finishBody.contains("AXUIElementSetAttributeValue"))
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
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.52143",
            build: "5591",
            chromium: "150.0.7871.124"
        ))
        #expect(FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.70719",
            build: "5650",
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
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.52143",
            build: "5592",
            chromium: "150.0.7871.124"
        ))
        #expect(!FocusLockService.isAuditedOpenAISubmitBuild(
            applicationBundleName: "ChatGPT.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "26.715.70719",
            build: "5651",
            chromium: "150.0.7871.124"
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
        #expect(backgroundRoute.contains("telegramTargetedHIDReturn"))
        #expect(backgroundRoute.contains("performTargetedTelegramHIDReturn"))
        #expect(backgroundRoute.contains(
            "revalidateTelegramVisualIdentityIfRequired"
        ))
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
        #expect(primitive.contains("postPreparedEvent(\n                primerDown"))
        #expect(primitive.contains("postPreparedEvent(\n            primerUp"))
        #expect(primitive.contains("postPreparedEvent(\n            targetDown"))
        #expect(primitive.contains("postPreparedEvent(\n            targetUp"))
        #expect(!primitive.contains("performAutoSend("))
        #expect(!primitive.contains("AXUIElementPerformAction"))
        #expect(!primitive.contains("postToPid("))
        #expect(!primitive.contains("post(tap:"))
    }

    @Test func targetedTelegramHIDReturnMatchesProvenPublicSequence() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paster = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Paste/CursorPaster.swift"
            ),
            encoding: .utf8
        )
        let primitiveStart = try #require(paster.range(
            of: "    static func performTargetedTelegramHIDReturn("
        ))
        let primitiveEnd = try #require(paster.range(
            of: "    // MARK: - Auto Send Keys",
            range: primitiveStart.upperBound..<paster.endIndex
        ))
        let primitive = paster[
            primitiveStart.lowerBound..<primitiveEnd.lowerBound
        ]

        #expect(primitive.contains(
            "CGEventSource(stateID: .hidSystemState)"
        ))
        #expect(primitive.contains("modifiersBegan.type = .flagsChanged"))
        #expect(primitive.contains("keyDown.postToPid(targetPID)"))
        #expect(primitive.contains("keyUp.postToPid(targetPID)"))
        #expect(primitive.contains("modifiersEnded.type = .flagsChanged"))
        #expect(primitive.contains(
            "CGEventSource.flagsState(.combinedSessionState)"
        ))
        #expect(primitive.contains("modifiersEnded.postToPid(targetPID)"))
        #expect(primitive.contains("mach_absolute_time()"))
        #expect(primitive.contains("guard canPost() else"))
        #expect(!primitive.contains("post(tap:"))
        #expect(!primitive.contains("await wait"))
        #expect(!primitive.contains("SLEvent"))
        #expect(!primitive.contains("beginTargetedInputSession"))
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

    @Test func primaryDeliveryUsesOnlyBaseVoiceInkSystemFocusedCommands() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deliverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let primaryStart = try #require(deliverySource.range(
            of: "    private func deliverPrimaryToCurrentSystemInput("
        ))
        let pasteStart = try #require(deliverySource.range(of: "    private func paste("))
        let backgroundStart = try #require(deliverySource.range(
            of: "    private func deliverToBackgroundExactInput(",
            range: primaryStart.upperBound..<deliverySource.endIndex
        ))
        let pasteBody = deliverySource[pasteStart.lowerBound..<primaryStart.lowerBound]
        #expect(pasteBody.contains("if target.destination.usesBaseCurrentInputDelivery"))
        #expect(pasteBody.contains("await deliverPrimaryToCurrentSystemInput("))
        #expect(pasteBody.contains("target.destination.usesAppSpecificExactDelivery"))
        let primaryRoute = try #require(pasteBody.range(
            of: "if target.destination.usesBaseCurrentInputDelivery"
        ))
        let exactRoute = try #require(pasteBody.range(
            of: "target.destination.usesAppSpecificExactDelivery"
        ))
        #expect(primaryRoute.lowerBound < exactRoute.lowerBound)

        let primaryBody = deliverySource[
            primaryStart.lowerBound..<backgroundStart.lowerBound
        ]

        #expect(primaryBody.contains("startPasteAtCursor(pastedText)"))
        #expect(primaryBody.contains("method: .cgEvent"))
        #expect(primaryBody.contains("verification=notRequired"))
        #expect(!primaryBody.contains("focusedInput"))
        #expect(!primaryBody.contains("foregroundAutoSendMethod"))
        #expect(!primaryBody.contains("await performAutoSend("))
        #expect(!primaryBody.contains("prepareBackgroundDelivery"))
        #expect(!primaryBody.contains("deliverToBackgroundExactInput"))
        #expect(!primaryBody.contains("verifyAndRetry"))
        #expect(!primaryBody.contains("Telegram"))
        #expect(!primaryBody.contains("pressNearbySubmitButton"))
        #expect(!primaryBody.contains("foregroundOpenAIVerificationContext"))

        let engineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
            ),
            encoding: .utf8
        )
        let primaryStopStart = try #require(engineSource.range(
            of: "            case .primaryCurrentInput:"
        ))
        let secondChanceStart = try #require(engineSource.range(
            of: "            case .focusedDuringTranscription:",
            range: primaryStopStart.upperBound..<engineSource.endIndex
        ))
        let primaryStopBody = engineSource[
            primaryStopStart.lowerBound..<secondChanceStart.lowerBound
        ]
        #expect(primaryStopBody.contains("focusedInput: nil"))
        #expect(!primaryStopBody.contains("captureFocusedInput"))
        #expect(!primaryStopBody.contains("modeSnapshot"))
        #expect(!primaryStopBody.contains("Telegram"))

        let pipelineSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionPipeline.swift"
            ),
            encoding: .utf8
        )
        #expect(pipelineSource.contains(
            "pasteTargetForDelivery.resolvedAutoSendKey("
        ))
    }

    @MainActor
    @Test func exactForegroundAutoSendUsesSurfaceSpecificHandlingAndBoundsHIDRetry() throws {
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .enter
        ) == .systemEvents)
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "com.openai.chat",
            autoSendKey: .enter
        ) == .systemEvents)
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "ru.keepcoder.Telegram",
            autoSendKey: .enter
        ) == .cgEvent)
        #expect(TranscriptionDelivery.foregroundAutoSendMethod(
            bundleIdentifier: "com.openai.codex",
            autoSendKey: .shiftEnter
        ) == .cgEvent)

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

        #expect(autoSendBody.contains("foregroundAutoSendMethod"))
        #expect(autoSendBody.contains("method: sendMethod"))
        #expect(autoSendBody.contains("verification=pending"))
        #expect(autoSendBody.contains("verifyAndRetryForegroundOpenAIReturn"))
        #expect(autoSendBody.contains("case .actionGuardRefused:"))
        #expect(autoSendBody.contains("return .needsNonActivatingExactInput"))
        #expect(autoSendBody.contains("foregroundOpenAIVerificationContext"))
        #expect(!autoSendBody.contains("pressNearbySubmitButton"))
        #expect(!autoSendBody.contains("performAuthenticatedTargetedReturn"))
        #expect(autoSendBody.contains("method: .cgEvent"))
    }

    @Test func autoSendFailureWarningStaysVisibleButSilent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deliverySource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/TranscriptionDelivery.swift"
            ),
            encoding: .utf8
        )
        let failureStart = try #require(deliverySource.range(
            of: "    private func showAutoSendFailure("
        ))
        let nextFunction = try #require(deliverySource.range(
            of: "    private func handleMissingPasteTarget(",
            range: failureStart.upperBound..<deliverySource.endIndex
        ))
        let failureBody = deliverySource[
            failureStart.lowerBound..<nextFunction.lowerBound
        ]

        #expect(failureBody.contains("type: .error"))
        #expect(failureBody.contains("playSound: false"))

        let notificationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Notifications/NotificationManager.swift"
            ),
            encoding: .utf8
        )
        #expect(notificationSource.contains("playSound: Bool = true"))
        #expect(notificationSource.contains("if type == .error && playSound"))
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

        session.signalDestinationAction(.primaryCurrentInput)
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
