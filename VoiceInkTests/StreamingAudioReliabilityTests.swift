import Dispatch
import Foundation
import os
import Testing
@testable import VoiceInkPlusPlus

struct StreamingAudioReliabilityTests {
    private final class LockedValues<Value>: @unchecked Sendable {
        private let storage: OSAllocatedUnfairLock<Value>

        init(_ value: Value) {
            storage = OSAllocatedUnfairLock(initialState: value)
        }

        func update(_ operation: (inout Value) -> Void) {
            storage.withLock(operation)
        }

        func read() -> Value {
            storage.withLock { $0 }
        }
    }

    @Test func startupAudioReplayCannotBeOvertakenByALiveChunk() {
        let router = RecordingStartupAudioRouter()
        router.receive(Data([1]))

        let replayStarted = DispatchSemaphore(value: 0)
        let allowReplayToFinish = DispatchSemaphore(value: 0)
        let activationFinished = DispatchSemaphore(value: 0)
        let liveChunkFinished = DispatchSemaphore(value: 0)
        let received = LockedValues<[UInt8]>([])
        let activationResult = LockedValues<RecordingStartupAudioRouter.ActivationResult?>(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = router.activate { data in
                if data.first == 1 {
                    replayStarted.signal()
                    allowReplayToFinish.wait()
                }
                if let byte = data.first {
                    received.update { $0.append(byte) }
                }
            }
            activationResult.update { $0 = result }
            activationFinished.signal()
        }

        #expect(replayStarted.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global(qos: .userInitiated).async {
            router.receive(Data([2]))
            liveChunkFinished.signal()
        }

