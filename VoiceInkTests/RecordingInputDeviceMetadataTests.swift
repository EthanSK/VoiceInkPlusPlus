import CoreAudio
import Foundation
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

struct RecordingInputDeviceMetadataTests {
    @Test func snapshotUsesTheExactResolvedCoreAudioDevice() throws {
        let devices: [(id: AudioDeviceID, uid: String, name: String)] = [
            (11, "BuiltInMicrophoneDevice", "MacBook Pro Microphone"),
            (107, "focusrite-stable-uid", "Scarlett 18i8 USB")
        ]

        let snapshot = try #require(RecordingInputDeviceSnapshot(
            deviceID: 107,
            availableDevices: devices
        ))

        #expect(snapshot.name == "Scarlett 18i8 USB")
        #expect(snapshot.uid == "focusrite-stable-uid")
        #expect(RecordingInputDeviceSnapshot(
            deviceID: 999,
            availableDevices: devices
        ) == nil)
        #expect(RecordingInputDeviceSnapshot(name: " ", uid: "missing-name") == nil)
        #expect(RecordingInputDeviceSnapshot(name: "Missing UID", uid: "\n") == nil)
    }

    @Test @MainActor func snapshotPersistsThroughHistoryAndSessionMetrics() throws {
        let schema = Schema([Transcription.self, SessionMetric.self])
        let configuration = ModelConfiguration(
            "RecordingInputDevicePersistenceTest",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let snapshot = try #require(RecordingInputDeviceSnapshot(
            name: "Scarlett 18i8 USB",
            uid: "focusrite-stable-uid"
        ))
        let transcription = Transcription(
            text: "device lineage test",
            duration: 3.5,
            recordingInputDevice: snapshot,
            transcriptionModelName: "Test model",
            transcriptionDuration: 1.0,
            transcriptionStatus: .completed
        )

        context.insert(transcription)
        try context.save()
        #expect(try SessionMetricRecorder.recordRecorderSession(
            transcription: transcription,
            model: nil,
            in: context
        ))
        try context.save()

        let persistedTranscription = try #require(
            context.fetch(FetchDescriptor<Transcription>()).first
        )
        let persistedMetric = try #require(
            context.fetch(FetchDescriptor<SessionMetric>()).first
        )
        #expect(persistedTranscription.inputDeviceName == "Scarlett 18i8 USB")
        #expect(persistedTranscription.inputDeviceUID == "focusrite-stable-uid")
        #expect(persistedMetric.inputDeviceName == "Scarlett 18i8 USB")
        #expect(persistedMetric.inputDeviceUID == "focusrite-stable-uid")

        // Optional fields are the migration boundary for existing History rows.
        let legacy = Transcription(text: "pre-device-metadata row", duration: 1)
        #expect(legacy.inputDeviceName == nil)
        #expect(legacy.inputDeviceUID == nil)
    }

    @Test func enginePersistsTheStartTimeDeviceForNormalAndCanceledRecordings() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("VoiceInk/Transcription/Engine/VoiceInkEngine.swift"),
            encoding: .utf8
        )

        #expect(source.contains(
            "session.recordingInputDevice = try await self.recorder.startRecording("
        ))
        #expect(source.contains(
            "recordingInputDevice: active.recordingInputDevice"
        ))
        #expect(source.contains(
            "recordingInputDevice: session.recordingInputDevice"
        ))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
