import Testing
@testable import VoiceInkPlusPlus

struct AudioInputChannelSelectionTests {
    @Test func preferredPhysicalInputsExcludeLoopbackChannels() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 20,
            preferredStereoChannels: [1, 2]
        )
        #expect(selection.deviceChannelIndices == [0, 1])
    }

    @Test func missingPreferenceFallsBackToFirstTwoPhysicalInputs() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 20,
            preferredStereoChannels: nil
        )
        #expect(selection.deviceChannelIndices == [0, 1])
    }

    @Test func monoDeviceDoesNotDuplicateItsOnlyInput() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 1,
            preferredStereoChannels: [1, 1]
        )
        #expect(selection.deviceChannelIndices == [0])
    }

    @Test func invalidPreferenceFailsSafeToPhysicalInputPrefix() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 20,
            preferredStereoChannels: [0, 21]
        )
        #expect(selection.deviceChannelIndices == [0, 1])
    }
}
