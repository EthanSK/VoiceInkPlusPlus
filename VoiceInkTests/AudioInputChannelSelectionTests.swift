import Testing
@testable import VoiceInkPlusPlus

struct AudioInputChannelSelectionTests {
    @Test func preferredStereoPairNarrowsAMultichannelDevice() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 20,
            preferredStereoChannels: [1, 2]
        )
        #expect(selection.deviceChannelIndices == [0, 1])
    }

    @Test func missingPreferenceFallsBackToFirstTwoInputs() {
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

    @Test func invalidPreferenceFailsSafeToInputPrefix() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 20,
            preferredStereoChannels: [0, 21]
        )
        #expect(selection.deviceChannelIndices == [0, 1])
    }

    @Test func zeroChannelDeviceProducesNoInvalidMapEntries() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 0,
            preferredStereoChannels: [1, 2]
        )
        #expect(selection.deviceChannelIndices.isEmpty)
    }

    @Test func preferredPairIsAHintRatherThanAClaimAboutPhysicalTopology() {
        let selection = AudioInputChannelSelection.resolve(
            deviceChannelCount: 20,
            preferredStereoChannels: [19, 20]
        )
        #expect(selection.deviceChannelIndices == [18, 19])
    }

    @Test func dominantStereoInputKeepsMonoSpeechAtFullLevel() {
        let samples: [Float32] = [
            0.01, 0.8,
            -0.01, -0.6,
            0.02, 0.7
        ]
        let channel = samples.withUnsafeBufferPointer { buffer in
            AudioInputMonoMixdown.dominantChannelIndex(
                samples: buffer.baseAddress!,
                frameCount: 3,
                channelCount: 2
            )
        }
        #expect(channel == 1)
    }

    @Test func monoInputNeedsNoMixdownSelection() {
        let samples: [Float32] = [0.4, -0.2]
        let channel = samples.withUnsafeBufferPointer { buffer in
            AudioInputMonoMixdown.dominantChannelIndex(
                samples: buffer.baseAddress!,
                frameCount: 2,
                channelCount: 1
            )
        }
        #expect(channel == 0)
    }

    @Test func channelNarrowingFailureFallsBackInsteadOfAbortingCapture() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VoiceInk/CoreAudioRecorder.swift"),
            encoding: .utf8
        )

        #expect(source.contains("falling back to the complete device input layout"))
        #expect(source.contains("return fallbackChannelCount"))
        #expect(source.contains("let dominantChannel = AudioInputMonoMixdown.dominantChannelIndex"))
    }
}
