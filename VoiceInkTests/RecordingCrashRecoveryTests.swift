import Foundation
import SwiftData
import Testing
@testable import VoiceInkPlusPlus

@MainActor
struct RecordingCrashRecoveryTests {
    @Test func interruptedPCMIsHeaderRepairedAndRecoveredIntoPinnedHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let audioURL = fixture.recordingsDirectory.appendingPathComponent("interrupted.wav")
        try Self.writePCM16WAV(to: audioURL, payloadLength: 640, finalized: false)
        var journal = try fixture.journalStore.begin(audioURL: audioURL)
        journal.update(
            realtimeDraftText: "last visible live words",
            inputDevice: RecordingInputDeviceSnapshot(name: "Test Mic", uid: "test-mic-uid")
        )
        try fixture.journalStore.persist(journal)

        let summary = RecordingCrashRecoveryService.recoverPendingRecordings(
            modelContext: fixture.context,
            journalStore: fixture.journalStore
        )

        #expect(summary.recoveredCount == 1)
        #expect(summary.retainedForManualRecoveryCount == 0)
        #expect(fixture.journalStore.pendingJournals().isEmpty)

        let recovered = try #require(
            fixture.context.fetch(FetchDescriptor<Transcription>()).first
        )
        #expect(recovered.transcriptionStatus == TranscriptionStatus.recoveredAfterInterruption.rawValue)
        #expect(recovered.preservesOriginalAudioForRecovery)
        #expect(recovered.text == "last visible live words")
        #expect(recovered.recoverableRealtimeDraftText == "last visible live words")
        #expect(recovered.inputDeviceName == "Test Mic")
        #expect(recovered.inputDeviceUID == "test-mic-uid")
        #expect(recovered.duration == 0.02)

        let repaired = try Data(contentsOf: audioURL)
        #expect(Self.uint32LE(repaired, at: 4) == UInt32(repaired.count - 8))
        #expect(Self.uint32LE(repaired, at: 40) == 640)
    }

    @Test func emptyInterruptedCaptureCreatesReplayOnlyRecoveryRow() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let audioURL = fixture.recordingsDirectory.appendingPathComponent("empty-draft.wav")
        try Self.writePCM16WAV(to: audioURL, payloadLength: 320, finalized: false)
        _ = try fixture.journalStore.begin(audioURL: audioURL)

        let summary = RecordingCrashRecoveryService.recoverPendingRecordings(
            modelContext: fixture.context,
            journalStore: fixture.journalStore
        )

        #expect(summary.recoveredCount == 1)
        let recovered = try #require(
            fixture.context.fetch(FetchDescriptor<Transcription>()).first
        )
        #expect(recovered.preservesOriginalAudioForRecovery)
        #expect(recovered.transcriptionStatus == TranscriptionStatus.recoveredAfterInterruption.rawValue)
        #expect(recovered.recoverableRealtimeDraftText == nil)
        #expect(recovered.text.contains("replay or retranscribe"))
    }

    @Test func malformedJournaledAudioIsRetainedWithoutCreatingOrDeletingHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let audioURL = fixture.recordingsDirectory.appendingPathComponent("unknown-layout.wav")
        try Data("not a RIFF file".utf8).write(to: audioURL)
        _ = try fixture.journalStore.begin(audioURL: audioURL)

        let summary = RecordingCrashRecoveryService.recoverPendingRecordings(
            modelContext: fixture.context,
            journalStore: fixture.journalStore
        )

        #expect(summary.recoveredCount == 0)
        #expect(summary.retainedForManualRecoveryCount == 1)
        #expect(FileManager.default.fileExists(atPath: audioURL.path))
        #expect(fixture.journalStore.pendingJournals().count == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Transcription>()) == 0)
    }

    @Test func staleJournalForPersistedHistoryIsRemovedWithoutDuplicateRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let audioURL = fixture.recordingsDirectory.appendingPathComponent("already-owned.wav")
        try Self.writePCM16WAV(to: audioURL, payloadLength: 320, finalized: true)
        _ = try fixture.journalStore.begin(audioURL: audioURL)
        fixture.context.insert(
            Transcription(
                text: "normal stop saved this first",
                duration: 0.01,
                audioFileURL: audioURL.absoluteString,
                transcriptionStatus: .completed
            )
        )
        try fixture.context.save()

        let summary = RecordingCrashRecoveryService.recoverPendingRecordings(
            modelContext: fixture.context,
            journalStore: fixture.journalStore
        )

        #expect(summary.recoveredCount == 0)
        #expect(fixture.journalStore.pendingJournals().isEmpty)
        #expect(try fixture.context.fetchCount(FetchDescriptor<Transcription>()) == 1)
    }

    @Test func recoveryImplementationIsHistoryOnlyAndNeverReusesDestinationDelivery() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("VoiceInk/Services/RecordingCrashRecoveryService.swift"),
            encoding: .utf8
        )

        #expect(source.contains("never paste, submit, or recreate a live route"))
        #expect(source.contains("preservesOriginalAudioForRecovery: true"))
        #expect(source.contains("transcriptionStatus: .recoveredAfterInterruption"))
        #expect(!source.contains("FocusLockService"))
        #expect(!source.contains("TranscriptionDelivery"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func writePCM16WAV(
        to url: URL,
        payloadLength: Int,
        finalized: Bool
    ) throws {
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt32LE(16_000, to: &data)
        appendUInt32LE(32_000, to: &data)
        appendUInt16LE(2, to: &data)
        appendUInt16LE(16, to: &data)
        data.append(contentsOf: "data".utf8)
        appendUInt32LE(finalized ? UInt32(payloadLength) : 0, to: &data)
        data.append(Data(repeating: 0x21, count: payloadLength))
        if finalized {
            writeUInt32LE(UInt32(data.count - 8), into: &data, at: 4)
        }
        try data.write(to: url)
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func writeUInt32LE(_ value: UInt32, into data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private final class Fixture {
        let root: URL
        let recordingsDirectory: URL
        let journalStore: RecordingRecoveryJournalStore
        let container: ModelContainer
        let context: ModelContext

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("VoiceInkCrashRecoveryTests-\(UUID().uuidString)")
            recordingsDirectory = root.appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(
                at: recordingsDirectory,
                withIntermediateDirectories: true
            )
            journalStore = RecordingRecoveryJournalStore(
                directory: root.appendingPathComponent("RecordingRecovery")
            )
            let schema = Schema([Transcription.self])
            let configuration = ModelConfiguration(
                "RecordingCrashRecoveryTests-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true
            )
            container = try ModelContainer(for: schema, configurations: configuration)
            context = ModelContext(container)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
