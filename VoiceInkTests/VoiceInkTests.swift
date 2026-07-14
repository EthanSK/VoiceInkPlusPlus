//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInkPlusPlus

struct VoiceInkTests {

    @MainActor
    @Test func secondChanceRetargetCarriesAutoSendUntilDeliveryResolvesIt() {
        let session = RecordingSession()
        let retargeted = RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil,
            autoSendKey: .enter
        )

        #expect(session.retargetPaste(to: retargeted))
        let resolvedTarget = session.resolvePasteTargetForDelivery()
        #expect(resolvedTarget.destination == .focusedDuringTranscription)
        #expect(resolvedTarget.autoSendKey == .enter)
        #expect(!session.retargetPaste(to: RecordingPasteTarget(destination: .recordingStart, focusedInput: nil)))
        #expect(session.pasteTarget.destination == .focusedDuringTranscription)
    }

}
