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
    @Test func pendingPasteTargetCanChangeUntilDeliveryResolvesIt() {
        let session = RecordingSession()
        let retargeted = RecordingPasteTarget(
            destination: .focusedDuringTranscription,
            focusedInput: nil
        )

        #expect(session.retargetPaste(to: retargeted))
        #expect(session.resolvePasteTargetForDelivery().destination == .focusedDuringTranscription)
        #expect(!session.retargetPaste(to: RecordingPasteTarget(destination: .recordingStart, focusedInput: nil)))
        #expect(session.pasteTarget.destination == .focusedDuringTranscription)
    }

}
