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
    @Test func pasteDestinationCanToggleUntilDeliveryResolvesIt() {
        let session = RecordingSession()

        #expect(session.toggleRecordingStartInputMode() == true)
        #expect(session.toggleRecordingStartInputMode() == false)
        #expect(session.toggleRecordingStartInputMode() == true)
        #expect(session.resolvePasteTargetForDelivery().destination == .recordingStart)
        #expect(session.toggleRecordingStartInputMode() == nil)
        #expect(session.useRecordingStartInput)
    }

    @MainActor
    @Test func recordingStopInputIsTheDefaultPasteDestination() {
        let session = RecordingSession()

        #expect(session.resolvePasteTargetForDelivery().destination == .focusedAtStop)
    }

}