        // The new live chunk is blocked behind replay rather than overtaking it.
        #expect(liveChunkFinished.wait(timeout: .now() + 0.05) == .timedOut)
        allowReplayToFinish.signal()
        #expect(activationFinished.wait(timeout: .now() + 1) == .success)
        #expect(liveChunkFinished.wait(timeout: .now() + 1) == .success)
        #expect(received.read() == [1, 2])
        #expect(
            activationResult.read()
                == .connected(replayedChunks: 1, replayedBytes: 1)
        )
    }

    @Test func boundedStartupAudioForcesCompleteWAVFallbackInsteadOfDroppingAHead() {
        let router = RecordingStartupAudioRouter(maximumBufferedBytes: 4)
        router.receive(Data([1, 2, 3]))
        router.receive(Data([4, 5, 6]))
        var delivered: [Data] = []

        let result = router.activate { delivered.append($0) }

        #expect(
            result == .fallbackRequired(droppedChunks: 2, droppedBytes: 6)
        )
        #expect(delivered.isEmpty)
        router.receive(Data([7]))
        #expect(delivered.isEmpty)
    }

    @Test func liveSocketBufferIsByteBoundedAndReportsOverflow() async throws {
        let source = AudioChunkSource(maximumBufferedBytes: 4)
        #expect(source.send(Data([1, 2, 3])))
        #expect(!source.send(Data([4, 5, 6])))

        var iterator = source.stream.makeAsyncIterator()
        let next = await iterator.next()
        let first = try #require(next)
        #expect(first == Data([1, 2, 3]))
        source.didDequeue(first.count)
        #expect(source.send(Data([4, 5, 6])))
        source.finish()
    }

    @Test @MainActor func streamingDrainWaitHasARealTimeout() async {
        let (neverFinishes, continuation) = AsyncStream.makeStream(of: Void.self)
        let clock = ContinuousClock()
        let start = clock.now

        let completed = await StreamingTranscriptionService.waitForSendLoopCompletion(
            neverFinishes,
            timeoutNanoseconds: 20_000_000
        )

        continuation.finish()
        #expect(!completed)
        #expect(start.duration(to: clock.now) < .seconds(1))
    }

    @Test func streamingAudioCompletenessRejectsAnyMissingOrTimedOutPCM() {
        let complete = StreamingAudioMetricsSnapshot(
            receivedChunks: 2,
            receivedBytes: 8,
            sentChunks: 2,
            sentBytes: 8,
            droppedChunks: 0,
            droppedBytes: 0,
            drainTimedOut: false
        )
        let dropped = StreamingAudioMetricsSnapshot(
            receivedChunks: 2,
            receivedBytes: 8,
            sentChunks: 1,
            sentBytes: 4,
            droppedChunks: 1,
            droppedBytes: 4,
            drainTimedOut: false
        )
        let timedOut = StreamingAudioMetricsSnapshot(
            receivedChunks: 2,
            receivedBytes: 8,
            sentChunks: 1,
            sentBytes: 4,
            droppedChunks: 0,
            droppedBytes: 0,
            drainTimedOut: true
        )

        #expect(complete.isComplete)
        #expect(!dropped.isComplete)
        #expect(!timedOut.isComplete)
        #expect(
            StreamingFinalTextDisposition.resolve(
                "plausible but incomplete words",
                audioWasComplete: false
            ) == .useBatchFallback
        )
        #expect(
            StreamingFinalTextDisposition.resolve(
                "complete words",
                audioWasComplete: true
            ) == .deliver("complete words")
        )
    }

    @Test func recorderKeepsTheFinalWAVAndRealtimeChunkSinksAligned() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("VoiceInk/Recorder.swift"),
            encoding: .utf8
        )

        let stopGeneration = try #require(source.range(of: "let callbackGenerationAtStop = audioChunkGeneration"))
        let hardwareStop = try #require(source.range(of: "currentRecorder?.stopRecording()", range: stopGeneration.lowerBound..<source.endIndex))
        let guardedClear = try #require(source.range(of: "if audioChunkGeneration == callbackGenerationAtStop", range: hardwareStop.lowerBound..<source.endIndex))
        #expect(stopGeneration.lowerBound < hardwareStop.lowerBound)
        #expect(hardwareStop.lowerBound < guardedClear.lowerBound)

        let capturedStartCallback = try #require(source.range(of: "let callbackForThisStart = onAudioChunk"))
        let queuedStart = try #require(source.range(of: "audioSetupQueue.async", range: capturedStartCallback.lowerBound..<source.endIndex))
        let installedStartCallback = try #require(source.range(of: "coreAudioRecorder.onAudioChunk = callbackForThisStart", range: queuedStart.lowerBound..<source.endIndex))
        #expect(capturedStartCallback.lowerBound < queuedStart.lowerBound)
        #expect(queuedStart.lowerBound < installedStartCallback.lowerBound)
        #expect(source.contains("if activeHardwareStopCount == 0"))
    }

    @Test func startupAudioAccountingAndFallbackHUDRemainHonest() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let streaming = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Streaming/StreamingTranscriptionService.swift"
            ),
            encoding: .utf8
        )
        // The callback can receive startup PCM before the provider connection task runs.
        // A later reset would erase only the received side while the queued chunks remain.
        #expect(!streaming.contains("metrics.reset()"))

        let engine = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "VoiceInk/Transcription/Engine/VoiceInkEngine.swift"
            ),
            encoding: .utf8
        )
        let overflowStart = try #require(engine.range(of: "case .fallbackRequired"))
        let closedStart = try #require(
            engine.range(of: "case .closed:", range: overflowStart.upperBound..<engine.endIndex)
        )
        let nilCallbackStart = try #require(
            engine.range(of: "} else {", range: closedStart.upperBound..<engine.endIndex)
        )
        let overflowBranch = engine[overflowStart.lowerBound..<closedStart.lowerBound]
        let closedBranch = engine[closedStart.lowerBound..<nilCallbackStart.lowerBound]
        #expect(overflowBranch.contains("session.showsRealtimeTranscriptHUD = false"))
        #expect(closedBranch.contains("session.showsRealtimeTranscriptHUD = false"))
        // Exactly three abandon branches must collapse the realtime HUD: startup
        // overflow, a closed router, and a streaming session with no callback. A tail
        // search was too broad and could pass because of an unrelated later occurrence.
        #expect(
            engine.components(
                separatedBy: "session.showsRealtimeTranscriptHUD = false"
            ).count == 4
        )
    }
}
